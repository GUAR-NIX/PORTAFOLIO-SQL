/* =====================================================================
   03_limpieza.sql — Tipado, distancia Haversine y 7 reglas de calidad
   ---------------------------------------------------------------------
   Ninguna fila se borra: las 6.672.881 filas brutas quedan en limpio.viaje
   con motivo_exclusion = NULL si el viaje es válido, o el motivo exacto
   si presenta anomalía.
   ===================================================================== */
USE CitiBikeTuning;
GO

CREATE TABLE limpio.viaje
(
    id_viaje                INT           NOT NULL,
    ride_id                 VARCHAR(24)   NOT NULL,
    tipo_bici_cod           VARCHAR(20)   NOT NULL,
    es_electrica            BIT           NOT NULL,
    fecha_inicio            DATETIME2(0)  NULL,
    fecha_fin               DATETIME2(0)  NULL,
    fecha_dia               DATE          NULL,
    anio                    SMALLINT      NULL,
    mes                     TINYINT       NULL,
    hora                    TINYINT       NULL,
    dia_semana              TINYINT       NULL,
    es_fin_de_semana        BIT           NULL,
    estacion_origen_id      VARCHAR(32)   NOT NULL,
    estacion_origen_nombre  NVARCHAR(160) NOT NULL,
    estacion_destino_id     VARCHAR(32)   NOT NULL,
    estacion_destino_nombre NVARCHAR(160) NOT NULL,
    lat_origen              FLOAT         NULL,
    lng_origen              FLOAT         NULL,
    lat_destino             FLOAT         NULL,
    lng_destino             FLOAT         NULL,
    es_miembro              BIT           NOT NULL,
    duracion_seg            INT           NOT NULL,
    distancia_m             INT           NOT NULL,
    velocidad_kmh           DECIMAL(8,2)  NOT NULL,
    cruza_hudson        BIT           NOT NULL,
    periodo_archivo         INT           NOT NULL,
    fila_archivo            INT           NOT NULL,
    motivo_exclusion        VARCHAR(45)   NULL,
    CONSTRAINT PK_limpio_viaje PRIMARY KEY CLUSTERED (id_viaje)
);
GO

