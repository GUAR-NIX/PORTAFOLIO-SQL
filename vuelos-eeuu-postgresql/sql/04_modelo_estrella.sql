-- 04 · Modelo estrella: dimensiones y hecho particionado por mes
\set ON_ERROR_STOP on
SET client_min_messages = warning;

DROP MATERIALIZED VIEW IF EXISTS dw.mv_puntualidad_diaria CASCADE;
DROP TABLE IF EXISTS dw.fact_vuelo, dw.dim_aeropuerto, dw.dim_aerolinea, dw.dim_fecha,
                     ref.zona_horaria_manual CASCADE;

-- Aeropuertos de BTS que no tienen código IATA en mwgg/Airports: zona horaria
-- puesta a mano (se valida igual que las demás con los horarios de BTS).
CREATE TABLE ref.zona_horaria_manual (
    iata          text PRIMARY KEY,
    zona_horaria  text NOT NULL,
    motivo        text NOT NULL
);
INSERT INTO ref.zona_horaria_manual VALUES
    ('PBI', 'America/New_York', 'Palm Beach International (FL): sin código IATA en mwgg/Airports');

-- ---------------------------------------------------------------------------
-- Dimensión aerolínea
-- ---------------------------------------------------------------------------
CREATE TABLE dw.dim_aerolinea (
    aerolinea  text PRIMARY KEY,
    nombre     text NOT NULL
);
INSERT INTO dw.dim_aerolinea
SELECT DISTINCT v.aerolinea, coalesce(r.descripcion, v.aerolinea)
  FROM stg.vuelo v
  LEFT JOIN ref.aerolinea_bts r ON r.codigo = v.aerolinea;

-- ---------------------------------------------------------------------------
-- Dimensión aeropuerto (todos los que aparecen como origen o destino)
-- ---------------------------------------------------------------------------
CREATE TABLE dw.dim_aeropuerto (
    aeropuerto_id   int PRIMARY KEY,        -- AirportID de BTS (estable en el tiempo)
    iata            text NOT NULL,
    nombre          text,
    ciudad          text,
    estado          text,
    zona_horaria    text,                   -- nombre IANA, p. ej. America/Chicago
    fuente_zona     text,                   -- mwgg/Airports, manual o sin zona
    latitud         double precision,
    longitud        double precision
);
INSERT INTO dw.dim_aeropuerto
WITH usados AS (
    SELECT origen_id AS id, origen AS iata, origen_ciudad AS ciudad, origen_estado AS estado FROM stg.vuelo
    UNION
    SELECT destino_id, destino, destino_ciudad, destino_estado FROM stg.vuelo
), uno AS (
    SELECT DISTINCT ON (id) id, iata, ciudad, estado FROM usados ORDER BY id, iata
)
SELECT u.id, u.iata,
       split_part(b.descripcion, ': ', 2),
       u.ciudad, u.estado,
       coalesce(m.zona_horaria, t.zona_horaria),
       CASE WHEN m.iata IS NOT NULL THEN 'manual'
            WHEN t.iata IS NOT NULL THEN 'mwgg/Airports'
            ELSE 'sin zona' END,
       t.latitud, t.longitud
  FROM uno u
  LEFT JOIN ref.aeropuerto_bts b       ON b.codigo = u.id
  LEFT JOIN ref.zona_horaria_manual m  ON m.iata = u.iata
  LEFT JOIN ref.aeropuerto_tz t        ON t.iata = u.iata
                                      AND EXISTS (SELECT 1 FROM pg_timezone_names z WHERE z.name = t.zona_horaria);
CREATE UNIQUE INDEX ON dw.dim_aeropuerto (iata);

