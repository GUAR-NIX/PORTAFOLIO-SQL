/* =====================================================================
   03_dimensiones.sql
   Dimensiones del modelo estrella: fecha, hora, zona, proveedor, tipo de pago y tarifa.

   Las claves son los códigos naturales de la TLC (smallint/tinyint): el hecho de
   ~40 M filas no necesita claves sustitutas y así el linaje con la fuente es directo.
   Si llega un código que el diccionario no documenta, la carga lo agrega como
   "miembro inferido" (etl.sp_agregar_miembros_inferidos) en lugar de perder el viaje.
   ===================================================================== */
USE TaxisNYC;
GO

/* ---------- Fecha (2024–2025: el año analizado + margen para la ventana deslizante) ---------- */
IF OBJECT_ID(N'dw.dim_fecha') IS NULL
    CREATE TABLE dw.dim_fecha (
        fecha_key         INT          NOT NULL CONSTRAINT pk_dim_fecha PRIMARY KEY,  -- AAAAMMDD
        fecha             DATE         NOT NULL,
        anio              SMALLINT     NOT NULL,
        trimestre         TINYINT      NOT NULL,
        mes               TINYINT      NOT NULL,
        nombre_mes        NVARCHAR(12) NOT NULL,
        mes_corto         NCHAR(3)     NOT NULL,
        periodo           CHAR(7)      NOT NULL,   -- '2024-01' (mismo formato que la auditoría)
        dia               TINYINT      NOT NULL,
        dia_semana        TINYINT      NOT NULL,   -- 1 = lunes … 7 = domingo (independiente de DATEFIRST)
        nombre_dia        NVARCHAR(10) NOT NULL,
        semana_iso        TINYINT      NOT NULL,
        es_fin_de_semana  BIT          NOT NULL,
        es_feriado        BIT          NOT NULL,
        feriado           NVARCHAR(60) NULL
    );
GO

IF NOT EXISTS (SELECT 1 FROM dw.dim_fecha)
BEGIN
    DECLARE @feriados TABLE (fecha DATE PRIMARY KEY, nombre NVARCHAR(60));
    INSERT INTO @feriados VALUES   -- feriados federales de EE. UU. (los que cambian la demanda de taxis)
        ('2024-01-01', N'Año Nuevo'), ('2024-01-15', N'Día de Martin Luther King Jr.'),
        ('2024-02-19', N'Día de los Presidentes'), ('2024-05-27', N'Memorial Day'),
        ('2024-06-19', N'Juneteenth'), ('2024-07-04', N'Día de la Independencia'),
        ('2024-09-02', N'Día del Trabajo'), ('2024-10-14', N'Día de la Raza / Pueblos Indígenas'),
        ('2024-11-11', N'Día de los Veteranos'), ('2024-11-28', N'Acción de Gracias'),
        ('2024-12-25', N'Navidad'), ('2025-01-01', N'Año Nuevo'), ('2025-01-20', N'Día de Martin Luther King Jr.'),
        ('2025-02-17', N'Día de los Presidentes'), ('2025-05-26', N'Memorial Day'),
        ('2025-06-19', N'Juneteenth'), ('2025-07-04', N'Día de la Independencia'),
        ('2025-09-01', N'Día del Trabajo'), ('2025-10-13', N'Día de la Raza / Pueblos Indígenas'),
        ('2025-11-11', N'Día de los Veteranos'), ('2025-11-27', N'Acción de Gracias'), ('2025-12-25', N'Navidad');

    WITH n AS (SELECT TOP (731) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
               FROM sys.all_objects a CROSS JOIN sys.all_objects b),
    d AS (SELECT DATEADD(DAY, i, CAST('2024-01-01' AS DATE)) AS fecha FROM n)
    INSERT INTO dw.dim_fecha
    SELECT CONVERT(INT, CONVERT(CHAR(8), d.fecha, 112)), d.fecha, YEAR(d.fecha), DATEPART(QUARTER, d.fecha),
           MONTH(d.fecha),
           CHOOSE(MONTH(d.fecha), N'enero', N'febrero', N'marzo', N'abril', N'mayo', N'junio', N'julio',
                  N'agosto', N'septiembre', N'octubre', N'noviembre', N'diciembre'),
           CHOOSE(MONTH(d.fecha), N'ene', N'feb', N'mar', N'abr', N'may', N'jun', N'jul', N'ago', N'sep',
                  N'oct', N'nov', N'dic'),
           CONVERT(CHAR(7), d.fecha, 126), DAY(d.fecha), ds.dia_semana,
           CHOOSE(ds.dia_semana, N'lunes', N'martes', N'miércoles', N'jueves', N'viernes', N'sábado', N'domingo'),
           DATEPART(ISO_WEEK, d.fecha), IIF(ds.dia_semana >= 6, 1, 0), IIF(f.fecha IS NULL, 0, 1), f.nombre
    FROM d
    CROSS APPLY (SELECT DATEDIFF(DAY, '19000101', d.fecha) % 7 + 1 AS dia_semana) AS ds  -- 1900-01-01 fue lunes
    LEFT JOIN @feriados AS f ON f.fecha = d.fecha;
