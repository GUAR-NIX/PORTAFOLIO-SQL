"""Pruebas de integración contra SQL Server.

Requieren SQL Server Express local (o SQL_SERVER), ODBC Driver 18, WideWorldImporters
restaurado y DW_WWI construido con 00_EJECUTAR_TODO.sql; si no hay conexión se omiten.
No dependen de la simulación: dan lo mismo antes o después de 08_simular_cambios.sql.
Las que ejecutan el ETL o los controles lo hacen dentro de una transacción que se revierte,
así que no dejan filas en audit ni modifican el OLTP.
"""
from contextlib import closing, contextmanager
from datetime import timedelta
import pyodbc
import pytest
from scripts.conexion import conectar

CONTADORES = "filas_venta,filas_compra,filas_stock,cliente_cierres,cliente_aperturas,producto_cierres,producto_aperturas"


@pytest.fixture(scope="module", autouse=True)
def requiere_sql_server():
    try:
        with closing(conectar()) as cn:
            cn.cursor().execute("SELECT TOP(0) 1 FROM dw.fact_venta").fetchall()
    except pyodbc.Error as error:
        pytest.skip(f"Requiere SQL Server con DW_WWI construido: {error}")


def escalar(sql, *parametros):
    with closing(conectar()) as cn:
        return cn.cursor().execute(sql, *parametros).fetchval()


@contextmanager
def transaccion_revertida():
    cn = conectar(autocommit=False)
    try:
        yield cn.cursor()
    finally:
        cn.rollback(); cn.close()


def cargar_incremental(cur):
    cur.execute("EXEC etl.sp_cargar @modo='INCREMENTAL'")
    fila = cur.execute(f"SELECT TOP(1) {CONTADORES} FROM audit.ejecucion ORDER BY ejecucion_id DESC").fetchone()
    return dict(zip(CONTADORES.split(","), fila))


def cliente_sin_historia(cur):
    return cur.execute("SELECT MAX(cliente_id) FROM dw.dim_cliente WHERE es_actual=1 AND valido_desde='19000101'").fetchval()


def test_reconciliacion_ventas_y_compras():
    assert escalar("SELECT COUNT(*) FROM dw.fact_venta") == escalar("SELECT COUNT(*) FROM WideWorldImporters.Sales.InvoiceLines")
    assert escalar("SELECT COUNT(*) FROM dw.fact_compra") == escalar("SELECT COUNT(*) FROM WideWorldImporters.Purchasing.PurchaseOrderLines")
    assert float(escalar("SELECT ABS((SELECT SUM(importe_total) FROM dw.fact_venta)-(SELECT SUM(ExtendedPrice) FROM WideWorldImporters.Sales.InvoiceLines))")) < .01


def test_cada_hecho_apunta_a_la_version_vigente_en_su_fecha():
    fuera = escalar("""SELECT COUNT(*) FROM dw.fact_venta f JOIN dw.dim_fecha fe ON fe.fecha_key=f.fecha_key
      JOIN dw.dim_cliente c ON c.cliente_key=f.cliente_key JOIN dw.dim_producto p ON p.producto_key=f.producto_key
      WHERE NOT(fe.fecha>=CONVERT(date,c.valido_desde) AND fe.fecha<CONVERT(date,c.valido_hasta))
         OR NOT(fe.fecha>=CONVERT(date,p.valido_desde) AND fe.fecha<CONVERT(date,p.valido_hasta))""")
    assert fuera == 0


def test_hash_ignora_atributos_no_rastreados():
    with transaccion_revertida() as cur:
        cliente = cliente_sin_historia(cur)
        cur.execute("UPDATE WideWorldImporters.Sales.Customers SET PhoneNumber=N'(000) 000-0000' WHERE CustomerID=?", cliente)
        ejecucion = cargar_incremental(cur)
        assert (ejecucion["cliente_cierres"], ejecucion["cliente_aperturas"]) == (0, 0)
        assert cur.execute("SELECT COUNT(*) FROM dw.dim_cliente WHERE cliente_id=?", cliente).fetchval() == 1


def test_cambio_rastreado_cierra_y_abre_version_con_busqueda_punto_en_el_tiempo():
    with transaccion_revertida() as cur:
        cliente = cliente_sin_historia(cur)
        anterior = cur.execute("SELECT cliente_key,hash_atributos,dias_pago FROM dw.dim_cliente WHERE cliente_id=? AND es_actual=1", cliente).fetchone()
        cur.execute("UPDATE WideWorldImporters.Sales.Customers SET PaymentDays=PaymentDays+1 WHERE CustomerID=?", cliente)
        ejecucion = cargar_incremental(cur)
        assert ejecucion["cliente_cierres"] >= 1 and ejecucion["cliente_aperturas"] >= 1
        versiones = cur.execute("""SELECT cliente_key,hash_atributos,dias_pago,valido_desde,valido_hasta,es_actual
          FROM dw.dim_cliente WHERE cliente_id=? ORDER BY valido_desde""", cliente).fetchall()
        assert len(versiones) == 2
        vieja, nueva = versiones
        assert vieja.cliente_key == anterior.cliente_key and not vieja.es_actual and nueva.es_actual
        assert vieja.valido_hasta == nueva.valido_desde
        assert nueva.hash_atributos != anterior.hash_atributos and nueva.dias_pago == anterior.dias_pago + 1
        vigente = "SELECT cliente_key FROM dw.dim_cliente WHERE cliente_id=? AND ?>=valido_desde AND ?<valido_hasta"
        for instante, esperada in [("2015-06-30", vieja.cliente_key), (nueva.valido_desde + timedelta(seconds=1), nueva.cliente_key)]:
            assert [r.cliente_key for r in cur.execute(vigente, cliente, instante, instante).fetchall()] == [esperada]


def test_incremental_repetida_es_idempotente():
    conteo = "SELECT (SELECT COUNT(*) FROM dw.fact_venta),(SELECT COUNT(*) FROM dw.fact_compra),(SELECT COUNT(*) FROM dw.dim_cliente),(SELECT COUNT(*) FROM dw.dim_producto)"
    with transaccion_revertida() as cur:
        cargar_incremental(cur)
        antes = tuple(cur.execute(conteo).fetchone())
        segunda = cargar_incremental(cur)
        assert set(segunda.values()) == {0}
        assert tuple(cur.execute(conteo).fetchone()) == antes


def test_controles_calidad():
    with transaccion_revertida() as cur:
        cur.execute("EXEC audit.sp_validar")
        assert cur.execute("SELECT COUNT(*) FROM audit.controles").fetchval() > 0
        assert cur.execute("SELECT COUNT(*) FROM audit.controles WHERE estado='FALLA'").fetchval() == 0