-- ---------------------------------------------------------------------------
-- Dimensión fecha con los feriados federales de EE. UU. de 2024
-- ---------------------------------------------------------------------------
CREATE TABLE dw.dim_fecha (
    fecha              date PRIMARY KEY,
    anio               smallint NOT NULL,
    mes                smallint NOT NULL,
    nombre_mes         text     NOT NULL,
    dia_semana         smallint NOT NULL,     -- ISO: 1 = lunes ... 7 = domingo
    nombre_dia         text     NOT NULL,
    es_fin_semana      boolean  NOT NULL,
    feriado            text,                  -- nombre si la fecha es feriado federal
    feriado_cercano    text,                  -- feriado a 3 días o menos
    dias_al_feriado    smallint,              -- negativo = antes del feriado
    ventana_feriado    boolean  NOT NULL      -- dentro de ±3 días de un feriado
);
WITH feriados(fecha, nombre) AS (VALUES
    (date '2024-01-01', 'Año Nuevo'),
    (date '2024-01-15', 'Martin Luther King Jr.'),
    (date '2024-02-19', 'Día de los Presidentes'),
    (date '2024-05-27', 'Memorial Day'),
    (date '2024-06-19', 'Juneteenth'),
    (date '2024-07-04', 'Día de la Independencia'),
    (date '2024-09-02', 'Labor Day'),
    (date '2024-10-14', 'Columbus Day'),
    (date '2024-11-11', 'Día de los Veteranos'),
    (date '2024-11-28', 'Acción de Gracias'),
    (date '2024-12-25', 'Navidad')
), dias AS (
    SELECT d::date AS fecha FROM generate_series(date '2024-01-01', date '2024-12-31', interval '1 day') d
)
INSERT INTO dw.dim_fecha
SELECT d.fecha,
       extract(year FROM d.fecha), extract(month FROM d.fecha),
       (ARRAY['enero','febrero','marzo','abril','mayo','junio','julio','agosto',
              'septiembre','octubre','noviembre','diciembre'])[extract(month FROM d.fecha)],
       extract(isodow FROM d.fecha),
       (ARRAY['lunes','martes','miércoles','jueves','viernes','sábado','domingo'])[extract(isodow FROM d.fecha)],
       extract(isodow FROM d.fecha) >= 6,
       f.nombre,
       c.nombre, c.dias,
       c.nombre IS NOT NULL
  FROM dias d
  LEFT JOIN feriados f ON f.fecha = d.fecha
  LEFT JOIN LATERAL (
        SELECT fe.nombre, (d.fecha - fe.fecha)::smallint AS dias
          FROM feriados fe
         WHERE abs(d.fecha - fe.fecha) <= 3
         ORDER BY abs(d.fecha - fe.fecha)
         LIMIT 1) c ON true;

-- ---------------------------------------------------------------------------
-- Hecho: un vuelo por fila, particionado por mes (PARTITION BY RANGE)
-- ---------------------------------------------------------------------------
-- Las horas se guardan en UTC (timestamptz) además de la hora local
-- programada: así se pueden restar horas de aeropuertos en zonas distintas
-- (necesario para seguir un avión a lo largo del día).
CREATE TABLE dw.fact_vuelo (
    id_vuelo              bigint      NOT NULL,
    fecha_vuelo           date        NOT NULL REFERENCES dw.dim_fecha,
    aerolinea             text        NOT NULL REFERENCES dw.dim_aerolinea,
    numero_vuelo          int,
    matricula             text,
    origen_id             int         NOT NULL REFERENCES dw.dim_aeropuerto,
    destino_id            int         NOT NULL REFERENCES dw.dim_aeropuerto,
    hora_salida_local     smallint    NOT NULL,     -- hora programada, 0-23
    salida_prog_utc       timestamptz NOT NULL,
    llegada_prog_utc      timestamptz NOT NULL,
    salida_real_utc       timestamptz,
    llegada_real_utc      timestamptz,
    retraso_salida        smallint,
    retraso_llegada       smallint,
    taxi_out              smallint,
    taxi_in               smallint,
    tiempo_aire_min       smallint,
    duracion_prog_min     smallint,
    distancia_millas      smallint,
    cancelado             boolean     NOT NULL,
    codigo_cancelacion    char(1),
    desviado              boolean     NOT NULL,
    retraso_aerolinea     smallint,
    retraso_clima         smallint,
    retraso_nas           smallint,
    retraso_seguridad     smallint,
    retraso_avion_previo  smallint,
    PRIMARY KEY (id_vuelo, fecha_vuelo)               -- la clave debe incluir la columna de partición
) PARTITION BY RANGE (fecha_vuelo);

-- Una partición por mes de 2024 y una DEFAULT que debe quedar vacía
-- (un control lo verifica: si llega una fecha fuera de rango, se ve).
DO $$
DECLARE
    m int;
    desde date;
BEGIN
    FOR m IN 1 .. 12 LOOP
        desde := make_date(2024, m, 1);
        EXECUTE format('CREATE TABLE dw.fact_vuelo_%s PARTITION OF dw.fact_vuelo FOR VALUES FROM (%L) TO (%L)',
                       to_char(desde, 'YYYY_MM'), desde, (desde + interval '1 month')::date);
    END LOOP;
END $$;
CREATE TABLE dw.fact_vuelo_fuera_de_rango PARTITION OF dw.fact_vuelo DEFAULT;
