USE DW_WWI;
GO
CREATE OR ALTER VIEW rpt.ventas AS
SELECT f.linea_factura_id,f.factura_id,fe.fecha,fe.anio,fe.mes,c.cliente_id,c.cliente,c.categoria AS categoria_historica,
 ca.categoria AS categoria_actual,p.producto_id,p.producto,e.nombre AS vendedor,f.cantidad,f.precio_unitario,f.importe_total,f.beneficio
FROM dw.fact_venta f JOIN dw.dim_fecha fe ON fe.fecha_key=f.fecha_key JOIN dw.dim_cliente c ON c.cliente_key=f.cliente_key
JOIN dw.dim_cliente ca ON ca.cliente_id=c.cliente_id AND ca.es_actual=1 JOIN dw.dim_producto p ON p.producto_key=f.producto_key
JOIN dw.dim_empleado e ON e.empleado_key=f.empleado_key;
GO
CREATE OR ALTER VIEW rpt.ventas_anuales AS
SELECT anio,COUNT_BIG(*) lineas,COUNT(DISTINCT factura_id) facturas,SUM(importe_total) ventas,SUM(beneficio) beneficio
FROM rpt.ventas GROUP BY anio;
GO
CREATE OR ALTER VIEW rpt.ventas_categoria_comparacion AS
SELECT categoria_historica,categoria_actual,SUM(importe_total) ventas,COUNT_BIG(*) lineas
FROM rpt.ventas GROUP BY categoria_historica,categoria_actual;
GO
CREATE OR ALTER VIEW rpt.margen_producto AS
SELECT producto_id,producto,SUM(importe_total) ventas,SUM(beneficio) beneficio,
 CAST(100.0*SUM(beneficio)/NULLIF(SUM(importe_total),0) AS decimal(9,2)) margen_pct,
 DENSE_RANK() OVER(ORDER BY SUM(beneficio) DESC) ranking_beneficio
FROM rpt.ventas GROUP BY producto_id,producto;
GO
CREATE OR ALTER VIEW rpt.rendimiento_vendedor AS
SELECT vendedor,COUNT(DISTINCT factura_id) facturas,SUM(importe_total) ventas,SUM(beneficio) beneficio,
 DENSE_RANK() OVER(ORDER BY SUM(importe_total) DESC) ranking_ventas
FROM rpt.ventas GROUP BY vendedor;
GO
/* La foto de existencias se toma al ejecutar el ETL (fecha_key), pero las cantidades de
   Warehouse.StockItemHoldings describen el inventario a su LastEditedWhen (31-05-2016, fin de
   las ventas del respaldo). La ventana de 365 días termina en esa fecha de referencia, no en la
   fecha de ejecución: así no se compara inventario de 2016 con ventas inexistentes de 2026.
   Las ventas se suman por producto_id para incluir todas las versiones SCD2 del producto. */
CREATE OR ALTER VIEW rpt.stock_actual AS
SELECT f.fecha_key AS fecha_snapshot_key,r.fecha_referencia,p.producto_id,p.producto,f.cantidad_disponible,f.costo_ultimo,
 f.punto_reorden,f.stock_objetivo,COALESCE(v.unidades_365,0) unidades_vendidas_365,
 CAST(COALESCE(v.unidades_365,0)/365.0 AS decimal(18,2)) unidades_dia,
 CAST(f.cantidad_disponible/NULLIF(v.unidades_365/365.0,0) AS decimal(18,1)) dias_cobertura,
 CAST(COALESCE(v.unidades_365,0)*1.0/NULLIF(f.cantidad_disponible,0) AS decimal(18,2)) rotacion_aproximada
FROM dw.fact_stock_diario f JOIN dw.dim_producto p ON p.producto_key=f.producto_key
CROSS APPLY(SELECT CONVERT(date,f.editado_en) fecha_referencia) r
OUTER APPLY(SELECT SUM(CONVERT(bigint,vv.cantidad)) unidades_365
 FROM dw.fact_venta vv JOIN dw.dim_producto vp ON vp.producto_key=vv.producto_key JOIN dw.dim_fecha df ON df.fecha_key=vv.fecha_key
 WHERE vp.producto_id=p.producto_id AND df.fecha>DATEADD(day,-365,r.fecha_referencia) AND df.fecha<=r.fecha_referencia) v;
GO
