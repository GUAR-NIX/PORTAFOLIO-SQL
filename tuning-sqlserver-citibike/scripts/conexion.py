"""Conexión a SQL Server Express local (autenticación integrada de Windows, sin credenciales)."""

from __future__ import annotations

import os
import warnings

import pandas as pd
import pyodbc

SERVIDOR = os.environ.get("CITIBIKE_SQL_SERVIDOR", r"localhost\SQLEXPRESS")
BASE = os.environ.get("CITIBIKE_SQL_BASE", "CitiBikeTuning")


def obtener_driver() -> str:
    """Selecciona el controlador ODBC de SQL Server más reciente instalado."""
    disponibles = pyodbc.drivers()
    for candidato in ("ODBC Driver 18 for SQL Server", "ODBC Driver 17 for SQL Server", "SQL Server"):
        if candidato in disponibles:
            return candidato
    return "SQL Server"


def conectar(autocommit: bool = True, base: str | None = None) -> pyodbc.Connection:
    """Abre una conexión ODBC hacia SQL Server Express local."""
    driver = obtener_driver()
    bd = base or BASE
    cadena = (
        f"DRIVER={{{driver}}};"
        f"SERVER={SERVIDOR};"
        f"DATABASE={bd};"
        "Trusted_Connection=yes;"
        "TrustServerCertificate=yes;"
    )
    return pyodbc.connect(cadena, autocommit=autocommit)


def consultar(sql: str, conexion: pyodbc.Connection | None = None) -> pd.DataFrame:
    """Ejecuta una consulta T-SQL y devuelve el resultado en un DataFrame de pandas."""
    propia = conexion is None
    cn = conexion or conectar()
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            return pd.read_sql(sql, cn)
    finally:
        if propia:
            cn.close()
