/* =====================================================================
   08_vistas_powerbi.sql
   Capa rpt: lo único que lee Power BI. Nombres en español y sin columnas técnicas.

   Modelo estrella para Power BI (modo Import o DirectQuery):
     rpt.fact_viajes ── rpt.dim_fecha (fecha_key) · rpt.dim_hora (hora)
                     ├─ rpt.dim_zona_origen (zona_origen_id) · rpt.dim_zona_destino (zona_destino_id)
                     └─ rpt.dim_proveedor · rpt.dim_tipo_pago · rpt.dim_tarifa
   La zona es una dimensión de rol doble: se expone dos veces para no tener relaciones inactivas.
   Con 40 M filas conviene DirectQuery sobre el columnstore o Import solo de los marts (rpt.kpi_*).
   ===================================================================== */
USE TaxisNYC;
GO

CREATE OR ALTER VIEW rpt.fact_viajes AS
SELECT fecha_key, hora, zona_origen_id, zona_destino_id, proveedor_id, tipo_pago_id, tarifa_id,
       recogida, llegada, CAST(duracion_seg / 60.0 AS DECIMAL(9,2)) AS duracion_min, pasajeros,
       distancia_millas, tarifa_base, extra, impuesto_mta, propina, peajes, recargo_mejora,
       recargo_congestion, cargo_aeropuerto, total
FROM dw.fact_viaje;
GO

CREATE OR ALTER VIEW rpt.dim_fecha AS
SELECT fecha_key, fecha, anio, trimestre, mes, nombre_mes, mes_corto, periodo, dia, dia_semana, nombre_dia,
       semana_iso, es_fin_de_semana, es_feriado, feriado
FROM dw.dim_fecha;
GO
CREATE OR ALTER VIEW rpt.dim_hora AS SELECT hora, etiqueta, franja, orden_franja FROM dw.dim_hora;
GO
CREATE OR ALTER VIEW rpt.dim_zona_origen AS
SELECT zona_id AS zona_origen_id, distrito AS distrito_origen, zona AS zona_origen,
       zona_servicio AS zona_servicio_origen, es_aeropuerto AS origen_es_aeropuerto, aeropuerto AS aeropuerto_origen
FROM dw.dim_zona;
GO
CREATE OR ALTER VIEW rpt.dim_zona_destino AS
SELECT zona_id AS zona_destino_id, distrito AS distrito_destino, zona AS zona_destino,
       zona_servicio AS zona_servicio_destino, es_aeropuerto AS destino_es_aeropuerto, aeropuerto AS aeropuerto_destino
FROM dw.dim_zona;
GO
CREATE OR ALTER VIEW rpt.dim_proveedor AS SELECT proveedor_id, proveedor FROM dw.dim_proveedor;
GO
CREATE OR ALTER VIEW rpt.dim_tipo_pago AS SELECT tipo_pago_id, tipo_pago, registra_propina FROM dw.dim_tipo_pago;
GO
CREATE OR ALTER VIEW rpt.dim_tarifa AS SELECT tarifa_id, tarifa FROM dw.dim_tarifa;
GO

/* ---------- Marts (tablas pequeñas, ideales para Import) ---------- */
CREATE OR ALTER VIEW rpt.kpi_mensual AS
SELECT k.periodo, f.nombre_mes, k.dias, k.viajes, k.viajes_por_dia, k.ingreso_total, k.tarifa_base, k.propinas,
       k.millas, k.ticket_medio, k.distancia_media, k.duracion_media_min, k.recargo_congestion, k.cargo_aeropuerto,
       k.pct_viajes_anio, k.viajes_acumulados, k.var_viajes_dia_pct, k.rank_demanda_diaria
FROM mart.kpi_mensual AS k
JOIN (SELECT DISTINCT periodo, nombre_mes FROM dw.dim_fecha) AS f ON f.periodo = k.periodo;
GO
CREATE OR ALTER VIEW rpt.horas_pico AS
SELECT d.dia_semana, d.nombre_dia, d.hora, h.etiqueta, h.franja, d.viajes, d.viajes_por_dia, d.pct_del_dia,
       d.rank_en_el_dia, d.rank_semana, d.velocidad_media_mph, d.tarifa_por_milla,
       IIF(d.rank_en_el_dia <= 3, 1, 0) AS es_hora_pico
FROM mart.demanda_dia_hora AS d JOIN dw.dim_hora AS h ON h.hora = d.hora;
GO
CREATE OR ALTER VIEW rpt.demanda_diaria AS
SELECT fecha, periodo, nombre_dia, es_fin_de_semana, es_feriado, feriado, viajes, ingreso_total, media_movil_7d,
       media_movil_28d, viajes_semana_anterior, var_vs_semana_anterior_pct, desvio_vs_mismo_dia_pct, rank_anio
FROM mart.demanda_diaria;
GO
CREATE OR ALTER VIEW rpt.rutas_top AS
SELECT rank_global, rank_en_distrito_origen, distrito_origen, zona_origen, distrito_destino, zona_destino,
       viajes, ingreso_total, ticket_medio, distancia_media, duracion_media_min, es_misma_zona, pct_acumulado
