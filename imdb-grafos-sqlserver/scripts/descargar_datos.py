"""
descargar_datos.py
Descarga los IMDb Non-Commercial Datasets desde la fuente oficial
(https://datasets.imdbws.com/), los descomprime a TSV listos para BULK INSERT
y calcula las cifras de control de la fuente (filas de datos por archivo).

Es reanudable:
  * la descarga usa archivos .part y la cabecera HTTP Range: si la PC se apaga,
    la siguiente ejecución continúa desde el último byte recibido;
  * un archivo .gz completo (mismo tamaño que el servidor) no se vuelve a bajar;
  * un .tsv ya descomprimido y contado no se vuelve a procesar.

Uso (desde la carpeta del proyecto):
    .venv\\Scripts\\python scripts\\descargar_datos.py
"""
from __future__ import annotations

import gzip
import json
import shutil
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

URL_BASE = "https://datasets.imdbws.com/"
ARCHIVOS = [
    "title.basics.tsv.gz",
    "title.ratings.tsv.gz",
    "title.principals.tsv.gz",
    "title.crew.tsv.gz",
    "name.basics.tsv.gz",
    "title.akas.tsv.gz",
]
RAIZ = Path(__file__).resolve().parents[1]
CARPETA_RAW = RAIZ / "data" / "raw"
CONTROL_DESTINO = RAIZ / "data" / "cifras_control.json"
BLOQUE = 1 << 20  # 1 MB


def tamano_remoto(url: str) -> tuple[int, str]:
    peticion = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(peticion, timeout=60) as r:
        return int(r.headers["Content-Length"]), r.headers.get("Last-Modified", "")


def descargar(nombre: str) -> dict:
    url = URL_BASE + nombre
    destino = CARPETA_RAW / nombre
    parcial = destino.with_suffix(destino.suffix + ".part")
    total, modificado = tamano_remoto(url)

    if destino.exists() and destino.stat().st_size == total:
        print(f"[OMITIDO] {nombre} ya está completo ({total / 1e6:,.1f} MB)")
        return {"bytes_gz": total, "last_modified": modificado}

    for intento in range(1, 6):
        ya = parcial.stat().st_size if parcial.exists() else 0
        if ya > total:  # el servidor publicó una versión nueva: empezar de cero
            parcial.unlink()
            ya = 0
        if ya == total:  # el .part ya está completo: pedir más bytes devolvería HTTP 416
            parcial.replace(destino)
            return {"bytes_gz": total, "last_modified": modificado}
        peticion = urllib.request.Request(url, headers={"Range": f"bytes={ya}-"} if ya else {})
        print(f"Descargando {nombre}: {ya / 1e6:,.1f} de {total / 1e6:,.1f} MB (intento {intento})")
        try:
            with urllib.request.urlopen(peticion, timeout=120) as r, open(parcial, "ab") as f:
                if ya and r.status != 206:  # el servidor ignoró el Range
                    f.seek(0)
                    f.truncate()
                shutil.copyfileobj(r, f, BLOQUE)
            if parcial.stat().st_size == total:
                parcial.replace(destino)
                return {"bytes_gz": total, "last_modified": modificado}
        except OSError as error:
            print(f"  corte de conexión ({error}); se reintenta en 10 s")
            time.sleep(10)
    raise RuntimeError(f"No se pudo completar la descarga de {nombre}")


def descomprimir_y_contar(nombre: str) -> dict:
    """Descomprime el .gz a .tsv y cuenta las filas de datos (sin la cabecera)."""
    gz = CARPETA_RAW / nombre
    tsv = CARPETA_RAW / nombre.removesuffix(".gz")
    marca = tsv.with_suffix(".conteo.json")  # se escribe al final: prueba de que el .tsv está completo
    if tsv.exists() and marca.exists():
        datos = json.loads(marca.read_text(encoding="utf-8"))
        print(f"[OMITIDO] {tsv.name} ya descomprimido ({datos['filas_datos']:,} filas)")
        return datos

    print(f"Descomprimiendo {nombre} ...")
    inicio = time.perf_counter()
    lineas = 0
    with gzip.open(gz, "rb") as origen, open(tsv, "wb") as salida:
        cabecera = origen.readline()
        salida.write(cabecera)
        while bloque := origen.read(16 * BLOQUE):
            lineas += bloque.count(b"\n")
            salida.write(bloque)
    datos = {
        "columnas": cabecera.decode("utf-8").rstrip("\n").split("\t"),
        "filas_datos": lineas,
        "bytes_tsv": tsv.stat().st_size,
    }
    marca.write_text(json.dumps(datos, ensure_ascii=False), encoding="utf-8")
    print(f"  {lineas:,} filas · {datos['bytes_tsv'] / 1e9:.2f} GB · {time.perf_counter() - inicio:.0f} s")
    return datos


def main() -> None:
    CARPETA_RAW.mkdir(parents=True, exist_ok=True)
    control: dict = {
        "fuente": URL_BASE,
        "licencia": "IMDb Non-Commercial Datasets: uso personal y no comercial "
                    "(https://developer.imdb.com/non-commercial-datasets/)",
        "fecha_descarga": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "archivos": {},
    }
    for nombre in ARCHIVOS:
        info = descargar(nombre)
        info.update(descomprimir_y_contar(nombre))
        control["archivos"][nombre.removesuffix(".tsv.gz")] = info
    CONTROL_DESTINO.write_text(json.dumps(control, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Cifras de control: {CONTROL_DESTINO}")


if __name__ == "__main__":
    main()