CREATE OR ALTER PROCEDURE etl.sp_limpiar
AS
BEGIN
    SET NOCOUNT ON;
    SET DATEFIRST 1; -- Lunes = 1 .. Domingo = 7
    DECLARE @t0 DATETIME2(3) = SYSDATETIME();

    TRUNCATE TABLE limpio.viaje;

    ;WITH tipado AS
    (
        SELECT
            ROW_NUMBER() OVER (ORDER BY periodo_archivo, fila_archivo) AS id_viaje,
            -- Intercalación binaria: compara ride_id byte a byte (igual que pandas) y ordena mucho más rápido
            ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(ride_id)) COLLATE Latin1_General_BIN2 ORDER BY periodo_archivo, fila_archivo) AS orden_ride,
            ISNULL(LEFT(LTRIM(RTRIM(ride_id)), 24), '') AS ride_id,
            ISNULL(LEFT(LTRIM(RTRIM(rideable_type)), 20), 'unknown') AS tipo_bici_cod,
            CASE WHEN LTRIM(RTRIM(rideable_type)) = 'electric_bike' THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS es_electrica,
            TRY_CONVERT(DATETIME2(0), LEFT(LTRIM(RTRIM(started_at)), 19), 120) AS fecha_inicio,
            TRY_CONVERT(DATETIME2(0), LEFT(LTRIM(RTRIM(ended_at)), 19), 120)   AS fecha_fin,
            ISNULL(LEFT(LTRIM(RTRIM(start_station_id)), 32), '')               AS estacion_origen_id,
            ISNULL(LEFT(LTRIM(RTRIM(start_station_name)), 160), N'')           AS estacion_origen_nombre,
            ISNULL(LEFT(LTRIM(RTRIM(end_station_id)), 32), '')                 AS estacion_destino_id,
            ISNULL(LEFT(LTRIM(RTRIM(end_station_name)), 160), N'')             AS estacion_destino_nombre,
            TRY_CONVERT(FLOAT, NULLIF(LTRIM(RTRIM(start_lat)), ''))            AS lat_origen,
            TRY_CONVERT(FLOAT, NULLIF(LTRIM(RTRIM(start_lng)), ''))            AS lng_origen,
            TRY_CONVERT(FLOAT, NULLIF(LTRIM(RTRIM(end_lat)), ''))              AS lat_destino,
            TRY_CONVERT(FLOAT, NULLIF(LTRIM(RTRIM(end_lng)), ''))              AS lng_destino,
            CASE WHEN LTRIM(RTRIM(member_casual)) = 'member' THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS es_miembro,
            ISNULL(periodo_archivo, 0)                                         AS periodo_archivo,
            ISNULL(fila_archivo, 0)                                            AS fila_archivo
        FROM stg.viaje_crudo
    ),
    con_metricas AS
    (
        SELECT
            t.*,
            ISNULL(DATEDIFF(SECOND, t.fecha_inicio, t.fecha_fin), 0) AS duracion_seg,
            -- Distancia ortodrómica de Haversine en metros (radio terrestre R = 6.371.000 m)
            CASE
                WHEN t.lat_origen IS NOT NULL AND t.lng_origen IS NOT NULL
                 AND t.lat_destino IS NOT NULL AND t.lng_destino IS NOT NULL
                THEN CAST(ROUND(
                    6371000.0 * 2.0 * ATN2(
                        SQRT(
                             hav.a_val
                        ),
                        SQRT(CASE WHEN 1.0 - hav.a_val < 0.0 THEN 0.0 ELSE 1.0 - hav.a_val END)
                    ), 0) AS INT)
                ELSE 0
            END AS distancia_m
        FROM tipado AS t
        OUTER APPLY
        (
            SELECT
                CASE
                    WHEN t.lat_origen IS NOT NULL AND t.lng_origen IS NOT NULL
                     AND t.lat_destino IS NOT NULL AND t.lng_destino IS NOT NULL
                    THEN
                        POWER(SIN(RADIANS(t.lat_destino - t.lat_origen) / 2.0), 2)
                        + COS(RADIANS(t.lat_origen)) * COS(RADIANS(t.lat_destino))
                        * POWER(SIN(RADIANS(t.lng_destino - t.lng_origen) / 2.0), 2)
                    ELSE 0.0
                END AS a_raw
        ) AS calc
        OUTER APPLY
        (
            SELECT CASE WHEN calc.a_raw > 1.0 THEN 1.0 WHEN calc.a_raw < 0.0 THEN 0.0 ELSE calc.a_raw END AS a_val
        ) AS hav
    )
    INSERT INTO limpio.viaje WITH (TABLOCK)
    (
        id_viaje, ride_id, tipo_bici_cod, es_electrica,
        fecha_inicio, fecha_fin, fecha_dia, anio, mes, hora, dia_semana, es_fin_de_semana,
        estacion_origen_id, estacion_origen_nombre, estacion_destino_id, estacion_destino_nombre,
        lat_origen, lng_origen, lat_destino, lng_destino,
        es_miembro, duracion_seg, distancia_m, velocidad_kmh, cruza_hudson,
        periodo_archivo, fila_archivo, motivo_exclusion
    )
    SELECT
        m.id_viaje,
        m.ride_id,
        m.tipo_bici_cod,
        m.es_electrica,
        m.fecha_inicio,
        m.fecha_fin,
        CAST(m.fecha_inicio AS DATE) AS fecha_dia,
        CAST(YEAR(m.fecha_inicio) AS SMALLINT) AS anio,
        CAST(MONTH(m.fecha_inicio) AS TINYINT) AS mes,
        CAST(DATEPART(HOUR, m.fecha_inicio) AS TINYINT) AS hora,
        CAST(DATEPART(WEEKDAY, m.fecha_inicio) AS TINYINT) AS dia_semana,
        CASE WHEN DATEPART(WEEKDAY, m.fecha_inicio) IN (6, 7) THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS es_fin_de_semana,
        m.estacion_origen_id,
        m.estacion_origen_nombre,
        m.estacion_destino_id,
        m.estacion_destino_nombre,
        m.lat_origen,
        m.lng_origen,
        m.lat_destino,
        m.lng_destino,
        m.es_miembro,
        m.duracion_seg,
        m.distancia_m,
        CASE
            WHEN m.duracion_seg > 0 AND m.distancia_m > 0
                 AND (CAST(m.distancia_m AS FLOAT) * 3.6 / m.duracion_seg) <= 99.99
            THEN CAST(ROUND(CAST(m.distancia_m AS FLOAT) * 3.6 / m.duracion_seg, 2) AS DECIMAL(8,2))
            ELSE CAST(0.00 AS DECIMAL(8,2))
        END AS velocidad_kmh,
        -- Las estaciones de Jersey City/Hoboken empiezan por JC o HB; las de Nueva York tienen código numérico.
        -- cruza_hudson = 1 si el viaje pasa de un lado del río al otro (en cualquier sentido).
        CASE
            WHEN m.estacion_destino_id <> ''
             AND m.estacion_origen_id <> ''
             AND (CASE WHEN LEFT(m.estacion_origen_id, 2) IN ('JC', 'HB') THEN 1 ELSE 0 END)
              <> (CASE WHEN LEFT(m.estacion_destino_id, 2) IN ('JC', 'HB') THEN 1 ELSE 0 END)
            THEN CAST(1 AS BIT)
            ELSE CAST(0 AS BIT)
        END AS cruza_hudson,
        m.periodo_archivo,
        m.fila_archivo,
        CASE
            WHEN m.orden_ride > 1 THEN 'DUPLICADO_RIDE_ID'
            WHEN m.fecha_inicio IS NULL OR m.fecha_fin IS NULL
              OR m.estacion_origen_id = ''
              OR m.lat_origen IS NULL OR m.lng_origen IS NULL THEN 'DATOS_ORIGEN_INCOMPLETOS'
            WHEN m.duracion_seg <= 0 THEN 'DURACION_NO_POSITIVA'
            WHEN m.estacion_origen_id = m.estacion_destino_id
             AND m.duracion_seg > 0 AND m.duracion_seg < 60 THEN 'FALSO_ARRANQUE_MISMA_ESTACION_MENOR_60S'
            WHEN m.estacion_destino_id = ''
              OR m.lat_destino IS NULL OR m.lng_destino IS NULL THEN 'SIN_ESTACION_O_COORD_DESTINO'
            WHEN m.duracion_seg > 86400 THEN 'DURACION_EXCESIVA_MAYOR_24H'
            WHEN m.lat_origen NOT BETWEEN 40.50 AND 41.00
              OR m.lng_origen NOT BETWEEN -74.30 AND -73.70
              OR m.lat_destino NOT BETWEEN 40.50 AND 41.00
              OR m.lng_destino NOT BETWEEN -74.30 AND -73.70 THEN 'COORDENADAS_FUERA_RANGO'
            ELSE NULL
        END AS motivo_exclusion
    FROM con_metricas AS m;

    DECLARE @filas BIGINT = (SELECT COUNT_BIG(*) FROM limpio.viaje);
    INSERT INTO etl.bitacora_carga (etapa, filas_afectadas, duracion_ms)
    VALUES (N'LIMPIEZA_Y_REGLAS_CALIDAD', @filas, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
END;
GO
