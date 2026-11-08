"""Ejecuta un script T-SQL con sqlcmd pasando la ruta del proyecto en la variable $(Proyecto).

Uso:
  python scripts/ejecutar_sql.py                       # corre sql/00_EJECUTAR_TODO.sql
  python scripts/ejecutar_sql.py otro.sql --log x.log

sqlcmd necesita la ruta entre comillas dobles (contiene ':'); desde PowerShell eso exige
`--%`, así que este envoltorio arma la línea de comandos tal cual la espera sqlcmd.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
SERVIDOR = os.environ.get("CITIBIKE_SQL_SERVIDOR", r"localhost\SQLEXPRESS")


def ejecutar(script: Path, log: Path | None = None) -> int:
    comando = (
        f'sqlcmd -S "{SERVIDOR}" -E -C -I -b -f 65001 -W '
        f'-v Proyecto="{RAIZ}" -i "{script.resolve()}"'
    )
    if log is not None:
        comando += f' -o "{log.resolve()}"'
    inicio = time.perf_counter()
    # En Windows una cadena se pasa tal cual a CreateProcess (sin re-escapar las comillas)
    resultado = subprocess.run(comando, shell=False)
    print(f"[sqlcmd] {script.name}: código {resultado.returncode} en {time.perf_counter() - inicio:,.0f} s")
    return resultado.returncode


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("script", nargs="?", type=Path, default=RAIZ / "sql" / "00_EJECUTAR_TODO.sql")
    parser.add_argument("--log", type=Path, default=None)
    args = parser.parse_args()
    sys.exit(ejecutar(args.script, args.log))


if __name__ == "__main__":
    main()