FROM mart.ruta
WHERE rank_global <= 500;
GO
CREATE OR ALTER VIEW rpt.propinas_por_pago AS
SELECT tipo_pago, registra_propina, viajes, pct_viajes, pct_con_propina, propina_media, propina_pct_tarifa, ticket_medio
FROM mart.propina_pago;
GO
CREATE OR ALTER VIEW rpt.propinas_por_zona AS
SELECT zona_id, distrito, zona, zona_servicio, es_aeropuerto, viajes_tarjeta, propina_pct_tarifa, pct_con_propina,
       propina_media, quintil_propina, rank_en_distrito, dif_vs_ciudad_pp
FROM mart.propina_zona;
GO
CREATE OR ALTER VIEW rpt.aeropuertos AS
SELECT periodo, aeropuerto, sentido, viajes, ingreso_total, pct_viajes_mes, pct_ingreso_mes, ticket_medio,
       distancia_media, duracion_media_min, propina_pct_tarifa, var_viajes_mes_pct
FROM mart.aeropuerto_mensual;
GO
CREATE OR ALTER VIEW rpt.precio_por_milla AS
SELECT periodo, banda_orden, banda_distancia, viajes, tarifa_por_milla, mediana_tarifa_por_milla,
       velocidad_media_mph, var_vs_enero_pct, var_vs_mes_anterior_pct
FROM mart.precio_milla_mensual;
GO

/* ---------- Gobierno del dato: cargas, cuarentena y cuadre contra la fuente ---------- */
CREATE OR ALTER VIEW rpt.auditoria_cargas AS
SELECT carga_id, periodo, archivo, estado, inicio, fin, filas_archivo, filas_staging, filas_hecho, filas_cuarentena,
       seg_bulk_insert, seg_clasificacion, seg_columnstore, ms_switch, seg_total, mensaje
FROM qa.auditoria_carga;
GO
CREATE OR ALTER VIEW rpt.cuarentena_por_mes AS
SELECT q.periodo, q.regla, r.nombre AS regla_nombre, r.descripcion, COUNT_BIG(*) AS viajes,
       SUM(q.total) AS total_usd,
       CAST(COUNT_BIG(*) * 100.0 / c.filas AS DECIMAL(6,3)) AS pct_del_archivo
FROM qa.cuarentena_viaje AS q
JOIN qa.regla_calidad AS r ON r.codigo = q.regla
JOIN qa.cifras_control AS c ON c.periodo = q.periodo
GROUP BY q.periodo, q.regla, r.nombre, r.descripcion, c.filas;
GO

/* Cuadre por mes: Parquet (Python) = hecho + cuarentena (SQL). Diferencias deben ser 0. */
CREATE OR ALTER VIEW rpt.cuadre_fuente AS
WITH h AS (
    SELECT f.periodo, COUNT_BIG(*) AS filas, SUM(v.total) AS total, SUM(v.tarifa_base) AS tarifa_base,
           SUM(v.propina) AS propina, SUM(v.distancia_millas) AS distancia, SUM(IIF(v.pasajeros IS NULL, 1, 0)) AS pas_nulos
    FROM dw.fact_viaje AS v JOIN dw.dim_fecha AS f ON f.fecha_key = v.fecha_key
    GROUP BY f.periodo
),
q AS (
    SELECT periodo, COUNT_BIG(*) AS filas, SUM(ISNULL(total, 0)) AS total, SUM(ISNULL(tarifa_base, 0)) AS tarifa_base,
           SUM(ISNULL(propina, 0)) AS propina, SUM(ISNULL(distancia_millas, 0)) AS distancia,
           SUM(IIF(pasajeros IS NULL, 1, 0)) AS pas_nulos, SUM(IIF(regla = 'R01', 1, 0)) AS fuera_del_mes
    FROM qa.cuarentena_viaje GROUP BY periodo
)
SELECT c.periodo, c.filas AS filas_parquet, ISNULL(h.filas, 0) AS filas_hecho, ISNULL(q.filas, 0) AS filas_cuarentena,
       c.filas - ISNULL(h.filas, 0) - ISNULL(q.filas, 0)                          AS dif_filas,
       c.suma_total, c.suma_total - ISNULL(h.total, 0) - ISNULL(q.total, 0)       AS dif_total,
       c.suma_tarifa_base - ISNULL(h.tarifa_base, 0) - ISNULL(q.tarifa_base, 0)   AS dif_tarifa_base,
       c.suma_propina - ISNULL(h.propina, 0) - ISNULL(q.propina, 0)               AS dif_propina,
       c.suma_distancia - ISNULL(h.distancia, 0) - ISNULL(q.distancia, 0)         AS dif_distancia,
       c.pasajeros_nulos - ISNULL(h.pas_nulos, 0) - ISNULL(q.pas_nulos, 0)        AS dif_pasajeros_nulos,
       c.filas_fuera_del_mes - ISNULL(q.fuera_del_mes, 0)                         AS dif_fuera_del_mes,
       CAST(ISNULL(q.filas, 0) * 100.0 / c.filas AS DECIMAL(6,3))                 AS pct_cuarentena
FROM qa.cifras_control AS c
LEFT JOIN h ON h.periodo = c.periodo
LEFT JOIN q ON q.periodo = c.periodo;
GO
