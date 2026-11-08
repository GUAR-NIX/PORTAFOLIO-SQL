/* =====================================================================
   07_vistas_analiticas.sql — Vistas de negocio y telemetría (rpt)
   ===================================================================== */
USE CitiBikeTuning;
GO

-- 1. Resumen de los experimentos de tuning (medianas en caliente y en frío)
CREATE OR ALTER VIEW rpt.resumen_experimentos_tuning AS
SELECT
    id_experimento, codigo_experimento, grupo_experimento, variante, rol_comparacion, tabla_objetivo,
    corridas_por_modo, lecturas_logicas, cpu_ms_caliente, duracion_ms_caliente, duracion_ms_frio,
    lecturas_fisicas_frio, memoria_kb, filas_devueltas, checksum_resultado, checksums_distintos,
    filas_estimadas_acceso, filas_reales_acceso, operador_principal, operadores_plan, modo_ejecucion,
    tiene_key_lookup, reduccion_lecturas_pct, speedup_caliente_x, speedup_frio_x
FROM perf.experimento_resultado;
GO

-- 1b. Cada corrida individual (para ver la dispersión alrededor de la mediana)
CREATE OR ALTER VIEW rpt.mediciones_corridas AS
SELECT m.codigo_experimento, e.grupo_experimento, e.rol_comparacion, m.modo, m.corrida,
       CAST(m.duracion_us / 1000.0 AS DECIMAL(12,3)) AS duracion_ms,
       CAST(m.cpu_us / 1000.0 AS DECIMAL(12,3)) AS cpu_ms,
       m.lecturas_logicas, m.lecturas_fisicas, m.memoria_kb, m.fuente_metricas, m.filas_devueltas, m.checksum_resultado
FROM perf.medicion AS m
JOIN perf.experimento_resultado AS e ON e.codigo_experimento = m.codigo_experimento;
GO

-- 1c. Tiempo de carga con y sin índices (mediana de las corridas)
CREATE OR ALTER VIEW rpt.tiempos_carga AS
SELECT DISTINCT
    estrategia,
    descripcion,
    COUNT(*) OVER (PARTITION BY estrategia) AS corridas,
    MAX(filas) OVER (PARTITION BY estrategia) AS filas,
    CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ms_insercion) OVER (PARTITION BY estrategia) AS DECIMAL(12,1)) AS mediana_ms_insercion,
    CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ms_indices) OVER (PARTITION BY estrategia) AS DECIMAL(12,1)) AS mediana_ms_indices,
    CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ms_total) OVER (PARTITION BY estrategia) AS DECIMAL(12,1)) AS mediana_ms_total,
    MIN(ms_total) OVER (PARTITION BY estrategia) AS min_ms_total,
    MAX(ms_total) OVER (PARTITION BY estrategia) AS max_ms_total
FROM perf.tiempo_carga;
GO

-- 1d. Bitácora del plan forzado con Query Store (E9)
CREATE OR ALTER VIEW rpt.demo_plan_forzado AS
SELECT paso, descripcion, query_id, plan_id, tiene_key_lookup, es_plan_forzado, fallos_forzado
FROM perf.demo_plan_forzado;
GO

-- 2. Curva empírica del Tipping Point
CREATE OR ALTER VIEW rpt.curva_tipping_point AS
SELECT
    id_punto,
    dias_ventana,
    etiqueta_ventana,
    filas_calificadas,
    pct_tabla,
    lecturas_heap_scan,
    lecturas_nocov_natural,
    operador_nocov_natural,
    lecturas_forzado_lookup,
    lecturas_covering_seek,
    lecturas_columnstore
FROM perf.curva_tipping_point;
GO

-- 3. Huella física de almacenamiento y compresión
CREATE OR ALTER VIEW rpt.huella_almacenamiento AS
SELECT
    orden,
    objeto_sql,
    arquitectura,
    filas,
    datos_mb,
    indices_secund_mb,
    total_reservado_mb,
    paginas_datos_8kb,
    bytes_por_fila,
    ratio_compresion_vs_heap
FROM perf.tamano_estructura;
GO

-- 4. Telemetría capturada en Query Store
CREATE OR ALTER VIEW rpt.auditoria_query_store AS
SELECT
    query_id,
    plan_id,
    etiqueta_bench,
    ejecuciones,
    lecturas_logicas_prom,
    cpu_ms_prom,
    duracion_ms_prom,
    memoria_kb_prom,
    es_plan_forzado,
    texto_consulta
FROM perf.resumen_query_store;
GO

