-- 05 · Calidad: reglas, cuarentena y carga del hecho particionado
--
-- Cada vuelo de stg.vuelo se evalúa contra todas las reglas a la vez y guarda
-- la lista de reglas que dispara (text[]). Dos tipos de regla:
--   cuarentena : el dato es imposible o no se puede situar en el tiempo; el
--                vuelo va a calidad.vuelo_cuarentena y NO entra al hecho.
--   marca      : el dato es válido pero especial (cancelado, desviado, hora
--                2400, cruza la medianoche...); entra al hecho y se cuenta.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

DROP TABLE IF EXISTS calidad.regla, calidad.evaluacion, calidad.vuelo_cuarentena, calidad.conteo_regla CASCADE;

CREATE TABLE calidad.regla (
    codigo       text PRIMARY KEY,
    tipo         text NOT NULL CHECK (tipo IN ('cuarentena', 'marca')),
    descripcion  text NOT NULL
);
INSERT INTO calidad.regla VALUES
    ('Q_CAMPO_CLAVE_VACIO',   'cuarentena', 'Sin número de vuelo, hora de salida programada o duración programada'),
    ('Q_SIN_ZONA',            'cuarentena', 'Origen o destino sin zona horaria IANA válida'),
    ('Q_ZONA_INCONSISTENTE',  'cuarentena', 'Salida programada + duración programada no da la llegada programada en la zona del destino'),
    ('Q_RETRASO_INCOHERENTE', 'cuarentena', 'El retraso informado no es la diferencia entre la hora real y la programada'),
    ('Q_TIEMPO_IMPOSIBLE',    'cuarentena', 'Tiempo en aire <= 0, duración real < tiempo en aire, taxi negativo, distancia <= 0 u origen = destino'),
    ('Q_VELOCIDAD_IMPOSIBLE', 'cuarentena', 'Velocidad media en el aire > 800 mph o < 50 mph'),
    ('Q_SIN_DATOS_LLEGADA',   'cuarentena', 'Vuelo operado y no desviado sin retraso de llegada o sin tiempo en aire'),
    ('Q_CAUSAS_NO_SUMAN',     'cuarentena', 'Llegada con 15+ min de retraso cuyas cinco causas no suman el retraso'),
    ('Q_DUPLICADO',           'cuarentena', 'Misma fecha, aerolínea, número de vuelo, origen y hora programada que otro vuelo'),
    ('M_CANCELADO',           'marca',      'Vuelo cancelado (sin horas reales ni retrasos)'),
    ('M_DESVIADO',            'marca',      'Vuelo desviado a otro aeropuerto (sin retraso de llegada)'),
    ('M_HORA_2400',           'marca',      'Hora real escrita como 2400: es las 00:00 del día siguiente'),
    ('M_CRUZA_MEDIANOCHE',    'marca',      'La llegada programada cae en el día siguiente (hora local del destino)'),
    ('M_SALE_DIA_SIGUIENTE',  'marca',      'Por el retraso, la salida real ocurre después de la medianoche'),
    ('M_CAMBIO_HORA_EN_VUELO','marca',      'El cambio de horario de verano ocurre mientras el avión está en el aire'),
    ('M_RETRASO_EXTREMO',     'marca',      'Retraso de salida o de llegada mayor a 12 horas'),
    ('M_SIN_MATRICULA',       'marca',      'Vuelo operado sin matrícula del avión (no sirve para el análisis en cadena)');

-- hhmm -> minutos desde la medianoche (2400 -> 1440, es decir, el día siguiente)
CREATE OR REPLACE FUNCTION calidad.min_dia(hhmm smallint) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT (hhmm / 100) * 60 + hhmm % 100 $$;

-- diferencia en minutos llevada a 0..1439 (0 = coinciden, módulo 24 h)
CREATE OR REPLACE FUNCTION calidad.mod_dia(minutos int) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT ((minutos % 1440) + 1440) % 1440 $$;

