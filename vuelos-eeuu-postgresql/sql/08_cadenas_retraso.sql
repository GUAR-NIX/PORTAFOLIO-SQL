-- 08 · Retrasos en cadena: seguir un avión (matrícula) a lo largo del día
--
-- Un mismo avión vuela varios tramos al día (A→B, B→C, C→D...). Si llega tarde
-- a B, probablemente sale tarde hacia C: el retraso se propaga. La CTE
-- recursiva parte de cada retraso "raíz" y avanza tramo a tramo mientras el
-- avión siga saliendo tarde.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

DROP TABLE IF EXISTS dw.tramo_avion, analisis.cadena_resumen, analisis.cadena_por_paso,
    analisis.cadena_por_tamano_raiz, analisis.cadena_por_hora_raiz, analisis.cadena_por_aerolinea,
    analisis.cadena_ejemplo CASCADE;

-- ---------------------------------------------------------------------------
-- Tramos de cada avión por día, numerados por hora de salida (UTC: los tramos
-- pueden pasar por zonas horarias distintas).
-- Solo vuelos operados, no desviados y con matrícula.
-- ---------------------------------------------------------------------------
CREATE TABLE dw.tramo_avion AS
SELECT f.matricula,
       f.fecha_vuelo,
       row_number() OVER w                                               AS n_tramo,
       count(*) OVER (PARTITION BY f.matricula, f.fecha_vuelo)           AS tramos_del_dia,
       f.id_vuelo, f.aerolinea, f.origen_id, f.destino_id, f.hora_salida_local,
       f.salida_prog_utc, f.llegada_prog_utc,
       f.retraso_salida, f.retraso_llegada,
       coalesce(f.retraso_avion_previo, 0)                               AS retraso_avion_previo,
       lag(f.retraso_llegada) OVER w                                     AS retraso_llegada_anterior,
       -- Holgura programada: minutos entre la llegada programada del tramo
       -- anterior y la salida programada de este (tiempo de rotación en tierra).
       (extract(epoch FROM f.salida_prog_utc - lag(f.llegada_prog_utc) OVER w) / 60)::int AS holgura_prog_min,
       coalesce(f.origen_id = lag(f.destino_id) OVER w, false)          AS continua
  FROM dw.fact_vuelo f
 WHERE f.matricula IS NOT NULL AND NOT f.cancelado AND NOT f.desviado
WINDOW w AS (PARTITION BY f.matricula, f.fecha_vuelo ORDER BY f.salida_prog_utc, f.id_vuelo);

ALTER TABLE dw.tramo_avion ADD PRIMARY KEY (matricula, fecha_vuelo, n_tramo);
ANALYZE dw.tramo_avion;

-- ---------------------------------------------------------------------------
-- La CTE recursiva, como función para poder probarla con un caso conocido.
--   Raíz : tramo que llega con >= p_umbral min de retraso y cuyo tramo anterior
--          ese día llegó a tiempo (o es el primero del día): el retraso nace aquí.
--   Paso : el tramo siguiente del mismo avión, que sale del aeropuerto donde
--          llegó el anterior, sale con >= p_umbral min de retraso y el anterior
--          llegó con >= p_umbral min. La cadena se corta cuando el avión
--          recupera el horario (sale o llega a tiempo).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analisis.cadenas_retraso(p_desde date, p_hasta date, p_umbral int DEFAULT 15)
RETURNS TABLE (
    matricula             text,
    fecha_vuelo           date,
    tramo_raiz            bigint,
    paso                  int,
    n_tramo               bigint,
    id_vuelo              bigint,
    retraso_raiz          int,
    retraso_salida        int,
    retraso_llegada       int,
    retraso_avion_previo  int,
    holgura_prog_min      int
)
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE cadena AS (
        SELECT t.matricula, t.fecha_vuelo, t.n_tramo AS tramo_raiz, 0 AS paso, t.n_tramo, t.id_vuelo,
               t.retraso_llegada::int AS retraso_raiz, t.retraso_salida::int, t.retraso_llegada::int,
               t.retraso_avion_previo::int, t.holgura_prog_min
          FROM dw.tramo_avion t
         WHERE t.fecha_vuelo BETWEEN p_desde AND p_hasta
           AND t.retraso_llegada >= p_umbral
           AND coalesce(t.retraso_llegada_anterior, 0) < p_umbral
        UNION ALL
        SELECT s.matricula, s.fecha_vuelo, c.tramo_raiz, c.paso + 1, s.n_tramo, s.id_vuelo,
               c.retraso_raiz, s.retraso_salida, s.retraso_llegada,
               s.retraso_avion_previo, s.holgura_prog_min
          FROM cadena c
          JOIN dw.tramo_avion s
            ON s.matricula = c.matricula
           AND s.fecha_vuelo = c.fecha_vuelo
           AND s.n_tramo = c.n_tramo + 1
         WHERE c.retraso_llegada >= p_umbral
           AND s.continua
           AND s.retraso_salida >= p_umbral
    )
    SELECT * FROM cadena
