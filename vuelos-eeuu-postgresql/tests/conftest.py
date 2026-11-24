"""Fixtures comunes. Las pruebas marcadas `db` se omiten si PostgreSQL no responde."""
from __future__ import annotations

import json
from pathlib import Path

import pandas as pd
import psycopg
import pytest

from conexion import conectar

RAIZ = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="session")
def con():
    try:
        conexion = conectar(autocommit=False)
    except psycopg.OperationalError as error:
        pytest.skip(f"PostgreSQL no disponible: {error}")
    yield conexion
    conexion.rollback()
    conexion.close()


@pytest.fixture(scope="session")
def resultados() -> dict:
    return json.loads((RAIZ / "reports" / "resultados.json").read_text(encoding="utf-8"))


@pytest.fixture(scope="session")
def cifras_csv() -> dict:
    """Cifras de control calculadas en Python directamente sobre los CSV de BTS."""
    return json.loads((RAIZ / "data" / "cifras_control.json").read_text(encoding="utf-8"))


@pytest.fixture(scope="session")
def tabla():
    def leer(nombre: str) -> pd.DataFrame:
        return pd.read_csv(RAIZ / "reports" / "tablas" / f"{nombre}.csv")
    return leer


@pytest.fixture(scope="session")
def readme() -> str:
    return (RAIZ / "README.es.md").read_text(encoding="utf-8")
