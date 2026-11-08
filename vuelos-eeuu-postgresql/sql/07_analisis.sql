-- 07 · Análisis de negocio con funciones de ventana
--
-- Cada resultado queda en una tabla del esquema `analisis`, que
-- scripts/exportar_reportes.py copia a reports/tablas/*.csv.
-- Puntualidad = llegada < 15 min tarde sobre vuelos programados (cancelados y
-- desviados cuentan como no puntuales, como en el reporte oficial del DOT).
\set ON_ERROR_STOP on
SET client_min_messages = warning;

DROP TABLE IF EXISTS analisis.kpi_general, analisis.mensual, analisis.ranking_aerolineas,
    analisis.ranking_aeropuertos, analisis.hora_dia_semana, analisis.causas_mes,
    analisis.rutas_problematicas, analisis.serie_diaria, analisis.feriados,
    analisis.feriados_por_distancia, analisis.validacion_zona_horaria, analisis.aerolinea_dia CASCADE;

-- ---------------------------------------------------------------------------
-- KPI generales (formato largo: métrica, valor)
-- ---------------------------------------------------------------------------
CREATE TABLE analisis.kpi_general AS
WITH t AS (
    SELECT sum(programados) AS programados, sum(cancelados) AS cancelados, sum(desviados) AS desviados,
           sum(puntuales) AS puntuales, sum(con_llegada) AS con_llegada,
           sum(suma_retraso_llegada) AS suma_retraso, sum(minutos_retraso) AS minutos_retraso,
           sum(min_aerolinea + min_clima + min_nas + min_seguridad + min_avion_previo) AS min_causas,
           count(DISTINCT aerolinea) AS aerolineas, count(DISTINCT origen_id) AS aeropuertos_origen,
           count(DISTINCT fecha_vuelo) AS dias
      FROM dw.mv_puntualidad_diaria
)
SELECT metrica, valor FROM t, LATERAL (VALUES
    ('vuelos_programados',            programados::numeric),
    ('vuelos_cancelados',             cancelados),
    ('vuelos_desviados',              desviados),
    ('pct_cancelados',                round(100.0 * cancelados / programados, 2)),
    ('pct_desviados',                 round(100.0 * desviados / programados, 2)),
    ('pct_puntuales',                 round(100.0 * puntuales / programados, 2)),
    ('pct_puntuales_entre_llegados',  round(100.0 * puntuales / con_llegada, 2)),
    ('retraso_medio_llegada_min',     round(suma_retraso / con_llegada, 2)),
    ('minutos_retraso_totales',       minutos_retraso),
    ('minutos_con_causa',             min_causas),
    ('aerolineas',                    aerolineas),
    ('aeropuertos_origen',            aeropuertos_origen),
    ('dias',                          dias)
) AS v(metrica, valor);

-- ---------------------------------------------------------------------------
-- Mes a mes, con la variación frente al mes anterior (LAG)
-- ---------------------------------------------------------------------------
CREATE TABLE analisis.mensual AS
WITH m AS (
    SELECT date_trunc('month', fecha_vuelo)::date AS mes,
           sum(programados) AS programados, sum(cancelados) AS cancelados,
           sum(puntuales) AS puntuales, sum(con_llegada) AS con_llegada,
           sum(suma_retraso_llegada) AS suma_retraso
      FROM dw.mv_puntualidad_diaria GROUP BY 1
)
SELECT mes, programados, cancelados,
       round(100.0 * puntuales / programados, 2)                        AS pct_puntuales,
       round(100.0 * cancelados / programados, 2)                       AS pct_cancelados,
       round(suma_retraso / con_llegada, 2)                             AS retraso_medio_llegada,
       round(100.0 * puntuales / programados
             - lag(100.0 * puntuales / programados) OVER (ORDER BY mes), 2) AS cambio_pp_vs_mes_anterior,
       rank() OVER (ORDER BY puntuales::numeric / programados DESC)    AS rango_puntualidad
  FROM m
 ORDER BY mes;

-- ---------------------------------------------------------------------------
-- Ranking de aerolíneas: RANK y PERCENT_RANK
-- ---------------------------------------------------------------------------
CREATE TABLE analisis.ranking_aerolineas AS
WITH a AS (
    SELECT p.aerolinea, d.nombre,
           sum(programados) AS programados, sum(cancelados) AS cancelados,
           sum(puntuales) AS puntuales, sum(con_llegada) AS con_llegada,
           sum(suma_retraso_llegada) AS suma_retraso,
           sum(minutos_retraso) AS minutos_retraso,
           sum(min_aerolinea) AS min_aerolinea, sum(min_avion_previo) AS min_avion_previo
      FROM dw.mv_puntualidad_diaria p
      JOIN dw.dim_aerolinea d USING (aerolinea)
     GROUP BY p.aerolinea, d.nombre
)
SELECT aerolinea, nombre, programados,
       round(100.0 * programados / sum(programados) OVER (), 2)          AS pct_del_mercado,
       round(100.0 * puntuales / programados, 2)                         AS pct_puntuales,
       round(100.0 * cancelados / programados, 2)                        AS pct_cancelados,
       round(suma_retraso / con_llegada, 2)                              AS retraso_medio_llegada,
       round(minutos_retraso::numeric / programados, 2)                  AS min_retraso_por_vuelo,
       round(100.0 * min_aerolinea / nullif(minutos_retraso, 0), 1)      AS pct_minutos_causa_aerolinea,
       rank() OVER (ORDER BY puntuales::numeric / programados DESC)      AS rango_puntualidad,
       round(percent_rank() OVER (ORDER BY puntuales::numeric / programados)::numeric, 3) AS percentil_puntualidad,
       rank() OVER (ORDER BY cancelados::numeric / programados)          AS rango_menos_cancelaciones
  FROM a
 ORDER BY rango_puntualidad;

-- ---------------------------------------------------------------------------
-- Ranking de aeropuertos de origen (>= 20.000 salidas en el año, unas 55 al día)
-- RANK nacional, PERCENT_RANK, cuartil (NTILE) y rango dentro del estado.
-- ---------------------------------------------------------------------------
CREATE TABLE analisis.ranking_aeropuertos AS
WITH a AS (
    SELECT p.origen_id, ap.iata, ap.nombre, ap.estado,
           sum(programados) AS programados, sum(cancelados) AS cancelados,
           sum(salidas_puntuales) AS salidas_puntuales, sum(con_salida) AS con_salida,
           sum(suma_retraso_salida) AS suma_retraso_salida,
           sum(puntuales) AS puntuales
      FROM dw.mv_puntualidad_diaria p
      JOIN dw.dim_aeropuerto ap ON ap.aeropuerto_id = p.origen_id
     GROUP BY p.origen_id, ap.iata, ap.nombre, ap.estado
    HAVING sum(programados) >= 20000
)
SELECT iata, nombre, estado, programados,
       round(100.0 * salidas_puntuales / programados, 2)                 AS pct_salidas_puntuales,
       round(100.0 * puntuales / programados, 2)                         AS pct_llegadas_puntuales,
       round(100.0 * cancelados / programados, 2)                        AS pct_cancelados,
       round(suma_retraso_salida / con_salida, 2)                        AS retraso_medio_salida,
       rank() OVER (ORDER BY salidas_puntuales::numeric / programados DESC) AS rango_nacional,
       round(percent_rank() OVER (ORDER BY salidas_puntuales::numeric / programados)::numeric, 3) AS percentil,
       ntile(4) OVER (ORDER BY salidas_puntuales::numeric / programados DESC) AS cuartil,
       rank() OVER (PARTITION BY estado ORDER BY salidas_puntuales::numeric / programados DESC) AS rango_en_estado,
       count(*) OVER (PARTITION BY estado)                               AS aeropuertos_en_estado
  FROM a
 ORDER BY rango_nacional;

-- ---------------------------------------------------------------------------
-- Retraso por hora programada de salida y día de la semana
-- ---------------------------------------------------------------------------
CREATE TABLE analisis.hora_dia_semana AS
SELECT f.hora_salida_local AS hora,
       d.dia_semana, d.nombre_dia,
       count(*)                                                          AS programados,
       round(100.0 * count(*) FILTER (WHERE f.retraso_salida >= 15) / count(*), 2) AS pct_salidas_retrasadas,
       round(avg(f.retraso_salida), 2)                                   AS retraso_medio_salida,
       round(100.0 * count(*) FILTER (WHERE f.cancelado) / count(*), 2)  AS pct_cancelados
  FROM dw.fact_vuelo f
  JOIN dw.dim_fecha d ON d.fecha = f.fecha_vuelo
 GROUP BY f.hora_salida_local, d.dia_semana, d.nombre_dia
 ORDER BY hora, dia_semana;

-- ---------------------------------------------------------------------------
-- Causas de retraso por mes (minutos y participación). BTS reparte los minutos
-- de cada llegada con 15+ min de retraso entre cinco causas.
-- ---------------------------------------------------------------------------
CREATE TABLE analisis.causas_mes AS
WITH m AS (
    SELECT date_trunc('month', fecha_vuelo)::date AS mes,
           sum(min_aerolinea) AS aerolinea, sum(min_clima) AS clima, sum(min_nas) AS nas,
           sum(min_seguridad) AS seguridad, sum(min_avion_previo) AS avion_previo
      FROM dw.mv_puntualidad_diaria GROUP BY 1
), largo AS (
    SELECT mes, causa, minutos FROM m, LATERAL (VALUES
        ('aerolinea', aerolinea), ('clima', clima), ('nas', nas),
        ('seguridad', seguridad), ('avion_previo', avion_previo)) v(causa, minutos)
)
SELECT mes, causa, minutos,
       round(100.0 * minutos / sum(minutos) OVER (PARTITION BY mes), 2)  AS pct_del_mes,
       round(100.0 * sum(minutos) OVER (PARTITION BY causa) / sum(minutos) OVER (), 2) AS pct_del_anio,
       rank() OVER (PARTITION BY mes ORDER BY minutos DESC)              AS rango_en_mes
  FROM largo
 ORDER BY mes, rango_en_mes;

-- ---------------------------------------------------------------------------
-- Rutas más problemáticas (>= 1.500 vuelos en el año, unos 4 al día)
-- ---------------------------------------------------------------------------
CREATE TABLE analisis.rutas_problematicas AS
WITH r AS (
    SELECT o.iata AS origen, d.iata AS destino,
           count(*) AS programados,
           count(*) FILTER (WHERE f.retraso_llegada < 15) AS puntuales,
           count(*) FILTER (WHERE f.cancelado) AS cancelados,
           avg(f.retraso_llegada) AS retraso_medio,
           sum(greatest(f.retraso_llegada, 0)) AS minutos_retraso,
           percentile_cont(0.9) WITHIN GROUP (ORDER BY f.retraso_llegada) AS p90_retraso
      FROM dw.fact_vuelo f
      JOIN dw.dim_aeropuerto o ON o.aeropuerto_id = f.origen_id
      JOIN dw.dim_aeropuerto d ON d.aeropuerto_id = f.destino_id
     GROUP BY o.iata, d.iata
    HAVING count(*) >= 1500
)
SELECT origen, destino, programados,
       round(100.0 * puntuales / programados, 2)                         AS pct_puntuales,
       round(100.0 * cancelados / programados, 2)                        AS pct_cancelados,
       round(retraso_medio, 2)                                           AS retraso_medio_llegada,
       p90_retraso                                                       AS p90_retraso_llegada,
       minutos_retraso,
       rank() OVER (ORDER BY puntuales::numeric / programados)           AS rango_peor_puntualidad,
       round(percent_rank() OVER (ORDER BY puntuales::numeric / programados DESC)::numeric, 3) AS percentil_problema,
       count(*) OVER ()                                                  AS rutas_evaluadas
  FROM r
 ORDER BY rango_peor_puntualidad;

-- ---------------------------------------------------------------------------
-- Serie diaria con media móvil de 7 días y percentil de cada día
-- ---------------------------------------------------------------------------
CREATE TABLE analisis.serie_diaria AS
WITH d AS (
    SELECT fecha_vuelo AS fecha, sum(programados) AS programados, sum(cancelados) AS cancelados,
           sum(puntuales) AS puntuales, sum(suma_retraso_llegada) AS suma_retraso, sum(con_llegada) AS con_llegada
      FROM dw.mv_puntualidad_diaria GROUP BY 1
)
SELECT d.fecha, f.nombre_dia, f.feriado, f.ventana_feriado,
       d.programados, d.cancelados,
       round(100.0 * d.puntuales / d.programados, 2)                     AS pct_puntuales,
       round(100.0 * d.cancelados / d.programados, 2)                    AS pct_cancelados,
       round(d.suma_retraso / d.con_llegada, 2)                          AS retraso_medio_llegada,
       round(avg(100.0 * d.puntuales / d.programados)
             OVER (ORDER BY d.fecha ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2) AS pct_puntuales_media_7d,
       rank() OVER (ORDER BY d.puntuales::numeric / d.programados)       AS rango_peor_dia,
       round(percent_rank() OVER (ORDER BY d.puntuales::numeric / d.programados)::numeric, 3) AS percentil
  FROM d
  JOIN dw.dim_fecha f ON f.fecha = d.fecha
 ORDER BY d.fecha;

-- ---------------------------------------------------------------------------
-- Aerolínea × día: detecta episodios (tormentas, fallas de sistemas) con el
-- rango de cada aerolínea dentro del día y su media móvil de cancelaciones.
-- ---------------------------------------------------------------------------
CREATE TABLE analisis.aerolinea_dia AS
WITH d AS (
    SELECT fecha_vuelo AS fecha, aerolinea, sum(programados) AS programados,
           sum(cancelados) AS cancelados, sum(puntuales) AS puntuales
      FROM dw.mv_puntualidad_diaria GROUP BY 1, 2
)
SELECT fecha, aerolinea, programados, cancelados,
       round(100.0 * cancelados / programados, 2)                        AS pct_cancelados,
       round(100.0 * puntuales / programados, 2)                         AS pct_puntuales,
       rank() OVER (PARTITION BY fecha ORDER BY cancelados DESC)         AS rango_cancelados_en_dia,
       sum(cancelados) OVER (PARTITION BY aerolinea ORDER BY fecha
                             ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)  AS cancelados_7d,
       rank() OVER (ORDER BY cancelados DESC)                            AS rango_cancelados_anio
  FROM d
 ORDER BY fecha, aerolinea;

-- ---------------------------------------------------------------------------
-- Feriados: ventana de ±3 días frente al resto del año
-- ---------------------------------------------------------------------------
CREATE TABLE analisis.feriados AS
WITH base AS (
    SELECT sum(puntuales)::numeric / sum(programados) AS pct_anual,
           sum(programados)::numeric / count(DISTINCT fecha_vuelo) AS vuelos_dia_anual
      FROM dw.mv_puntualidad_diaria
), v AS (
    SELECT f.feriado_cercano AS feriado,
           min(p.fecha_vuelo) AS desde, max(p.fecha_vuelo) AS hasta,
           sum(p.programados) AS programados, sum(p.puntuales) AS puntuales,
           sum(p.cancelados) AS cancelados, count(DISTINCT p.fecha_vuelo) AS dias
      FROM dw.mv_puntualidad_diaria p
      JOIN dw.dim_fecha f ON f.fecha = p.fecha_vuelo
     WHERE f.ventana_feriado
     GROUP BY f.feriado_cercano
)
SELECT v.feriado, v.desde, v.hasta, v.dias,
       round(v.programados::numeric / v.dias)                            AS vuelos_por_dia,
       round(100.0 * (v.programados::numeric / v.dias / b.vuelos_dia_anual - 1), 2) AS pct_vuelos_vs_promedio,
       round(100.0 * v.puntuales / v.programados, 2)                     AS pct_puntuales,
       round(100.0 * (v.puntuales::numeric / v.programados - b.pct_anual), 2) AS dif_pp_vs_anual,
       round(100.0 * v.cancelados / v.programados, 2)                    AS pct_cancelados,
       rank() OVER (ORDER BY v.puntuales::numeric / v.programados)       AS rango_peor
  FROM v CROSS JOIN base b
 ORDER BY v.desde;

-- Patrón promedio alrededor de los feriados: día -3 ... +3
CREATE TABLE analisis.feriados_por_distancia AS
SELECT f.dias_al_feriado,
       count(DISTINCT p.fecha_vuelo)                                     AS dias,
       round(sum(p.programados)::numeric / count(DISTINCT p.fecha_vuelo)) AS vuelos_por_dia,
       round(100.0 * sum(p.puntuales) / sum(p.programados), 2)           AS pct_puntuales
  FROM dw.mv_puntualidad_diaria p
  JOIN dw.dim_fecha f ON f.fecha = p.fecha_vuelo
 WHERE f.ventana_feriado
 GROUP BY f.dias_al_feriado
 ORDER BY f.dias_al_feriado;

-- ---------------------------------------------------------------------------
-- Validación de las zonas horarias: si un aeropuerto tuviera la zona mal
-- asignada, casi todos sus vuelos fallarían Q_ZONA_INCONSISTENTE.
-- ---------------------------------------------------------------------------
CREATE TABLE analisis.validacion_zona_horaria AS
WITH vuelos AS (
    SELECT origen_id AS aeropuerto_id, count(*) AS vuelos FROM dw.fact_vuelo GROUP BY 1
), fallos AS (
    SELECT ap.aeropuerto_id, count(*) AS inconsistentes
      FROM calidad.vuelo_cuarentena q
      JOIN dw.dim_aeropuerto ap ON ap.iata = q.origen
     WHERE 'Q_ZONA_INCONSISTENTE' = ANY (q.motivos)
     GROUP BY 1
)
SELECT ap.zona_horaria, ap.fuente_zona,
       count(*)                                                          AS aeropuertos,
       sum(coalesce(v.vuelos, 0))                                        AS vuelos_validos,
       sum(coalesce(fa.inconsistentes, 0))                               AS vuelos_inconsistentes,
       round(max(100.0 * coalesce(fa.inconsistentes, 0)
                 / nullif(coalesce(v.vuelos, 0) + coalesce(fa.inconsistentes, 0), 0)), 3) AS max_pct_aeropuerto
  FROM dw.dim_aeropuerto ap
  LEFT JOIN vuelos v USING (aeropuerto_id)
  LEFT JOIN fallos fa USING (aeropuerto_id)
 GROUP BY ap.zona_horaria, ap.fuente_zona
 ORDER BY vuelos_validos DESC;
