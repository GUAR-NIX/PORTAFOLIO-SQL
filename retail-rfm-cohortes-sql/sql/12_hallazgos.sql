/* =====================================================================
   12_hallazgos.sql
   Consultas de negocio que respaldan cada cifra del README.
   Ejecuta cada bloque por separado (selecciónalo y F5).
   ===================================================================== */
USE RetailAnalitica;
GO

/* H1. Panorama general ------------------------------------------------ */
SELECT COUNT(DISTINCT CASE WHEN es_devolucion = 0 THEN factura END)                AS facturas_venta,
       COUNT(DISTINCT CASE WHEN clave_cliente <> -1 THEN clave_cliente END)         AS clientes,
       SUM(CASE WHEN es_devolucion = 0 THEN importe ELSE 0 END)                     AS ventas_brutas,
       -SUM(CASE WHEN es_devolucion = 1 THEN importe ELSE 0 END)                    AS devoluciones,
       SUM(importe)                                                                 AS ventas_netas,
       SUM(CASE WHEN es_devolucion = 0 THEN importe ELSE 0 END)
         / COUNT(DISTINCT CASE WHEN es_devolucion = 0 THEN factura END)             AS ticket_promedio,
       SUM(CASE WHEN clave_cliente = -1 THEN importe ELSE 0 END) / SUM(importe)     AS pct_ingreso_sin_cliente
FROM dw.fact_linea;
GO

/* H2. Limpieza: qué se excluyó y por qué ------------------------------- */
SELECT ISNULL(motivo_exclusion, '(entra al modelo)') AS motivo,
       COUNT_BIG(*) AS lineas,
       CAST(COUNT_BIG(*) * 100.0 / SUM(COUNT_BIG(*)) OVER () AS DECIMAL(5,2)) AS pct_lineas,
       SUM(importe) AS importe,
       SUM(CAST(es_duplicado_entre_hojas AS INT)) AS duplicados_entre_hojas
FROM limpio.factura_linea
GROUP BY motivo_exclusion
ORDER BY lineas DESC;
GO

/* H3. Crecimiento interanual (dic-ene–nov comparables) ------------------ */
SELECT YEAR(mes) AS anio, SUM(ventas_netas) AS ventas_netas, SUM(facturas) AS facturas
FROM rpt.kpi_mensual
GROUP BY YEAR(mes) ORDER BY anio;

SELECT TOP (3) mes, ventas_netas, clientes_activos FROM rpt.kpi_mensual ORDER BY ventas_netas DESC;
GO

/* H4. Pareto de clientes: ¿qué % del ingreso hace el 20 % superior? ---- */
WITH c AS (
    SELECT cliente_id, monto,
           ROW_NUMBER() OVER (ORDER BY monto DESC) AS pos,
           COUNT(*) OVER () AS total,
           SUM(monto) OVER () AS monto_total,
           SUM(monto) OVER (ORDER BY monto DESC ROWS UNBOUNDED PRECEDING) AS acumulado
    FROM mart.cliente_rfm
)
SELECT CAST(SUM(CASE WHEN pos <= total * 0.2 THEN monto END) / MAX(monto_total) AS DECIMAL(5,4)) AS pct_ingreso_top20,
       CAST(SUM(CASE WHEN pos <= total * 0.01 THEN monto END) / MAX(monto_total) AS DECIMAL(5,4)) AS pct_ingreso_top1,
       MIN(CASE WHEN acumulado >= monto_total * 0.8 THEN pos END) * 1.0 / MAX(total) AS pct_clientes_para_80
FROM c;
GO

/* H5. Segmentos RFM ----------------------------------------------------- */
SELECT segmento, clientes, pct_clientes, monto, pct_monto, recencia_promedio, frecuencia_promedio, monto_promedio
FROM rpt.rfm_segmentos ORDER BY orden;
GO

