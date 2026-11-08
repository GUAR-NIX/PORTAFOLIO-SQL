USE DW_WWI;
GO
-- Atribución histórica frente a la categoría que el cliente tiene hoy.
SELECT categoria_historica,categoria_actual,SUM(importe_total) ventas,
 SUM(SUM(importe_total)) OVER(PARTITION BY categoria_historica) total_categoria_historica
FROM rpt.ventas GROUP BY categoria_historica,categoria_actual ORDER BY ventas DESC;
-- Margen y ranking por producto.
SELECT TOP(20) * FROM rpt.margen_producto ORDER BY ranking_beneficio;
-- Rotación y cobertura: prioriza faltantes y exceso de inventario.
SELECT TOP(20) * FROM rpt.stock_actual ORDER BY CASE WHEN dias_cobertura IS NULL THEN 1 ELSE 0 END,dias_cobertura;
-- Rendimiento de vendedores.
SELECT * FROM rpt.rendimiento_vendedor ORDER BY ranking_ventas;
-- Estacionalidad mensual contra el promedio móvil de 3 meses.
WITH m AS(SELECT anio,mes,SUM(importe_total) ventas FROM rpt.ventas GROUP BY anio,mes)
SELECT *,AVG(ventas) OVER(ORDER BY anio,mes ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) media_movil_3m,
 LAG(ventas,12) OVER(ORDER BY anio,mes) ventas_mismo_mes_anterior FROM m ORDER BY anio,mes;
GO

