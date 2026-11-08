"""Mide la carga completa y la incremental con repeticiones y guarda la mediana.

Escenarios (5 repeticiones cada uno):
- completa: reconstruye DW_WWI (02 + 03 + 04) y carga todo desde el OLTP.
- incremental_sin_cambios: nada nuevo en la fuente; mide el costo fijo.
- incremental_dia_tipico: copia como facturas de hoy las de un día real con la mediana de
  líneas por día, cambia 5 clientes y 5 productos y carga. Todo ocurre en una transacción
  que se revierte, así que el OLTP y el DW quedan como estaban.

La duración es la que registra etl.sp_cargar en audit.ejecucion (inicio y fin del
procedimiento). Debe ejecutarse sobre la fuente limpia y antes de 00_EJECUTAR_TODO.sql,
porque deja DW_WWI sin vistas ni controles.
"""
from __future__ import annotations
import os
from contextlib import closing
import statistics
import subprocess
from pathlib import Path
import pandas as pd
import pyodbc
from conexion import conectar

# 02_crear_dw.sql expulsa las sesiones abiertas; sin pool no se reutiliza una conexión cerrada.
pyodbc.pooling = False

RAIZ = Path(__file__).resolve().parents[1]
TABLAS = RAIZ / "reports" / "tablas"
REPETICIONES = 5
COLUMNAS = ("duracion_ms", "filas_venta", "filas_compra", "filas_stock",
            "cliente_cierres", "cliente_aperturas", "producto_cierres", "producto_aperturas")
ULTIMA = ("SELECT TOP(1) DATEDIFF_BIG(microsecond,inicio,fin)/1000.0,filas_venta,filas_compra,filas_stock,"
          "cliente_cierres,cliente_aperturas,producto_cierres,producto_aperturas "
          "FROM DW_WWI.audit.ejecucion ORDER BY ejecucion_id DESC")

DIA_TIPICO = """
SET NOCOUNT ON;
DECLARE @mediana int=(SELECT DISTINCT CONVERT(int,PERCENTILE_CONT(.5) WITHIN GROUP(ORDER BY n) OVER())
 FROM(SELECT i.InvoiceDate,COUNT(*) n FROM Sales.Invoices i JOIN Sales.InvoiceLines l ON l.InvoiceID=i.InvoiceID GROUP BY i.InvoiceDate)d);
DECLARE @dia date=(SELECT TOP(1) InvoiceDate
 FROM(SELECT i.InvoiceDate,COUNT(*) n FROM Sales.Invoices i JOIN Sales.InvoiceLines l ON l.InvoiceID=i.InvoiceID GROUP BY i.InvoiceDate)d
 ORDER BY ABS(n-@mediana),InvoiceDate DESC);
DECLARE @f int=(SELECT MAX(InvoiceID) FROM Sales.Invoices),@l int=(SELECT MAX(InvoiceLineID) FROM Sales.InvoiceLines),
 @hoy date=CONVERT(date,SYSUTCDATETIME()),@ahora datetime2(7)=SYSUTCDATETIME();
DECLARE @mapa TABLE(InvoiceID int PRIMARY KEY,nueva int NOT NULL);
INSERT @mapa SELECT InvoiceID,@f+ROW_NUMBER() OVER(ORDER BY InvoiceID) FROM Sales.Invoices WHERE InvoiceDate=@dia;
INSERT Sales.Invoices(InvoiceID,CustomerID,BillToCustomerID,OrderID,DeliveryMethodID,ContactPersonID,AccountsPersonID,SalespersonPersonID,PackedByPersonID,InvoiceDate,CustomerPurchaseOrderNumber,IsCreditNote,CreditNoteReason,Comments,DeliveryInstructions,InternalComments,TotalDryItems,TotalChillerItems,DeliveryRun,RunPosition,ReturnedDeliveryData,LastEditedBy,LastEditedWhen)
SELECT m.nueva,i.CustomerID,i.BillToCustomerID,NULL,i.DeliveryMethodID,i.ContactPersonID,i.AccountsPersonID,i.SalespersonPersonID,i.PackedByPersonID,@hoy,N'SQL03-MEDICION',i.IsCreditNote,i.CreditNoteReason,i.Comments,i.DeliveryInstructions,i.InternalComments,i.TotalDryItems,i.TotalChillerItems,i.DeliveryRun,i.RunPosition,NULL,1,@ahora
FROM Sales.Invoices i JOIN @mapa m ON m.InvoiceID=i.InvoiceID;
INSERT Sales.InvoiceLines(InvoiceLineID,InvoiceID,StockItemID,Description,PackageTypeID,Quantity,UnitPrice,TaxRate,TaxAmount,LineProfit,ExtendedPrice,LastEditedBy,LastEditedWhen)
SELECT @l+ROW_NUMBER() OVER(ORDER BY l.InvoiceLineID),m.nueva,l.StockItemID,l.Description,l.PackageTypeID,l.Quantity,l.UnitPrice,l.TaxRate,l.TaxAmount,l.LineProfit,l.ExtendedPrice,1,@ahora
FROM Sales.InvoiceLines l JOIN @mapa m ON m.InvoiceID=l.InvoiceID;
;WITH x AS(SELECT TOP(5) * FROM Sales.Customers ORDER BY CustomerID DESC) UPDATE x SET PaymentDays=PaymentDays+1;
;WITH x AS(SELECT TOP(5) * FROM Warehouse.StockItems ORDER BY StockItemID DESC) UPDATE x SET UnitPrice=ROUND(UnitPrice*1.05,2);
"""


