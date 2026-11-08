-- 06 · Índices del hecho y vista materializada del reporte
--
-- Los índices definidos sobre la tabla particionada se crean automáticamente
-- en cada partición (y en las que se agreguen después).
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- BRIN sobre la hora programada en UTC: las filas se cargaron ordenadas por
-- fecha y hora, así que cada bloque de 32 páginas cubre un rango corto de
-- tiempo. El índice guarda solo el mínimo y el máximo de cada bloque.
CREATE INDEX IF NOT EXISTS fact_vuelo_brin_salida
    ON dw.fact_vuelo USING brin (salida_prog_utc) WITH (pages_per_range = 32);

-- Índices parciales: solo indexan la pequeña parte de la tabla que consultan.
CREATE INDEX IF NOT EXISTS fact_vuelo_cancelados
    ON dw.fact_vuelo (aerolinea, fecha_vuelo) WHERE cancelado;
CREATE INDEX IF NOT EXISTS fact_vuelo_retraso_grave
    ON dw.fact_vuelo (origen_id, fecha_vuelo) WHERE retraso_llegada >= 60;

-- Itinerario de un avión: solo vuelos operados con matrícula.
CREATE INDEX IF NOT EXISTS fact_vuelo_avion
    ON dw.fact_vuelo (matricula, salida_prog_utc) WHERE matricula IS NOT NULL AND NOT cancelado;

ANALYZE dw.fact_vuelo;

-- ---------------------------------------------------------------------------
-- Vista materializada: puntualidad por día, aerolínea y aeropuerto de origen.
-- Resume ~7 M de vuelos en unas pocas centenas de miles de filas; el reporte
-- (rankings, estacionalidad, feriados) lee de aquí.
-- Definición de puntualidad del DOT (Air Travel Consumer Report): un vuelo es
-- puntual si llega menos de 15 minutos después de lo programado; cancelados y
-- desviados cuentan como no puntuales.
-- ---------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS dw.mv_puntualidad_diaria;
CREATE MATERIALIZED VIEW dw.mv_puntualidad_diaria AS
SELECT fecha_vuelo,
       aerolinea,
       origen_id,
       count(*)                                                     AS programados,
       count(*) FILTER (WHERE cancelado)                            AS cancelados,
       count(*) FILTER (WHERE desviado)                             AS desviados,
       count(*) FILTER (WHERE retraso_llegada < 15)                 AS puntuales,
       count(*) FILTER (WHERE retraso_llegada >= 15)                AS con_retraso,
       count(*) FILTER (WHERE retraso_llegada IS NOT NULL)          AS con_llegada,
       count(*) FILTER (WHERE retraso_salida < 15)                  AS salidas_puntuales,
       count(*) FILTER (WHERE retraso_salida IS NOT NULL)           AS con_salida,
       sum(retraso_salida)                                          AS suma_retraso_salida,
       sum(retraso_llegada)                                         AS suma_retraso_llegada,
       sum(greatest(retraso_llegada, 0))                            AS minutos_retraso,
       sum(retraso_aerolinea)                                       AS min_aerolinea,
       sum(retraso_clima)                                           AS min_clima,
       sum(retraso_nas)                                             AS min_nas,
       sum(retraso_seguridad)                                       AS min_seguridad,
       sum(retraso_avion_previo)                                    AS min_avion_previo
  FROM dw.fact_vuelo
 GROUP BY fecha_vuelo, aerolinea, origen_id;

-- Índice único: permite REFRESH MATERIALIZED VIEW CONCURRENTLY (sin bloquear lecturas).
CREATE UNIQUE INDEX mv_puntualidad_diaria_pk
    ON dw.mv_puntualidad_diaria (fecha_vuelo, aerolinea, origen_id);
ANALYZE dw.mv_puntualidad_diaria;