-- ---------------------------------------------------------------------------
-- Evaluación de todas las reglas en una sola pasada
-- ---------------------------------------------------------------------------
CREATE UNLOGGED TABLE calidad.evaluacion AS
WITH base AS (
    SELECT v.*,
           o.zona_horaria AS zona_origen,
           d.zona_horaria AS zona_destino,
           v.fecha_vuelo + make_interval(mins => calidad.min_dia(v.salida_prog_hhmm)) AS salida_prog_local,
           row_number() OVER (PARTITION BY v.fecha_vuelo, v.aerolinea, v.numero_vuelo,
                                           v.origen_id, v.salida_prog_hhmm
                              ORDER BY v.id_vuelo) AS orden_duplicado
      FROM stg.vuelo v
      LEFT JOIN dw.dim_aeropuerto o ON o.aeropuerto_id = v.origen_id
      LEFT JOIN dw.dim_aeropuerto d ON d.aeropuerto_id = v.destino_id
), utc AS (
    SELECT b.*,
           b.salida_prog_local AT TIME ZONE b.zona_origen AS salida_prog_utc,
           (b.salida_prog_local AT TIME ZONE b.zona_origen)
               + make_interval(mins => b.duracion_prog_min) AS llegada_prog_utc
      FROM base b
)
SELECT u.*,
       u.salida_prog_utc + make_interval(mins => u.retraso_salida)  AS salida_real_utc,
       u.llegada_prog_utc + make_interval(mins => u.retraso_llegada) AS llegada_real_utc,
       array_remove(ARRAY[
           CASE WHEN u.numero_vuelo IS NULL OR u.salida_prog_hhmm IS NULL OR u.duracion_prog_min IS NULL
                THEN 'Q_CAMPO_CLAVE_VACIO' END,
           CASE WHEN u.zona_origen IS NULL OR u.zona_destino IS NULL THEN 'Q_SIN_ZONA' END,
           CASE WHEN calidad.mod_dia(
                     calidad.min_dia(u.llegada_prog_hhmm)
                     - (extract(hour FROM u.llegada_prog_utc AT TIME ZONE u.zona_destino) * 60
                        + extract(minute FROM u.llegada_prog_utc AT TIME ZONE u.zona_destino))::int) <> 0
                THEN 'Q_ZONA_INCONSISTENTE' END,
           CASE WHEN (NOT u.cancelado AND u.salida_real_hhmm IS NOT NULL
                      AND calidad.mod_dia(calidad.min_dia(u.salida_real_hhmm)
                                          - calidad.min_dia(u.salida_prog_hhmm) - u.retraso_salida) <> 0)
                  OR (NOT u.cancelado AND NOT u.desviado AND u.llegada_real_hhmm IS NOT NULL
                      AND calidad.mod_dia(calidad.min_dia(u.llegada_real_hhmm)
                                          - calidad.min_dia(u.llegada_prog_hhmm) - u.retraso_llegada) <> 0)
                THEN 'Q_RETRASO_INCOHERENTE' END,
           CASE WHEN u.tiempo_aire_min <= 0 OR u.duracion_real_min < u.tiempo_aire_min
                  OR u.taxi_out < 0 OR u.taxi_in < 0 OR u.duracion_prog_min <= 0
                  OR u.distancia_millas <= 0 OR u.origen_id = u.destino_id
                THEN 'Q_TIEMPO_IMPOSIBLE' END,
           CASE WHEN u.tiempo_aire_min > 0
                 AND (u.distancia_millas * 60.0 / u.tiempo_aire_min > 800
                      OR u.distancia_millas * 60.0 / u.tiempo_aire_min < 50)
                THEN 'Q_VELOCIDAD_IMPOSIBLE' END,
           CASE WHEN NOT u.cancelado AND NOT u.desviado
                 AND (u.retraso_llegada IS NULL OR u.tiempo_aire_min IS NULL OR u.retraso_salida IS NULL)
                THEN 'Q_SIN_DATOS_LLEGADA' END,
           CASE WHEN u.llegada_15
                 AND coalesce(u.retraso_aerolinea + u.retraso_clima + u.retraso_nas
                              + u.retraso_seguridad + u.retraso_avion_previo, -1) <> u.retraso_llegada
                THEN 'Q_CAUSAS_NO_SUMAN' END,
           CASE WHEN u.orden_duplicado > 1 THEN 'Q_DUPLICADO' END,
           CASE WHEN u.cancelado THEN 'M_CANCELADO' END,
           CASE WHEN u.desviado THEN 'M_DESVIADO' END,
           CASE WHEN 2400 IN (u.salida_real_hhmm, u.llegada_real_hhmm, u.despegue_hhmm, u.aterrizaje_hhmm)
                THEN 'M_HORA_2400' END,
           CASE WHEN (u.llegada_prog_utc AT TIME ZONE u.zona_destino)::date > u.fecha_vuelo
                THEN 'M_CRUZA_MEDIANOCHE' END,
           CASE WHEN NOT u.cancelado
                 AND (u.salida_prog_local + make_interval(mins => u.retraso_salida))::date > u.fecha_vuelo
                THEN 'M_SALE_DIA_SIGUIENTE' END,
           -- En la zona de origen, la hora local de llegada menos la de salida no
           -- coincide con la duración: el reloj cambió (horario de verano) en el aire.
           CASE WHEN (u.llegada_prog_utc AT TIME ZONE u.zona_origen) - u.salida_prog_local
                     <> make_interval(mins => u.duracion_prog_min)
                THEN 'M_CAMBIO_HORA_EN_VUELO' END,
           CASE WHEN u.retraso_salida > 720 OR u.retraso_llegada > 720 THEN 'M_RETRASO_EXTREMO' END,
           CASE WHEN NOT u.cancelado AND u.matricula IS NULL THEN 'M_SIN_MATRICULA' END
       ], NULL) AS reglas
  FROM utc u;

