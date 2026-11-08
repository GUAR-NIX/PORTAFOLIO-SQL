"""Pruebas unitarias de la ingesta, reglas de calidad y cifras de control en Python."""

from __future__ import annotations

import json
from pathlib import Path

import pandas as pd

from descargar_datos import clasificar_motivo_exclusion

RAIZ = Path(__file__).resolve().parents[1]


def test_cifras_control_existen_y_cuadran() -> None:
    ruta_json = RAIZ / "data" / "cifras_control.json"
    assert ruta_json.exists()
    c = json.loads(ruta_json.read_text(encoding="utf-8"))

    assert c["periodo"] == "2024-01 a 2024-03"
    assert c["archivos_mensuales"] == 3
    assert set(c["meses"]) == {"202401", "202402", "202403"}
    assert all(not m["archivo_zip"].startswith("JC-") for m in c["meses"].values())
    assert c["filas_totales_brutas"] > 6_000_000
    assert c["filas_totales_brutas"] == c["filas_validas"] + c["filas_excluidas"]
    assert sum(m["filas"] for m in c["meses"].values()) == c["filas_totales_brutas"]
    assert sum(m["filas_validas"] for m in c["meses"].values()) == c["filas_validas"]
    assert sum(c["desglose_motivos"].values()) == c["filas_totales_brutas"]
    assert c["desglose_motivos"]["VALIDO"] == c["filas_validas"]


def test_muestra_versionada_existe_y_es_ligera() -> None:
    ruta_muestra = RAIZ / "data" / "muestra_citibike_2024T1.csv"
    assert ruta_muestra.exists()
    assert ruta_muestra.stat().st_size < 1_000_000  # < 1 MB
    df = pd.read_csv(ruta_muestra)
    assert len(df) == 450
    assert sorted(df["periodo_archivo"].unique()) == [202401, 202402, 202403]


def test_clasificador_motivos_exclusion_determinista() -> None:
    df_prueba = pd.DataFrame(
        [
            # 1. Viaje válido
            {
                "ride_id": "R1",
                "started_at_dt": pd.Timestamp("2024-06-01 08:00:00"),
                "ended_at_dt": pd.Timestamp("2024-06-01 08:10:00"),
                "start_station_id": "HB102",
                "end_station_id": "HB101",
                "duracion_seg": 600,
                "start_lat_num": 40.735,
                "start_lng_num": -74.030,
                "end_lat_num": 40.742,
                "end_lng_num": -74.028,
            },
            # 2. Duplicado de ride_id
            {
                "ride_id": "R1",
                "started_at_dt": pd.Timestamp("2024-06-01 08:00:00"),
                "ended_at_dt": pd.Timestamp("2024-06-01 08:10:00"),
                "start_station_id": "HB102",
                "end_station_id": "HB101",
                "duracion_seg": 600,
                "start_lat_num": 40.735,
                "start_lng_num": -74.030,
                "end_lat_num": 40.742,
                "end_lng_num": -74.028,
            },
            # 3. Falso arranque (<60 s en la misma estación)
            {
                "ride_id": "R2",
                "started_at_dt": pd.Timestamp("2024-06-01 09:00:00"),
                "ended_at_dt": pd.Timestamp("2024-06-01 09:00:25"),
                "start_station_id": "HB102",
                "end_station_id": "HB102",
                "duracion_seg": 25,
                "start_lat_num": 40.735,
                "start_lng_num": -74.030,
                "end_lat_num": 40.735,
                "end_lng_num": -74.030,
            },
            # 4. Sin estación de destino
            {
                "ride_id": "R3",
                "started_at_dt": pd.Timestamp("2024-06-01 10:00:00"),
                "ended_at_dt": pd.Timestamp("2024-06-01 10:20:00"),
                "start_station_id": "HB102",
                "end_station_id": "",
                "duracion_seg": 1200,
                "start_lat_num": 40.735,
                "start_lng_num": -74.030,
                "end_lat_num": float("nan"),
                "end_lng_num": float("nan"),
            },
        ]
    )
    motivos = clasificar_motivo_exclusion(df_prueba).tolist()
    assert motivos == [
        "VALIDO",
        "DUPLICADO_RIDE_ID",
        "FALSO_ARRANQUE_MISMA_ESTACION_MENOR_60S",
        "SIN_ESTACION_O_COORD_DESTINO",
    ]


def test_duplicado_entre_meses_se_marca() -> None:
    df = pd.DataFrame(
        [
            {
                "ride_id": "VISTO_EN_ENERO",
                "started_at_dt": pd.Timestamp("2024-02-01 08:00:00"),
                "ended_at_dt": pd.Timestamp("2024-02-01 08:10:00"),
                "start_station_id": "5788.13",
                "end_station_id": "6140.05",
                "duracion_seg": 600,
                "start_lat_num": 40.74,
                "start_lng_num": -73.99,
                "end_lat_num": 40.75,
                "end_lng_num": -73.98,
            }
        ]
    )
    assert clasificar_motivo_exclusion(df, {"VISTO_EN_ENERO"}).tolist() == ["DUPLICADO_RIDE_ID"]
    assert clasificar_motivo_exclusion(df, set()).tolist() == ["VALIDO"]
