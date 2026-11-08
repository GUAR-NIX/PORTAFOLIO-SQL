"""El README es el que genera scripts/generar_readme.py y sus cifras clave cuadran con reports/."""
from __future__ import annotations

import json

import pandas as pd
import pytest

import generar_readme
from formato import num, pct
from conftest import RAIZ


def test_readme_coincide_con_el_generador(readme):
    assert readme == generar_readme.render(), "Ejecuta scripts/generar_readme.py"


def test_total_de_vuelos_igual_a_las_cifras_de_control(readme, cifras_csv, resultados):
    total = sum(m["filas"] for m in cifras_csv["meses"].values())
    assert total == resultados["datos"]["filas_copiadas"]
    assert f"**Datos:** {num(total)} vuelos" in readme


def test_hecho_mas_cuarentena_cuadra(resultados, tabla):
    d = resultados["datos"]
    assert d["filas_hecho"] + d["filas_cuarentena"] == d["filas_copiadas"]
    rec = tabla("reconciliacion")
    assert (rec["diferencia"] == 0).all()
    assert rec["filas_hecho"].sum() == d["filas_hecho"]


def test_kpi_de_puntualidad_recalculado_desde_la_serie_diaria(readme, tabla):
    kpi = tabla("kpi_general").set_index("metrica")["valor"]
    diaria = tabla("serie_diaria")
    puntuales = (diaria["programados"] * diaria["pct_puntuales"] / 100).sum()
    assert 100 * puntuales / diaria["programados"].sum() == pytest.approx(kpi["pct_puntuales"], abs=0.01)
    assert diaria["programados"].sum() == kpi["vuelos_programados"]
    assert f"**{pct(kpi['pct_puntuales'], 2)}**" in readme


def test_ranking_de_aerolineas(readme, tabla):
    aer = tabla("ranking_aerolineas")
    assert aer["programados"].sum() == tabla("kpi_general").set_index("metrica")["valor"]["vuelos_programados"]
    assert list(aer["rango_puntualidad"]) == sorted(aer["rango_puntualidad"])
    assert aer["pct_puntuales"].is_monotonic_decreasing
    mejor = aer.iloc[0]
    assert f"la más puntual es {mejor['nombre']} ({mejor['aerolinea']}, {pct(mejor['pct_puntuales'])})" in readme


def test_causas_suman_100(tabla):
    causas = tabla("causas_mes").drop_duplicates("causa")["pct_del_anio"]
    assert causas.sum() == pytest.approx(100, abs=0.05)


def test_cadena_en_readme(readme, resultados):
    c = resultados["cadenas"]
    assert f"el **{pct(c['pct_propagan'])}** se propaga" in readme
    assert c["raices_que_propagan"] == pytest.approx(c["raices"] * c["pct_propagan"] / 100, rel=1e-3)


def test_rendimiento_despues_mejor_que_antes(resultados):
    rend = pd.DataFrame(resultados["rendimiento"])
    for exp in ["P1", "P2", "P4", "P5", "P6"]:
        g = rend[rend["experimento"] == exp]
        antes = g[g["rol"] == "Antes"].iloc[0]
        for _, despues in g[g["rol"] == "Después"].iterrows():
            assert despues["ms_mediana"] < antes["ms_mediana"], (exp, despues["variante"])
            assert despues["bloques"] < antes["bloques"], (exp, despues["variante"])
    # Todas las variantes de un experimento devuelven el mismo número de filas
    assert (rend.groupby("experimento")["filas"].nunique() == 1).all()


def test_mediana_recalculada_desde_las_corridas(resultados, tabla):
    corridas = tabla("rendimiento_corridas")
    corridas = corridas[corridas["corrida"] > 0]
    mediana = corridas.groupby(["experimento", "variante"])["ms_ejecucion"].median()
    for r in resultados["rendimiento"]:
        assert mediana[(r["experimento"], r["variante"])] == pytest.approx(r["ms_mediana"], abs=0.001)
    assert (corridas.groupby(["experimento", "variante"]).size() == 7).all()


def test_brin_mucho_mas_pequeno_que_btree(tabla):
    idx = tabla("indices_lab").set_index("indice")
    assert idx.loc["lab_brin_fecha_128", "bytes"] * 100 < idx.loc["lab_btree_fecha", "bytes"]


def test_poda_lee_una_particion(resultados):
    p1 = {r["variante"]: r for r in resultados["rendimiento"] if r["experimento"] == "P1"}
    assert p1["Particionada, filtro por rango"]["tablas_leidas"] == 1
    assert p1["Particionada, filtro con función"]["tablas_leidas"] == resultados["datos"]["particiones"]


def test_figuras_existen():
    figuras = sorted(p.name for p in (RAIZ / "reports" / "figures").glob("*.png"))
    assert len(figuras) == 9
    readme = (RAIZ / "README.md").read_text(encoding="utf-8")
    for f in figuras:
        assert f"reports/figures/{f}" in readme


def test_sin_rutas_personales():
    usuario = "gu" + "arn"  # armado por partes para que este archivo no se detecte a sí mismo
    patrones = [f"Users{sep}{usuario}" for sep in ("\\", "/")]
    for ruta in RAIZ.rglob("*"):
        if any(p in ruta.parts for p in (".venv", "raw", "__pycache__", ".pytest_cache")):
            continue
        if ruta.is_file() and ruta.suffix in {".md", ".py", ".sql", ".csv", ".json", ".txt", ".yml", ".ini"}:
            texto = ruta.read_text(encoding="utf-8", errors="ignore")
            assert not any(p in texto for p in patrones), ruta
