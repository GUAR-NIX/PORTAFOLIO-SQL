"""Ejecuta el proyecto de punta a punta.

    python scripts/ejecutar_todo.py                 # todo, 12 meses
    python scripts/ejecutar_todo.py --meses 1-6     # solo enero-junio
    python scripts/ejecutar_todo.py --desde 07      # retoma desde sql/07_*.sql

Pasos: levanta PostgreSQL (docker compose), descarga los datos (reanudable),
ejecuta sql/01..11 con psql dentro del contenedor, exporta reports/ y genera
las figuras y el README. La carga mensual es reanudable: si la PC se apaga,
volver a correr el script salta los meses que ya quedaron en estado 'OK'.
"""
from __future__ import annotations

import argparse
import csv
import subprocess
import sys
import time
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
PY = sys.executable
PSQL = ["docker", "compose", "exec", "-T", "db", "psql", "-X", "-q",
        "-U", "analista", "-d", "vuelos", "-v", "ON_ERROR_STOP=1"]


def correr(cmd: list[str], nombre: str, tiempos: list[tuple[str, float]]) -> None:
    print(f"\n=== {nombre}", flush=True)
    t0 = time.perf_counter()
    subprocess.run(cmd, cwd=RAIZ, check=True)
    tiempos.append((nombre, round(time.perf_counter() - t0, 1)))
    print(f"    {tiempos[-1][1]} s", flush=True)


def main() -> int:
    p = argparse.ArgumentParser(description="Ejecuta todo el proyecto")
    p.add_argument("--meses", default="1-12", help="rango de meses de 2024, p. ej. 1-6")
    p.add_argument("--desde", default="00", help="número del primer script SQL a ejecutar (00 = todo)")
    p.add_argument("--sin-descarga", action="store_true")
    args = p.parse_args()
    desde_mes, hasta_mes = (int(x) for x in args.meses.split("-"))
    tiempos: list[tuple[str, float]] = []

    correr(["docker", "compose", "up", "-d", "--build", "--wait"], "docker compose up", tiempos)
    if not args.sin_descarga and args.desde == "00":
        correr([PY, "scripts/descargar_datos.py", "--meses", args.meses], "descarga", tiempos)

    for script in sorted((RAIZ / "sql").glob("[0-9][0-9]_*.sql")):
        if script.name[:2] < args.desde:
            continue
        correr(PSQL + ["-f", f"/sql/{script.name}"], script.name, tiempos)
        if script.name.startswith("02_"):
            correr(PSQL + ["-c", f"CALL control.cargar_rango(2024, {desde_mes}, {hasta_mes})"],
                   "carga mensual con COPY", tiempos)

    # Solo una corrida completa reemplaza los tiempos que cita el README
    if args.desde == "00":
        with open(RAIZ / "reports" / "tablas" / "tiempos_pipeline.csv", "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["paso", "segundos"])
            w.writerows(tiempos)

    for paso in ("exportar_reportes.py", "generar_graficos.py", "generar_readme.py"):
        correr([PY, f"scripts/{paso}"], paso, tiempos)
    print(f"\nListo en {sum(s for _, s in tiempos) / 60:.1f} min")
    return 0


if __name__ == "__main__":
    sys.exit(main())
