/* =====================================================================
   10_vistas_powerbi.sql
   Capa rpt: lo ÚNICO que lee Power BI. Nombres y columnas en español,
   sin claves técnicas innecesarias y con los cálculos de negocio ya hechos.

   Modelo en Power BI (importar):
     rpt.dim_fecha, rpt.dim_cliente, rpt.dim_producto, rpt.dim_pais -> rpt.fact_ventas
   Tablas de apoyo (sin relación o relación simple):
     rpt.kpi_mensual, rpt.rfm_segmentos, rpt.cohorte_retencion,
     rpt.devoluciones_producto, rpt.devoluciones_mensual, rpt.canasta_pares
   ===================================================================== */
USE RetailAnalitica;
GO

CREATE OR ALTER VIEW rpt.dim_fecha AS
SELECT clave_fecha, fecha, anio, trimestre, mes, nombre_mes, anio_mes, inicio_mes,
       dia_semana, nombre_dia, es_fin_semana
FROM dw.dim_fecha;
GO

CREATE OR ALTER VIEW rpt.dim_pais AS
SELECT clave_pais, pais, pais_es, region,
       CASE WHEN es_mercado_local = 1 THEN N'Reino Unido' ELSE N'Internacional' END AS mercado
FROM dw.dim_pais;
GO

CREATE OR ALTER VIEW rpt.dim_producto AS
SELECT clave_producto, codigo_producto, descripcion, precio_mediano
FROM dw.dim_producto;
GO

-- Cliente con su segmento RFM: permite filtrar cualquier visual por segmento
CREATE OR ALTER VIEW rpt.dim_cliente AS
SELECT c.clave_cliente, c.cliente_id, c.pais_principal,
       CAST(c.primera_compra AS DATE) AS primera_compra,
       CAST(c.ultima_compra AS DATE)  AS ultima_compra,
       c.cohorte_mes,
       ISNULL(r.segmento, CASE WHEN c.clave_cliente = -1 THEN N'(sin identificar)' ELSE N'(sin compras)' END) AS segmento_rfm,
       r.rfm_codigo, r.r, r.f, r.m, r.recencia_dias, r.frecuencia, r.monto
FROM dw.dim_cliente AS c
LEFT JOIN mart.cliente_rfm AS r ON r.cliente_id = c.clave_cliente;
GO

CREATE OR ALTER VIEW rpt.fact_ventas AS
SELECT linea_id, clave_fecha, clave_cliente, clave_producto, clave_pais, factura,
       CASE WHEN es_devolucion = 1 THEN N'Devolución' ELSE N'Venta' END AS tipo,
       cantidad, precio_unitario, importe
FROM dw.fact_linea;
GO

CREATE OR ALTER VIEW rpt.kpi_mensual AS
SELECT d.inicio_mes                                                         AS mes,
       SUM(CASE WHEN f.es_devolucion = 0 THEN f.importe ELSE 0 END)         AS ventas_brutas,
       -SUM(CASE WHEN f.es_devolucion = 1 THEN f.importe ELSE 0 END)        AS devoluciones,
       SUM(f.importe)                                                       AS ventas_netas,
       COUNT(DISTINCT CASE WHEN f.es_devolucion = 0 THEN f.factura END)     AS facturas,
       COUNT(DISTINCT CASE WHEN f.es_devolucion = 0 AND f.clave_cliente <> -1
                           THEN f.clave_cliente END)                        AS clientes_activos,
       SUM(CASE WHEN f.es_devolucion = 0 THEN f.importe ELSE 0 END)
         / NULLIF(COUNT(DISTINCT CASE WHEN f.es_devolucion = 0 THEN f.factura END), 0) AS ticket_promedio,
       -SUM(CASE WHEN f.es_devolucion = 1 THEN f.importe ELSE 0 END)
         / NULLIF(SUM(CASE WHEN f.es_devolucion = 0 THEN f.importe ELSE 0 END), 0)    AS tasa_devolucion
FROM dw.fact_linea AS f
JOIN dw.dim_fecha AS d ON d.clave_fecha = f.clave_fecha
GROUP BY d.inicio_mes;
GO

CREATE OR ALTER VIEW rpt.rfm_cliente AS
SELECT r.cliente_id, c.pais_principal, r.ultima_compra, r.recencia_dias, r.frecuencia, r.monto,
       r.r, r.f, r.m, r.rfm_codigo, r.segmento, s.orden AS orden_segmento, s.accion_sugerida
FROM mart.cliente_rfm AS r
JOIN dw.dim_cliente AS c ON c.clave_cliente = r.cliente_id
JOIN mart.regla_segmento AS s ON s.segmento = r.segmento;
GO

CREATE OR ALTER VIEW rpt.rfm_segmentos AS
SELECT s.orden, r.segmento, s.accion_sugerida,
       COUNT(*)                                                    AS clientes,
       CAST(COUNT(*) * 1.0 / SUM(COUNT(*)) OVER () AS DECIMAL(7,4)) AS pct_clientes,
       SUM(r.monto)                                                AS monto,
       CAST(SUM(r.monto) / SUM(SUM(r.monto)) OVER () AS DECIMAL(7,4)) AS pct_monto,
       AVG(CAST(r.recencia_dias AS DECIMAL(9,1)))                  AS recencia_promedio,
       AVG(CAST(r.frecuencia AS DECIMAL(9,1)))                     AS frecuencia_promedio,
       AVG(r.monto)                                                AS monto_promedio
