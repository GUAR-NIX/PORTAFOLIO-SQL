/* Laboratorio idempotente. Modifica solo la copia local restaurada de WWI.
   Para volver al estado original, restaure de nuevo el .bak. */
USE WideWorldImporters;
GO
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM Sales.Invoices WHERE CustomerPurchaseOrderNumber=N'SQL03-SIM-001')
BEGIN
 BEGIN TRAN;
 ;WITH x AS(SELECT TOP(50) CustomerID,CustomerCategoryID,ROW_NUMBER() OVER(ORDER BY CustomerID) n FROM Sales.Customers ORDER BY CustomerID)
 UPDATE c SET CustomerCategoryID=CASE WHEN c.CustomerCategoryID=1 THEN 2 ELSE 1 END,LastEditedBy=1
 FROM Sales.Customers c JOIN x ON x.CustomerID=c.CustomerID;
 ;WITH x AS(SELECT TOP(100) StockItemID FROM Warehouse.StockItems ORDER BY StockItemID)
 UPDATE p SET UnitPrice=ROUND(p.UnitPrice*1.05,2),LastEditedBy=1 FROM Warehouse.StockItems p JOIN x ON x.StockItemID=p.StockItemID;
 DECLARE @i int=1,@factura int,@cliente int,@vendedor int=(SELECT MIN(PersonID) FROM Application.People WHERE IsSalesperson=1);
 WHILE @i<=5
 BEGIN
  SELECT @cliente=CustomerID FROM(SELECT CustomerID,ROW_NUMBER() OVER(ORDER BY CustomerID) n FROM Sales.Customers)x WHERE n=@i;
  SET @factura=NEXT VALUE FOR Sequences.InvoiceID;
  INSERT Sales.Invoices(InvoiceID,CustomerID,BillToCustomerID,OrderID,DeliveryMethodID,ContactPersonID,AccountsPersonID,SalespersonPersonID,PackedByPersonID,InvoiceDate,CustomerPurchaseOrderNumber,IsCreditNote,CreditNoteReason,Comments,DeliveryInstructions,InternalComments,TotalDryItems,TotalChillerItems,DeliveryRun,RunPosition,ReturnedDeliveryData,LastEditedBy,LastEditedWhen)
  SELECT @factura,c.CustomerID,c.BillToCustomerID,NULL,c.DeliveryMethodID,c.PrimaryContactPersonID,c.PrimaryContactPersonID,@vendedor,@vendedor,CONVERT(date,SYSUTCDATETIME()),CONCAT('SQL03-SIM-',FORMAT(@i,'000')),0,NULL,N'Escenario de prueba SQL_03',NULL,NULL,3,0,c.DeliveryRun,c.RunPosition,NULL,1,SYSUTCDATETIME() FROM Sales.Customers c WHERE c.CustomerID=@cliente;
  INSERT Sales.InvoiceLines(InvoiceLineID,InvoiceID,StockItemID,Description,PackageTypeID,Quantity,UnitPrice,TaxRate,TaxAmount,LineProfit,ExtendedPrice,LastEditedBy,LastEditedWhen)
  SELECT NEXT VALUE FOR Sequences.InvoiceLineID,@factura,p.StockItemID,p.StockItemName,p.UnitPackageID,2,p.UnitPrice,p.TaxRate,ROUND(2*p.UnitPrice*p.TaxRate/100,2),ROUND(2*(p.UnitPrice-h.LastCostPrice),2),ROUND(2*p.UnitPrice*(1+p.TaxRate/100),2),1,SYSUTCDATETIME()
  FROM(SELECT TOP(3)* FROM Warehouse.StockItems ORDER BY StockItemID)p JOIN Warehouse.StockItemHoldings h ON h.StockItemID=p.StockItemID;
  SET @i+=1;
 END;
 COMMIT;
END;
GO
USE DW_WWI;
GO
EXEC etl.sp_cargar @modo='INCREMENTAL';
EXEC audit.sp_validar;
GO