END;
GO

/* ---------- Hora del día ---------- */
IF OBJECT_ID(N'dw.dim_hora') IS NULL
BEGIN
    CREATE TABLE dw.dim_hora (
        hora        TINYINT      NOT NULL CONSTRAINT pk_dim_hora PRIMARY KEY,
        etiqueta    CHAR(5)      NOT NULL,       -- '07:00'
        franja      NVARCHAR(20) NOT NULL,
        orden_franja TINYINT     NOT NULL
    );
    INSERT INTO dw.dim_hora
    SELECT h, FORMAT(h, '00') + ':00',
           CASE WHEN h < 6 THEN N'Madrugada' WHEN h < 10 THEN N'Pico mañana' WHEN h < 16 THEN N'Mediodía'
                WHEN h < 20 THEN N'Pico tarde' ELSE N'Noche' END,
           CASE WHEN h < 6 THEN 1 WHEN h < 10 THEN 2 WHEN h < 16 THEN 3 WHEN h < 20 THEN 4 ELSE 5 END
    FROM (SELECT TOP (24) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS TINYINT) AS h
          FROM sys.all_objects) AS x;
END;
GO

/* ---------- Zonas de taxi (265, del archivo taxi_zone_lookup.csv) ---------- */
IF OBJECT_ID(N'dw.dim_zona') IS NULL
    CREATE TABLE dw.dim_zona (
        zona_id        SMALLINT      NOT NULL CONSTRAINT pk_dim_zona PRIMARY KEY,
        distrito       NVARCHAR(30)  NOT NULL,   -- Borough
        zona           NVARCHAR(100) NOT NULL,
        zona_servicio  NVARCHAR(30)  NOT NULL,   -- Yellow Zone, Boro Zone, Airports, EWR
        es_aeropuerto  BIT           NOT NULL,
        aeropuerto     NVARCHAR(12)  NULL,       -- JFK · LaGuardia · Newark
        es_inferida    BIT           NOT NULL CONSTRAINT df_dim_zona_inferida DEFAULT 0
    );
GO

