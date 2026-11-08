"""
Pruebas del pipeline contra la base RetailAnalitica ya cargada
(ejecuta antes sql/00_EJECUTAR_TODO.sql). Si no hay SQL Server, se omiten.

    .venv\\Scripts\\python -m pytest -q
"""
from __future__ import annotations

import json
from pathlib import Path

import pyodbc
import pytest

from conexion import conectar, consultar

RAIZ = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def cn():
    try:
        conexion = conectar()
    except pyodbc.Error as e:  # pragma: no cover - depende del entorno
        pytest.skip(f"SQL Server no disponible: {e}")
    yield conexion
    conexion.close()


def test_controles_de_calidad_todos_ok(cn):
    df = consultar("EXEC qa.sp_validar_calidad @lanzar_error = 0;", cn)
    assert len(df) == 27
    alertas = df[df["estado"] != "OK"]
    assert alertas.empty, alertas[["orden", "control", "valor"]].to_string()


def test_control_detecta_un_importe_alterado():
    """Prueba negativa: si alguien altera un hecho, la reconciliación lo detecta (y se revierte)."""
    try:
        cn = conectar(autocommit=False)
    except pyodbc.Error as e:  # pragma: no cover
        pytest.skip(f"SQL Server no disponible: {e}")
    try:
        cur = cn.cursor()
        cur.execute("UPDATE TOP (1) dw.fact_linea SET importe = importe + 1 WHERE es_devolucion = 0;")
        cur.execute("EXEC qa.sp_validar_calidad @lanzar_error = 0;")
        filas = {r.orden: r.estado for r in cur.fetchall()}
        assert filas[8] == "ALERTA"          # limpio válido − hecho
        with pytest.raises(pyodbc.Error, match="ALERTA"):
            cur.execute("EXEC qa.sp_validar_calidad;")
            while cur.nextset():
                pass
    finally:
        cn.rollback()
        cn.close()


def test_reconciliacion_independiente_contra_json(cn):
    """Las cifras de control salen del Excel vía Python; aquí se comparan con el modelo + excluidas."""
    control = json.loads((RAIZ / "data" / "cifras_control.json").read_text(encoding="utf-8"))
    filas_fuente = sum(h["filas"] for h in control["hojas"].values())
    importe_fuente = sum(float(h["importe_total"]) for h in control["hojas"].values())
    df = consultar("SELECT COUNT_BIG(*) AS filas, SUM(importe) AS importe FROM limpio.factura_linea", cn)
    assert int(df.at[0, "filas"]) == filas_fuente == 1_067_371
    assert float(df.at[0, "importe"]) == pytest.approx(importe_fuente, abs=0.01)


def test_rfm_puntajes_y_segmentos(cn):
    df = consultar("SELECT r, f, m, segmento, recencia_dias, frecuencia FROM mart.cliente_rfm", cn)
    for col in ("r", "f", "m"):
        tamanos = df[col].value_counts()
        assert sorted(tamanos.index) == [1, 2, 3, 4, 5]
        assert tamanos.max() - tamanos.min() <= 1          # propiedad de NTILE
    # R = 5 debe ser más reciente que R = 1
    medias = df.groupby("r")["recencia_dias"].mean()
    assert medias[5] < medias[1]
    assert df["segmento"].notna().all() and df["segmento"].nunique() == 10


def test_matriz_de_retencion(cn):
    df = consultar("EXEC etl.sp_matriz_retencion;", cn)
    assert list(df.columns[:3]) == ["cohorte", "tamano_cohorte", "M0"]
    assert (df["M0"] == 100).all()
    assert len(df) == 25                                     # dic-2009 a dic-2011
    # Triángulo: la última cohorte solo tiene el mes 0
    assert df.iloc[-1, 3:].isna().all()


def test_canasta_metricas_coherentes(cn):
    df = consultar("SELECT soporte, confianza_a_b, confianza_b_a, lift, facturas_ab, facturas_a, facturas_b, "
                   "total_facturas FROM mart.canasta_par", cn)
    assert len(df) > 0
    recalculado = (df["facturas_ab"] / df["total_facturas"]) / (
        (df["facturas_a"] / df["total_facturas"]) * (df["facturas_b"] / df["total_facturas"]))
    assert ((recalculado - df["lift"].astype(float)).abs() < 0.001).all()
    assert (df["confianza_a_b"] <= 1).all() and (df["confianza_b_a"] <= 1).all()


@pytest.mark.parametrize("vista", [
    "rpt.dim_fecha", "rpt.dim_pais", "rpt.dim_producto", "rpt.dim_cliente", "rpt.fact_ventas",
    "rpt.kpi_mensual", "rpt.rfm_cliente", "rpt.rfm_segmentos", "rpt.cohorte_retencion",
    "rpt.devoluciones_producto", "rpt.devoluciones_pais", "rpt.devoluciones_tiempo", "rpt.canasta_pares",
])
def test_vistas_power_bi_responden(cn, vista):
    df = consultar(f"SELECT TOP (5) * FROM {vista}", cn)
    assert len(df) > 0


def test_tablas_exportadas_respaldan_las_cifras_del_readme():
    """Sin SQL Server: los CSV de reports/tablas/ (scripts/exportar_hallazgos.py) contienen las cifras citadas."""
    import pandas as pd

    tablas = RAIZ / "reports" / "tablas"
    ret = pd.read_csv(tablas / "retencion_promedio.csv").set_index("mes_desde")["retencion_promedio"]
    assert [round(ret[m] * 100, 1) for m in (1, 6, 12)] == [20.7, 17.3, 17.9]

    pareto = pd.read_csv(tablas / "pareto_clientes.csv").iloc[0]
    assert round(pareto["pct_ingreso_top20"] * 100, 1) == 76.8
    assert pareto["clientes_top1"] == 58 and round(pareto["pct_ingreso_top1"] * 100, 1) == 31.1

    mercados = pd.read_csv(tablas / "mercados_top.csv").set_index("pais")
    assert round(mercados.loc["Irlanda", "pct_ventas"] * 100, 1) == 3.2 and mercados.loc["Irlanda", "clientes"] == 3

    paises = pd.read_csv(tablas / "devoluciones_por_pais.csv").set_index("pais")
    assert round(paises.loc["España", "tasa_devolucion_importe"] * 100, 1) == 13.3

    plazo = pd.read_csv(tablas / "devoluciones_plazo.csv")
    assert round(plazo.iloc[0]["pct_importe"] * 100) == 64
