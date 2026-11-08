"""Pruebas de la conversión Parquet → CSV y de las cifras de control (sin red ni SQL Server)."""
from __future__ import annotations

from datetime import datetime
from decimal import Decimal

import pyarrow as pa
import pyarrow.parquet as pq
import pytest

import descargar_datos as dd


def tabla_tlc(**cambios) -> pa.Table:
    """Mini Parquet con el esquema real de la TLC (nombres en mayúsculas mezcladas, dinero en double)."""
    datos = {
        "VendorID": pa.array([2, 1, 2], pa.int32()),
        "tpep_pickup_datetime": pa.array([datetime(2024, 1, 1, 0, 57, 55), datetime(2024, 1, 31, 23, 59, 59),
                                          datetime(2002, 12, 31, 22, 59, 39)], pa.timestamp("us")),
        "tpep_dropoff_datetime": pa.array([datetime(2024, 1, 1, 1, 17, 43), datetime(2024, 2, 1, 0, 10, 0),
                                           datetime(2002, 12, 31, 23, 5, 0)], pa.timestamp("us")),
        "passenger_count": pa.array([1, None, 2], pa.int64()),
        "trip_distance": [1.72, 0.0, 312722.3],
        "RatecodeID": pa.array([1, None, 99], pa.int64()),
        "store_and_fwd_flag": pa.array(["N", None, "Y"], pa.large_string()),
        "PULocationID": pa.array([186, 140, 264], pa.int32()),
        "DOLocationID": pa.array([79, 236, 265], pa.int32()),
        "payment_type": pa.array([2, 0, 4], pa.int64()),
        "fare_amount": [17.7, 10.0, -900.0],
        "extra": [1.0, 3.5, 0.0], "mta_tax": [0.5, 0.5, 0.0], "tip_amount": [0.0, 3.75, 0.0],
        "tolls_amount": [0.0, 0.0, 0.0], "improvement_surcharge": [1.0, 1.0, 1.0],
        "total_amount": [22.7, 18.75, -899.0], "congestion_surcharge": [2.5, None, 0.0],
        "Airport_fee": [0.0, None, 0.0],
    }
    datos.update(cambios)
    return pa.table(datos)


def test_normalizar_columnas_y_formatos():
    tabla, redondeados = dd.normalizar(tabla_tlc())
    assert tabla.column_names == dd.ORDEN_CSV
    assert tabla["fila_origen"].to_pylist() == [1, 2, 3]
    assert tabla["tpep_pickup_datetime"][0].as_py() == "2024-01-01 00:57:55"   # formato que entiende BULK INSERT
    assert tabla["total_amount"].type == pa.decimal128(12, 2)
    assert tabla["total_amount"].to_pylist() == [Decimal("22.70"), Decimal("18.75"), Decimal("-899.00")]
    assert tabla["passenger_count"].to_pylist() == [1, None, 2]               # nulos se conservan
    assert redondeados == 0


def test_normalizar_cuenta_valores_con_mas_de_dos_decimales():
    _, redondeados = dd.normalizar(tabla_tlc(fare_amount=[17.701, 10.0, -900.0]))
    assert redondeados == 1


def test_normalizar_rechaza_fracciones_de_segundo():
    pickup = pa.array([datetime(2024, 1, 1, 0, 0, 0, 500000)] * 3, pa.timestamp("us"))
    with pytest.raises(pa.ArrowInvalid):
        dd.normalizar(tabla_tlc(tpep_pickup_datetime=pickup))


def test_normalizar_sin_airport_fee():
    tabla = tabla_tlc().drop_columns(["Airport_fee"])
    resultado, _ = dd.normalizar(tabla)
    assert resultado["airport_fee"].null_count == 3


def test_cifras_de_control(tmp_path):
    parquet = tmp_path / "yellow_tripdata_2024-01.parquet"
    pq.write_table(tabla_tlc(), parquet)
    tabla, redondeados = dd.normalizar(pq.read_table(parquet))
    control = dd.cifras_de_control(tabla, 1, parquet, redondeados)
    assert control["filas"] == 3
    assert control["filas_fuera_del_mes"] == 1           # el viaje de 2002
    assert Decimal(control["suma_total_amount"]) == Decimal("-857.55")
    assert Decimal(control["suma_tip_amount"]) == Decimal("3.75")
    assert control["pasajeros_nulos"] == 1
    assert control["recogida_min"].startswith("2002-12-31")
    assert len(control["sha256"]) == 64


def test_cifras_de_control_diciembre_cruza_el_anio(tmp_path):
    pickup = pa.array([datetime(2024, 12, 31, 23, 0), datetime(2025, 1, 1, 0, 5), datetime(2024, 12, 1)],
                      pa.timestamp("us"))
    parquet = tmp_path / "dic.parquet"
    pq.write_table(tabla_tlc(tpep_pickup_datetime=pickup), parquet)
    tabla, r = dd.normalizar(pq.read_table(parquet))
    assert dd.cifras_de_control(tabla, 12, parquet, r)["filas_fuera_del_mes"] == 1
