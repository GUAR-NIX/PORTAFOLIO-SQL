"""El README debe coincidir con reports/ y data/ (no puede quedar con cifras de otra corrida)."""

from __future__ import annotations

import json
import re
from pathlib import Path

import pandas as pd

from generar_readme import README, dec, miles, renderizar

RAIZ = Path(__file__).resolve().parents[1]
TABLAS = RAIZ / "reports" / "tablas"
TEXTO = README.read_text(encoding="utf-8")


def test_readme_es_exactamente_el_generado_desde_reports() -> None:
    assert TEXTO == renderizar(), "README.md desactualizado: ejecuta python scripts/generar_readme.py"


def test_cifras_de_datos_recalculadas_aparecen_en_el_readme() -> None:
    c = json.loads((RAIZ / "data" / "cifras_control.json").read_text(encoding="utf-8"))
    for clave in ("filas_totales_brutas", "filas_validas", "filas_excluidas"):
        assert miles(c[clave]) in TEXTO, clave
    # El TSV del README es el real
    assert f"{miles((RAIZ / 'data' / 'raw' / 'citibike_2024T1.tsv').stat().st_size / 1024**2)} MB" in TEXTO \
        if (RAIZ / "data" / "raw" / "citibike_2024T1.tsv").exists() else True


def test_cifras_clave_de_experimentos_aparecen_en_el_readme() -> None:
    exp = pd.read_csv(TABLAS / "experimentos_tuning.csv").set_index("codigo_experimento")
    # Lecturas lógicas de todas las variantes en la tabla principal
    for cod, fila in exp.iterrows():
        assert f"| {miles(fila['lecturas_logicas'])} |" in TEXTO, cod
    # Rango de reducción de lecturas de las variantes DESPUÉS
    despues = exp[exp["rol_comparacion"] == "DESPUES"]
    assert f"**{dec(despues['reduccion_lecturas_pct'].min(), 2)} %**" in TEXTO
    assert f"**{dec(despues['reduccion_lecturas_pct'].max(), 2)} %**" in TEXTO


def test_analitica_y_controles_coinciden() -> None:
    mes = pd.read_csv(TABLAS / "kpi_mensual.csv")
    assert miles(mes["total_viajes"].sum()) in TEXTO
    pct_ebike = mes["viajes_electrica"].sum() / mes["total_viajes"].sum() * 100
    assert f"{dec(pct_ebike, 1)} %" in TEXTO
    qa = pd.read_csv(TABLAS / "controles_calidad.csv")
    assert (qa["estado"] == "OK").all()
    assert f"{len(qa)}/{len(qa)} controles OK" in TEXTO
    est = pd.read_csv(TABLAS / "desbalance_estaciones.csv")
    peor = est.nsmallest(1, "balance_neto_manana_6_10h").iloc[0]
    assert peor["estacion_nombre"] in TEXTO


def test_readme_sin_restos_de_la_version_anterior() -> None:
    for viejo in ("JC-2024", "1.052.451", "1.044.446", "9.374x", "100 % reproducible", "````carousel",
                  "test_sql_tuning.py", "generar_notebooks.py`  ", "05_laboratorio_indices", "06_experimentos_antes",
                  "02_cargar_staging", "03_limpieza_y_calidad", "07_vistas_analiticas_y_query_store", "114,5 MB"):
        assert viejo not in TEXTO, viejo
    assert "\\n" not in TEXTO.split("```mermaid")[1].split("```")[0]


def test_enlaces_locales_del_readme_existen() -> None:
    for destino in re.findall(r"\]\(((?!https?://)[^)#]+)\)", TEXTO):
        assert (RAIZ / destino).exists(), destino
