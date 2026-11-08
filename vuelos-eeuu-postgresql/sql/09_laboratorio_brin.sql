-- 09 · Laboratorio de índices: BRIN frente a B-tree sobre la fecha
--
-- Se usa una copia SIN particionar del hecho, ordenada por hora de salida,
-- para comparar los índices sobre la misma tabla de ~7 M de filas. Cada índice
-- se construye 3 veces y se guarda la mediana del tiempo y su tamaño.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

DROP TABLE IF EXISTS lab.vuelo_plano, lab.indice_comparacion, lab.correlacion CASCADE;

CREATE TABLE lab.vuelo_plano AS
SELECT * FROM dw.fact_vuelo ORDER BY salida_prog_utc, id_vuelo;
VACUUM ANALYZE lab.vuelo_plano;

-- Correlación física: 1 = el orden en disco coincide con el orden de la columna.
-- BRIN solo sirve cuando la correlación es alta.
CREATE TABLE lab.correlacion AS
SELECT attname AS columna, round(correlation::numeric, 4) AS correlacion, n_distinct
  FROM pg_stats
 WHERE schemaname = 'lab' AND tablename = 'vuelo_plano'
   AND attname IN ('fecha_vuelo', 'salida_prog_utc', 'distancia_millas', 'id_vuelo', 'aerolinea');

CREATE TABLE lab.indice_comparacion (
    indice             text,
    tipo               text,
    columna            text,
    pages_per_range    int,
    corrida            int,
    segundos_creacion  numeric(10,3),
    bytes              bigint,
    PRIMARY KEY (indice, corrida)
);

DO $$
DECLARE
    d   record;
    i   int;
    t0  timestamptz;
BEGIN
    FOR d IN SELECT * FROM (VALUES
        ('lab_btree_fecha',         'B-tree', 'fecha_vuelo',      NULL::int,
         'CREATE INDEX lab_btree_fecha ON lab.vuelo_plano (fecha_vuelo)'),
        ('lab_brin_fecha_128',      'BRIN',   'fecha_vuelo',      128,
         'CREATE INDEX lab_brin_fecha_128 ON lab.vuelo_plano USING brin (fecha_vuelo) WITH (pages_per_range = 128)'),
        ('lab_brin_fecha_32',       'BRIN',   'fecha_vuelo',      32,
         'CREATE INDEX lab_brin_fecha_32 ON lab.vuelo_plano USING brin (fecha_vuelo) WITH (pages_per_range = 32)'),
        ('lab_btree_distancia',     'B-tree', 'distancia_millas', NULL::int,
         'CREATE INDEX lab_btree_distancia ON lab.vuelo_plano (distancia_millas)'),
        ('lab_brin_distancia_32',   'BRIN',   'distancia_millas', 32,
         'CREATE INDEX lab_brin_distancia_32 ON lab.vuelo_plano USING brin (distancia_millas) WITH (pages_per_range = 32)')
    ) v(indice, tipo, columna, ppr, ddl)
    LOOP
        FOR i IN 1 .. 3 LOOP
            EXECUTE format('DROP INDEX IF EXISTS lab.%I', d.indice);
            t0 := clock_timestamp();
            EXECUTE d.ddl;
            INSERT INTO lab.indice_comparacion
            VALUES (d.indice, d.tipo, d.columna, d.ppr, i,
                    extract(epoch FROM clock_timestamp() - t0),
                    pg_relation_size(format('lab.%I', d.indice)::regclass));
        END LOOP;
        EXECUTE format('DROP INDEX lab.%I', d.indice);
    END LOOP;
END $$;

CREATE OR REPLACE VIEW lab.v_indice_resumen AS
SELECT indice, tipo, columna, pages_per_range,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY segundos_creacion) AS segundos_creacion_mediana,
       max(bytes)                                                      AS bytes,
       round(max(bytes) / 1048576.0, 3)                                AS mb,
       pg_relation_size('lab.vuelo_plano')                             AS bytes_tabla
  FROM lab.indice_comparacion
 GROUP BY indice, tipo, columna, pages_per_range
 ORDER BY columna, tipo DESC, pages_per_range;