CREATE OR ALTER PROCEDURE etl.sp_cargar_zonas
    @carpeta_datos NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE stg.zona;
    DECLARE @sql NVARCHAR(MAX) = N'BULK INSERT stg.zona FROM '''
        + REPLACE(@carpeta_datos, N'''', N'''''') + N'\raw\taxi_zone_lookup.csv'''
        + N' WITH (FORMAT = ''CSV'', FIRSTROW = 2, CODEPAGE = ''65001'', ROWTERMINATOR = ''0x0d0a'', TABLOCK);';
    EXEC (@sql);

    MERGE dw.dim_zona AS d
    USING (
        SELECT CAST(location_id AS SMALLINT) AS zona_id,
               CASE borough WHEN N'Unknown' THEN N'Desconocido' WHEN N'N/A' THEN N'Fuera de NYC'
                            ELSE ISNULL(borough, N'Desconocido') END AS distrito,
               CASE zone WHEN N'N/A' THEN N'Desconocida' ELSE ISNULL(zone, N'Desconocida') END AS zona,
               CASE service_zone WHEN N'N/A' THEN N'Sin zona' ELSE ISNULL(service_zone, N'Sin zona') END AS zona_servicio,
               CASE location_id WHEN N'1' THEN N'Newark' WHEN N'132' THEN N'JFK' WHEN N'138' THEN N'LaGuardia' END
                   AS aeropuerto
        FROM stg.zona
    ) AS o
    ON d.zona_id = o.zona_id
    WHEN MATCHED THEN UPDATE SET distrito = o.distrito, zona = o.zona, zona_servicio = o.zona_servicio,
        es_aeropuerto = IIF(o.aeropuerto IS NULL, 0, 1), aeropuerto = o.aeropuerto, es_inferida = 0
    WHEN NOT MATCHED THEN INSERT (zona_id, distrito, zona, zona_servicio, es_aeropuerto, aeropuerto)
        VALUES (o.zona_id, o.distrito, o.zona, o.zona_servicio, IIF(o.aeropuerto IS NULL, 0, 1), o.aeropuerto);

    PRINT CONCAT(N'Zonas: ', @@ROWCOUNT);
END;
GO

/* ---------- Catálogos del diccionario de datos de la TLC (versión 2024) ---------- */
IF OBJECT_ID(N'dw.dim_proveedor') IS NULL
BEGIN
    CREATE TABLE dw.dim_proveedor (
        proveedor_id  TINYINT       NOT NULL CONSTRAINT pk_dim_proveedor PRIMARY KEY,
        proveedor     NVARCHAR(60)  NOT NULL,
        es_inferido   BIT           NOT NULL CONSTRAINT df_dim_proveedor_inferido DEFAULT 0
    );
    INSERT INTO dw.dim_proveedor (proveedor_id, proveedor) VALUES
        (1, N'Creative Mobile Technologies'), (2, N'Curb Mobility'),
        (6, N'Myle Technologies'), (7, N'Helix');
END;
GO

IF OBJECT_ID(N'dw.dim_tipo_pago') IS NULL
BEGIN
    CREATE TABLE dw.dim_tipo_pago (
        tipo_pago_id      TINYINT      NOT NULL CONSTRAINT pk_dim_tipo_pago PRIMARY KEY,
        tipo_pago         NVARCHAR(40) NOT NULL,
        registra_propina  BIT          NOT NULL,   -- solo la tarjeta registra la propina en el taxímetro
        es_inferido       BIT          NOT NULL CONSTRAINT df_dim_tipo_pago_inferido DEFAULT 0
    );
    INSERT INTO dw.dim_tipo_pago (tipo_pago_id, tipo_pago, registra_propina) VALUES
        (0, N'Tarifa flexible (sin código)', 0), (1, N'Tarjeta de crédito', 1), (2, N'Efectivo', 0),
        (3, N'Sin cargo', 0), (4, N'Disputa', 0), (5, N'Desconocido', 0), (6, N'Viaje anulado', 0);
END;
GO

IF OBJECT_ID(N'dw.dim_tarifa') IS NULL
BEGIN
    CREATE TABLE dw.dim_tarifa (
        tarifa_id     TINYINT      NOT NULL CONSTRAINT pk_dim_tarifa PRIMARY KEY,   -- RatecodeID
        tarifa        NVARCHAR(40) NOT NULL,
        es_inferida   BIT          NOT NULL CONSTRAINT df_dim_tarifa_inferida DEFAULT 0
    );
    INSERT INTO dw.dim_tarifa (tarifa_id, tarifa) VALUES
        (0, N'Sin código (registro nulo)'), (1, N'Estándar (taxímetro)'), (2, N'JFK (tarifa fija)'),
        (3, N'Newark'), (4, N'Nassau o Westchester'), (5, N'Negociada'), (6, N'Viaje compartido'),
        (99, N'Desconocida');
END;
GO

/* Códigos que aparecen en el mes cargado y no están en el diccionario: se agregan marcados como inferidos */
CREATE OR ALTER PROCEDURE etl.sp_agregar_miembros_inferidos
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dw.dim_proveedor (proveedor_id, proveedor, es_inferido)
    SELECT DISTINCT s.vendor_id, CONCAT(N'Proveedor ', s.vendor_id, N' (no documentado)'), 1
    FROM stg.viaje AS s
    WHERE s.vendor_id BETWEEN 0 AND 255
      AND NOT EXISTS (SELECT 1 FROM dw.dim_proveedor AS d WHERE d.proveedor_id = s.vendor_id);

    INSERT INTO dw.dim_tipo_pago (tipo_pago_id, tipo_pago, registra_propina, es_inferido)
    SELECT DISTINCT s.tipo_pago_id, CONCAT(N'Pago ', s.tipo_pago_id, N' (no documentado)'), 0, 1
    FROM stg.viaje AS s
    WHERE s.tipo_pago_id BETWEEN 0 AND 255
      AND NOT EXISTS (SELECT 1 FROM dw.dim_tipo_pago AS d WHERE d.tipo_pago_id = s.tipo_pago_id);

    INSERT INTO dw.dim_tarifa (tarifa_id, tarifa, es_inferida)
    SELECT DISTINCT s.ratecode_id, CONCAT(N'Tarifa ', s.ratecode_id, N' (no documentada)'), 1
    FROM stg.viaje AS s
    WHERE s.ratecode_id BETWEEN 0 AND 255
      AND NOT EXISTS (SELECT 1 FROM dw.dim_tarifa AS d WHERE d.tarifa_id = s.ratecode_id);
END;
GO
