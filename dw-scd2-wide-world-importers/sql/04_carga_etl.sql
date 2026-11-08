USE DW_WWI;
GO
CREATE OR ALTER PROCEDURE etl.sp_cargar @modo varchar(12)='INCREMENTAL'
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON; SET DATEFIRST 7;
 DECLARE @inicio datetime2(7)=SYSUTCDATETIME(), @corte datetime2(7)=SYSUTCDATETIME(), @id bigint;
 DECLARE @wm_cliente datetime2(7)=COALESCE((SELECT ultima_fecha FROM audit.marca_agua WHERE fuente='cliente'),'19000101');
 DECLARE @wm_producto datetime2(7)=COALESCE((SELECT ultima_fecha FROM audit.marca_agua WHERE fuente='producto'),'19000101');
 DECLARE @wm_venta datetime2(7)=COALESCE((SELECT ultima_fecha FROM audit.marca_agua WHERE fuente='venta'),'19000101');
 DECLARE @wm_compra datetime2(7)=COALESCE((SELECT ultima_fecha FROM audit.marca_agua WHERE fuente='compra'),'19000101');
 IF @modo='COMPLETA' SELECT @wm_cliente='19000101',@wm_producto='19000101',@wm_venta='19000101',@wm_compra='19000101';
 INSERT audit.ejecucion(tipo,inicio) VALUES(@modo,@inicio); SET @id=SCOPE_IDENTITY();
 BEGIN TRY
  BEGIN TRAN;
  IF NOT EXISTS(SELECT 1 FROM dw.dim_fecha)
  BEGIN
   ;WITH n AS(SELECT TOP(DATEDIFF(day,'20130101','20310101')) ROW_NUMBER() OVER(ORDER BY (SELECT NULL))-1 n FROM sys.all_objects a CROSS JOIN sys.all_objects b),
   f AS(SELECT DATEADD(day,n,CONVERT(date,'20130101')) fecha FROM n)
   INSERT dw.dim_fecha SELECT CONVERT(int,CONVERT(char(8),fecha,112)),fecha,YEAR(fecha),DATEPART(quarter,fecha),MONTH(fecha),
    CHOOSE(MONTH(fecha),'enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'),
    DAY(fecha),DATEPART(weekday,fecha),CHOOSE(DATEPART(weekday,fecha),'domingo','lunes','martes','miércoles','jueves','viernes','sábado') FROM f;
  END;
  INSERT dw.dim_ciudad(ciudad_id,ciudad,provincia,territorio_ventas,pais,continente)
  SELECT c.CityID,c.CityName,sp.StateProvinceName,sp.SalesTerritory,co.CountryName,co.Continent
  FROM WideWorldImporters.Application.Cities c JOIN WideWorldImporters.Application.StateProvinces sp ON sp.StateProvinceID=c.StateProvinceID
  JOIN WideWorldImporters.Application.Countries co ON co.CountryID=sp.CountryID
  WHERE NOT EXISTS(SELECT 1 FROM dw.dim_ciudad d WHERE d.ciudad_id=c.CityID);
  INSERT dw.dim_empleado(empleado_id,nombre,es_vendedor)
  SELECT PersonID,FullName,IsSalesperson FROM WideWorldImporters.Application.People p
  WHERE p.IsEmployee=1 AND NOT EXISTS(SELECT 1 FROM dw.dim_empleado d WHERE d.empleado_id=p.PersonID);
  INSERT dw.dim_proveedor(proveedor_id,proveedor,ciudad_key)
  SELECT s.SupplierID,s.SupplierName,c.ciudad_key FROM WideWorldImporters.Purchasing.Suppliers s JOIN dw.dim_ciudad c ON c.ciudad_id=s.DeliveryCityID
  WHERE NOT EXISTS(SELECT 1 FROM dw.dim_proveedor d WHERE d.proveedor_id=s.SupplierID);

  SELECT c.CustomerID,c.CustomerName,c.CustomerCategoryID,cc.CustomerCategoryName,dc.ciudad_key,c.CreditLimit,c.PaymentDays,c.ValidFrom,
   HASHBYTES('SHA2_256',CONCAT(c.CustomerName,'|',c.CustomerCategoryID,'|',c.DeliveryCityID,'|',COALESCE(CONVERT(varchar(30),c.CreditLimit),'NULL'),'|',c.PaymentDays)) h
  INTO #cliente FROM stg.cliente_actual c JOIN WideWorldImporters.Sales.CustomerCategories cc ON cc.CustomerCategoryID=c.CustomerCategoryID
  JOIN dw.dim_ciudad dc ON dc.ciudad_id=c.DeliveryCityID WHERE c.ValidFrom>@wm_cliente AND c.ValidFrom<=@corte;
  DECLARE @cc int=0,@ca int=0;
  UPDATE d SET valido_hasta=@corte,es_actual=0 FROM dw.dim_cliente d JOIN #cliente s ON s.CustomerID=d.cliente_id WHERE d.es_actual=1 AND d.hash_atributos<>s.h;
  SET @cc=@@ROWCOUNT;
  INSERT dw.dim_cliente(cliente_id,cliente,categoria_id,categoria,ciudad_key,limite_credito,dias_pago,hash_atributos,valido_desde,valido_hasta,es_actual)
  SELECT s.CustomerID,s.CustomerName,s.CustomerCategoryID,s.CustomerCategoryName,s.ciudad_key,s.CreditLimit,s.PaymentDays,s.h,
   CASE WHEN d.cliente_id IS NULL AND NOT EXISTS(SELECT 1 FROM dw.dim_cliente) THEN CONVERT(datetime2,'19000101') ELSE @corte END,'99991231',1
  FROM #cliente s LEFT JOIN dw.dim_cliente d ON d.cliente_id=s.CustomerID AND d.es_actual=1
  WHERE d.cliente_id IS NULL OR d.hash_atributos<>s.h;
  SET @ca=@@ROWCOUNT;

  SELECT p.StockItemID,p.StockItemName,p.SupplierID,p.Brand,p.Size,p.UnitPrice,p.RecommendedRetailPrice,p.LeadTimeDays,p.ValidFrom,
   HASHBYTES('SHA2_256',CONCAT(p.StockItemName,'|',p.SupplierID,'|',COALESCE(p.Brand,'NULL'),'|',COALESCE(p.Size,'NULL'),'|',p.UnitPrice,'|',COALESCE(p.RecommendedRetailPrice,-1),'|',p.LeadTimeDays)) h
  INTO #producto FROM stg.producto_actual p WHERE p.ValidFrom>@wm_producto AND p.ValidFrom<=@corte;
  DECLARE @pc int=0,@pa int=0;
  UPDATE d SET valido_hasta=@corte,es_actual=0 FROM dw.dim_producto d JOIN #producto s ON s.StockItemID=d.producto_id WHERE d.es_actual=1 AND d.hash_atributos<>s.h;
  SET @pc=@@ROWCOUNT;
  INSERT dw.dim_producto(producto_id,producto,proveedor_id,marca,tamano,precio_unitario,precio_recomendado,dias_reposicion,hash_atributos,valido_desde,valido_hasta,es_actual)
  SELECT s.StockItemID,s.StockItemName,s.SupplierID,s.Brand,s.Size,s.UnitPrice,s.RecommendedRetailPrice,s.LeadTimeDays,s.h,
   CASE WHEN d.producto_id IS NULL AND NOT EXISTS(SELECT 1 FROM dw.dim_producto) THEN CONVERT(datetime2,'19000101') ELSE @corte END,'99991231',1
  FROM #producto s LEFT JOIN dw.dim_producto d ON d.producto_id=s.StockItemID AND d.es_actual=1
  WHERE d.producto_id IS NULL OR d.hash_atributos<>s.h;
  SET @pa=@@ROWCOUNT;

  INSERT dw.fact_venta(linea_factura_id,factura_id,fecha_key,cliente_key,producto_key,empleado_key,cantidad,precio_unitario,impuesto,beneficio,importe_total,editado_en)
  SELECT l.InvoiceLineID,l.InvoiceID,CONVERT(int,CONVERT(char(8),l.InvoiceDate,112)),dc.cliente_key,dp.producto_key,de.empleado_key,
   l.Quantity,l.UnitPrice,l.TaxAmount,l.LineProfit,l.ExtendedPrice,l.LastEditedWhen
  FROM stg.venta_linea l
  JOIN dw.dim_cliente dc ON dc.cliente_id=l.CustomerID AND l.InvoiceDate>=CONVERT(date,dc.valido_desde) AND l.InvoiceDate<CONVERT(date,dc.valido_hasta)
  JOIN dw.dim_producto dp ON dp.producto_id=l.StockItemID AND l.InvoiceDate>=CONVERT(date,dp.valido_desde) AND l.InvoiceDate<CONVERT(date,dp.valido_hasta)
  JOIN dw.dim_empleado de ON de.empleado_id=l.SalespersonPersonID
  WHERE l.LastEditedWhen>@wm_venta AND l.LastEditedWhen<=@corte AND NOT EXISTS(SELECT 1 FROM dw.fact_venta f WHERE f.linea_factura_id=l.InvoiceLineID);
  DECLARE @fv int=@@ROWCOUNT;
  INSERT dw.fact_compra(linea_compra_id,orden_compra_id,fecha_key,producto_key,proveedor_key,exteriores_pedidos,exteriores_recibidos,precio_exterior,editado_en)
  SELECT l.PurchaseOrderLineID,l.PurchaseOrderID,CONVERT(int,CONVERT(char(8),l.OrderDate,112)),dp.producto_key,dpr.proveedor_key,l.OrderedOuters,l.ReceivedOuters,l.ExpectedUnitPricePerOuter,l.LastEditedWhen
  FROM stg.compra_linea l
  JOIN dw.dim_producto dp ON dp.producto_id=l.StockItemID AND l.OrderDate>=CONVERT(date,dp.valido_desde) AND l.OrderDate<CONVERT(date,dp.valido_hasta)
  JOIN dw.dim_proveedor dpr ON dpr.proveedor_id=l.SupplierID
  WHERE l.LastEditedWhen>@wm_compra AND l.LastEditedWhen<=@corte AND NOT EXISTS(SELECT 1 FROM dw.fact_compra f WHERE f.linea_compra_id=l.PurchaseOrderLineID);
  DECLARE @fc int=@@ROWCOUNT;
  DELETE f FROM dw.fact_stock_diario f JOIN dw.dim_producto p ON p.producto_key=f.producto_key
   WHERE f.fecha_key=CONVERT(int,CONVERT(char(8),CONVERT(date,@corte),112)) AND p.es_actual=0;
  MERGE dw.fact_stock_diario t USING(SELECT CONVERT(int,CONVERT(char(8),CONVERT(date,@corte),112)) fecha_key,p.producto_key,h.QuantityOnHand,h.LastCostPrice,h.ReorderLevel,h.TargetStockLevel,h.LastEditedWhen
   FROM stg.stock_actual h JOIN dw.dim_producto p ON p.producto_id=h.StockItemID AND p.es_actual=1) s
  ON s.fecha_key=t.fecha_key AND s.producto_key=t.producto_key
  WHEN MATCHED AND (t.cantidad_disponible<>s.QuantityOnHand OR t.costo_ultimo<>s.LastCostPrice OR t.punto_reorden<>s.ReorderLevel OR t.stock_objetivo<>s.TargetStockLevel OR t.editado_en<>s.LastEditedWhen)
   THEN UPDATE SET cantidad_disponible=s.QuantityOnHand,costo_ultimo=s.LastCostPrice,punto_reorden=s.ReorderLevel,stock_objetivo=s.TargetStockLevel,editado_en=s.LastEditedWhen
  WHEN NOT MATCHED THEN INSERT VALUES(s.fecha_key,s.producto_key,s.QuantityOnHand,s.LastCostPrice,s.ReorderLevel,s.TargetStockLevel,s.LastEditedWhen);
  DECLARE @fs int=@@ROWCOUNT;
  MERGE audit.marca_agua t USING(VALUES('cliente',@corte),('producto',@corte),('venta',@corte),('compra',@corte)) s(fuente,fecha)
  ON t.fuente=s.fuente WHEN MATCHED THEN UPDATE SET ultima_fecha=s.fecha,actualizado_en=SYSUTCDATETIME() WHEN NOT MATCHED THEN INSERT(fuente,ultima_fecha) VALUES(s.fuente,s.fecha);
  UPDATE audit.ejecucion SET fin=SYSUTCDATETIME(),filas_venta=@fv,filas_compra=@fc,filas_stock=@fs,cliente_cierres=@cc,cliente_aperturas=@ca,producto_cierres=@pc,producto_aperturas=@pa,estado='OK' WHERE ejecucion_id=@id;
  COMMIT;
 END TRY
 BEGIN CATCH
  IF @@TRANCOUNT>0 ROLLBACK;
  UPDATE audit.ejecucion SET fin=SYSUTCDATETIME(),estado='FALLA',detalle=ERROR_MESSAGE() WHERE ejecucion_id=@id;
  THROW;
 END CATCH
END;
GO
EXEC etl.sp_cargar @modo='COMPLETA';
GO
