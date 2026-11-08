"""
descargar_datos.py
Descarga los viajes de taxi amarillo de Nueva York 2024 (NYC TLC, un Parquet por mes) y la tabla
de zonas, convierte cada Parquet a un CSV listo para BULK INSERT (SQL Server no lee Parquet) y
calcula las cifras de control de cada archivo, que luego se reconcilian en SQL mes a mes.

Uso (desde la carpeta del proyecto):
    .venv\\Scripts\\python scripts\\descargar_datos.py              # los 12 meses
    .venv\\Scripts\\python scripts\\descargar_datos.py --meses 1 2  # solo enero y febrero
"""
from __future__ import annotations

import argparse
import hashlib
import json
import time
import urllib.request
from datetime import datetime
from pathlib import Path

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.csv as pacsv
import pyarrow.parquet as pq

ANIO = 2024
URL_VIAJES = "https://d37ci6vzurychx.cloudfront.net/trip-data/yellow_tripdata_{anio}-{mes:02d}.parquet"
URL_ZONAS = "https://d37ci6vzurychx.cloudfront.net/misc/taxi_zone_lookup.csv"
RAIZ = Path(__file__).resolve().parents[1]
CARPETA_RAW = RAIZ / "data" / "raw"
CONTROL_DESTINO = RAIZ / "data" / "cifras_control.json"

# Columnas del CSV en el mismo orden que stg.viaje (fila_origen primero, para el linaje)
COLUMNAS_FECHA = ["tpep_pickup_datetime", "tpep_dropoff_datetime"]
COLUMNAS_ENTERAS = ["vendorid", "passenger_count", "ratecodeid", "pulocationid", "dolocationid", "payment_type"]
COLUMNAS_DINERO = ["trip_distance", "fare_amount", "extra", "mta_tax", "tip_amount", "tolls_amount",
                   "improvement_surcharge", "total_amount", "congestion_surcharge", "airport_fee"]
ORDEN_CSV = ["fila_origen", "vendorid", "tpep_pickup_datetime", "tpep_dropoff_datetime", "passenger_count",
             "trip_distance", "ratecodeid", "store_and_fwd_flag", "pulocationid", "dolocationid",
             "payment_type", "fare_amount", "extra", "mta_tax", "tip_amount", "tolls_amount",
             "improvement_surcharge", "total_amount", "congestion_surcharge", "airport_fee"]
DECIMAL = pa.decimal128(12, 2)


def descargar(url: str, destino: Path) -> None:
    if destino.exists() and destino.stat().st_size > 0:
        print(f"[OMITIDO] {destino.name} ya existe ({destino.stat().st_size / 1e6:.1f} MB)")
        return
    temporal = destino.with_suffix(destino.suffix + ".parcial")
    for intento in range(1, 4):
        try:
            print(f"Descargando {url} ...")
            urllib.request.urlretrieve(url, temporal)
            temporal.replace(destino)
            print(f"  {destino.stat().st_size / 1e6:.1f} MB")
            return
        except OSError as e:  # red inestable: reintenta
            print(f"  intento {intento} falló: {e}")
            time.sleep(5 * intento)
    raise RuntimeError(f"No se pudo descargar {url}")


def sha256(ruta: Path) -> str:
    h = hashlib.sha256()
    with open(ruta, "rb") as f:
        for bloque in iter(lambda: f.read(1 << 20), b""):
            h.update(bloque)
    return h.hexdigest()


def normalizar(tabla: pa.Table) -> tuple[pa.Table, int]:
    """Nombres en minúscula, tipos fijos, dinero a DECIMAL(12,2) y fechas a texto sin fracción.

    Devuelve la tabla lista para el CSV y cuántos valores tenían más de 2 decimales (se redondean).
    """
    tabla = tabla.rename_columns([c.lower() for c in tabla.column_names])
    if "airport_fee" not in tabla.column_names:  # algunos meses antiguos no la traen
        tabla = tabla.append_column("airport_fee", pa.nulls(tabla.num_rows, pa.float64()))
    columnas: dict[str, pa.Array] = {"fila_origen": pa.array(range(1, tabla.num_rows + 1), pa.int32())}
    redondeados = 0
    for c in COLUMNAS_ENTERAS:
        columnas[c] = pc.cast(tabla[c], pa.int32())
    for c in COLUMNAS_FECHA:
        # safe=True: si hubiera fracciones de segundo, el cast falla en vez de perderlas en silencio
        en_segundos = pc.cast(tabla[c], pa.timestamp("s"), safe=True)
        columnas[c] = pc.cast(en_segundos, pa.string())  # "AAAA-MM-DD HH:MM:SS" (mucho más rápido que strftime)
    for c in COLUMNAS_DINERO:
        valores = pc.cast(tabla[c], pa.float64())
        centavos = pc.round(valores, 2)
        redondeados += pc.sum(pc.cast(pc.not_equal(valores, centavos), pa.int64())).as_py() or 0
        columnas[c] = pc.cast(centavos, DECIMAL)
    columnas["store_and_fwd_flag"] = pc.cast(tabla["store_and_fwd_flag"], pa.string())
    return pa.table({c: columnas[c] for c in ORDEN_CSV}), redondeados


