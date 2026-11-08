/* =====================================================================
   04_modelo_estrella.sql — Modelo dimensional en estrella (dw)
   ===================================================================== */
USE CitiBikeTuning;
GO

CREATE TABLE dw.dim_fecha
(
    fecha_key           INT          NOT NULL PRIMARY KEY, -- YYYYMMDD
    fecha               DATE         NOT NULL UNIQUE,
    anio                SMALLINT     NOT NULL,
    trimestre           TINYINT      NOT NULL,
    mes                 TINYINT      NOT NULL,
    nombre_mes          NVARCHAR(20) NOT NULL,
    dia_mes             TINYINT      NOT NULL,
    dia_semana          TINYINT      NOT NULL,
    nombre_dia          NVARCHAR(20) NOT NULL,
    es_fin_de_semana    BIT          NOT NULL,
    estacion_climatica  NVARCHAR(20) NOT NULL
);
GO

CREATE TABLE dw.dim_estacion
(
    estacion_key        INT IDENTITY(1,1) PRIMARY KEY,
    estacion_id         VARCHAR(32)   NOT NULL UNIQUE,
    estacion_nombre     NVARCHAR(160) NOT NULL,
    ciudad_zona         NVARCHAR(40)  NOT NULL,
    latitud             FLOAT         NOT NULL,
    longitud            FLOAT         NOT NULL
);
GO

CREATE TABLE dw.dim_tipo_bici
(
    tipo_bici_key       TINYINT       NOT NULL PRIMARY KEY,
    tipo_bici_cod       VARCHAR(20)   NOT NULL UNIQUE,
    tipo_bici_nombre    NVARCHAR(40)  NOT NULL,
    es_electrica        BIT           NOT NULL
);
GO

CREATE TABLE dw.fact_viaje
(
    id_viaje                INT          NOT NULL,
    fecha_key               INT          NOT NULL,
    hora                    TINYINT      NOT NULL,
    estacion_origen_key     INT          NOT NULL,
    estacion_destino_key    INT          NOT NULL,
    tipo_bici_key           TINYINT      NOT NULL,
    es_miembro              BIT          NOT NULL,
    cruza_hudson        BIT          NOT NULL,
    fecha_inicio            DATETIME2(0) NOT NULL,
    duracion_seg            INT          NOT NULL,
    distancia_m             INT          NOT NULL,
    velocidad_kmh           DECIMAL(8,2) NOT NULL,
    INDEX CCI_dw_fact_viaje CLUSTERED COLUMNSTORE
);
GO

