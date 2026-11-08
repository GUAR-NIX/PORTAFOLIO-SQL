-- 10 · Rendimiento: EXPLAIN (ANALYZE, BUFFERS) antes y después
--
-- perf.medir ejecuta una consulta 1 vez para calentar la caché y luego
-- p_corridas veces con EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON); guarda el
-- tiempo, los bloques leídos y el plan de cada corrida. El reporte usa la
-- mediana. Todas las variantes de un experimento devuelven las mismas filas
-- (lo verifica sql/11_verificaciones.sql con el checksum de cada resultado).
\set ON_ERROR_STOP on
SET client_min_messages = warning;

DROP TABLE IF EXISTS perf.medicion, perf.plan_texto, perf.variante, perf.indice_tamano CASCADE;

CREATE TABLE perf.variante (
    experimento   text,
    variante      text,
    rol           text,          -- Antes / Intermedio / Después
    orden         int,
    descripcion   text,
    consulta      text,
    filas         bigint,
    checksum      text,          -- md5 del resultado ordenado: mismas filas en cada variante
    PRIMARY KEY (experimento, variante)
);
CREATE TABLE perf.medicion (
    experimento        text,
    variante           text,
    corrida            int,      -- 0 = calentamiento (no entra en la mediana)
    ms_ejecucion       numeric,
    ms_planificacion   numeric,
    bloques_cache      bigint,   -- Shared Hit Blocks (estaban en shared_buffers)
    bloques_leidos     bigint,   -- Shared Read Blocks (vinieron del sistema operativo/disco)
    plan               jsonb,
    PRIMARY KEY (experimento, variante, corrida)
);
CREATE TABLE perf.plan_texto (
    experimento   text,
    variante      text,
    plan          text,
    PRIMARY KEY (experimento, variante)
);
CREATE TABLE perf.indice_tamano (
    indice   text PRIMARY KEY,
    tipo     text,
    bytes    bigint
);

CREATE OR REPLACE PROCEDURE perf.medir(p_exp text, p_var text, p_rol text, p_orden int,
                                       p_desc text, p_sql text, p_corridas int DEFAULT 7)
LANGUAGE plpgsql AS $$
DECLARE
    v_plan  json;
    v_texto text := '';
    r       record;
    i       int;
    v_filas bigint;
    v_md5   text;