def suma(tabla: pa.Table, columna: str) -> str:
    valor = pc.sum(tabla[columna]).as_py()
    return str(valor if valor is not None else 0)


def cifras_de_control(tabla: pa.Table, mes: int, parquet: Path, redondeados: int) -> dict:
    """Cifras del archivo fuente calculadas con Arrow, independientes de SQL Server."""
    recogida = pc.cast(tabla["tpep_pickup_datetime"], pa.timestamp("s"))
    inicio = pa.scalar(datetime(ANIO, mes, 1), pa.timestamp("s"))
    fin = pa.scalar(datetime(ANIO + (mes == 12), mes % 12 + 1, 1), pa.timestamp("s"))
    dentro = pc.and_(pc.greater_equal(recogida, inicio), pc.less(recogida, fin))
    minimo, maximo = pc.min_max(recogida).values()
    return {
        "archivo": parquet.name,
        "sha256": sha256(parquet),
        "bytes": parquet.stat().st_size,
        "filas": tabla.num_rows,
        "filas_fuera_del_mes": tabla.num_rows - pc.sum(pc.cast(dentro, pa.int64())).as_py(),
        "suma_total_amount": suma(tabla, "total_amount"),
        "suma_fare_amount": suma(tabla, "fare_amount"),
        "suma_tip_amount": suma(tabla, "tip_amount"),
        "suma_trip_distance": suma(tabla, "trip_distance"),
        "pasajeros_nulos": tabla["passenger_count"].null_count,
        "valores_redondeados_a_centavos": redondeados,
        "recogida_min": str(minimo.as_py()),
        "recogida_max": str(maximo.as_py()),
    }


def procesar_mes(mes: int) -> dict:
    parquet = CARPETA_RAW / f"yellow_tripdata_{ANIO}-{mes:02d}.parquet"
    csv_destino = CARPETA_RAW / f"yellow_tripdata_{ANIO}-{mes:02d}.csv"
    descargar(URL_VIAJES.format(anio=ANIO, mes=mes), parquet)
    t0 = time.perf_counter()
    tabla, redondeados = normalizar(pq.read_table(parquet))
    control = cifras_de_control(tabla, mes, parquet, redondeados)
    opciones = pacsv.WriteOptions(include_header=True, quoting_style="needed", batch_size=200_000)
    pacsv.write_csv(tabla, csv_destino, write_options=opciones)
    control["csv"] = csv_destino.name
    control["csv_bytes"] = csv_destino.stat().st_size
    print(f"{ANIO}-{mes:02d}: {control['filas']:,} filas - CSV {control['csv_bytes'] / 1e6:.0f} MB "
          f"- {time.perf_counter() - t0:.0f} s")
    return control


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--meses", type=int, nargs="+", default=list(range(1, 13)))
    args = parser.parse_args()

    CARPETA_RAW.mkdir(parents=True, exist_ok=True)
    descargar(URL_ZONAS, CARPETA_RAW / "taxi_zone_lookup.csv")

    control = {"fuente": "NYC TLC Trip Record Data (yellow taxi)", "anio": ANIO, "meses": {}}
    if CONTROL_DESTINO.exists():  # conserva los meses procesados en ejecuciones anteriores
        control = json.loads(CONTROL_DESTINO.read_text(encoding="utf-8"))
    for mes in args.meses:
        control["meses"][f"{ANIO}-{mes:02d}"] = procesar_mes(mes)
        control["meses"] = dict(sorted(control["meses"].items()))
        CONTROL_DESTINO.write_text(json.dumps(control, indent=2, ensure_ascii=False), encoding="utf-8")

    total = sum(m["filas"] for m in control["meses"].values())
    print(f"Total: {total:,} viajes en {len(control['meses'])} meses -> {CONTROL_DESTINO.relative_to(RAIZ)}")


if __name__ == "__main__":
    main()
