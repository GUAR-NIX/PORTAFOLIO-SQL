USE DW_WWI;
GO
CREATE TABLE audit.marca_agua(
 fuente sysname NOT NULL PRIMARY KEY, ultima_fecha datetime2(7) NOT NULL,
 actualizado_en datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME()
);
CREATE TABLE audit.ejecucion(
 ejecucion_id bigint IDENTITY PRIMARY KEY, tipo varchar(20) NOT NULL,
 inicio datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME(), fin datetime2(7) NULL,
 filas_venta int NOT NULL DEFAULT 0, filas_compra int NOT NULL DEFAULT 0,
 filas_stock int NOT NULL DEFAULT 0,
 -- SCD2: un cambio de atributos produce un cierre (versión anterior) y una apertura (versión nueva).
 -- En la carga completa las aperturas son las versiones iniciales y no hay cierres.
 cliente_cierres int NOT NULL DEFAULT 0, cliente_aperturas int NOT NULL DEFAULT 0,
 producto_cierres int NOT NULL DEFAULT 0, producto_aperturas int NOT NULL DEFAULT 0,
 estado varchar(20) NOT NULL DEFAULT 'EN_CURSO',
 detalle nvarchar(1000) NULL
);
CREATE TABLE audit.controles(
 control_id bigint IDENTITY PRIMARY KEY, ejecutado_en datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME(),
 control nvarchar(150) NOT NULL, valor_observado decimal(28,4) NULL,
 valor_esperado decimal(28,4) NULL, estado varchar(10) NOT NULL, detalle nvarchar(500) NULL
);

CREATE TABLE dw.dim_fecha(
 fecha_key int NOT NULL PRIMARY KEY, fecha date NOT NULL UNIQUE, anio smallint NOT NULL,
 trimestre tinyint NOT NULL, mes tinyint NOT NULL, nombre_mes varchar(15) NOT NULL,
 dia tinyint NOT NULL, dia_semana tinyint NOT NULL, nombre_dia varchar(15) NOT NULL
);
CREATE TABLE dw.dim_ciudad(
 ciudad_key int IDENTITY PRIMARY KEY, ciudad_id int NOT NULL UNIQUE, ciudad nvarchar(50) NOT NULL,
 provincia nvarchar(50) NOT NULL, territorio_ventas nvarchar(50) NOT NULL, pais nvarchar(60) NOT NULL,
 continente nvarchar(30) NOT NULL
);
CREATE TABLE dw.dim_empleado(
 empleado_key int IDENTITY PRIMARY KEY, empleado_id int NOT NULL UNIQUE,
 nombre nvarchar(50) NOT NULL, es_vendedor bit NOT NULL
);
CREATE TABLE dw.dim_proveedor(
 proveedor_key int IDENTITY PRIMARY KEY, proveedor_id int NOT NULL UNIQUE,
 proveedor nvarchar(100) NOT NULL, ciudad_key int NOT NULL REFERENCES dw.dim_ciudad(ciudad_key)
);
CREATE TABLE dw.dim_cliente(
 cliente_key int IDENTITY PRIMARY KEY, cliente_id int NOT NULL, cliente nvarchar(100) NOT NULL,
 categoria_id int NOT NULL, categoria nvarchar(50) NOT NULL, ciudad_key int NOT NULL REFERENCES dw.dim_ciudad(ciudad_key),
 limite_credito decimal(18,2) NULL, dias_pago int NOT NULL, hash_atributos varbinary(32) NOT NULL,
 valido_desde datetime2(7) NOT NULL, valido_hasta datetime2(7) NOT NULL, es_actual bit NOT NULL,
 CONSTRAINT UQ_dim_cliente_version UNIQUE(cliente_id,valido_desde),
 CONSTRAINT CK_dim_cliente_intervalo CHECK(valido_desde<valido_hasta)
);
CREATE UNIQUE INDEX UX_dim_cliente_actual ON dw.dim_cliente(cliente_id) WHERE es_actual=1;
CREATE INDEX IX_dim_cliente_vigencia ON dw.dim_cliente(cliente_id,valido_desde,valido_hasta);
CREATE TABLE dw.dim_producto(
 producto_key int IDENTITY PRIMARY KEY, producto_id int NOT NULL, producto nvarchar(100) NOT NULL,
 proveedor_id int NOT NULL, marca nvarchar(50) NULL, tamano nvarchar(20) NULL,
 precio_unitario decimal(18,2) NOT NULL, precio_recomendado decimal(18,2) NULL,
 dias_reposicion int NOT NULL, hash_atributos varbinary(32) NOT NULL,
 valido_desde datetime2(7) NOT NULL, valido_hasta datetime2(7) NOT NULL, es_actual bit NOT NULL,
 CONSTRAINT UQ_dim_producto_version UNIQUE(producto_id,valido_desde),
 CONSTRAINT CK_dim_producto_intervalo CHECK(valido_desde<valido_hasta)
);
CREATE UNIQUE INDEX UX_dim_producto_actual ON dw.dim_producto(producto_id) WHERE es_actual=1;
CREATE INDEX IX_dim_producto_vigencia ON dw.dim_producto(producto_id,valido_desde,valido_hasta);

