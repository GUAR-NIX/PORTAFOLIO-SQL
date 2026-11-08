"""
descargar_datos.py
Descarga UCI Online Retail II desde la fuente oficial, convierte las dos hojas
del Excel a un único CSV listo para BULK INSERT y calcula las cifras de control
de la fuente (filas, cantidad e importe por hoja), que luego se reconcilian en SQL.

Uso (desde la carpeta del proyecto):
    .venv\\Scripts\\python scripts\\descargar_datos.py
"""
from __future__ import annotations

import csv
import hashlib
import json
import urllib.request
import zipfile
from decimal import Decimal
from pathlib import Path

import pandas as pd

URL_FUENTE = "https://archive.ics.uci.edu/static/public/502/online+retail+ii.zip"
RAIZ = Path(__file__).resolve().parents[1]
CARPETA_RAW = RAIZ / "data" / "raw"
ZIP_DESTINO = CARPETA_RAW / "online_retail_ii.zip"
CSV_DESTINO = CARPETA_RAW / "online_retail_ii.csv"
CONTROL_DESTINO = RAIZ / "data" / "cifras_control.json"

# Columnas del CSV en el mismo orden que stg.factura_linea (sin la columna de identidad)
COLUMNAS = ["hoja", "fila_origen", "invoice", "stock_code", "description", "quantity",
            "invoice_date", "price", "customer_id", "country"]


def descargar(url: str, destino: Path) -> None:
    # is_zipfile busca el índice que va al final del ZIP: un archivo cortado no lo tiene y se vuelve a bajar.
    if zipfile.is_zipfile(destino):
        print(f"[OMITIDO] {destino.name} ya existe ({destino.stat().st_size / 1e6:.1f} MB)")
        return
    print(f"Descargando {url} ...")
    parcial = destino.with_suffix(destino.suffix + ".part")
    urllib.request.urlretrieve(url, parcial)
    if not zipfile.is_zipfile(parcial):
        raise RuntimeError(f"La descarga de {destino.name} no es un ZIP completo; vuelve a ejecutar el script")
    parcial.replace(destino)
    print(f"  {destino.stat().st_size / 1e6:.1f} MB")


def extraer_excel(zip_path: Path) -> Path:
    with zipfile.ZipFile(zip_path) as z:
        nombre = next(n for n in z.namelist() if n.lower().endswith(".xlsx"))
        destino = CARPETA_RAW / Path(nombre).name
        if not destino.exists():
            parcial = destino.with_suffix(destino.suffix + ".part")
            with z.open(nombre) as origen, open(parcial, "wb") as salida:
                salida.write(origen.read())
            parcial.replace(destino)
    return destino


def texto(valor) -> str:
    """Normaliza a texto plano: sin saltos de línea y vacío para nulos."""
    if pd.isna(valor):
        return ""
    return str(valor).replace("\r", " ").replace("\n", " ").strip()


def convertir_a_csv(excel: Path) -> dict:
    """Lee las dos hojas como texto (sin que pandas reinterprete códigos) y escribe un CSV UTF-8."""
    hojas = pd.read_excel(excel, sheet_name=None, dtype=str, engine="openpyxl")
    control: dict = {"fuente": URL_FUENTE, "hojas": {}}
    with open(CSV_DESTINO, "w", encoding="utf-8", newline="") as f:
        escritor = csv.writer(f, quoting=csv.QUOTE_MINIMAL, lineterminator="\n")
        escritor.writerow(COLUMNAS)
        for nombre_hoja, df in hojas.items():
            df.columns = [c.strip() for c in df.columns]
            filas = 0
            cantidad = 0
            importe = Decimal("0")
            for i, r in enumerate(df.itertuples(index=False), start=2):  # fila 1 = cabecera
                cliente = texto(r[6])
                if cliente.endswith(".0"):
                    cliente = cliente[:-2]
                fecha = pd.Timestamp(r[4]).strftime("%Y-%m-%d %H:%M:%S")
                escritor.writerow([nombre_hoja, i, texto(r[0]), texto(r[1]), texto(r[2]),
                                   texto(r[3]), fecha, texto(r[5]), cliente, texto(r[7])])
                filas += 1
                cantidad += int(r[3])
                importe += Decimal(texto(r[3])) * Decimal(texto(r[5]))
            control["hojas"][nombre_hoja] = {
                "filas": filas,
                "cantidad_total": cantidad,
                "importe_total": str(importe.quantize(Decimal("0.001"))),
            }
            print(f"  hoja {nombre_hoja}: {filas:,} filas")
    return control


def sha256(ruta: Path) -> str:
    h = hashlib.sha256()
    with open(ruta, "rb") as f:
        for bloque in iter(lambda: f.read(1 << 20), b""):
            h.update(bloque)
    return h.hexdigest()


def main() -> None:
    CARPETA_RAW.mkdir(parents=True, exist_ok=True)
    descargar(URL_FUENTE, ZIP_DESTINO)
    excel = extraer_excel(ZIP_DESTINO)
    print(f"Convirtiendo {excel.name} a CSV (tarda ~2 min)...")
    control = convertir_a_csv(excel)
    control["sha256_excel"] = sha256(excel)
    CONTROL_DESTINO.write_text(json.dumps(control, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"CSV: {CSV_DESTINO} ({CSV_DESTINO.stat().st_size / 1e6:.1f} MB)")
    print(f"Cifras de control: {CONTROL_DESTINO}")


if __name__ == "__main__":
    main()
