-- 11 · Verificaciones finales: si un control falla, el script se detiene
\set ON_ERROR_STOP on
SET client_min_messages = warning;

DROP TABLE IF EXISTS control.verificacion;
CREATE TABLE control.verificacion (
    control    text PRIMARY KEY,
    esperado   text,
    obtenido   text,
    ok         boolean NOT NULL
);

INSERT INTO control.verificacion
SELECT 'Todos los meses cargados en estado OK', '0 meses distintos de OK',
       count(*) FILTER (WHERE estado <> 'OK') || ' meses distintos de OK',
       count(*) FILTER (WHERE estado <> 'OK') = 0
  FROM control.carga_mes
UNION ALL
SELECT 'COPY = staging tipado (por mes)', '0 diferencias',
       count(*) FILTER (WHERE filas_copiadas <> filas_tipadas) || ' diferencias',
       count(*) FILTER (WHERE filas_copiadas <> filas_tipadas) = 0
  FROM control.carga_mes
UNION ALL
SELECT 'Cifras de control = filas copiadas (por mes)', '0 diferencias',
       count(*) FILTER (WHERE c.filas <> m.filas_copiadas) || ' diferencias',
       count(*) FILTER (WHERE c.filas <> m.filas_copiadas) = 0
  FROM control.cifras_mes c JOIN control.carga_mes m USING (anio_mes)
UNION ALL
SELECT 'Copiadas = hecho + cuarentena (por mes)', '0 filas de diferencia',
       sum(abs(diferencia)) || ' filas de diferencia', sum(abs(diferencia)) = 0
  FROM control.v_reconciliacion
UNION ALL
SELECT 'Partición DEFAULT vacía', '0 filas',
       count(*) || ' filas', count(*) = 0
  FROM dw.fact_vuelo_fuera_de_rango
UNION ALL
SELECT 'Cada partición mensual solo tiene fechas de su mes', '0 filas fuera de su mes',
       count(*) || ' filas fuera de su mes', count(*) = 0
  FROM (SELECT tableoid::regclass::text AS particion, fecha_vuelo FROM dw.fact_vuelo) x
 WHERE particion <> 'dw.fact_vuelo_' || to_char(fecha_vuelo, 'YYYY_MM')
UNION ALL
SELECT 'Vista materializada = hecho (vuelos programados)',
       (SELECT count(*) FROM dw.fact_vuelo)::text,
       sum(programados)::text,
       sum(programados) = (SELECT count(*) FROM dw.fact_vuelo)
  FROM dw.mv_puntualidad_diaria
UNION ALL
SELECT 'Minutos por causa = retraso de llegada (llegadas con 15+ min)', '0 vuelos con diferencia',
       count(*) || ' vuelos con diferencia', count(*) = 0
  FROM dw.fact_vuelo
 WHERE retraso_llegada >= 15
   AND retraso_aerolinea + retraso_clima + retraso_nas + retraso_seguridad + retraso_avion_previo <> retraso_llegada
UNION ALL
SELECT 'Llegada programada UTC = salida UTC + duración programada', '0 vuelos con diferencia',
       count(*) || ' vuelos con diferencia', count(*) = 0
  FROM dw.fact_vuelo
 WHERE llegada_prog_utc <> salida_prog_utc + make_interval(mins => duracion_prog_min)
UNION ALL
SELECT 'Cancelados sin horas reales', '0 vuelos con hora real',
       count(*) || ' vuelos con hora real', count(*) = 0
  FROM dw.fact_vuelo WHERE cancelado AND (salida_real_utc IS NOT NULL OR llegada_real_utc IS NOT NULL)
UNION ALL
SELECT 'Cada vuelo en cuarentena tiene al menos un motivo', '0 sin motivo',
       count(*) || ' sin motivo', count(*) = 0
  FROM calidad.vuelo_cuarentena WHERE cardinality(motivos) = 0
UNION ALL
SELECT 'Rendimiento: todas las variantes de un experimento devuelven lo mismo', '0 experimentos con checksums distintos',
       count(*) || ' experimentos con checksums distintos', count(*) = 0
  FROM (SELECT experimento FROM perf.variante GROUP BY experimento HAVING count(DISTINCT checksum) > 1) x
UNION ALL
SELECT 'Rendimiento: P1 con rango lee 1 partición', '1 partición',
       (SELECT count(*) FROM jsonb_path_query(plan, 'strict $.**."Relation Name"') r
         WHERE r #>> '{}' LIKE 'fact_vuelo_%') || ' particiones',
       (SELECT count(*) FROM jsonb_path_query(plan, 'strict $.**."Relation Name"') r
         WHERE r #>> '{}' LIKE 'fact_vuelo_%') = 1
  FROM perf.medicion WHERE experimento = 'P1' AND variante = 'Particionada, filtro por rango' AND corrida = 1
UNION ALL
SELECT 'Índice parcial más pequeño que el B-tree completo', 'parcial < completo',
       max(bytes) FILTER (WHERE indice = 'fact_vuelo_cancelados') || ' < '
           || max(bytes) FILTER (WHERE indice = 'fact_vuelo_aerolinea_fecha_completo'),
       max(bytes) FILTER (WHERE indice = 'fact_vuelo_cancelados')
           < max(bytes) FILTER (WHERE indice = 'fact_vuelo_aerolinea_fecha_completo')
  FROM perf.indice_tamano;

-- La CTE recursiva solo encadena tramos contiguos del mismo avión (julio completo)
INSERT INTO control.verificacion
SELECT 'Cadenas: cada paso > 0 sale del aeropuerto donde llegó el tramo anterior', '0 pasos discontinuos',
       count(*) || ' pasos discontinuos', count(*) = 0
  FROM analisis.cadenas_retraso(date '2024-07-01', date '2024-07-31') c
  JOIN dw.tramo_avion t USING (matricula, fecha_vuelo, n_tramo)
 WHERE c.paso > 0 AND NOT t.continua;

DO $$
DECLARE
    fallas text;
BEGIN
    SELECT string_agg(control, '; ') INTO fallas FROM control.verificacion WHERE NOT ok;
    IF fallas IS NOT NULL THEN
        RAISE EXCEPTION 'Controles fallidos: %', fallas;
    END IF;
END $$;

SELECT control, obtenido, ok FROM control.verificacion ORDER BY control;
