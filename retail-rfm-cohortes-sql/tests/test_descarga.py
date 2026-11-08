"""Pruebas sin base de datos: normalización de texto y formato de las cifras de control."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from descargar_datos import COLUMNAS, texto

RAIZ = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("entrada, esperado", [
    (None, ""),
    (float("nan"), ""),
    ("  WHITE HANGING HEART \n", "WHITE HANGING HEART"),
    ("linea\r\ncon salto", "linea  con salto"),
    (12, "12"),
])
def test_texto_normaliza(entrada, esperado):
    assert texto(entrada) == esperado


def test_columnas_coinciden_con_staging():
    ddl = (RAIZ / "sql" / "02_staging.sql").read_text(encoding="utf-8")
    bloque = ddl.split("CREATE TABLE stg.factura_linea (")[1].split(") WITH")[0]
    columnas_sql = [linea.split()[0] for linea in bloque.strip().splitlines() if linea.strip()]
    assert columnas_sql == COLUMNAS


def test_cifras_control_tienen_las_dos_hojas():
    ruta = RAIZ / "data" / "cifras_control.json"
    if not ruta.exists():
        pytest.skip("Ejecuta primero scripts/descargar_datos.py")
    control = json.loads(ruta.read_text(encoding="utf-8"))
    assert set(control["hojas"]) == {"Year 2009-2010", "Year 2010-2011"}
    assert control["hojas"]["Year 2009-2010"]["filas"] == 525_461
    assert control["hojas"]["Year 2010-2011"]["filas"] == 541_910