$$;

-- Resultado del año completo (se materializa una sola vez)
CREATE TEMP TABLE cadenas AS
SELECT * FROM analisis.cadenas_retraso(date '2024-01-01', date '2024-12-31');
CREATE INDEX ON cadenas (matricula, fecha_vuelo, tramo_raiz);
ANALYZE cadenas;

CREATE TEMP TABLE cadena_por_raiz AS
SELECT matricula, fecha_vuelo, tramo_raiz,
       max(retraso_raiz)                                    AS retraso_raiz,
       max(paso)                                            AS largo,
       coalesce(sum(retraso_salida) FILTER (WHERE paso > 0), 0) AS minutos_salida_aguas_abajo,
       coalesce(sum(retraso_avion_previo) FILTER (WHERE paso > 0), 0) AS minutos_avion_previo_bts
  FROM cadenas
 GROUP BY matricula, fecha_vuelo, tramo_raiz;

-- ---------------------------------------------------------------------------
-- Resumen general
-- ---------------------------------------------------------------------------
CREATE TABLE analisis.cadena_resumen AS
SELECT metrica, valor FROM (
    SELECT count(*)                                                       AS raices,
           count(*) FILTER (WHERE largo >= 1)                             AS raices_que_propagan,
           round(100.0 * count(*) FILTER (WHERE largo >= 1) / count(*), 2) AS pct_propagan,
           round(avg(largo) FILTER (WHERE largo >= 1), 3)                AS largo_medio_si_propaga,
           max(largo)                                                     AS largo_maximo,
           sum(largo)                                                     AS vuelos_afectados_aguas_abajo,
           sum(retraso_raiz)                                              AS minutos_raiz,
           sum(minutos_salida_aguas_abajo)                                AS minutos_aguas_abajo,
           round(sum(minutos_salida_aguas_abajo)::numeric / sum(retraso_raiz), 3) AS multiplicador,
           sum(minutos_avion_previo_bts)                                  AS minutos_avion_previo_bts_en_cadenas
      FROM cadena_por_raiz
) r, LATERAL (VALUES
    ('raices', raices::numeric), ('raices_que_propagan', raices_que_propagan),
    ('pct_propagan', pct_propagan), ('largo_medio_si_propaga', largo_medio_si_propaga),
    ('largo_maximo', largo_maximo), ('vuelos_afectados_aguas_abajo', vuelos_afectados_aguas_abajo),
    ('minutos_raiz', minutos_raiz), ('minutos_aguas_abajo', minutos_aguas_abajo),
    ('multiplicador', multiplicador),
    ('minutos_avion_previo_bts_en_cadenas', minutos_avion_previo_bts_en_cadenas),
    ('tramos_analizados', (SELECT count(*) FROM dw.tramo_avion)),
    ('aviones', (SELECT count(DISTINCT matricula) FROM dw.tramo_avion)),
    ('tramos_por_avion_dia', (SELECT round(avg(tramos_del_dia), 3) FROM dw.tramo_avion WHERE n_tramo = 1)),
    ('pct_avion_previo_bts_sobre_total', (SELECT round(100.0 * minutos_avion_previo_bts_en_cadenas
                                                       / sum(min_avion_previo), 2)
                                            FROM dw.mv_puntualidad_diaria))
) v(metrica, valor);

-- ---------------------------------------------------------------------------
-- Cómo decae el retraso paso a paso
-- ---------------------------------------------------------------------------
CREATE TABLE analisis.cadena_por_paso AS
SELECT c.paso,
       count(*)                                                          AS vuelos,
       round(avg(c.retraso_raiz), 2)                                     AS retraso_raiz_medio,
       round(avg(c.retraso_salida), 2)                                   AS retraso_salida_medio,
       round(avg(c.retraso_llegada), 2)                                  AS retraso_llegada_medio,
       round(avg(c.holgura_prog_min) FILTER (WHERE c.paso > 0), 2)       AS holgura_media,
       round(avg(c.retraso_salida::numeric / c.retraso_raiz), 3)         AS salida_sobre_raiz,
       round(100.0 * count(*) FILTER (WHERE c.retraso_avion_previo > 0) / count(*), 2) AS pct_con_avion_previo_bts,
       -- Supervivencia: de las raíces, qué % llega a este paso
       round(100.0 * count(*) / first_value(count(*)) OVER (ORDER BY c.paso), 2) AS pct_de_raices
  FROM cadenas c
 GROUP BY c.paso
 ORDER BY c.paso;