CREATE TABLE dw.fact_venta(
 linea_factura_id int NOT NULL PRIMARY KEY, factura_id int NOT NULL, fecha_key int NOT NULL REFERENCES dw.dim_fecha(fecha_key),
 cliente_key int NOT NULL REFERENCES dw.dim_cliente(cliente_key), producto_key int NOT NULL REFERENCES dw.dim_producto(producto_key),
 empleado_key int NOT NULL REFERENCES dw.dim_empleado(empleado_key), cantidad int NOT NULL,
 precio_unitario decimal(18,2) NULL, impuesto decimal(18,2) NOT NULL, beneficio decimal(18,2) NOT NULL,
 importe_total decimal(18,2) NOT NULL, editado_en datetime2(7) NOT NULL
);
CREATE INDEX IX_fact_venta_fecha ON dw.fact_venta(fecha_key) INCLUDE(importe_total,beneficio);
CREATE TABLE dw.fact_compra(
 linea_compra_id int NOT NULL PRIMARY KEY, orden_compra_id int NOT NULL, fecha_key int NOT NULL REFERENCES dw.dim_fecha(fecha_key),
 producto_key int NOT NULL REFERENCES dw.dim_producto(producto_key), proveedor_key int NOT NULL REFERENCES dw.dim_proveedor(proveedor_key),
 exteriores_pedidos int NOT NULL, exteriores_recibidos int NOT NULL, precio_exterior decimal(18,2) NULL,
 importe_esperado AS CONVERT(decimal(18,2),exteriores_pedidos*precio_exterior) PERSISTED,
 editado_en datetime2(7) NOT NULL
);
CREATE TABLE dw.fact_stock_diario(
 fecha_key int NOT NULL REFERENCES dw.dim_fecha(fecha_key), producto_key int NOT NULL REFERENCES dw.dim_producto(producto_key),
 cantidad_disponible int NOT NULL, costo_ultimo decimal(18,2) NOT NULL, punto_reorden int NOT NULL,
 stock_objetivo int NOT NULL, editado_en datetime2(7) NOT NULL,
 CONSTRAINT PK_fact_stock PRIMARY KEY(fecha_key,producto_key)
);
GO
/* stg: vistas sobre el OLTP restaurado en la misma instancia, no tablas copiadas.
   Fijan el contrato de columnas y el grano que lee etl.sp_cargar sin duplicar ~230 mil filas;
   la marca de agua se aplica al leer la vista. Si la fuente estuviera en otro servidor,
   este esquema se materializaría con tablas de aterrizaje. */
CREATE OR ALTER VIEW stg.cliente_actual AS SELECT * FROM WideWorldImporters.Sales.Customers;
GO
CREATE OR ALTER VIEW stg.producto_actual AS SELECT * FROM WideWorldImporters.Warehouse.StockItems;
GO
CREATE OR ALTER VIEW stg.venta_linea AS
SELECT l.InvoiceLineID,i.InvoiceID,i.CustomerID,i.SalespersonPersonID,i.InvoiceDate,l.StockItemID,l.Quantity,l.UnitPrice,l.TaxRate,l.TaxAmount,l.LineProfit,l.ExtendedPrice,l.LastEditedWhen
FROM WideWorldImporters.Sales.Invoices i JOIN WideWorldImporters.Sales.InvoiceLines l ON l.InvoiceID=i.InvoiceID;
GO
CREATE OR ALTER VIEW stg.compra_linea AS
SELECT l.PurchaseOrderLineID,o.PurchaseOrderID,o.SupplierID,o.OrderDate,l.StockItemID,l.OrderedOuters,l.ReceivedOuters,l.ExpectedUnitPricePerOuter,l.LastEditedWhen
FROM WideWorldImporters.Purchasing.PurchaseOrders o JOIN WideWorldImporters.Purchasing.PurchaseOrderLines l ON l.PurchaseOrderID=o.PurchaseOrderID;
GO
CREATE OR ALTER VIEW stg.stock_actual AS SELECT * FROM WideWorldImporters.Warehouse.StockItemHoldings;
GO


