/* =====================================================================
   12_hallazgos.sql
   Consultas que respaldan cada cifra del README (leen los marts, son instantáneas).
   ===================================================================== */
USE TaxisNYC;
GO

-- 0. Volumen: fuente, modelo y cuarentena
SELECT SUM(CAST(filas_parquet AS BIGINT)) AS viajes_parquet, SUM(filas_hecho) AS viajes_hecho,
       SUM(filas_cuarentena) AS viajes_cuarentena,
       CAST(SUM(filas_cuarentena) * 100.0 / SUM(CAST(filas_parquet AS BIGINT)) AS DECIMAL(5,2)) AS pct_cuarentena
FROM rpt.cuadre_fuente;

SELECT regla, regla_nombre, SUM(viajes) AS viajes, SUM(total_usd) AS total_usd
FROM rpt.cuarentena_por_mes GROUP BY regla, regla_nombre ORDER BY regla;

-- 1. KPI del año y meses extremos
SELECT SUM(viajes) AS viajes, SUM(ingreso_total) AS ingreso, SUM(ingreso_total) / SUM(viajes) AS ticket,
       SUM(millas) / SUM(viajes) AS distancia_media, SUM(propinas) AS propinas
FROM mart.kpi_mensual;
SELECT periodo, viajes, viajes_por_dia, ticket_medio, var_viajes_dia_pct, rank_demanda_diaria
FROM mart.kpi_mensual ORDER BY periodo;

-- 2. Horas pico: top 3 por día y la hora más tranquila
SELECT nombre_dia, hora, viajes_por_dia, pct_del_dia, velocidad_media_mph
FROM mart.demanda_dia_hora WHERE rank_en_el_dia <= 3 ORDER BY dia_semana, rank_en_el_dia;
SELECT TOP (3) nombre_dia, hora, viajes_por_dia, velocidad_media_mph FROM mart.demanda_dia_hora ORDER BY viajes ASC;
SELECT hora, SUM(viajes) AS viajes, AVG(velocidad_media_mph) AS mph FROM mart.demanda_dia_hora
WHERE dia_semana <= 5 GROUP BY hora ORDER BY mph;

-- 3. Estacionalidad: días récord y mínimos, feriados
SELECT TOP (5) fecha, nombre_dia, viajes, feriado FROM mart.demanda_diaria ORDER BY viajes DESC;
SELECT TOP (5) fecha, nombre_dia, viajes, feriado FROM mart.demanda_diaria ORDER BY viajes ASC;
SELECT fecha, feriado, viajes, desvio_vs_mismo_dia_pct FROM mart.demanda_diaria WHERE es_feriado = 1 ORDER BY fecha;
SELECT es_fin_de_semana, AVG(viajes * 1.0) AS viajes_dia FROM mart.demanda_diaria GROUP BY es_fin_de_semana;

-- 4. Rutas: concentración (Pareto) y top
SELECT COUNT(*) AS rutas_con_viajes,
       MIN(CASE WHEN pct_acumulado >= 50 THEN rank_global END) AS rutas_para_50pct,
       MIN(CASE WHEN pct_acumulado >= 80 THEN rank_global END) AS rutas_para_80pct
FROM mart.ruta;
SELECT TOP (10) rank_global, zona_origen, zona_destino, viajes, ticket_medio, distancia_media FROM mart.ruta ORDER BY rank_global;
SELECT distrito_origen, SUM(viajes) AS viajes, CAST(SUM(viajes) * 100.0 / SUM(SUM(viajes)) OVER () AS DECIMAL(5,2)) AS pct
FROM mart.ruta GROUP BY distrito_origen ORDER BY viajes DESC;

-- 5. Propinas
SELECT * FROM mart.propina_pago ORDER BY viajes DESC;
SELECT TOP (5) zona, distrito, viajes_tarjeta, propina_pct_tarifa FROM mart.propina_zona ORDER BY propina_pct_tarifa DESC;
SELECT TOP (5) zona, distrito, viajes_tarjeta, propina_pct_tarifa FROM mart.propina_zona ORDER BY propina_pct_tarifa ASC;
SELECT distrito, SUM(viajes_tarjeta) AS viajes, AVG(propina_pct_tarifa) AS propina_media_pct
FROM mart.propina_zona GROUP BY distrito ORDER BY propina_media_pct DESC;

-- 6. Aeropuertos
SELECT aeropuerto, SUM(viajes) AS viajes, SUM(ingreso_total) AS ingreso, SUM(ingreso_total) / SUM(viajes) AS ticket,
       CAST(SUM(viajes) * 100.0 / (SELECT SUM(viajes) FROM mart.kpi_mensual) AS DECIMAL(5,2)) AS pct_viajes,
       CAST(SUM(ingreso_total) * 100.0 / (SELECT SUM(ingreso_total) FROM mart.kpi_mensual) AS DECIMAL(5,2)) AS pct_ingreso
FROM mart.aeropuerto_mensual GROUP BY aeropuerto ORDER BY viajes DESC;
SELECT aeropuerto, sentido, SUM(viajes) AS viajes, SUM(ingreso_total) / SUM(viajes) AS ticket
FROM mart.aeropuerto_mensual GROUP BY aeropuerto, sentido ORDER BY aeropuerto, sentido;

-- 7. Precio por milla
SELECT banda_distancia, periodo, tarifa_por_milla, mediana_tarifa_por_milla, velocidad_media_mph, var_vs_enero_pct
FROM mart.precio_milla_mensual WHERE periodo IN ('2024-01', '2024-12') ORDER BY banda_orden, periodo;
