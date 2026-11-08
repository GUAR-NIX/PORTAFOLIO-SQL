"""Exporta evidencia reproducible y tres figuras desde las vistas rpt.*."""
from __future__ import annotations
import json
from pathlib import Path
import matplotlib.pyplot as plt
import pandas as pd
from conexion import conectar

RAIZ = Path(__file__).resolve().parents[1]
TABLAS = RAIZ / "reports" / "tablas"
FIGURAS = RAIZ / "reports" / "figures"
# Facturas insertadas por sql/08_simular_cambios.sql; el DW no las distingue, el OLTP sí.
SIMULADAS = "SELECT InvoiceID FROM WideWorldImporters.Sales.Invoices WHERE CustomerPurchaseOrderNumber LIKE N'SQL03-SIM-%'"


def consulta(sql: str) -> pd.DataFrame:
    with conectar() as cn:
        return pd.read_sql(sql, cn)


def guardar_figura(nombre: str) -> None:
    plt.tight_layout()
    plt.savefig(FIGURAS / nombre, dpi=160, bbox_inches="tight")
    plt.close()


def main() -> None:
    TABLAS.mkdir(parents=True, exist_ok=True); FIGURAS.mkdir(parents=True, exist_ok=True)
    ventas = consulta(f"""SELECT anio,o.origen,COUNT(DISTINCT mes) meses_con_ventas,COUNT_BIG(*) lineas,COUNT(DISTINCT factura_id) facturas,
      SUM(importe_total) ventas,SUM(beneficio) beneficio
      FROM rpt.ventas v CROSS APPLY(SELECT CASE WHEN v.factura_id IN({SIMULADAS}) THEN 'simulación SQL_03' ELSE 'WWI original' END origen) o
      GROUP BY anio,o.origen ORDER BY o.origen DESC,anio""")
    controles = consulta("SELECT control,valor_observado,valor_esperado,estado,detalle FROM audit.controles ORDER BY control_id")
    categorias = consulta("SELECT * FROM rpt.ventas_categoria_comparacion ORDER BY ventas DESC")
    ejecuciones = consulta("""SELECT ejecucion_id,tipo,DATEDIFF(millisecond,inicio,fin) duracion_ms,filas_venta,filas_compra,filas_stock,
      cliente_cierres,cliente_aperturas,producto_cierres,producto_aperturas,estado FROM audit.ejecucion ORDER BY ejecucion_id""")
    stock = consulta("SELECT * FROM rpt.stock_actual ORDER BY producto_id")
    for nombre,df in {"ventas_anuales":ventas,"controles_calidad":controles,"categorias_historica_actual":categorias,
                      "ejecuciones":ejecuciones,"stock_cobertura":stock}.items():
        df.to_csv(TABLAS / f"{nombre}.csv", index=False, encoding="utf-8-sig")
    metricas = consulta(f"""
      SELECT
       (SELECT COUNT(*) FROM dw.dim_fecha) dim_fecha,
       (SELECT COUNT(*) FROM dw.dim_cliente) dim_cliente,
       (SELECT COUNT(*) FROM dw.dim_producto) dim_producto,
       (SELECT COUNT(*) FROM dw.dim_proveedor) dim_proveedor,
       (SELECT COUNT(*) FROM dw.dim_empleado) dim_empleado,
       (SELECT COUNT(*) FROM dw.dim_ciudad) dim_ciudad,
       (SELECT COUNT(*) FROM dw.fact_venta) fact_venta,
       (SELECT COUNT(*) FROM dw.fact_venta WHERE factura_id IN({SIMULADAS})) fact_venta_simuladas,
       (SELECT COUNT(*) FROM dw.fact_compra) fact_compra,
       (SELECT COUNT(*) FROM dw.fact_stock_diario) fact_stock_diario,
       (SELECT COUNT(*) FROM (SELECT cliente_id FROM dw.dim_cliente GROUP BY cliente_id HAVING COUNT(*)>1)x) clientes_con_historia,
       (SELECT COUNT(*) FROM (SELECT producto_id FROM dw.dim_producto GROUP BY producto_id HAVING COUNT(*)>1)x) productos_con_historia,
       (SELECT COUNT(*) FROM audit.controles WHERE estado='OK') controles_ok,
       (SELECT COUNT(*) FROM audit.controles WHERE estado='FALLA') controles_falla
    """).iloc[0].to_dict()
    # Demostración SCD2: los hechos de los clientes cambiados apuntan a su versión original
    # (categoría histórica) salvo las líneas creadas después del cambio.
    demo = consulta("""WITH cambiados AS(SELECT cliente_id FROM dw.dim_cliente GROUP BY cliente_id HAVING COUNT(*)>1)
      SELECT SUM(CASE WHEN c.valido_desde>'19000101' THEN 1 ELSE 0 END) lineas_version_nueva,
       SUM(CASE WHEN c.valido_desde>'19000101' THEN f.importe_total ELSE 0 END) importe_version_nueva,
       SUM(CASE WHEN c.valido_desde='19000101' THEN 1 ELSE 0 END) lineas_version_original,
       SUM(CASE WHEN c.valido_desde='19000101' THEN f.importe_total ELSE 0 END) importe_version_original
      FROM dw.fact_venta f JOIN dw.dim_cliente c ON c.cliente_key=f.cliente_key JOIN cambiados x ON x.cliente_id=c.cliente_id""").iloc[0]
    atrib = consulta("""WITH h AS(SELECT categoria_historica categoria,SUM(importe_total) ventas FROM rpt.ventas GROUP BY categoria_historica),
      a AS(SELECT categoria_actual categoria,SUM(importe_total) ventas FROM rpt.ventas GROUP BY categoria_actual)
      SELECT SUM(ABS(COALESCE(h.ventas,0)-COALESCE(a.ventas,0)))/2 diferencia_reasignada FROM h FULL JOIN a ON a.categoria=h.categoria""").iloc[0,0]
    metricas["scd2_demo"] = {
        "clientes_cambiados_por_simulacion": int(metricas["clientes_con_historia"]),
        "lineas_con_version_original": int(demo.lineas_version_original),
        "importe_con_version_original": float(demo.importe_version_original),
        "lineas_con_version_nueva": int(demo.lineas_version_nueva),
        "importe_con_version_nueva": float(demo.importe_version_nueva),
        "ventas_reasignadas_entre_categorias": float(atrib),
    }
    con_cobertura = stock.dropna(subset=["dias_cobertura"])
    metricas["stock"] = {
        "fecha_referencia": str(stock.fecha_referencia.max()),
        "productos": int(len(stock)),
        "productos_con_ventas_365d": int(len(con_cobertura)),
        "mediana_dias_cobertura": float(con_cobertura.dias_cobertura.astype(float).median()),
        "mediana_rotacion_aproximada": float(con_cobertura.rotacion_aproximada.astype(float).median()),
        "productos_cobertura_hasta_90_dias": int((con_cobertura.dias_cobertura.astype(float) <= 90).sum()),
        "productos_sobre_stock_objetivo": int((stock.cantidad_disponible > stock.stock_objetivo).sum()),
    }
    resumen_tiempos = TABLAS / "tiempos_carga_resumen.csv"
    tiempos = pd.read_csv(resumen_tiempos, encoding="utf-8-sig") if resumen_tiempos.exists() else None
    if tiempos is not None:
        metricas["tiempos_mediana_ms"] = dict(zip(tiempos.escenario, tiempos.mediana_ms.astype(float)))
    (RAIZ / "reports" / "metricas.json").write_text(json.dumps(metricas,ensure_ascii=False,indent=2,default=str)+"\n",encoding="utf-8")

    orig = ventas[ventas.origen == "WWI original"].copy()
    orig["etiqueta"] = [f"{a}\n({m} meses)" if m < 12 else str(a) for a, m in zip(orig.anio, orig.meses_con_ventas)]
    orig["millones"] = orig.ventas.astype(float) / 1e6
    ax = orig.plot.bar(x="etiqueta", y="millones", legend=False, color="#2563eb", rot=0,
                       title="Ventas por año del respaldo WWI (sin las 15 líneas simuladas)")
    ax.set_xlabel(""); plt.ylabel("millones, importe con impuestos"); guardar_figura("01_ventas_por_anio.png")
    por_cat = pd.DataFrame({
        "histórica (versión SCD2 del hecho)": categorias.groupby("categoria_historica").ventas.sum(),
        "actual (versión vigente hoy)": categorias.groupby("categoria_actual").ventas.sum(),
    }).fillna(0).astype(float).div(1e6).sort_values("histórica (versión SCD2 del hecho)")
    por_cat.plot.barh(color=["#7c3aed", "#f59e0b"], figsize=(8, 4),
                      title="Demostración SCD2: misma venta, atribuida por categoría histórica o actual")
    plt.xlabel("millones; la diferencia son los 50 clientes que cambió la simulación"); plt.ylabel("")
    guardar_figura("02_scd2_historica_vs_actual.png")
    if tiempos is not None:
        nombres = {"completa": "Completa", "incremental_sin_cambios": "Incremental sin cambios",
                   "incremental_dia_tipico": "Incremental de un día típico"}
        t = tiempos.iloc[::-1]
        fig, ax = plt.subplots(figsize=(8, 3.2))
        ax.barh([nombres[e] for e in t.escenario], t.mediana_ms, color="#059669",
                xerr=[t.mediana_ms - t.min_ms, t.max_ms - t.mediana_ms], capsize=4)
        for y, (_, r) in enumerate(t.iterrows()):
            ax.text(r.max_ms, y, f"  {r.mediana_ms:,.0f} ms · {int(r.filas_venta):,} líneas de venta".replace(",", "."), va="center")
        ax.set_xlabel(f"milisegundos (mediana de {int(t.repeticiones.max())} repeticiones; barra = mínimo–máximo)")
        ax.set_title("Duración de etl.sp_cargar por escenario")
        ax.set_xlim(0, t.max_ms.max() * 1.6)
        guardar_figura("03_tiempos_carga.png")
    print(json.dumps(metricas,ensure_ascii=False,indent=2,default=str))


if __name__ == "__main__": main()
