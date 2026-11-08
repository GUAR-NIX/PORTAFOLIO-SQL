/* =====================================================================
   04_hecho_particionado.sql
   Tabla de hechos particionada por mes con índice columnstore agrupado,
   tabla de cuarentena y reglas de calidad (como datos).

   Partición: RANGE RIGHT sobre fecha_key (AAAAMMDD) con un límite por mes.
     p1  < 20240101                (vacía: permite el MERGE de la ventana deslizante)
     p2  [20240101, 20240201)      enero 2024
     ...
     p13 [20241201, 20250101)      diciembre 2024
     p14 >= 20250101               (vacía: el SPLIT del mes nuevo es solo metadatos)
   Mantener vacías las dos puntas es lo que hace que SPLIT y MERGE no muevan datos.
   ===================================================================== */
USE TaxisNYC;
GO

IF NOT EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = N'pf_mes')
    CREATE PARTITION FUNCTION pf_mes (INT) AS RANGE RIGHT FOR VALUES
        (20240101, 20240201, 20240301, 20240401, 20240501, 20240601, 20240701,
         20240801, 20240901, 20241001, 20241101, 20241201, 20250101);
GO
IF NOT EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name = N'ps_mes')
    CREATE PARTITION SCHEME ps_mes AS PARTITION pf_mes ALL TO ([PRIMARY]);
GO

/* Grano: un viaje. Sin claves foráneas declaradas: el SWITCH de particiones exige que la
   tabla de trabajo sea idéntica y las FK solo lo complicarían. La integridad referencial
   la verifica qa.sp_validar_calidad después de cada carga. */
IF OBJECT_ID(N'dw.fact_viaje') IS NULL
BEGIN
    CREATE TABLE dw.fact_viaje (
        fecha_key           INT          NOT NULL,   -- fecha de recogida (clave de partición)
        hora                TINYINT      NOT NULL,   -- hora de recogida
        recogida            DATETIME2(0) NOT NULL,
        llegada             DATETIME2(0) NOT NULL,
        duracion_seg        INT          NOT NULL,
        proveedor_id        TINYINT      NOT NULL,
        tarifa_id           TINYINT      NOT NULL,   -- RatecodeID (nulo → 0)
        tipo_pago_id        TINYINT      NOT NULL,
        zona_origen_id      SMALLINT     NOT NULL,
        zona_destino_id     SMALLINT     NOT NULL,
        pasajeros           TINYINT      NULL,       -- nulo en los registros de tarifa flexible
        distancia_millas    DECIMAL(9,2) NOT NULL,
        tarifa_base         DECIMAL(9,2) NOT NULL,
        extra               DECIMAL(9,2) NOT NULL,
        impuesto_mta        DECIMAL(9,2) NOT NULL,
        propina             DECIMAL(9,2) NOT NULL,
        peajes              DECIMAL(9,2) NOT NULL,
        recargo_mejora      DECIMAL(9,2) NOT NULL,
        recargo_congestion  DECIMAL(9,2) NOT NULL,
        cargo_aeropuerto    DECIMAL(9,2) NOT NULL,
        total               DECIMAL(9,2) NOT NULL,
        envio_diferido      BIT          NULL,       -- store_and_fwd_flag = 'Y'
        fila_origen         INT          NOT NULL,   -- linaje: fila del Parquet del mes
        carga_id            INT          NOT NULL    -- qa.auditoria_carga
    ) ON ps_mes (fecha_key);

    -- ORDER (recogida): cada segmento cubre un rango de fechas estrecho → eliminación de segmentos
    CREATE CLUSTERED COLUMNSTORE INDEX cci_fact_viaje ON dw.fact_viaje ORDER (recogida) ON ps_mes (fecha_key);
END;
GO

/* Reglas de calidad como datos: el orden decide qué motivo recibe un viaje que rompe varias */
IF OBJECT_ID(N'qa.regla_calidad') IS NULL
BEGIN
    CREATE TABLE qa.regla_calidad (
        codigo       CHAR(3)        NOT NULL CONSTRAINT pk_regla_calidad PRIMARY KEY,
        orden        TINYINT        NOT NULL,
        nombre       NVARCHAR(40)   NOT NULL,
        descripcion  NVARCHAR(300)  NOT NULL,
        umbral       DECIMAL(12,2)  NULL,
        umbral_2     DECIMAL(12,2)  NULL
    );
    INSERT INTO qa.regla_calidad VALUES
        ('R01', 1, N'Fecha fuera del periodo', N'La recogida no cae en el mes del archivo (hay fechas de 2002, 2008 y 2026)', NULL, NULL),
        ('R02', 2, N'Duración no positiva', N'La llegada es igual o anterior a la recogida', NULL, NULL),
        ('R03', 3, N'Duración excesiva', N'El viaje dura más de umbral horas (taxímetro que no se detuvo)', 6, NULL),
        ('R04', 4, N'Importe negativo', N'Tarifa base o total negativos: reversos de disputas y anulaciones, no viajes', NULL, NULL),
        ('R05', 5, N'Distancia imposible', N'Distancia negativa o mayor a umbral millas', 200, NULL),
        ('R06', 6, N'Velocidad imposible', N'Velocidad media mayor a umbral mph', 80, NULL),
        ('R07', 7, N'Tarifa imposible', N'Tarifa base mayor a umbral USD, o mayor a umbral_2 USD con menos de 2 millas', 1000, 250),
        ('R08', 8, N'Zona inválida', N'Zona de origen o destino fuera del catálogo (1–265) o nula', NULL, NULL),
        ('R09', 9, N'Campo obligatorio nulo', N'Fecha, proveedor, tipo de pago o importes nulos', NULL, NULL);
