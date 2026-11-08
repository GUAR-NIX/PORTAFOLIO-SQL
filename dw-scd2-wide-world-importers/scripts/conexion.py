"""Conexión integrada a SQL Server Express, sin credenciales en archivos."""
from __future__ import annotations
import os
import pyodbc


def conectar(base: str = "DW_WWI", autocommit: bool = True):
    servidor = os.getenv("SQL_SERVER", r"localhost\SQLEXPRESS")
    cadena = (
        "DRIVER={ODBC Driver 18 for SQL Server};"
        f"SERVER={servidor};DATABASE={base};Trusted_Connection=yes;"
        "TrustServerCertificate=yes;Encrypt=yes"
    )
    return pyodbc.connect(cadena, autocommit=autocommit)

