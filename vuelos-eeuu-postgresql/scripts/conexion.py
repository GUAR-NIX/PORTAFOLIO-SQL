"""Conexión a la base `vuelos` del contenedor de docker-compose.

Los valores por defecto son los del contenedor local (puerto ligado a
127.0.0.1); se pueden cambiar con las variables PGHOST, PGPORT, PGUSER,
PGPASSWORD y PGDATABASE.
"""
from __future__ import annotations

import os

import psycopg

PARAMETROS = {
    "host": os.environ.get("PGHOST", "127.0.0.1"),
    "port": int(os.environ.get("PGPORT", "55432")),
    "user": os.environ.get("PGUSER", "analista"),
    "password": os.environ.get("PGPASSWORD", "analista_local"),
    "dbname": os.environ.get("PGDATABASE", "vuelos"),
}


def conectar(**extra) -> psycopg.Connection:
    return psycopg.connect(**PARAMETROS, connect_timeout=5, **extra)