-- ---------------------------------------------------------------------------
-- Tamaño del retraso raíz frente a propagación
-- ---------------------------------------------------------------------------
CREATE TABLE analisis.cadena_por_tamano_raiz AS
SELECT CASE WHEN retraso_raiz < 30 THEN '1) 15-29 min'
            WHEN retraso_raiz < 60 THEN '2) 30-59 min'
            WHEN retraso_raiz < 120 THEN '3) 60-119 min'
            WHEN retraso_raiz < 240 THEN '4) 120-239 min'
            ELSE '5) 240+ min' END                                       AS tramo_retraso_raiz,
       count(*)                                                          AS raices,
       round(100.0 * count(*) FILTER (WHERE largo >= 1) / count(*), 2)   AS pct_propagan,
       round(avg(largo), 3)                                              AS vuelos_afectados_por_raiz,
       round(avg(minutos_salida_aguas_abajo), 1)                         AS minutos_aguas_abajo_por_raiz,
       round(sum(minutos_salida_aguas_abajo)::numeric / sum(retraso_raiz), 3) AS multiplicador
  FROM cadena_por_raiz
 GROUP BY 1
 ORDER BY 1;

-- ---------------------------------------------------------------------------
-- Hora del día del retraso raíz: un retraso temprano tiene más tramos por delante
-- ---------------------------------------------------------------------------
CREATE TABLE analisis.cadena_por_hora_raiz AS
SELECT t.hora_salida_local                                               AS hora_raiz,
       count(*)                                                          AS raices,
       round(avg(t.tramos_del_dia - t.n_tramo), 2)                       AS tramos_restantes_medios,
       round(100.0 * count(*) FILTER (WHERE r.largo >= 1) / count(*), 2) AS pct_propagan,
       round(avg(r.largo), 3)                                            AS vuelos_afectados_por_raiz,
       round(sum(r.minutos_salida_aguas_abajo)::numeric / sum(r.retraso_raiz), 3) AS multiplicador
  FROM cadena_por_raiz r
  JOIN dw.tramo_avion t
    ON t.matricula = r.matricula AND t.fecha_vuelo = r.fecha_vuelo AND t.n_tramo = r.tramo_raiz
 GROUP BY t.hora_salida_local
 ORDER BY t.hora_salida_local;

-- ---------------------------------------------------------------------------
-- Por aerolínea (cadenas de su propia flota)
-- ---------------------------------------------------------------------------
CREATE TABLE analisis.cadena_por_aerolinea AS
SELECT t.aerolinea,
       count(*)                                                          AS raices,
       round(100.0 * count(*) FILTER (WHERE r.largo >= 1) / count(*), 2) AS pct_propagan,
       round(avg(r.largo), 3)                                            AS vuelos_afectados_por_raiz,
       round(sum(r.minutos_salida_aguas_abajo)::numeric / sum(r.retraso_raiz), 3) AS multiplicador,
       round(avg(t.tramos_del_dia), 2)                                   AS tramos_dia_medios,
       rank() OVER (ORDER BY sum(r.minutos_salida_aguas_abajo)::numeric / sum(r.retraso_raiz) DESC) AS rango_mas_propagacion
  FROM cadena_por_raiz r
  JOIN dw.tramo_avion t
    ON t.matricula = r.matricula AND t.fecha_vuelo = r.fecha_vuelo AND t.n_tramo = r.tramo_raiz
 GROUP BY t.aerolinea
 ORDER BY rango_mas_propagacion;

-- ---------------------------------------------------------------------------
-- Ejemplo: la cadena más larga del año (desempate: mayor retraso raíz)
-- ---------------------------------------------------------------------------
CREATE TABLE analisis.cadena_ejemplo AS
WITH elegida AS (
    SELECT matricula, fecha_vuelo, tramo_raiz
      FROM cadena_por_raiz
     ORDER BY largo DESC, retraso_raiz DESC, matricula, fecha_vuelo
     LIMIT 1
)
SELECT t.matricula, t.fecha_vuelo, t.n_tramo, t.aerolinea,
       o.iata AS origen, d.iata AS destino,
       to_char(t.salida_prog_utc AT TIME ZONE o.zona_horaria, 'HH24:MI') AS salida_prog_local,
       t.holgura_prog_min, t.retraso_salida, t.retraso_llegada, t.retraso_avion_previo,
       c.paso
  FROM elegida e
  JOIN dw.tramo_avion t ON t.matricula = e.matricula AND t.fecha_vuelo = e.fecha_vuelo
  JOIN dw.dim_aeropuerto o ON o.aeropuerto_id = t.origen_id
  JOIN dw.dim_aeropuerto d ON d.aeropuerto_id = t.destino_id
  LEFT JOIN cadenas c
    ON c.matricula = t.matricula AND c.fecha_vuelo = t.fecha_vuelo
   AND c.tramo_raiz = e.tramo_raiz AND c.n_tramo = t.n_tramo
 ORDER BY t.n_tramo;
