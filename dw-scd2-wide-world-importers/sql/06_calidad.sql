USE DW_WWI;
GO
CREATE OR ALTER PROCEDURE audit.sp_validar
AS
BEGIN
 SET NOCOUNT ON; DELETE audit.controles;
 DECLARE @obs decimal(28,4),@esp decimal(28,4);
 SELECT @obs=COUNT(*) FROM dw.fact_venta; SELECT @esp=COUNT(*) FROM WideWorldImporters.Sales.InvoiceLines;
 INSERT audit.controles(control,valor_observado,valor_esperado,estado,detalle) VALUES(N'Filas de venta DW = OLTP',@obs,@esp,IIF(@obs=@esp,'OK','FALLA'),N'Grano: línea de factura');
 SELECT @obs=SUM(importe_total) FROM dw.fact_venta; SELECT @esp=SUM(ExtendedPrice) FROM WideWorldImporters.Sales.InvoiceLines;
 INSERT audit.controles(control,valor_observado,valor_esperado,estado,detalle) VALUES(N'Importe de venta DW = OLTP',@obs,@esp,IIF(ABS(@obs-@esp)<0.01,'OK','FALLA'),N'Tolerancia 0,01');
 ;WITH d AS(SELECT YEAR(fe.fecha) anio,COUNT(*) n FROM dw.fact_venta f JOIN dw.dim_fecha fe ON fe.fecha_key=f.fecha_key GROUP BY YEAR(fe.fecha)),
 s AS(SELECT YEAR(i.InvoiceDate) anio,COUNT(*) n FROM WideWorldImporters.Sales.InvoiceLines l JOIN WideWorldImporters.Sales.Invoices i ON i.InvoiceID=l.InvoiceID GROUP BY YEAR(i.InvoiceDate))
 INSERT audit.controles(control,valor_observado,valor_esperado,estado,detalle)
 SELECT CONCAT(N'Filas de venta ',COALESCE(d.anio,s.anio)),d.n,s.n,IIF(d.n=s.n,'OK','FALLA'),N'Reconciliación anual'
 FROM d FULL JOIN s ON s.anio=d.anio;
 ;WITH d AS(SELECT YEAR(fe.fecha) anio,SUM(f.importe_total) n FROM dw.fact_venta f JOIN dw.dim_fecha fe ON fe.fecha_key=f.fecha_key GROUP BY YEAR(fe.fecha)),
 s AS(SELECT YEAR(i.InvoiceDate) anio,SUM(l.ExtendedPrice) n FROM WideWorldImporters.Sales.InvoiceLines l JOIN WideWorldImporters.Sales.Invoices i ON i.InvoiceID=l.InvoiceID GROUP BY YEAR(i.InvoiceDate))
 INSERT audit.controles(control,valor_observado,valor_esperado,estado,detalle)
 SELECT CONCAT(N'Importe de venta ',COALESCE(d.anio,s.anio)),d.n,s.n,IIF(ABS(d.n-s.n)<0.01,'OK','FALLA'),N'Reconciliación anual; tolerancia 0,01'
 FROM d FULL JOIN s ON s.anio=d.anio;
 SELECT @obs=COUNT(*) FROM dw.fact_compra; SELECT @esp=COUNT(*) FROM WideWorldImporters.Purchasing.PurchaseOrderLines;
 INSERT audit.controles(control,valor_observado,valor_esperado,estado,detalle) VALUES(N'Filas de compra DW = OLTP',@obs,@esp,IIF(@obs=@esp,'OK','FALLA'),N'Grano: línea de orden de compra');
 SELECT @obs=COUNT(*) FROM dw.fact_venta f LEFT JOIN dw.dim_cliente c ON c.cliente_key=f.cliente_key LEFT JOIN dw.dim_producto p ON p.producto_key=f.producto_key WHERE c.cliente_key IS NULL OR p.producto_key IS NULL;
 INSERT audit.controles(control,valor_observado,valor_esperado,estado,detalle) VALUES(N'Hechos de venta huérfanos',@obs,0,IIF(@obs=0,'OK','FALLA'),NULL);
 SELECT @obs=COUNT(*) FROM(SELECT cliente_id FROM dw.dim_cliente GROUP BY cliente_id HAVING SUM(CONVERT(int,es_actual))<>1)x;
 INSERT audit.controles(control,valor_observado,valor_esperado,estado,detalle) VALUES(N'Una versión actual por cliente',@obs,0,IIF(@obs=0,'OK','FALLA'),NULL);
 SELECT @obs=COUNT(*) FROM dw.dim_cliente a JOIN dw.dim_cliente b ON a.cliente_id=b.cliente_id AND a.cliente_key<b.cliente_key AND a.valido_desde<b.valido_hasta AND b.valido_desde<a.valido_hasta;
 INSERT audit.controles(control,valor_observado,valor_esperado,estado,detalle) VALUES(N'Sin intervalos SCD2 de cliente solapados',@obs,0,IIF(@obs=0,'OK','FALLA'),NULL);
 SELECT @obs=COUNT(*) FROM(SELECT producto_id FROM dw.dim_producto GROUP BY producto_id HAVING SUM(CONVERT(int,es_actual))<>1)x;
 INSERT audit.controles(control,valor_observado,valor_esperado,estado,detalle) VALUES(N'Una versión actual por producto',@obs,0,IIF(@obs=0,'OK','FALLA'),NULL);
 SELECT @obs=COUNT(*) FROM dw.dim_producto a JOIN dw.dim_producto b ON a.producto_id=b.producto_id AND a.producto_key<b.producto_key AND a.valido_desde<b.valido_hasta AND b.valido_desde<a.valido_hasta;
 INSERT audit.controles(control,valor_observado,valor_esperado,estado,detalle) VALUES(N'Sin intervalos SCD2 de producto solapados',@obs,0,IIF(@obs=0,'OK','FALLA'),NULL);
 IF EXISTS(SELECT 1 FROM audit.controles WHERE estado='FALLA') THROW 51000,N'Falló al menos un control de calidad.',1;
END;
GO
EXEC audit.sp_validar;
GO