-- 5. Evolución mensual (enero–marzo 2024): e-bikes, membresía, duración
CREATE OR ALTER VIEW rpt.kpi_mensual AS
SELECT
    f.anio,
    f.mes,
    f.nombre_mes,
    f.estacion_climatica,
    COUNT_BIG(*) AS total_viajes,
    SUM(CASE WHEN tb.es_electrica = 1 THEN 1 ELSE 0 END) AS viajes_electrica,
    SUM(CASE WHEN tb.es_electrica = 0 THEN 1 ELSE 0 END) AS viajes_clasica,
    CAST(ROUND(SUM(CASE WHEN tb.es_electrica = 1 THEN 100.0 ELSE 0.0 END) / COUNT_BIG(*), 2) AS DECIMAL(6,2)) AS pct_electrica,
    SUM(CASE WHEN v.es_miembro = 1 THEN 1 ELSE 0 END) AS viajes_miembro,
    SUM(CASE WHEN v.es_miembro = 0 THEN 1 ELSE 0 END) AS viajes_ocasional,
    CAST(ROUND(SUM(CASE WHEN v.es_miembro = 1 THEN 100.0 ELSE 0.0 END) / COUNT_BIG(*), 2) AS DECIMAL(6,2)) AS pct_miembro,
    CAST(ROUND(AVG(CAST(v.duracion_seg AS FLOAT)) / 60.0, 2) AS DECIMAL(8,2)) AS duracion_media_min,
    CAST(ROUND(AVG(CAST(v.distancia_m AS FLOAT)), 0) AS INT) AS distancia_media_m,
    CAST(ROUND(AVG(CAST(v.velocidad_kmh AS FLOAT)), 2) AS DECIMAL(6,2)) AS velocidad_media_kmh,
    SUM(CASE WHEN v.cruza_hudson = 1 THEN 1 ELSE 0 END) AS viajes_cruzan_hudson
FROM dw.fact_viaje AS v
INNER JOIN dw.dim_fecha AS f ON f.fecha_key = v.fecha_key
INNER JOIN dw.dim_tipo_bici AS tb ON tb.tipo_bici_key = v.tipo_bici_key
GROUP BY f.anio, f.mes, f.nombre_mes, f.estacion_climatica;
GO

-- 6. Perfil horario (bimodal laboral vs unimodal fin de semana)
CREATE OR ALTER VIEW rpt.perfil_horario_semanal AS
SELECT
    f.es_fin_de_semana,
    CASE WHEN f.es_fin_de_semana = 1 THEN N'Fin de semana (Sáb-Dom)' ELSE N'Día laboral (Lun-Vie)' END AS tipo_dia,
    v.hora,
    COUNT_BIG(*) AS total_viajes,
    SUM(CASE WHEN v.es_miembro = 1 THEN 1 ELSE 0 END) AS viajes_miembro,
    SUM(CASE WHEN v.es_miembro = 0 THEN 1 ELSE 0 END) AS viajes_ocasional,
    SUM(CASE WHEN tb.es_electrica = 1 THEN 1 ELSE 0 END) AS viajes_electrica,
    CAST(ROUND(AVG(CAST(v.duracion_seg AS FLOAT)) / 60.0, 2) AS DECIMAL(8,2)) AS duracion_media_min,
    CAST(ROUND(AVG(CAST(v.velocidad_kmh AS FLOAT)), 2) AS DECIMAL(6,2)) AS velocidad_media_kmh
FROM dw.fact_viaje AS v
INNER JOIN dw.dim_fecha AS f ON f.fecha_key = v.fecha_key
INNER JOIN dw.dim_tipo_bici AS tb ON tb.tipo_bici_key = v.tipo_bici_key
GROUP BY f.es_fin_de_semana, v.hora;
GO