def sqlcmd(*archivos: str) -> None:
    servidor = os.getenv("SQL_SERVER", r"localhost\SQLEXPRESS")
    entradas = [a for archivo in archivos for a in ("-i", str(Path("sql") / archivo))]
    subprocess.run(["sqlcmd", "-S", servidor, "-E", "-C", "-I", "-b", "-f", "65001", *entradas],
                   cwd=RAIZ, check=True, capture_output=True)


def medir(escenario: str, repeticion: int, cursor) -> dict:
    fila = cursor.execute(ULTIMA).fetchone()
    return {"escenario": escenario, "repeticion": repeticion, **dict(zip(COLUMNAS, fila))}


def main() -> None:
    with closing(conectar("WideWorldImporters")) as cn:
        simuladas = cn.cursor().execute(
            "SELECT COUNT(*) FROM Sales.Invoices WHERE CustomerPurchaseOrderNumber LIKE N'SQL03-SIM-%'").fetchval()
    if simuladas:
        raise SystemExit("La fuente ya tiene la simulación: restaure el .bak antes de medir (ver README).")

    filas = []
    for r in range(1, REPETICIONES + 1):
        sqlcmd("02_crear_dw.sql", "03_modelo_estrella.sql", "04_carga_etl.sql")
        with closing(conectar()) as cn:
            filas.append(medir("completa", r, cn.cursor()))
    for r in range(1, REPETICIONES + 1):
        with closing(conectar()) as cn:
            cur = cn.cursor()
            cur.execute("EXEC etl.sp_cargar @modo='INCREMENTAL'")
            filas.append(medir("incremental_sin_cambios", r, cur))
    for r in range(1, REPETICIONES + 1):
        cn = conectar("WideWorldImporters", autocommit=False)
        try:
            cur = cn.cursor()
            cur.execute(DIA_TIPICO)
            cur.execute("EXEC DW_WWI.etl.sp_cargar @modo='INCREMENTAL'")
            filas.append(medir("incremental_dia_tipico", r, cur))
        finally:
            cn.rollback(); cn.close()

    TABLAS.mkdir(parents=True, exist_ok=True)
    detalle = pd.DataFrame(filas)
    detalle["duracion_ms"] = detalle["duracion_ms"].astype(float).round(1)
    detalle.to_csv(TABLAS / "tiempos_carga.csv", index=False, encoding="utf-8-sig")
    resumen = detalle.groupby("escenario", sort=False).agg(
        repeticiones=("duracion_ms", "size"), mediana_ms=("duracion_ms", statistics.median),
        min_ms=("duracion_ms", "min"), max_ms=("duracion_ms", "max"),
        filas_venta=("filas_venta", "median"), filas_compra=("filas_compra", "median"),
        filas_stock=("filas_stock", "median"), cliente_cierres=("cliente_cierres", "median"),
        cliente_aperturas=("cliente_aperturas", "median"), producto_cierres=("producto_cierres", "median"),
        producto_aperturas=("producto_aperturas", "median")).reset_index()
    resumen.to_csv(TABLAS / "tiempos_carga_resumen.csv", index=False, encoding="utf-8-sig")
    print(resumen.to_string(index=False))
    print("DW_WWI quedó sin vistas ni controles: ejecute ahora sql\\00_EJECUTAR_TODO.sql.")


if __name__ == "__main__": main()
