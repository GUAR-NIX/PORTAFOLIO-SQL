"""Descarga reanudable del respaldo oficial WideWorldImporters."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
from urllib.request import Request, urlopen

URL = "https://github.com/microsoft/sql-server-samples/releases/download/wide-world-importers-v1.0/WideWorldImporters-Full.bak"
RAIZ = Path(__file__).resolve().parents[1]
DESTINO = RAIZ / "data" / "raw" / "WideWorldImporters-Full.bak"
METADATOS = RAIZ / "data" / "fuente.json"


def sha256_archivo(ruta: Path, bloque: int = 1024 * 1024) -> str:
    resumen = hashlib.sha256()
    with ruta.open("rb") as archivo:
        for parte in iter(lambda: archivo.read(bloque), b""):
            resumen.update(parte)
    return resumen.hexdigest()


def descargar() -> Path:
    DESTINO.parent.mkdir(parents=True, exist_ok=True)
    if DESTINO.exists() and DESTINO.stat().st_size > 0:
        print(f"Ya existe: {DESTINO} ({DESTINO.stat().st_size / 1024**2:,.1f} MiB)")
        return DESTINO
    parcial = DESTINO.with_suffix(DESTINO.suffix + ".parcial")
    inicio = parcial.stat().st_size if parcial.exists() else 0
    cabeceras = {"Range": f"bytes={inicio}-"} if inicio else {}
    solicitud = Request(URL, headers={**cabeceras, "User-Agent": "sql03-wwi/1.0"})
    with urlopen(solicitud, timeout=120) as respuesta:
        codigo = respuesta.status
        modo = "ab" if inicio and codigo == 206 else "wb"
        if modo == "wb":
            inicio = 0
        total = inicio + int(respuesta.headers.get("Content-Length", 0))
        recibidos = inicio
        with parcial.open(modo) as archivo:
            while bloque := respuesta.read(1024 * 1024):
                archivo.write(bloque)
                recibidos += len(bloque)
                print(f"\r{recibidos / 1024**2:,.1f} / {total / 1024**2:,.1f} MiB", end="", flush=True)
    print()
    parcial.replace(DESTINO)
    METADATOS.write_text(json.dumps({
        "url": URL,
        "licencia": "MIT",
        "archivo": DESTINO.name,
        "bytes": DESTINO.stat().st_size,
        "sha256": sha256_archivo(DESTINO),
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return DESTINO


if __name__ == "__main__":
    print(descargar())