-- ---------------------------------------------------------------------------
-- Conteo por regla (un vuelo puede disparar varias)
-- ---------------------------------------------------------------------------
CREATE TABLE calidad.conteo_regla AS
SELECT r.codigo, r.tipo, r.descripcion,
       count(e.id_vuelo)                                               AS vuelos,
       round(100.0 * count(e.id_vuelo) / (SELECT count(*) FROM calidad.evaluacion), 4) AS pct
  FROM calidad.regla r
  LEFT JOIN (SELECT id_vuelo, unnest(reglas) AS codigo FROM calidad.evaluacion) e USING (codigo)
 GROUP BY r.codigo, r.tipo, r.descripcion
 ORDER BY r.tipo, vuelos DESC;

-- ---------------------------------------------------------------------------
-- Cuarentena: el vuelo completo en JSON, con los motivos
-- ---------------------------------------------------------------------------
CREATE TABLE calidad.vuelo_cuarentena AS
SELECT e.id_vuelo, e.anio_mes, e.fecha_vuelo, e.aerolinea, e.numero_vuelo,
       e.origen, e.destino,
       ARRAY(SELECT x FROM unnest(e.reglas) x WHERE x LIKE 'Q\_%') AS motivos,
       to_jsonb(s) AS fila_staging
  FROM calidad.evaluacion e
  JOIN stg.vuelo s USING (id_vuelo)
 WHERE EXISTS (SELECT 1 FROM unnest(e.reglas) x WHERE x LIKE 'Q\_%');
ALTER TABLE calidad.vuelo_cuarentena ADD PRIMARY KEY (id_vuelo);

-- ---------------------------------------------------------------------------
-- Carga del hecho particionado: el router de particiones de PostgreSQL envía
-- cada fila a la partición de su mes. Orden por fecha y hora: así las filas
-- quedan físicamente ordenadas en disco, que es lo que aprovecha BRIN.
-- ---------------------------------------------------------------------------
TRUNCATE dw.fact_vuelo;
INSERT INTO dw.fact_vuelo
SELECT e.id_vuelo, e.fecha_vuelo, e.aerolinea, e.numero_vuelo, e.matricula,
       e.origen_id, e.destino_id,
       (calidad.min_dia(e.salida_prog_hhmm) / 60) % 24,
       e.salida_prog_utc, e.llegada_prog_utc,
       CASE WHEN NOT e.cancelado THEN e.salida_real_utc END,
       CASE WHEN NOT e.cancelado AND NOT e.desviado THEN e.llegada_real_utc END,
       e.retraso_salida, e.retraso_llegada, e.taxi_out, e.taxi_in,
       e.tiempo_aire_min, e.duracion_prog_min, e.distancia_millas,
       e.cancelado, e.codigo_cancelacion, e.desviado,
       e.retraso_aerolinea, e.retraso_clima, e.retraso_nas,
       e.retraso_seguridad, e.retraso_avion_previo
  FROM calidad.evaluacion e
 WHERE NOT EXISTS (SELECT 1 FROM unnest(e.reglas) x WHERE x LIKE 'Q\_%')
 ORDER BY e.fecha_vuelo, e.salida_prog_utc;

ANALYZE dw.fact_vuelo;

-- Reconciliación por mes: copiadas del CSV = hecho + cuarentena
CREATE OR REPLACE VIEW control.v_reconciliacion AS
SELECT c.anio_mes,
       c.filas_copiadas,
       coalesce(f.filas, 0)                           AS filas_hecho,
       coalesce(q.filas, 0)                           AS filas_cuarentena,
       c.filas_copiadas - coalesce(f.filas, 0) - coalesce(q.filas, 0) AS diferencia
  FROM control.carga_mes c
  LEFT JOIN (SELECT (extract(year FROM fecha_vuelo) * 100 + extract(month FROM fecha_vuelo))::int AS anio_mes,
                    count(*) AS filas
               FROM dw.fact_vuelo GROUP BY 1) f USING (anio_mes)
  LEFT JOIN (SELECT anio_mes, count(*) AS filas FROM calidad.vuelo_cuarentena GROUP BY 1) q USING (anio_mes)
 ORDER BY c.anio_mes;

-- Las columnas de evaluación ya están en el hecho y en la cuarentena.
DROP TABLE calidad.evaluacion;