-- 7. Asimetría operativa y necesidad de rebalanceo por estación (Fuentes vs Sumideros)
CREATE OR ALTER VIEW rpt.desbalance_estaciones_rebalanceo AS
WITH salidas AS
(
    SELECT
        estacion_origen_key AS estacion_key,
        COUNT_BIG(*) AS total_salidas,
        SUM(CASE WHEN hora BETWEEN 6 AND 10 THEN 1 ELSE 0 END) AS salidas_manana,
        SUM(CASE WHEN hora BETWEEN 16 AND 20 THEN 1 ELSE 0 END) AS salidas_tarde
    FROM dw.fact_viaje
    GROUP BY estacion_origen_key
),
llegadas AS
(
    SELECT
        estacion_destino_key AS estacion_key,
        COUNT_BIG(*) AS total_llegadas,
        SUM(CASE WHEN hora BETWEEN 6 AND 10 THEN 1 ELSE 0 END) AS llegadas_manana,
        SUM(CASE WHEN hora BETWEEN 16 AND 20 THEN 1 ELSE 0 END) AS llegadas_tarde
    FROM dw.fact_viaje
    GROUP BY estacion_destino_key
)
SELECT
    e.estacion_id,
    e.estacion_nombre,
    e.ciudad_zona,
    e.latitud,
    e.longitud,
    ISNULL(s.total_salidas, 0) AS total_salidas,
    ISNULL(l.total_llegadas, 0) AS total_llegadas,
    ISNULL(s.total_salidas, 0) + ISNULL(l.total_llegadas, 0) AS movimiento_total,
    -- Balance neto del trimestre: positivo = sumidero (acumula bicicletas), negativo = fuente (se vacía)
    ISNULL(l.total_llegadas, 0) - ISNULL(s.total_salidas, 0) AS balance_neto_trimestre,
    ISNULL(l.llegadas_manana, 0) - ISNULL(s.salidas_manana, 0) AS balance_neto_manana_6_10h,
    ISNULL(l.llegadas_tarde, 0) - ISNULL(s.salidas_tarde, 0) AS balance_neto_tarde_16_20h,
    CASE
        WHEN ISNULL(l.total_llegadas, 0) - ISNULL(s.total_salidas, 0) >= 500 THEN N'Sumidero neto (requiere retirar bicis)'
        WHEN ISNULL(l.total_llegadas, 0) - ISNULL(s.total_salidas, 0) <= -500 THEN N'Fuente neta (requiere reponer bicis)'
        ELSE N'Estación equilibrada'
    END AS rol_operativo
FROM dw.dim_estacion AS e
LEFT JOIN salidas AS s ON s.estacion_key = e.estacion_key
LEFT JOIN llegadas AS l ON l.estacion_key = e.estacion_key;
GO

-- 8. Principales corredores Origen-Destino y comparativa e-bike vs clásica
CREATE OR ALTER VIEW rpt.top_rutas_origen_destino AS
SELECT TOP (100)
    eo.estacion_id AS origen_id,
    eo.estacion_nombre AS origen_nombre,
    ed.estacion_id AS destino_id,
    ed.estacion_nombre AS destino_nombre,
    eo.ciudad_zona AS zona_origen,
    ed.ciudad_zona AS zona_destino,
    COUNT_BIG(*) AS viajes,
    CAST(ROUND(SUM(CASE WHEN tb.es_electrica = 1 THEN 100.0 ELSE 0.0 END) / COUNT_BIG(*), 2) AS DECIMAL(6,2)) AS pct_electrica,
    CAST(ROUND(SUM(CASE WHEN v.es_miembro = 1 THEN 100.0 ELSE 0.0 END) / COUNT_BIG(*), 2) AS DECIMAL(6,2)) AS pct_miembro,
    CAST(ROUND(AVG(CAST(v.duracion_seg AS FLOAT)) / 60.0, 2) AS DECIMAL(8,2)) AS duracion_media_min,
    CAST(ROUND(AVG(CAST(v.distancia_m AS FLOAT)), 0) AS INT) AS distancia_media_m,
    CAST(ROUND(AVG(CASE WHEN tb.es_electrica = 1 THEN CAST(v.velocidad_kmh AS FLOAT) END), 2) AS DECIMAL(6,2)) AS vel_electrica_kmh,
    CAST(ROUND(AVG(CASE WHEN tb.es_electrica = 0 THEN CAST(v.velocidad_kmh AS FLOAT) END), 2) AS DECIMAL(6,2)) AS vel_clasica_kmh
FROM dw.fact_viaje AS v
INNER JOIN dw.dim_estacion AS eo ON eo.estacion_key = v.estacion_origen_key
INNER JOIN dw.dim_estacion AS ed ON ed.estacion_key = v.estacion_destino_key
INNER JOIN dw.dim_tipo_bici AS tb ON tb.tipo_bici_key = v.tipo_bici_key
GROUP BY
    eo.estacion_id, eo.estacion_nombre,
    ed.estacion_id, ed.estacion_nombre,
    eo.ciudad_zona, ed.ciudad_zona
ORDER BY COUNT_BIG(*) DESC;
GO

-- 9. Resumen de auditoría de limpieza
CREATE OR ALTER VIEW rpt.resumen_limpieza_calidad AS
SELECT
    ISNULL(motivo_exclusion, 'VALIDO') AS estado_calidad,
    CASE WHEN motivo_exclusion IS NULL THEN 1 ELSE 0 END AS entra_al_modelo,
    COUNT_BIG(*) AS filas,
    CAST(ROUND(COUNT_BIG(*) * 100.0 / SUM(COUNT_BIG(*)) OVER (), 4) AS DECIMAL(8,4)) AS porcentaje_total,
    SUM(CAST(duracion_seg AS BIGINT)) AS suma_duracion_seg
FROM limpio.viaje
GROUP BY motivo_exclusion;
GO
