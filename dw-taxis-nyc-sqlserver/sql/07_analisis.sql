/* =====================================================================
   07_analisis.sql
   Análisis de negocio con funciones de ventana, materializado en mart.*

     mart.kpi_mensual           LAG, SUM() OVER acumulado, RANK
     mart.demanda_dia_hora      horas pico: RANK y % del día con PARTITION BY día de semana
     mart.demanda_diaria        estacionalidad: medias móviles de 7 y 28 días, LAG 7 (mismo día semana anterior)
     mart.ruta                  rutas top: ROW_NUMBER global y por distrito, % acumulado (Pareto)
     mart.propina_pago          propinas por tipo de pago
     mart.propina_zona          propinas por zona de origen (tarjeta): NTILE(5), RANK dentro del distrito
     mart.aeropuerto_mensual    JFK, LaGuardia y Newark: participación del mes y variación con LAG
     mart.precio_milla_mensual  tarifa por milla por banda de distancia: mediana aproximada, FIRST_VALUE, LAG

   Cada mart se calcula en una sola pasada agregada sobre el columnstore (modo batch) y las
   funciones de ventana trabajan sobre el resultado agregado, que es pequeño.
   ===================================================================== */
USE TaxisNYC;
GO

CREATE OR ALTER PROCEDURE etl.sp_calcular_analisis
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t DATETIME2(3) = SYSDATETIME();

    /* ---------- 1. KPI mensual ---------- */
    DROP TABLE IF EXISTS mart.kpi_mensual;
    WITH m AS (
        SELECT f.periodo, COUNT(DISTINCT f.fecha_key) AS dias,
               COUNT_BIG(*) AS viajes, SUM(v.total) AS ingreso_total, SUM(v.tarifa_base) AS tarifa_base,
               SUM(v.propina) AS propinas, SUM(v.distancia_millas) AS millas,
               AVG(CAST(v.duracion_seg AS FLOAT)) / 60 AS duracion_media_min,
               SUM(v.recargo_congestion) AS recargo_congestion, SUM(v.cargo_aeropuerto) AS cargo_aeropuerto
        FROM dw.fact_viaje AS v
        JOIN dw.dim_fecha AS f ON f.fecha_key = v.fecha_key
        GROUP BY f.periodo
    )
    SELECT periodo, dias, viajes, ingreso_total, tarifa_base, propinas, millas, recargo_congestion, cargo_aeropuerto,
           CAST(viajes * 1.0 / dias AS DECIMAL(12,1))                         AS viajes_por_dia,
           CAST(ingreso_total / viajes AS DECIMAL(9,2))                       AS ticket_medio,
           CAST(millas / viajes AS DECIMAL(9,2))                              AS distancia_media,
           CAST(duracion_media_min AS DECIMAL(9,1))                           AS duracion_media_min,
           CAST(viajes * 1.0 / SUM(viajes) OVER () * 100 AS DECIMAL(5,2))     AS pct_viajes_anio,
           SUM(viajes) OVER (ORDER BY periodo ROWS UNBOUNDED PRECEDING)       AS viajes_acumulados,
           CAST((viajes * 1.0 / dias) / NULLIF(LAG(viajes * 1.0 / dias) OVER (ORDER BY periodo), 0) * 100 - 100
                AS DECIMAL(6,2))                                              AS var_viajes_dia_pct,
           RANK() OVER (ORDER BY viajes * 1.0 / dias DESC)                    AS rank_demanda_diaria
    INTO mart.kpi_mensual
    FROM m;

    /* ---------- 2. Horas pico (día de semana × hora) ---------- */
    DROP TABLE IF EXISTS mart.demanda_dia_hora;
    WITH dias AS (SELECT dia_semana, COUNT(*) AS n_dias FROM dw.dim_fecha WHERE anio = 2024 GROUP BY dia_semana),
    a AS (
        SELECT f.dia_semana, f.nombre_dia, v.hora, COUNT_BIG(*) AS viajes,
               SUM(v.distancia_millas) AS millas, SUM(CAST(v.duracion_seg AS BIGINT)) AS segundos,
               SUM(v.tarifa_base) AS tarifa_base
        FROM dw.fact_viaje AS v
        JOIN dw.dim_fecha AS f ON f.fecha_key = v.fecha_key
        GROUP BY f.dia_semana, f.nombre_dia, v.hora
    )
    SELECT a.dia_semana, a.nombre_dia, a.hora, a.viajes,
           CAST(a.viajes * 1.0 / d.n_dias AS DECIMAL(10,1))                                        AS viajes_por_dia,
           CAST(a.viajes * 100.0 / SUM(a.viajes) OVER (PARTITION BY a.dia_semana) AS DECIMAL(5,2)) AS pct_del_dia,
           RANK() OVER (PARTITION BY a.dia_semana ORDER BY a.viajes DESC)                          AS rank_en_el_dia,
           RANK() OVER (ORDER BY a.viajes DESC)                                                    AS rank_semana,
           CAST(a.millas * 3600.0 / NULLIF(a.segundos, 0) AS DECIMAL(5,1))                         AS velocidad_media_mph,
           CAST(a.tarifa_base / NULLIF(a.millas, 0) AS DECIMAL(6,2))                               AS tarifa_por_milla
    INTO mart.demanda_dia_hora
    FROM a JOIN dias AS d ON d.dia_semana = a.dia_semana;

    /* ---------- 3. Estacionalidad diaria ---------- */
    DROP TABLE IF EXISTS mart.demanda_diaria;
    WITH d AS (
        SELECT v.fecha_key, COUNT_BIG(*) AS viajes, SUM(v.total) AS ingreso_total
        FROM dw.fact_viaje AS v GROUP BY v.fecha_key
    )
    SELECT f.fecha_key, f.fecha, f.periodo, f.dia_semana, f.nombre_dia, f.es_fin_de_semana, f.es_feriado, f.feriado,
           d.viajes, d.ingreso_total,
           CAST(AVG(d.viajes * 1.0) OVER (ORDER BY f.fecha ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS DECIMAL(10,1))
               AS media_movil_7d,
           CAST(AVG(d.viajes * 1.0) OVER (ORDER BY f.fecha ROWS BETWEEN 27 PRECEDING AND CURRENT ROW) AS DECIMAL(10,1))
               AS media_movil_28d,
           LAG(d.viajes, 7) OVER (ORDER BY f.fecha)                                                 AS viajes_semana_anterior,
           CAST(d.viajes * 100.0 / NULLIF(LAG(d.viajes, 7) OVER (ORDER BY f.fecha), 0) - 100 AS DECIMAL(6,1))
               AS var_vs_semana_anterior_pct,
           CAST(d.viajes * 100.0 / AVG(d.viajes * 1.0) OVER (PARTITION BY f.dia_semana) - 100 AS DECIMAL(6,1))
               AS desvio_vs_mismo_dia_pct,       -- vs. el promedio anual de ese día de la semana
           DENSE_RANK() OVER (ORDER BY d.viajes DESC)                                               AS rank_anio,
           DENSE_RANK() OVER (ORDER BY d.viajes ASC)                                                AS rank_anio_asc
    INTO mart.demanda_diaria
    FROM d JOIN dw.dim_fecha AS f ON f.fecha_key = d.fecha_key;

    /* ---------- 4. Rutas origen → destino ---------- */
    DROP TABLE IF EXISTS mart.ruta;
    WITH r AS (
        SELECT zona_origen_id, zona_destino_id, COUNT_BIG(*) AS viajes, SUM(total) AS ingreso_total,
               SUM(distancia_millas) AS millas, SUM(CAST(duracion_seg AS BIGINT)) AS segundos
        FROM dw.fact_viaje GROUP BY zona_origen_id, zona_destino_id
    )
    SELECT r.zona_origen_id, r.zona_destino_id, o.distrito AS distrito_origen, o.zona AS zona_origen,
           d.distrito AS distrito_destino, d.zona AS zona_destino, r.viajes, r.ingreso_total,
           CAST(r.millas / r.viajes AS DECIMAL(7,2))                          AS distancia_media,
           CAST(r.segundos / 60.0 / r.viajes AS DECIMAL(7,1))                 AS duracion_media_min,
           CAST(r.ingreso_total / r.viajes AS DECIMAL(9,2))                   AS ticket_medio,
           IIF(r.zona_origen_id = r.zona_destino_id, 1, 0)                    AS es_misma_zona,
           ROW_NUMBER() OVER (ORDER BY r.viajes DESC, r.zona_origen_id, r.zona_destino_id) AS rank_global,
           ROW_NUMBER() OVER (PARTITION BY o.distrito ORDER BY r.viajes DESC, r.zona_origen_id, r.zona_destino_id)
               AS rank_en_distrito_origen,
           CAST(SUM(r.viajes) OVER (ORDER BY r.viajes DESC, r.zona_origen_id, r.zona_destino_id ROWS UNBOUNDED PRECEDING)
                * 100.0 / SUM(r.viajes) OVER () AS DECIMAL(6,2))              AS pct_acumulado
    INTO mart.ruta
    FROM r
    JOIN dw.dim_zona AS o ON o.zona_id = r.zona_origen_id
    JOIN dw.dim_zona AS d ON d.zona_id = r.zona_destino_id;

    /* ---------- 5. Propinas por tipo de pago ---------- */
    DROP TABLE IF EXISTS mart.propina_pago;
    SELECT p.tipo_pago_id, p.tipo_pago, p.registra_propina, COUNT_BIG(*) AS viajes,
           CAST(COUNT_BIG(*) * 100.0 / SUM(COUNT_BIG(*)) OVER () AS DECIMAL(5,2))            AS pct_viajes,
           CAST(SUM(IIF(v.propina > 0, 1, 0)) * 100.0 / COUNT_BIG(*) AS DECIMAL(5,2))       AS pct_con_propina,
           CAST(AVG(v.propina) AS DECIMAL(7,2))                                              AS propina_media,
           CAST(SUM(v.propina) * 100.0 / NULLIF(SUM(v.tarifa_base), 0) AS DECIMAL(5,2))      AS propina_pct_tarifa,
           CAST(AVG(v.total) AS DECIMAL(7,2))                                                AS ticket_medio
    INTO mart.propina_pago
    FROM dw.fact_viaje AS v JOIN dw.dim_tipo_pago AS p ON p.tipo_pago_id = v.tipo_pago_id
    GROUP BY p.tipo_pago_id, p.tipo_pago, p.registra_propina;

    /* ---------- 6. Propinas por zona de origen (solo tarjeta: el efectivo no registra propina) ---------- */
    DROP TABLE IF EXISTS mart.propina_zona;
    WITH z AS (
        SELECT v.zona_origen_id, COUNT_BIG(*) AS viajes_tarjeta, SUM(v.propina) AS propinas,
               SUM(v.tarifa_base) AS tarifa_base, SUM(IIF(v.propina > 0, 1, 0)) AS con_propina
        FROM dw.fact_viaje AS v
        WHERE v.tipo_pago_id = 1 AND v.tarifa_base > 0
        GROUP BY v.zona_origen_id
        HAVING COUNT_BIG(*) >= 5000                 -- zonas con muestra suficiente
    )
    SELECT z.zona_origen_id AS zona_id, d.distrito, d.zona, d.zona_servicio, d.es_aeropuerto, z.viajes_tarjeta,
           CAST(z.propinas * 100.0 / z.tarifa_base AS DECIMAL(5,2))                AS propina_pct_tarifa,
           CAST(z.con_propina * 100.0 / z.viajes_tarjeta AS DECIMAL(5,2))          AS pct_con_propina,
           CAST(z.propinas / z.viajes_tarjeta AS DECIMAL(7,2))                     AS propina_media,
           NTILE(5) OVER (ORDER BY z.propinas / z.tarifa_base)                     AS quintil_propina,   -- 5 = más generosa
           RANK() OVER (PARTITION BY d.distrito ORDER BY z.propinas / z.tarifa_base DESC) AS rank_en_distrito,
           CAST((z.propinas / z.tarifa_base - SUM(z.propinas) OVER () / SUM(z.tarifa_base) OVER ()) * 100
                AS DECIMAL(5,2))                                                    AS dif_vs_ciudad_pp
    INTO mart.propina_zona
    FROM z JOIN dw.dim_zona AS d ON d.zona_id = z.zona_origen_id;

    /* ---------- 7. Aeropuertos ---------- */
    DROP TABLE IF EXISTS mart.aeropuerto_mensual;
    WITH a AS (
        SELECT f.periodo,
               COALESCE(o.aeropuerto, d.aeropuerto) AS aeropuerto,
               CASE WHEN o.es_aeropuerto = 1 AND d.es_aeropuerto = 1 THEN N'Entre aeropuertos'
                    WHEN o.es_aeropuerto = 1 THEN N'Desde el aeropuerto' ELSE N'Hacia el aeropuerto' END AS sentido,
               COUNT_BIG(*) AS viajes, SUM(v.total) AS ingreso_total, SUM(v.tarifa_base) AS tarifa_base,
               SUM(v.propina) AS propinas, SUM(v.distancia_millas) AS millas,
               SUM(CAST(v.duracion_seg AS BIGINT)) AS segundos
        FROM dw.fact_viaje AS v
        JOIN dw.dim_fecha AS f ON f.fecha_key = v.fecha_key
        JOIN dw.dim_zona AS o ON o.zona_id = v.zona_origen_id
        JOIN dw.dim_zona AS d ON d.zona_id = v.zona_destino_id
        WHERE o.es_aeropuerto = 1 OR d.es_aeropuerto = 1
        GROUP BY f.periodo, COALESCE(o.aeropuerto, d.aeropuerto),
                 CASE WHEN o.es_aeropuerto = 1 AND d.es_aeropuerto = 1 THEN N'Entre aeropuertos'
                      WHEN o.es_aeropuerto = 1 THEN N'Desde el aeropuerto' ELSE N'Hacia el aeropuerto' END
    )
    SELECT a.periodo, a.aeropuerto, a.sentido, a.viajes, a.ingreso_total,
           CAST(a.viajes * 100.0 / k.viajes AS DECIMAL(5,2))                       AS pct_viajes_mes,
           CAST(a.ingreso_total * 100.0 / k.ingreso_total AS DECIMAL(5,2))         AS pct_ingreso_mes,
           CAST(a.ingreso_total / a.viajes AS DECIMAL(7,2))                        AS ticket_medio,
           CAST(a.millas / a.viajes AS DECIMAL(6,2))                               AS distancia_media,
           CAST(a.segundos / 60.0 / a.viajes AS DECIMAL(6,1))                      AS duracion_media_min,
           CAST(a.propinas * 100.0 / NULLIF(a.tarifa_base, 0) AS DECIMAL(5,2))     AS propina_pct_tarifa,
           CAST(a.viajes * 100.0 / NULLIF(LAG(a.viajes) OVER (PARTITION BY a.aeropuerto, a.sentido
                ORDER BY a.periodo), 0) - 100 AS DECIMAL(6,1))                     AS var_viajes_mes_pct
    INTO mart.aeropuerto_mensual
    FROM a JOIN mart.kpi_mensual AS k ON k.periodo = a.periodo;

    /* ---------- 8. Tendencia del precio por milla (tarifa estándar de taxímetro) ---------- */
    DROP TABLE IF EXISTS mart.precio_milla_mensual;
    WITH b AS (
        SELECT f.periodo,
               CASE WHEN v.distancia_millas < 2 THEN 1 WHEN v.distancia_millas < 5 THEN 2
                    WHEN v.distancia_millas < 10 THEN 3 ELSE 4 END AS banda_orden,
               v.tarifa_base, v.distancia_millas, v.duracion_seg,
               v.tarifa_base / v.distancia_millas AS tarifa_por_milla
        FROM dw.fact_viaje AS v
        JOIN dw.dim_fecha AS f ON f.fecha_key = v.fecha_key
        WHERE v.tarifa_id = 1 AND v.distancia_millas >= 0.5 AND v.tarifa_base > 0
    ),
    m AS (
        SELECT periodo, banda_orden, COUNT_BIG(*) AS viajes,
               SUM(tarifa_base) / SUM(distancia_millas) AS tarifa_por_milla_ponderada,
               APPROX_PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tarifa_por_milla) AS mediana_tarifa_por_milla,
               SUM(distancia_millas) * 3600.0 / SUM(CAST(duracion_seg AS BIGINT)) AS velocidad_media_mph
        FROM b GROUP BY periodo, banda_orden
    )
    SELECT periodo, banda_orden,
           CHOOSE(banda_orden, N'0,5–2 mi', N'2–5 mi', N'5–10 mi', N'10+ mi') AS banda_distancia, viajes,
           CAST(tarifa_por_milla_ponderada AS DECIMAL(6,3))                  AS tarifa_por_milla,
           CAST(mediana_tarifa_por_milla AS DECIMAL(6,3))                    AS mediana_tarifa_por_milla,
           CAST(velocidad_media_mph AS DECIMAL(5,1))                         AS velocidad_media_mph,
           CAST(tarifa_por_milla_ponderada * 100.0 / FIRST_VALUE(tarifa_por_milla_ponderada)
                OVER (PARTITION BY banda_orden ORDER BY periodo) - 100 AS DECIMAL(6,2)) AS var_vs_enero_pct,
           CAST(tarifa_por_milla_ponderada * 100.0 / LAG(tarifa_por_milla_ponderada)
                OVER (PARTITION BY banda_orden ORDER BY periodo) - 100 AS DECIMAL(6,2)) AS var_vs_mes_anterior_pct
    INTO mart.precio_milla_mensual
    FROM m;

    PRINT CONCAT(N'Análisis materializado en mart.* (', DATEDIFF(SECOND, @t, SYSDATETIME()), N' s)');
END;
GO