END;
GO

/* Cuarentena: los viajes que no pasan las reglas se guardan completos (valores originales),
   con la regla que los detuvo. Nada se borra: archivo = hecho + cuarentena, mes a mes. */
IF OBJECT_ID(N'qa.cuarentena_viaje') IS NULL
    CREATE TABLE qa.cuarentena_viaje (
        periodo             CHAR(7)       NOT NULL,
        fila_origen         INT           NOT NULL,
        regla               CHAR(3)       NOT NULL,
        carga_id            INT           NOT NULL,
        vendor_id           INT           NULL,
        recogida            DATETIME2(0)  NULL,
        llegada             DATETIME2(0)  NULL,
        pasajeros           INT           NULL,
        distancia_millas    DECIMAL(12,2) NULL,
        ratecode_id         INT           NULL,
        zona_origen_id      INT           NULL,
        zona_destino_id     INT           NULL,
        tipo_pago_id        INT           NULL,
        tarifa_base         DECIMAL(12,2) NULL,
        propina             DECIMAL(12,2) NULL,
        total               DECIMAL(12,2) NULL,
        CONSTRAINT pk_cuarentena_viaje PRIMARY KEY (periodo, fila_origen) WITH (DATA_COMPRESSION = PAGE)
    );
GO

/* Clasifica cada viaje del staging con la primera regla que rompe (NULL = pasa).
   Una sola definición la usan la cuarentena y el hecho, así nunca divergen. */
CREATE OR ALTER FUNCTION etl.fn_viajes_clasificados (@inicio DATETIME2(0), @fin DATETIME2(0))
RETURNS TABLE
AS
RETURN
    WITH u AS (
        SELECT MAX(CASE codigo WHEN 'R03' THEN umbral END) * 3600 AS seg_max,
               MAX(CASE codigo WHEN 'R05' THEN umbral END)        AS millas_max,
               MAX(CASE codigo WHEN 'R06' THEN umbral END)        AS mph_max,
               MAX(CASE codigo WHEN 'R07' THEN umbral END)        AS tarifa_max,
               MAX(CASE codigo WHEN 'R07' THEN umbral_2 END)      AS tarifa_max_corta
        FROM qa.regla_calidad
    )
    SELECT s.*, d.duracion_seg,
           CAST(CASE
                WHEN s.recogida IS NULL OR s.recogida < @inicio OR s.recogida >= @fin        THEN 'R01'
                WHEN s.llegada IS NULL OR s.llegada <= s.recogida                           THEN 'R02'
                WHEN d.duracion_seg > u.seg_max                                             THEN 'R03'
                WHEN s.tarifa_base < 0 OR s.total < 0                                       THEN 'R04'
                WHEN s.distancia_millas < 0 OR s.distancia_millas > u.millas_max            THEN 'R05'
                WHEN s.distancia_millas * 3600.0 / d.duracion_seg > u.mph_max               THEN 'R06'
                WHEN s.tarifa_base > u.tarifa_max
                     OR (s.tarifa_base > u.tarifa_max_corta AND s.distancia_millas < 2)     THEN 'R07'
                WHEN s.zona_origen_id IS NULL OR s.zona_origen_id NOT BETWEEN 1 AND 265
                     OR s.zona_destino_id IS NULL OR s.zona_destino_id NOT BETWEEN 1 AND 265 THEN 'R08'
                WHEN s.vendor_id IS NULL OR s.tipo_pago_id IS NULL OR s.distancia_millas IS NULL
                     OR s.tarifa_base IS NULL OR s.propina IS NULL OR s.total IS NULL        THEN 'R09'
           END AS CHAR(3)) AS regla
    FROM stg.viaje AS s
    CROSS JOIN u
    CROSS APPLY (SELECT DATEDIFF_BIG(SECOND, s.recogida, s.llegada) AS duracion_seg) AS d;
GO
