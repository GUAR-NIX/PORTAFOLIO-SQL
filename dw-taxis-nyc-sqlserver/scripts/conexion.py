"""Conexión a SQL Server Express local (autenticación de Windows, sin credenciales)."""
from __future__ import annotations

import os
import warnings

import pandas as pd
import pyodbc

SERVIDOR = os.environ.get("TAXIS_SQL_SERVIDOR", r"localhost\SQLEXPRESS")
BASE = os.environ.get("TAXIS_SQL_BASE", "TaxisNYC")


def conectar(autocommit: bool = True) -> pyodbc.Connection:
    driver = next((d for d in ("ODBC Driver 18 for SQL Server", "ODBC Driver 17 for SQL Server")
                   if d in pyodbc.drivers()), "SQL Server")
    cadena = (f"DRIVER={{{driver}}};SERVER={SERVIDOR};DATABASE={BASE};"
              "Trusted_Connection=yes;TrustServerCertificate=yes;")
    return pyodbc.connect(cadena, autocommit=autocommit)


def consultar(sql: str, conexion: pyodbc.Connection | None = None) -> pd.DataFrame:
    propia = conexion is None
    cn = conexion or conectar()
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)  # pandas avisa que prefiere SQLAlchemy
            return pd.read_sql(sql, cn)
    finally:
        if propia:
            cn.close()
