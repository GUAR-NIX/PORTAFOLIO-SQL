"""Descarga reanudable de los datos de BTS y cálculo de las cifras de control.

Baja los ZIP mensuales de On-Time Performance 2024 (uno por mes), las tablas de
referencia de aeropuertos y aerolíneas de BTS y la tabla de zonas horarias de
aeropuertos (mwgg/Airports, licencia MIT). Si la PC se apaga a mitad de una
descarga, el archivo `.part` queda en disco y la siguiente corrida continúa
desde ese byte con una petición `Range`.

Las cifras de control (filas, cancelados, desviados, suma de retrasos...) se
calculan aquí, leyendo el CSV dentro del ZIP con Python, sin pasar por
PostgreSQL. Así la base se compara contra una fuente independiente.

Uso:
    python scripts/descargar_datos.py              # 12 meses
    python scripts/descargar_datos.py --meses 1-6  # solo enero-junio
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
DIR_VUELOS = RAIZ / "data" / "raw" / "vuelos"
DIR_REF = RAIZ / "data" / "raw" / "referencia"
ARCHIVO_CONTROL = RAIZ / "data" / "cifras_control.json"

ANIO = 2024
URL_MES = ("https://transtats.bts.gov/PREZIP/"
           "On_Time_Reporting_Carrier_On_Time_Performance_1987_present_{anio}_{mes}.zip")
# BTS publica sus tablas de búsqueda con el nombre "cifrado" en ROT13
# (Y_NVecbeg_VQ = L_AIRPORT_ID, Y_haVdhR_PNeeVRef = L_UNIQUE_CARRIERS).
URL_REFERENCIA = {
    "L_AIRPORT_ID.csv": "https://transtats.bts.gov/Download_Lookup.asp?Y11x72=Y_NVecbeg_VQ",
    "L_UNIQUE_CARRIERS.csv": "https://transtats.bts.gov/Download_Lookup.asp?Y11x72=Y_haVdhR_PNeeVRef",
    "airports_mwgg.json": "https://raw.githubusercontent.com/mwgg/Airports/master/airports.json",
}
BLOQUE = 1 << 20


def _tamano_remoto(url: str, reintentos: int = 5) -> int | None:
    peticion = urllib.request.Request(url, method="HEAD")
    for intento in range(1, reintentos + 1):
        try:
            with urllib.request.urlopen(peticion, timeout=60) as r:
                largo = r.headers.get("Content-Length")
                return int(largo) if largo else None
        except OSError as error:  # corte de red: un solo fallo no debe detener toda la descarga
            print(f"  consulta de tamaño, intento {intento} falló ({error}); reintentando...", flush=True)
            time.sleep(5 * intento)
    raise RuntimeError(f"No se pudo consultar el tamaño de {url}")


def descargar(url: str, destino: Path, reintentos: int = 5) -> Path:
    """Descarga `url` en `destino`, continuando un `.part` si existe."""
    destino.parent.mkdir(parents=True, exist_ok=True)
    total = _tamano_remoto(url, reintentos)
    if destino.exists() and (total is None or destino.stat().st_size == total):
        return destino
    parcial = destino.with_suffix(destino.suffix + ".part")
    for intento in range(1, reintentos + 1):
        ya = parcial.stat().st_size if parcial.exists() else 0
        if total is not None and ya >= total:
            break
        peticion = urllib.request.Request(url)
        if ya:
            peticion.add_header("Range", f"bytes={ya}-")
        try:
            with urllib.request.urlopen(peticion, timeout=120) as r:
                # Si el servidor ignora Range (200 en vez de 206) se empieza de cero.
                modo = "ab" if ya and r.status == 206 else "wb"
                with open(parcial, modo) as f:
                    while bloque := r.read(BLOQUE):
                        f.write(bloque)
            break
        except OSError as error:  # corte de red: se reintenta desde el último byte
            print(f"  intento {intento} falló ({error}); reintentando...", flush=True)
            time.sleep(5 * intento)
    else:
        raise RuntimeError(f"No se pudo descargar {url}")
    if total is not None and parcial.stat().st_size != total:
        raise RuntimeError(f"Tamaño incompleto en {parcial}")
    parcial.replace(destino)
    return destino


def sha256(ruta: Path) -> str:
    h = hashlib.sha256()
    with open(ruta, "rb") as f:
        while bloque := f.read(BLOQUE):
            h.update(bloque)
    return h.hexdigest()


def _num(valor: str) -> float:
    return float(valor) if valor else 0.0


def cifras_de_zip(ruta: Path) -> dict:
    """Cifras de control de un mes, leídas del CSV dentro del ZIP."""
    with zipfile.ZipFile(ruta) as z:
        nombre_csv = next(n for n in z.namelist() if n.lower().endswith(".csv"))
        with z.open(nombre_csv) as crudo:
            lector = csv.DictReader(io.TextIOWrapper(crudo, encoding="utf-8", newline=""))
            c = dict(filas=0, cancelados=0, desviados=0, con_retraso_15=0,
                     suma_retraso_llegada=0.0, suma_retraso_salida=0.0,
                     suma_distancia=0.0, suma_late_aircraft=0.0, sin_matricula=0)
            fechas, aerolineas = set(), set()
            for fila in lector:
                c["filas"] += 1
                c["cancelados"] += _num(fila["Cancelled"]) == 1
                c["desviados"] += _num(fila["Diverted"]) == 1
                c["con_retraso_15"] += _num(fila["ArrDel15"]) == 1
                c["suma_retraso_llegada"] += _num(fila["ArrDelay"])
                c["suma_retraso_salida"] += _num(fila["DepDelay"])
                c["suma_distancia"] += _num(fila["Distance"])
                c["suma_late_aircraft"] += _num(fila["LateAircraftDelay"])
                c["sin_matricula"] += not fila["Tail_Number"].strip()
                fechas.add(fila["FlightDate"])
                aerolineas.add(fila["Reporting_Airline"])
            columnas = len(lector.fieldnames or [])
    for clave in ("suma_retraso_llegada", "suma_retraso_salida", "suma_distancia", "suma_late_aircraft"):
        c[clave] = round(c[clave], 1)
    c.update(fecha_min=min(fechas), fecha_max=max(fechas), dias=len(fechas),
             aerolineas=len(aerolineas), columnas_csv=columnas, archivo_csv=nombre_csv)
    return c


def preparar_zonas_horarias(json_mwgg: Path, salida: Path) -> int:
    """Convierte el JSON de mwgg/Airports en un CSV (IATA, zona horaria, coordenadas)."""
    datos = json.loads(json_mwgg.read_text(encoding="utf-8"))
    filas = {}
    for a in datos.values():
        iata = (a.get("iata") or "").strip().upper()
        if len(iata) == 3 and a.get("tz") and iata not in filas:
            filas[iata] = (iata, a["tz"], a.get("lat"), a.get("lon"), a.get("country", ""))
    with open(salida, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["iata", "zona_horaria", "latitud", "longitud", "pais"])
        w.writerows(sorted(filas.values()))
    return len(filas)


def _rango_meses(texto: str) -> list[int]:
    if "-" in texto:
        a, b = (int(x) for x in texto.split("-"))
        return list(range(a, b + 1))
    return [int(x) for x in texto.split(",")]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--meses", default="1-12", help="rango (1-12) o lista (1,2,3)")
    args = parser.parse_args()
    meses = _rango_meses(args.meses)

    for nombre, url in URL_REFERENCIA.items():
        descargar(url, DIR_REF / nombre)
    n_tz = preparar_zonas_horarias(DIR_REF / "airports_mwgg.json", DIR_REF / "aeropuertos_tz.csv")
    print(f"Referencias listas ({n_tz} aeropuertos con zona horaria)", flush=True)

    control = json.loads(ARCHIVO_CONTROL.read_text(encoding="utf-8")) if ARCHIVO_CONTROL.exists() else {}
    control.setdefault("fuente", URL_MES.format(anio=ANIO, mes="{M}"))
    control.setdefault("meses", {})
    for mes in meses:
        zip_mes = DIR_VUELOS / f"{ANIO}_{mes:02d}.zip"
        t0 = time.perf_counter()
        descargar(URL_MES.format(anio=ANIO, mes=mes), zip_mes)
        clave = f"{ANIO}-{mes:02d}"
        huella = sha256(zip_mes)
        previo = control["meses"].get(clave)
        if not previo or previo.get("sha256") != huella:
            control["meses"][clave] = {"zip": zip_mes.name, "bytes_zip": zip_mes.stat().st_size,
                                       "sha256": huella, **cifras_de_zip(zip_mes)}
            # Se guarda después de cada mes: si la PC se apaga, no se repite lo hecho.
            ARCHIVO_CONTROL.write_text(json.dumps(control, indent=2, ensure_ascii=False), encoding="utf-8")
        m = control["meses"][clave]
        print(f"{clave}: {m['filas']:>9,} filas | {m['bytes_zip'] / 1e6:5.1f} MB | "
              f"{time.perf_counter() - t0:5.1f} s", flush=True)

    total = sum(control["meses"][f"{ANIO}-{m:02d}"]["filas"] for m in meses)
    control["total_filas"] = sum(m["filas"] for m in control["meses"].values())
    ARCHIVO_CONTROL.write_text(json.dumps(control, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Total de los meses pedidos: {total:,} filas")
    return 0


if __name__ == "__main__":
    sys.exit(main())
