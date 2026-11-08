-- 01 · Esquemas de la base `vuelos`
-- stg      : datos crudos y tipados tal como llegan de BTS
-- ref      : tablas de referencia (aeropuertos, aerolíneas, zonas horarias)
-- control  : auditoría de carga y cifras de control por mes
-- calidad  : reglas, cuarentena y conteos
-- dw       : modelo estrella (hecho particionado por mes + dimensiones)
-- analisis : resultados de negocio que se exportan a reports/
-- lab      : copia sin particionar para comparar BRIN frente a B-tree
-- perf     : mediciones de EXPLAIN (ANALYZE, BUFFERS)
\set ON_ERROR_STOP on
SET client_min_messages = warning;
CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS ref;
CREATE SCHEMA IF NOT EXISTS control;
CREATE SCHEMA IF NOT EXISTS calidad;
CREATE SCHEMA IF NOT EXISTS dw;
CREATE SCHEMA IF NOT EXISTS analisis;
CREATE SCHEMA IF NOT EXISTS lab;
CREATE SCHEMA IF NOT EXISTS perf;