BEGIN
    EXECUTE format('SELECT count(*), md5(string_agg(x::text, %L ORDER BY x::text)) FROM (%s) x', '|', p_sql)
       INTO v_filas, v_md5;
    INSERT INTO perf.variante VALUES (p_exp, p_var, p_rol, p_orden, p_desc, p_sql, v_filas, v_md5)
    ON CONFLICT (experimento, variante) DO UPDATE
       SET rol = EXCLUDED.rol, orden = EXCLUDED.orden, descripcion = EXCLUDED.descripcion,
           consulta = EXCLUDED.consulta, filas = EXCLUDED.filas, checksum = EXCLUDED.checksum;
    DELETE FROM perf.medicion WHERE experimento = p_exp AND variante = p_var;

    FOR i IN 0 .. p_corridas LOOP
        EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || p_sql INTO v_plan;
        INSERT INTO perf.medicion VALUES (
            p_exp, p_var, i,
            (v_plan -> 0 ->> 'Execution Time')::numeric,
            (v_plan -> 0 ->> 'Planning Time')::numeric,
            (v_plan -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint,
            (v_plan -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint,
            v_plan::jsonb);
    END LOOP;

    FOR r IN EXECUTE 'EXPLAIN (ANALYZE, BUFFERS) ' || p_sql LOOP
        v_texto := v_texto || r."QUERY PLAN" || E'\n';
    END LOOP;
    INSERT INTO perf.plan_texto VALUES (p_exp, p_var, v_texto)
    ON CONFLICT (experimento, variante) DO UPDATE SET plan = EXCLUDED.plan;
END $$;

-- Tamaño de un índice (en una tabla particionada, suma de todas sus particiones)
CREATE OR REPLACE FUNCTION perf.bytes_indice(p_indice regclass) RETURNS bigint
LANGUAGE sql STABLE AS $$
    SELECT sum(pg_relation_size(relid))::bigint FROM pg_partition_tree(p_indice)
$$;

-- ===========================================================================
-- P1 · Poda de particiones (partition pruning): un mes de vuelos
-- ===========================================================================
CALL perf.medir('P1', 'Tabla sin particionar', 'Antes', 1,
    'lab.vuelo_plano (7 M filas, sin índices): recorre toda la tabla',
    $q$SELECT aerolinea, count(*) AS vuelos, round(avg(retraso_llegada), 2) AS retraso
         FROM lab.vuelo_plano
        WHERE fecha_vuelo >= DATE '2024-07-01' AND fecha_vuelo < DATE '2024-08-01'
        GROUP BY aerolinea$q$);
CALL perf.medir('P1', 'Particionada, filtro con función', 'Intermedio', 2,
    'dw.fact_vuelo con extract(month FROM fecha_vuelo) = 7: el planificador no puede podar',
    $q$SELECT aerolinea, count(*) AS vuelos, round(avg(retraso_llegada), 2) AS retraso
         FROM dw.fact_vuelo
        WHERE extract(year FROM fecha_vuelo) = 2024 AND extract(month FROM fecha_vuelo) = 7
        GROUP BY aerolinea$q$);
CALL perf.medir('P1', 'Particionada, filtro por rango', 'Después', 3,
    'dw.fact_vuelo con rango sobre la clave de partición: solo lee la partición de julio',
    $q$SELECT aerolinea, count(*) AS vuelos, round(avg(retraso_llegada), 2) AS retraso
         FROM dw.fact_vuelo
        WHERE fecha_vuelo >= DATE '2024-07-01' AND fecha_vuelo < DATE '2024-08-01'
        GROUP BY aerolinea$q$);

-- ===========================================================================
-- P2 · BRIN frente a B-tree: una semana de vuelos en la tabla sin particionar
-- ===========================================================================
DROP INDEX IF EXISTS lab.lab_btree_fecha, lab.lab_brin_fecha_128, lab.lab_brin_fecha_32;
\set consulta_p2 'SELECT fecha_vuelo, count(*) AS vuelos, sum(retraso_llegada) AS minutos FROM lab.vuelo_plano WHERE fecha_vuelo BETWEEN DATE ''2024-07-15'' AND DATE ''2024-07-21'' GROUP BY fecha_vuelo'
CALL perf.medir('P2', 'Sin índice', 'Antes', 1,
    'Seq Scan de 7 M filas para quedarse con una semana', :'consulta_p2');
CREATE INDEX lab_btree_fecha ON lab.vuelo_plano (fecha_vuelo);
CALL perf.medir('P2', 'B-tree (fecha)', 'Alternativa', 2,
    'Índice B-tree: una entrada por fila', :'consulta_p2');
DROP INDEX lab.lab_btree_fecha;
CREATE INDEX lab_brin_fecha_128 ON lab.vuelo_plano USING brin (fecha_vuelo) WITH (pages_per_range = 128);
CALL perf.medir('P2', 'BRIN 128 páginas', 'Después', 3,
    'BRIN: mínimo y máximo de cada bloque de 128 páginas', :'consulta_p2');
DROP INDEX lab.lab_brin_fecha_128;
CREATE INDEX lab_brin_fecha_32 ON lab.vuelo_plano USING brin (fecha_vuelo) WITH (pages_per_range = 32);
CALL perf.medir('P2', 'BRIN 32 páginas', 'Después', 4,
    'BRIN con rangos más finos: índice algo mayor, menos páginas descartadas al revisar', :'consulta_p2');
DROP INDEX lab.lab_brin_fecha_32;

-- ===========================================================================
-- P3 · BRIN en una columna SIN correlación física (distancia)
-- ===========================================================================
\set consulta_p3 'SELECT aerolinea, count(*) AS vuelos FROM lab.vuelo_plano WHERE distancia_millas BETWEEN 2400 AND 2500 GROUP BY aerolinea'
CALL perf.medir('P3', 'Sin índice', 'Antes', 1,
    'Seq Scan: rutas de 2.400 a 2.500 millas', :'consulta_p3');
CREATE INDEX lab_brin_distancia_32 ON lab.vuelo_plano USING brin (distancia_millas) WITH (pages_per_range = 32);
CALL perf.medir('P3', 'BRIN (distancia)', 'Intermedio', 2,
    'El planificador decide si usar el BRIN según la correlación física que estima en pg_stats',
    :'consulta_p3');
-- Forzado: se prohíbe el Seq Scan para ver qué haría el BRIN en una columna desordenada
SET enable_seqscan = off;
CALL perf.medir('P3', 'BRIN forzado (enable_seqscan = off)', 'Intermedio', 3,
    'Cada bloque contiene distancias cortas y largas: el BRIN no descarta casi ninguno',
    :'consulta_p3');
RESET enable_seqscan;
DROP INDEX lab.lab_brin_distancia_32;
CREATE INDEX lab_btree_distancia ON lab.vuelo_plano (distancia_millas);
CALL perf.medir('P3', 'B-tree (distancia)', 'Después', 4,
    'B-tree: no depende del orden físico', :'consulta_p3');
DROP INDEX lab.lab_btree_distancia;

-- ===========================================================================
-- P4 · Índice parcial: cancelaciones de Delta del 18 al 25 de julio
-- ===========================================================================
DROP INDEX IF EXISTS dw.fact_vuelo_cancelados;
\set consulta_p4 'SELECT fecha_vuelo, count(*) AS cancelados FROM dw.fact_vuelo WHERE cancelado AND aerolinea = ''DL'' AND fecha_vuelo BETWEEN DATE ''2024-07-18'' AND DATE ''2024-07-25'' GROUP BY fecha_vuelo'
CALL perf.medir('P4', 'Sin índice', 'Antes', 1,
    'Seq Scan de la partición de julio (ya podada)', :'consulta_p4');
CREATE INDEX fact_vuelo_aerolinea_fecha_completo ON dw.fact_vuelo (aerolinea, fecha_vuelo, cancelado);
CALL perf.medir('P4', 'B-tree completo', 'Alternativa', 2,
    'B-tree (aerolinea, fecha_vuelo, cancelado) sobre todas las filas', :'consulta_p4');
INSERT INTO perf.indice_tamano
VALUES ('fact_vuelo_aerolinea_fecha_completo', 'B-tree completo',
        perf.bytes_indice('dw.fact_vuelo_aerolinea_fecha_completo'));
DROP INDEX dw.fact_vuelo_aerolinea_fecha_completo;
CREATE INDEX fact_vuelo_cancelados ON dw.fact_vuelo (aerolinea, fecha_vuelo) WHERE cancelado;
CALL perf.medir('P4', 'Índice parcial', 'Después', 3,
    'B-tree (aerolinea, fecha_vuelo) WHERE cancelado: solo indexa los vuelos cancelados', :'consulta_p4');
INSERT INTO perf.indice_tamano
VALUES ('fact_vuelo_cancelados', 'B-tree parcial (WHERE cancelado)', perf.bytes_indice('dw.fact_vuelo_cancelados'));

-- ===========================================================================
-- P5 · Historial de un avión en el año (el que más voló)
-- ===========================================================================
SELECT matricula AS avion
  FROM dw.fact_vuelo WHERE matricula IS NOT NULL AND NOT cancelado
 GROUP BY matricula ORDER BY count(*) DESC, matricula LIMIT 1 \gset
DROP INDEX IF EXISTS dw.fact_vuelo_avion;
\set consulta_p5 'SELECT salida_prog_utc, origen_id, destino_id, retraso_salida, retraso_llegada FROM dw.fact_vuelo WHERE matricula = ' :'avion' ' AND NOT cancelado ORDER BY salida_prog_utc'
CALL perf.medir('P5', 'Sin índice', 'Antes', 1,
    'Seq Scan de las 13 particiones: la matrícula no es la clave de partición', :'consulta_p5');
CREATE INDEX fact_vuelo_avion ON dw.fact_vuelo (matricula, salida_prog_utc)
    WHERE matricula IS NOT NULL AND NOT cancelado;
CALL perf.medir('P5', 'Índice parcial (matrícula, salida)', 'Después', 2,
    'Index Scan en cada partición; el orden del índice evita el Sort', :'consulta_p5');
INSERT INTO perf.indice_tamano
VALUES ('fact_vuelo_avion', 'B-tree parcial (operados con matrícula)', perf.bytes_indice('dw.fact_vuelo_avion'));

-- ===========================================================================
-- P6 · Reporte anual por aerolínea: hecho frente a vista materializada
-- ===========================================================================
CALL perf.medir('P6', 'Desde el hecho', 'Antes', 1,
    'Agrega los ~7 M de vuelos de dw.fact_vuelo',
    $q$SELECT aerolinea, count(*) AS programados,
              round(100.0 * count(*) FILTER (WHERE retraso_llegada < 15) / count(*), 2) AS pct_puntuales
         FROM dw.fact_vuelo GROUP BY aerolinea$q$);
CALL perf.medir('P6', 'Desde la vista materializada', 'Después', 2,
    'Agrega dw.mv_puntualidad_diaria (día × aerolínea × origen)',
    $q$SELECT aerolinea, sum(programados) AS programados,
              round(100.0 * sum(puntuales) / sum(programados), 2) AS pct_puntuales
         FROM dw.mv_puntualidad_diaria GROUP BY aerolinea$q$);

-- Tamaños de los demás índices del hecho y de la vista materializada
INSERT INTO perf.indice_tamano VALUES
    ('fact_vuelo_brin_salida', 'BRIN (salida_prog_utc, 32 páginas)', perf.bytes_indice('dw.fact_vuelo_brin_salida')),
    ('fact_vuelo_retraso_grave', 'B-tree parcial (retraso >= 60)', perf.bytes_indice('dw.fact_vuelo_retraso_grave')),
    ('fact_vuelo_pkey', 'B-tree (clave primaria)', perf.bytes_indice('dw.fact_vuelo_pkey')),
    ('mv_puntualidad_diaria', 'Vista materializada (datos)', pg_relation_size('dw.mv_puntualidad_diaria')),
    ('fact_vuelo (datos)', 'Tabla particionada (datos)',
        (SELECT sum(pg_relation_size(relid))::bigint FROM pg_partition_tree('dw.fact_vuelo')));

-- Resumen: mediana de las corridas 1..n
CREATE OR REPLACE VIEW perf.v_resumen AS
SELECT v.experimento, v.variante, v.rol, v.orden, v.descripcion, v.filas, v.checksum,
       count(*)                                                                  AS corridas,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY m.ms_ejecucion)::numeric, 3) AS ms_mediana,
       round(min(m.ms_ejecucion), 3)                                             AS ms_min,
       round(max(m.ms_ejecucion), 3)                                             AS ms_max,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY m.ms_planificacion)::numeric, 3) AS ms_planificacion,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY m.bloques_cache + m.bloques_leidos) AS bloques_mediana
  FROM perf.variante v
  JOIN perf.medicion m USING (experimento, variante)
 WHERE m.corrida > 0
 GROUP BY v.experimento, v.variante, v.rol, v.orden, v.descripcion, v.filas, v.checksum
 ORDER BY v.experimento, v.orden;

-- Tiempo de refrescar la vista materializada sin bloquear lecturas
DROP TABLE IF EXISTS perf.tiempo_operacion;
CREATE TABLE perf.tiempo_operacion (operacion text PRIMARY KEY, segundos numeric(10,3));
DO $$
DECLARE t0 timestamptz;
BEGIN
    t0 := clock_timestamp();
    REFRESH MATERIALIZED VIEW CONCURRENTLY dw.mv_puntualidad_diaria;
    INSERT INTO perf.tiempo_operacion VALUES
        ('REFRESH MATERIALIZED VIEW CONCURRENTLY', extract(epoch FROM clock_timestamp() - t0));
END $$;
