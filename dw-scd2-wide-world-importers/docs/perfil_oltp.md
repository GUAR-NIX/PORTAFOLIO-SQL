# Perfil del OLTP WideWorldImporters

Perfil tomado inmediatamente después de restaurar el respaldo oficial `WideWorldImporters-Full.bak`.

## Volumen y período

| Entidad | Filas |
|---|---:|
| `Sales.Invoices` | 70.510 |
| `Sales.InvoiceLines` | 228.265 |
| `Sales.Orders` | 73.595 |
| `Sales.OrderLines` | 231.412 |
| `Purchasing.PurchaseOrders` | 2.074 |
| `Purchasing.PurchaseOrderLines` | 8.367 |
| `Warehouse.StockItems` | 227 |
| `Warehouse.StockItemTransactions` | 236.667 |
| `Sales.Customers` | 663 |
| `Application.Cities` | 37.940 |

Las 228.265 líneas son las del respaldo. El DW termina con 228.280 porque `sql/08_simular_cambios.sql` agrega 5 facturas y 15 líneas de prueba; los reportes las marcan como simulación.

Las facturas abarcan del 01-01-2013 al 31-05-2016 (2016 solo tiene cinco meses). La granularidad de venta elegida es una fila por `InvoiceLineID`; la de compra, una fila por `PurchaseOrderLineID`; la de inventario, producto y día de snapshot.

## Áreas y relaciones relevantes

- `Sales`: clientes, categorías, facturas y líneas. `Invoices` aporta fecha, cliente y vendedor; `InvoiceLines`, cantidades, precios, impuesto, beneficio e importe.
- `Purchasing`: proveedores, órdenes y líneas de compra.
- `Warehouse`: catálogo de productos, existencias y movimientos.
- `Application`: personas, ciudades, provincias y países.

## Temporalidad

`Sales.Customers`, `Sales.CustomerCategories`, `Warehouse.StockItems`, `Purchasing.Suppliers`, `Application.People`, `Application.Cities`, `Application.StateProvinces` y `Application.Countries` son tablas temporales del sistema. Sus columnas `ValidFrom` y `ValidTo` describen cuándo una versión existió en el OLTP.

El DW usa esas marcas para detectar cambios nuevos, pero inicia la primera versión analítica en `1900-01-01`. Es deliberado: las fechas de sistema del respaldo no equivalen necesariamente a vigencia comercial retroactiva. Las versiones creadas durante la simulación sí quedan cerradas y abiertas en el instante real de carga.

## Hallazgos de modelado

- Los hechos guardan claves sustitutas, no claves naturales, para conservar la versión de cliente/producto vigente.
- `LineProfit` ya existe en la fuente; evita inferir costo histórico a partir del costo actual.
- `ExtendedPrice` incluye impuesto y es la medida usada para reconciliar ventas.
- `Warehouse.StockItemHoldings` está fechado el 31-05-2016 y sus existencias son muy altas frente al stock objetivo (221 de 227 productos lo superan; el producto 1 tiene 175.609 unidades con objetivo 100). Además no cuadran con `StockItemTransactions` (para el producto 1, los movimientos suman −5.781). Por eso la cobertura de `rpt.stock_actual` resulta alta: es un rasgo de los datos de muestra.
- Express no tiene SQL Agent: la ejecución periódica se deja documentada para Programador de tareas o un orquestador externo.

Fuente: [Microsoft SQL Server Samples — Wide World Importers](https://github.com/microsoft/sql-server-samples/tree/master/samples/databases/wide-world-importers). Licencia: MIT.