FROM mart.cliente_rfm AS r
JOIN mart.regla_segmento AS s ON s.segmento = r.segmento
GROUP BY s.orden, r.segmento, s.accion_sugerida;
GO

CREATE OR ALTER VIEW rpt.cohorte_retencion AS
SELECT cohorte_mes, CONVERT(CHAR(7), cohorte_mes, 120) AS cohorte, mes_desde, mes_calendario,
       tamano_cohorte, clientes_activos, tasa_retencion,
       ingreso_neto, ingreso_acumulado, ingreso_acum_por_cliente,
       CASE WHEN cohorte_mes = (SELECT MIN(cohorte_mes) FROM mart.cohorte_mes)
            THEN 1 ELSE 0 END                                     AS censurada_izquierda,
       CASE WHEN mes_calendario = (SELECT MAX(mes_calendario) FROM mart.cohorte_mes)
            THEN 1 ELSE 0 END                                     AS mes_incompleto
FROM mart.cohorte_mes;
GO

CREATE OR ALTER VIEW rpt.devoluciones_producto AS
WITH ventas AS (
    SELECT clave_producto, SUM(importe) AS vendido, SUM(cantidad) AS unidades_vendidas
    FROM dw.fact_linea WHERE es_devolucion = 0 GROUP BY clave_producto
), dev AS (
    SELECT clave_producto, SUM(importe) AS devuelto, SUM(unidades) AS unidades_devueltas,
           COUNT(*) AS lineas_devueltas
    FROM mart.devolucion_linea GROUP BY clave_producto
)
SELECT p.codigo_producto, p.descripcion,
       ISNULL(v.vendido, 0) AS importe_vendido, d.devuelto AS importe_devuelto,
       ISNULL(v.unidades_vendidas, 0) AS unidades_vendidas, d.unidades_devueltas, d.lineas_devueltas,
       CAST(d.devuelto / NULLIF(v.vendido, 0) AS DECIMAL(9,4)) AS tasa_devolucion_importe
FROM dev AS d
JOIN dw.dim_producto AS p ON p.clave_producto = d.clave_producto
LEFT JOIN ventas AS v ON v.clave_producto = d.clave_producto;
GO

CREATE OR ALTER VIEW rpt.devoluciones_pais AS
WITH ventas AS (
    SELECT clave_pais, SUM(importe) AS vendido FROM dw.fact_linea WHERE es_devolucion = 0 GROUP BY clave_pais
), dev AS (
    SELECT clave_pais, SUM(importe) AS devuelto, COUNT(*) AS lineas FROM mart.devolucion_linea GROUP BY clave_pais
)
SELECT p.pais_es AS pais, p.region, v.vendido AS importe_vendido, ISNULL(d.devuelto, 0) AS importe_devuelto,
       ISNULL(d.lineas, 0) AS lineas_devueltas,
       CAST(ISNULL(d.devuelto, 0) / NULLIF(v.vendido, 0) AS DECIMAL(9,4)) AS tasa_devolucion_importe
FROM ventas AS v
JOIN dw.dim_pais AS p ON p.clave_pais = v.clave_pais
LEFT JOIN dev AS d ON d.clave_pais = v.clave_pais;
GO

CREATE OR ALTER VIEW rpt.devoluciones_tiempo AS
SELECT CASE WHEN dias_desde_compra IS NULL THEN N'Sin compra previa en el archivo'
            WHEN dias_desde_compra <= 7    THEN N'0–7 días'
            WHEN dias_desde_compra <= 30   THEN N'8–30 días'
            WHEN dias_desde_compra <= 90   THEN N'31–90 días'
            ELSE N'Más de 90 días' END AS rango,
       CASE WHEN dias_desde_compra IS NULL THEN 5
            WHEN dias_desde_compra <= 7    THEN 1
            WHEN dias_desde_compra <= 30   THEN 2
            WHEN dias_desde_compra <= 90   THEN 3
            ELSE 4 END AS orden,
       COUNT(*) AS lineas, SUM(importe) AS importe
FROM mart.devolucion_linea
GROUP BY CASE WHEN dias_desde_compra IS NULL THEN N'Sin compra previa en el archivo'
              WHEN dias_desde_compra <= 7    THEN N'0–7 días'
              WHEN dias_desde_compra <= 30   THEN N'8–30 días'
              WHEN dias_desde_compra <= 90   THEN N'31–90 días'
              ELSE N'Más de 90 días' END,
         CASE WHEN dias_desde_compra IS NULL THEN 5
              WHEN dias_desde_compra <= 7    THEN 1
              WHEN dias_desde_compra <= 30   THEN 2
              WHEN dias_desde_compra <= 90   THEN 3
              ELSE 4 END;
GO

CREATE OR ALTER VIEW rpt.canasta_pares AS
SELECT pa.codigo_producto AS codigo_a, pa.descripcion AS producto_a,
       pb.codigo_producto AS codigo_b, pb.descripcion AS producto_b,
       c.facturas_ab, c.soporte, c.confianza_a_b, c.confianza_b_a, c.lift
FROM mart.canasta_par AS c
JOIN dw.dim_producto AS pa ON pa.clave_producto = c.clave_producto_a
JOIN dw.dim_producto AS pb ON pb.clave_producto = c.clave_producto_b;
GO

PRINT N'Vistas de reporte (rpt) creadas.';
GO