CREATE OR ALTER PROCEDURE etl.sp_cargar_modelo
AS
BEGIN
    SET NOCOUNT ON;
    SET DATEFIRST 1;
    DECLARE @t0 DATETIME2(3) = SYSDATETIME();

    TRUNCATE TABLE dw.fact_viaje;
    TRUNCATE TABLE dw.dim_estacion;
    TRUNCATE TABLE dw.dim_tipo_bici;
    TRUNCATE TABLE dw.dim_fecha;

    -- 1. Dimensión tipo de bicicleta
    -- Se arma con los valores reales de rideable_type para que ningún viaje quede fuera del INNER JOIN
    INSERT INTO dw.dim_tipo_bici (tipo_bici_key, tipo_bici_cod, tipo_bici_nombre, es_electrica)
    SELECT
        CAST(ROW_NUMBER() OVER (ORDER BY t.tipo_bici_cod) AS TINYINT),
        t.tipo_bici_cod,
        CASE t.tipo_bici_cod
            WHEN 'classic_bike'  THEN N'Bicicleta clásica mecánica'
            WHEN 'electric_bike' THEN N'Bicicleta eléctrica asistida'
            ELSE CAST(t.tipo_bici_cod AS NVARCHAR(40))
        END,
        CAST(MAX(CAST(t.es_electrica AS TINYINT)) AS BIT)
    FROM limpio.viaje AS t
    WHERE t.motivo_exclusion IS NULL
    GROUP BY t.tipo_bici_cod;

    -- 2. Dimensión fecha (calendario completo de los viajes válidos)
    ;WITH fechas AS
    (
        SELECT DISTINCT fecha_dia
        FROM limpio.viaje
        WHERE motivo_exclusion IS NULL AND fecha_dia IS NOT NULL
    )
    INSERT INTO dw.dim_fecha
    (
        fecha_key, fecha, anio, trimestre, mes, nombre_mes,
        dia_mes, dia_semana, nombre_dia, es_fin_de_semana, estacion_climatica
    )
    SELECT
        YEAR(fecha_dia) * 10000 + MONTH(fecha_dia) * 100 + DAY(fecha_dia) AS fecha_key,
        fecha_dia,
        YEAR(fecha_dia),
        DATEPART(QUARTER, fecha_dia),
        MONTH(fecha_dia),
        CASE MONTH(fecha_dia)
            WHEN 1 THEN N'Enero' WHEN 2 THEN N'Febrero' WHEN 3 THEN N'Marzo'
            WHEN 4 THEN N'Abril' WHEN 5 THEN N'Mayo' WHEN 6 THEN N'Junio'
            WHEN 7 THEN N'Julio' WHEN 8 THEN N'Agosto' WHEN 9 THEN N'Septiembre'
            WHEN 10 THEN N'Octubre' WHEN 11 THEN N'Noviembre' ELSE N'Diciembre'
        END,
        DAY(fecha_dia),
        DATEPART(WEEKDAY, fecha_dia),
        CASE DATEPART(WEEKDAY, fecha_dia)
            WHEN 1 THEN N'Lunes' WHEN 2 THEN N'Martes' WHEN 3 THEN N'Miércoles'
            WHEN 4 THEN N'Jueves' WHEN 5 THEN N'Viernes' WHEN 6 THEN N'Sábado' ELSE N'Domingo'
        END,
        CASE WHEN DATEPART(WEEKDAY, fecha_dia) IN (6, 7) THEN 1 ELSE 0 END,
        CASE
            WHEN MONTH(fecha_dia) IN (12, 1, 2) THEN N'Invierno'
            WHEN MONTH(fecha_dia) IN (3, 4, 5)  THEN N'Primavera'
            WHEN MONTH(fecha_dia) IN (6, 7, 8)  THEN N'Verano'
            ELSE N'Otoño'
        END
    FROM fechas
    ORDER BY fecha_dia;

    -- 3. Dimensión estación (unión de origen y destino con el nombre más frecuente)
    ;WITH todas_estaciones AS
    (
        SELECT estacion_origen_id AS estacion_id, estacion_origen_nombre AS nombre, lat_origen AS lat, lng_origen AS lng
        FROM limpio.viaje
        WHERE motivo_exclusion IS NULL
        UNION ALL
        SELECT estacion_destino_id AS estacion_id, estacion_destino_nombre AS nombre, lat_destino AS lat, lng_destino AS lng
        FROM limpio.viaje
        WHERE motivo_exclusion IS NULL
    ),
    agrupadas AS
    (
        SELECT
            estacion_id,
            nombre,
            COUNT_BIG(*) AS usos,
            AVG(lat) AS lat_media,
            AVG(lng) AS lng_media,
            ROW_NUMBER() OVER (PARTITION BY estacion_id ORDER BY COUNT_BIG(*) DESC, nombre) AS rn
        FROM todas_estaciones
        GROUP BY estacion_id, nombre
    ),
    coordenadas_globales AS
    (
        SELECT estacion_id, AVG(lat) AS lat_global, AVG(lng) AS lng_global
        FROM todas_estaciones
        GROUP BY estacion_id
    )
    INSERT INTO dw.dim_estacion (estacion_id, estacion_nombre, ciudad_zona, latitud, longitud)
    SELECT
        a.estacion_id,
        a.nombre,
        CASE
            WHEN LEFT(a.estacion_id, 2) = 'JC' THEN N'Jersey City (NJ)'
            WHEN LEFT(a.estacion_id, 2) = 'HB' THEN N'Hoboken (NJ)'
            ELSE N'Nueva York (NY)'
        END AS ciudad_zona,
        ROUND(c.lat_global, 6),
        ROUND(c.lng_global, 6)
    FROM agrupadas AS a
    INNER JOIN coordenadas_globales AS c ON c.estacion_id = a.estacion_id
    WHERE a.rn = 1
    ORDER BY a.estacion_id;

    -- 4. Tabla de hechos Columnstore
    INSERT INTO dw.fact_viaje WITH (TABLOCK)
    (
        id_viaje, fecha_key, hora, estacion_origen_key, estacion_destino_key,
        tipo_bici_key, es_miembro, cruza_hudson, fecha_inicio,
        duracion_seg, distancia_m, velocidad_kmh
    )
    SELECT
        v.id_viaje,
        YEAR(v.fecha_dia) * 10000 + MONTH(v.fecha_dia) * 100 + DAY(v.fecha_dia) AS fecha_key,
        v.hora,
        eo.estacion_key,
        ed.estacion_key,
        tb.tipo_bici_key,
        v.es_miembro,
        v.cruza_hudson,
        v.fecha_inicio,
        v.duracion_seg,
        v.distancia_m,
        v.velocidad_kmh
    FROM limpio.viaje AS v
    INNER JOIN dw.dim_estacion AS eo ON eo.estacion_id = v.estacion_origen_id
    INNER JOIN dw.dim_estacion AS ed ON ed.estacion_id = v.estacion_destino_id
    INNER JOIN dw.dim_tipo_bici AS tb ON tb.tipo_bici_cod = v.tipo_bici_cod
    WHERE v.motivo_exclusion IS NULL;

    ALTER INDEX CCI_dw_fact_viaje ON dw.fact_viaje REBUILD;

    DECLARE @filas BIGINT = (SELECT COUNT_BIG(*) FROM dw.fact_viaje);
    INSERT INTO etl.bitacora_carga (etapa, filas_afectadas, duracion_ms)
    VALUES (N'CARGA_MODELO_ESTRELLA_CCI', @filas, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
END;
GO
