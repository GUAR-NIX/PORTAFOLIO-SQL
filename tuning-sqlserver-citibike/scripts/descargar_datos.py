"""Descarga y audita los viajes de Citi Bike Nueva York de enero a marzo de 2024 (S3 tripdata).

Fuente oficial (sistema principal de Nueva York, no los archivos `JC-` de Jersey City):
  https://s3.amazonaws.com/tripdata/202401-citibike-tripdata.zip
  https://s3.amazonaws.com/tripdata/202402-citibike-tripdata.zip
  https://s3.amazonaws.com/tripdata/202403-citibike-tripdata.zip

Cada ZIP mensual trae varios CSV (`_1.csv`, `_2.csv`, ...). Se procesan mes a mes para no
cargar los ~6,7 M de filas en memoria a la vez.

Uso:
  python descargar_datos.py                       # descarga a data/raw si faltan los ZIP
  python descargar_datos.py --cache D:\\zips       # reutiliza ZIP ya descargados en otra carpeta

Genera:
  - data/raw/citibike_2024T1.tsv      (archivo consolidado para BULK INSERT en SQL Server)
  - data/muestra_citibike_2024T1.csv  (muestra ligera versionada: 150 filas por mes)
  - data/cifras_control.json          (cifras de control para reconciliar con SQL Server)
  - docs/cifras_control.md            (resumen legible de la auditoría de ingesta)
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import urllib.request
import zipfile
from pathlib import Path

import numpy as np
import pandas as pd

RAIZ = Path(__file__).resolve().parents[1]
DIR_DATOS = RAIZ / "data"
DIR_RAW = DIR_DATOS / "raw"
DIR_DOCS = RAIZ / "docs"

URL_BASE_S3 = "https://s3.amazonaws.com/tripdata"
MESES = ["202401", "202402", "202403"]
NOMBRE_TSV = "citibike_2024T1.tsv"
NOMBRE_MUESTRA = "muestra_citibike_2024T1.csv"
FILAS_MUESTRA_POR_MES = 150

COLUMNAS_ESPERADAS = [
    "ride_id",
    "rideable_type",
    "started_at",
    "ended_at",
    "start_station_name",
    "start_station_id",
    "end_station_name",
    "end_station_id",
    "start_lat",
    "start_lng",
    "end_lat",
    "end_lng",
    "member_casual",
]


def _sha256_archivo(ruta: Path) -> str:
    h = hashlib.sha256()
    with ruta.open("rb") as f:
        for bloque in iter(lambda: f.read(4 * 1024 * 1024), b""):
            h.update(bloque)
    return h.hexdigest()


def ubicar_zips(dir_raw: Path = DIR_RAW, dir_cache: Path | None = None) -> list[Path]:
    """Devuelve la ruta de cada ZIP mensual; usa la caché si existe y, si no, descarga desde S3."""
    dir_raw.mkdir(parents=True, exist_ok=True)
    rutas: list[Path] = []
    for periodo in MESES:
        nombre = f"{periodo}-citibike-tripdata.zip"
        en_cache = dir_cache / nombre if dir_cache else None
        if en_cache is not None and en_cache.exists():
            rutas.append(en_cache)
            continue
        destino = dir_raw / nombre
        # is_zipfile busca el índice que va al final del ZIP: un archivo cortado no lo tiene y se vuelve a bajar.
        if not zipfile.is_zipfile(destino):
            url = f"{URL_BASE_S3}/{nombre}"
            print(f"[descarga] {url}")
            req = urllib.request.Request(url, headers={"User-Agent": "Portafolio-SQL06"})
            parcial = destino.with_suffix(destino.suffix + ".part")
            with urllib.request.urlopen(req, timeout=600) as resp, parcial.open("wb") as out:
                while bloque := resp.read(8 * 1024 * 1024):
                    out.write(bloque)
            if not zipfile.is_zipfile(parcial):
                raise RuntimeError(f"La descarga de {nombre} no es un ZIP completo; vuelve a ejecutar el script")
            parcial.replace(destino)
        rutas.append(destino)
    return rutas


def _limpiar_texto_tsv(serie: pd.Series) -> pd.Series:
    return (
        serie.fillna("")
        .astype(str)
        .str.replace("\t", " ", regex=False)
        .str.replace("\r", " ", regex=False)
        .str.replace("\n", " ", regex=False)
        .str.strip()
    )


def clasificar_motivo_exclusion(df: pd.DataFrame, ya_vistos: set[str] | None = None) -> pd.Series:
    """Aplica las mismas 7 reglas de calidad que `etl.sp_limpiar` en T-SQL (y en el mismo orden).

    `ya_vistos` contiene los ride_id de meses anteriores: un ride_id repetido entre meses también
    cuenta como duplicado (SQL numera por periodo_archivo y fila_archivo).
    """
    es_duplicado = df.duplicated(subset=["ride_id"], keep="first")
    if ya_vistos:
        es_duplicado = es_duplicado | df["ride_id"].isin(ya_vistos)

    sin_base = (
        df["started_at_dt"].isna()
        | df["ended_at_dt"].isna()
        | (df["start_station_id"] == "")
        | df["start_lat_num"].isna()
        | df["start_lng_num"].isna()
    )
    dur = df["duracion_seg"]
    falso_arranque = (
        (df["start_station_id"] != "")
        & (df["start_station_id"] == df["end_station_id"])
        & (dur > 0)
        & (dur < 60)
    )
    sin_destino = (
        (df["end_station_id"] == "")
        | df["end_lat_num"].isna()
        | df["end_lng_num"].isna()
    )
    coord_fuera = (
        ~df["start_lat_num"].between(40.50, 41.00)
        | ~df["start_lng_num"].between(-74.30, -73.70)
        | ~df["end_lat_num"].between(40.50, 41.00)
        | ~df["end_lng_num"].between(-74.30, -73.70)
    )
    condiciones = [
        es_duplicado,
        sin_base,
        dur <= 0,
        falso_arranque,
        sin_destino,
        dur > 86_400,
        coord_fuera,
    ]
    etiquetas = [
        "DUPLICADO_RIDE_ID",
        "DATOS_ORIGEN_INCOMPLETOS",
        "DURACION_NO_POSITIVA",
        "FALSO_ARRANQUE_MISMA_ESTACION_MENOR_60S",
        "SIN_ESTACION_O_COORD_DESTINO",
        "DURACION_EXCESIVA_MAYOR_24H",
        "COORDENADAS_FUERA_RANGO",
    ]
    return pd.Series(
        np.select([c.to_numpy(dtype=bool) for c in condiciones], etiquetas, default="VALIDO"),
        index=df.index,
        dtype="object",
    )


def _orden_natural(nombre: str) -> tuple:
    return tuple(int(t) if t.isdigit() else t for t in re.split(r"(\d+)", nombre))


def leer_mes(ruta_zip: Path) -> pd.DataFrame:
    """Lee todos los CSV de un ZIP mensual en orden (_1, _2, ...) y los concatena."""
    partes = []
    with zipfile.ZipFile(ruta_zip) as zf:
        nombres = sorted(
            (n for n in zf.namelist() if n.lower().endswith(".csv") and not n.startswith("__MACOSX")),
            key=_orden_natural,
        )
        if not nombres:
            raise RuntimeError(f"No hay CSV dentro de {ruta_zip.name}")
        for nombre in nombres:
            with zf.open(nombre) as f:
                partes.append(pd.read_csv(f, dtype=str, keep_default_na=False))
    df = pd.concat(partes, ignore_index=True)
    faltantes = set(COLUMNAS_ESPERADAS) - set(df.columns)
    if faltantes:
        raise ValueError(f"Faltan columnas {faltantes} en {ruta_zip.name}")
    return df[COLUMNAS_ESPERADAS].copy()


def preparar_mes(df: pd.DataFrame, periodo: str) -> pd.DataFrame:
    for col in COLUMNAS_ESPERADAS:
        df[col] = _limpiar_texto_tsv(df[col])
    # En 2024 las marcas de tiempo traen milisegundos: se truncan a segundos (igual que en SQL)
    df["started_at"] = df["started_at"].str.slice(0, 19)
    df["ended_at"] = df["ended_at"].str.slice(0, 19)
    df["periodo_archivo"] = int(periodo)
    df["fila_archivo"] = np.arange(1, len(df) + 1, dtype=np.int64)

    df["started_at_dt"] = pd.to_datetime(df["started_at"], format="%Y-%m-%d %H:%M:%S", errors="coerce")
    df["ended_at_dt"] = pd.to_datetime(df["ended_at"], format="%Y-%m-%d %H:%M:%S", errors="coerce")
    df["duracion_seg"] = (
        (df["ended_at_dt"] - df["started_at_dt"]).dt.total_seconds().fillna(0).round().astype(np.int64)
    )
    for col in ("start_lat", "start_lng", "end_lat", "end_lng"):
        df[f"{col}_num"] = pd.to_numeric(df[col].replace("", np.nan), errors="coerce")
    return df


def consolidar_y_auditar(
    dir_raw: Path = DIR_RAW,
    dir_datos: Path = DIR_DATOS,
    dir_docs: Path = DIR_DOCS,
    dir_cache: Path | None = None,
) -> dict:
    """Genera el TSV para BULK INSERT y las cifras de control, procesando un mes a la vez."""
    rutas_zip = ubicar_zips(dir_raw, dir_cache)
    cols_tsv = COLUMNAS_ESPERADAS + ["periodo_archivo", "fila_archivo"]
    ruta_tsv = dir_raw / NOMBRE_TSV

    ya_vistos: set[str] = set()
    resumen_mensual: dict[str, dict] = {}
    conteo_motivos: dict[str, int] = {}
    muestras: list[pd.DataFrame] = []
    tot = {"filas": 0, "validas": 0, "dur_bruta": 0, "dur_valida": 0}
    tipos_validos: dict[str, int] = {}
    membresia_validos: dict[str, int] = {}
    est_origen: set[str] = set()
    est_destino: set[str] = set()

    for i, ruta_zip in enumerate(rutas_zip):
        periodo = ruta_zip.name.split("-")[0]
        df = preparar_mes(leer_mes(ruta_zip), periodo)
        df["motivo"] = clasificar_motivo_exclusion(df, ya_vistos)
        ya_vistos.update(df["ride_id"].tolist())

        df[cols_tsv].to_csv(
            ruta_tsv,
            sep="\t",
            index=False,
            header=(i == 0),
            mode="w" if i == 0 else "a",
            encoding="utf-8",
            lineterminator="\n",
            quoting=csv.QUOTE_NONE,
            quotechar="\x07",
        )
        muestras.append(df.head(FILAS_MUESTRA_POR_MES)[cols_tsv])

        validos = df["motivo"] == "VALIDO"
        for k, v in df["motivo"].value_counts().items():
            conteo_motivos[k] = conteo_motivos.get(k, 0) + int(v)
        for k, v in df.loc[validos, "rideable_type"].value_counts().items():
            tipos_validos[k] = tipos_validos.get(k, 0) + int(v)
        for k, v in df.loc[validos, "member_casual"].value_counts().items():
            membresia_validos[k] = membresia_validos.get(k, 0) + int(v)
        est_origen.update(df.loc[validos, "start_station_id"].unique().tolist())
        est_destino.update(df.loc[validos, "end_station_id"].unique().tolist())
        tot["filas"] += len(df)
        tot["validas"] += int(validos.sum())
        tot["dur_bruta"] += int(df["duracion_seg"].sum())
        tot["dur_valida"] += int(df.loc[validos, "duracion_seg"].sum())

        resumen_mensual[periodo] = {
            "archivo_zip": ruta_zip.name,
            "bytes_zip": int(ruta_zip.stat().st_size),
            "sha256_zip": _sha256_archivo(ruta_zip),
            "filas": int(len(df)),
            "filas_validas": int(validos.sum()),
            "electric_bike": int((df["rideable_type"] == "electric_bike").sum()),
            "classic_bike": int((df["rideable_type"] == "classic_bike").sum()),
            "member": int((df["member_casual"] == "member").sum()),
            "casual": int((df["member_casual"] == "casual").sum()),
        }
        print(f"[ingesta] {periodo}: {len(df):,} filas ({int(validos.sum()):,} válidas)")
        del df

    pd.concat(muestras, ignore_index=True).to_csv(dir_datos / NOMBRE_MUESTRA, index=False, encoding="utf-8")

    cifras = {
        "fuente": "Citi Bike System Data (Lyft), sistema principal de Nueva York",
        "url_indice": "https://s3.amazonaws.com/tripdata/index.html",
        "periodo": "2024-01 a 2024-03",
        "archivos_mensuales": len(MESES),
        "archivo_tsv": NOMBRE_TSV,
        "bytes_tsv": int(ruta_tsv.stat().st_size),
        "filas_totales_brutas": tot["filas"],
        "filas_validas": tot["validas"],
        "filas_excluidas": tot["filas"] - tot["validas"],
        "tasa_retencion_pct": round(tot["validas"] * 100.0 / tot["filas"], 4),
        "suma_duracion_seg_bruta": tot["dur_bruta"],
        "suma_duracion_seg_valida": tot["dur_valida"],
        "estaciones_origen_unicas_validas": len(est_origen),
        "estaciones_destino_unicas_validas": len(est_destino),
        "desglose_tipo_bici_validos": tipos_validos,
        "desglose_membresia_validos": membresia_validos,
        "desglose_motivos": dict(sorted(conteo_motivos.items(), key=lambda kv: -kv[1])),
        "meses": resumen_mensual,
    }
    dir_datos.mkdir(parents=True, exist_ok=True)
    dir_docs.mkdir(parents=True, exist_ok=True)
    (dir_datos / "cifras_control.json").write_text(
        json.dumps(cifras, indent=2, ensure_ascii=False), encoding="utf-8"
    )

    def n(x: int) -> str:
        return f"{x:,}".replace(",", ".")

    lineas = [
        "# Cifras de control de la ingesta (Citi Bike Nueva York, enero–marzo 2024)",
        "",
        "Archivo generado por `scripts/descargar_datos.py`. No editar a mano.",
        "",
        f"- **Fuente:** {cifras['url_indice']} (archivos `202401`, `202402` y `202403` del sistema de Nueva York)",
        f"- **TSV consolidado:** `data/raw/{NOMBRE_TSV}` ({cifras['bytes_tsv'] / 1024**2:,.1f} MB)".replace(",", "X").replace(".", ",").replace("X", "."),
        f"- **Filas brutas:** {n(cifras['filas_totales_brutas'])}",
        f"- **Filas válidas:** {n(cifras['filas_validas'])}",
        f"- **Filas con motivo de exclusión:** {n(cifras['filas_excluidas'])}",
        "",
        "## Desglose por mes",
        "",
        "| Periodo | Archivo ZIP | MB del ZIP | Filas | Válidas | Eléctrica | Clásica | Miembros | Ocasionales |",
        "| :---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for per, m in resumen_mensual.items():
        mb = f"{m['bytes_zip'] / 1024**2:.1f}".replace(".", ",")
        lineas.append(
            f"| `{per}` | `{m['archivo_zip']}` | {mb} | {n(m['filas'])} | {n(m['filas_validas'])} | "
            f"{n(m['electric_bike'])} | {n(m['classic_bike'])} | {n(m['member'])} | {n(m['casual'])} |"
        )
    lineas += ["", "## Reglas de calidad (`motivo_exclusion`)", "", "| Estado / motivo | Filas |", "| :--- | ---: |"]
    for mot, cnt in cifras["desglose_motivos"].items():
        lineas.append(f"| `{mot}` | {n(cnt)} |")
    lineas += ["", "## Huella SHA-256 de los ZIP", ""]
    for per, m in resumen_mensual.items():
        lineas.append(f"- `{m['archivo_zip']}`: `{m['sha256_zip']}`")
    (dir_docs / "cifras_control.md").write_text("\n".join(lineas) + "\n", encoding="utf-8")

    print(f"[ok] {NOMBRE_TSV}: {n(tot['filas'])} filas brutas, {n(tot['validas'])} válidas")
    return cifras


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--cache",
        type=Path,
        default=os.environ.get("CITIBIKE_ZIPS_CACHE"),
        help="Carpeta con los ZIP mensuales ya descargados (se leen en su sitio, sin copiarlos).",
    )
    args = parser.parse_args()
    consolidar_y_auditar(dir_cache=Path(args.cache) if args.cache else None)


if __name__ == "__main__":
    main()