/* H6. Retención promedio por mes transcurrido (sin la cohorte censurada) */
SELECT mes_desde,
       AVG(tasa_retencion)       AS retencion_promedio,
       SUM(clientes_activos) * 1.0 / SUM(tamano_cohorte) AS retencion_ponderada,
       COUNT(*)                  AS cohortes
FROM rpt.cohorte_retencion
WHERE censurada_izquierda = 0 AND mes_incompleto = 0 AND mes_desde IN (1, 3, 6, 12)
GROUP BY mes_desde ORDER BY mes_desde;
GO

-- Clientes que nunca volvieron (una sola factura de compra)
SELECT COUNT(*) AS clientes, SUM(CASE WHEN frecuencia = 1 THEN 1 ELSE 0 END) AS una_sola_compra,
       AVG(CASE WHEN frecuencia = 1 THEN 1.0 ELSE 0 END) AS pct_una_sola_compra
FROM mart.cliente_rfm;
GO

/* H7. Valor acumulado por cliente a 12 meses: cohortes 2010 ------------- */
SELECT cohorte, tamano_cohorte, ingreso_acum_por_cliente AS gbp_por_cliente_12m
FROM rpt.cohorte_retencion
WHERE mes_desde = 12 AND cohorte LIKE '2010%'
ORDER BY cohorte;

-- Matriz completa (PIVOT dinámico)
EXEC etl.sp_matriz_retencion;
EXEC etl.sp_matriz_retencion @metrica = 'ingreso';
GO

/* H8. Devoluciones ------------------------------------------------------ */
SELECT SUM(importe_devuelto) / SUM(importe_vendido) AS tasa_devolucion_global
FROM rpt.devoluciones_pais;

SELECT rango, lineas, importe, CAST(importe / SUM(importe) OVER () AS DECIMAL(5,4)) AS pct_importe
FROM rpt.devoluciones_tiempo ORDER BY orden;

SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY dias_desde_compra) OVER () AS mediana_dias
FROM mart.devolucion_linea WHERE dias_desde_compra IS NOT NULL
ORDER BY 1 OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY;

-- Productos con más importe devuelto
SELECT TOP (10) codigo_producto, descripcion, importe_vendido, importe_devuelto, tasa_devolucion_importe
FROM rpt.devoluciones_producto ORDER BY importe_devuelto DESC;

-- Productos con tasa de devolución alta (con volumen relevante)
SELECT TOP (10) codigo_producto, descripcion, importe_vendido, importe_devuelto, tasa_devolucion_importe
FROM rpt.devoluciones_producto WHERE importe_vendido >= 5000 ORDER BY tasa_devolucion_importe DESC;

-- Países (con al menos 50 mil GBP vendidos)
SELECT TOP (10) pais, importe_vendido, importe_devuelto, tasa_devolucion_importe
FROM rpt.devoluciones_pais WHERE importe_vendido >= 50000 ORDER BY tasa_devolucion_importe DESC;
GO

/* H9. Canasta: pares con más lift y pares más frecuentes ---------------- */
SELECT TOP (10) producto_a, producto_b, facturas_ab, soporte, confianza_a_b, confianza_b_a, lift
FROM rpt.canasta_pares WHERE facturas_ab >= 300 ORDER BY lift DESC;

SELECT TOP (10) producto_a, producto_b, facturas_ab, soporte, confianza_a_b, confianza_b_a, lift
FROM rpt.canasta_pares ORDER BY facturas_ab DESC;
GO

/* H10. Mercados ---------------------------------------------------------- */
SELECT TOP (8) p.pais_es, SUM(f.importe) AS ventas_netas,
       CAST(SUM(f.importe) / SUM(SUM(f.importe)) OVER () AS DECIMAL(5,4)) AS pct,
       COUNT(DISTINCT NULLIF(f.clave_cliente, -1)) AS clientes
FROM dw.fact_linea AS f JOIN dw.dim_pais AS p ON p.clave_pais = f.clave_pais
GROUP BY p.pais_es ORDER BY ventas_netas DESC;
GO
