"""
Pruebas del data warehouse contra la base TaxisNYC ya cargada
(ejecuta antes sql/00_EJECUTAR_TODO.sql). Si no hay SQL Server, se omiten.

    .venv\\Scripts\\python -m pytest -q
"""
from __future__ import annotations

import json
from decimal import Decimal
from pathlib import Path

import pyodbc
import pytest

from conexion import conectar, consultar

RAIZ = Path(__file__).resolve().parents[1]
CARPETA_DATOS = str(RAIZ / "data")


@pytest.fixture(scope="module")
def cn():
    try:
        conexion = conectar()
    except pyodbc.Error as e:  # pragma: no cover - depende del entorno
        pytest.skip(f"SQL Server no disponible: {e}")
    yield conexion
    conexion.close()


def test_controles_de_calidad_todos_ok(cn):
    df = consultar("EXEC qa.sp_validar_calidad @lanzar_error = 0;", cn)
    assert len(df) == 27
    alertas = df[df["estado"] != "OK"]
    assert alertas.empty, alertas[["orden", "control", "valor"]].to_string()


def test_control_detecta_un_total_alterado():
    """Prueba negativa: si alguien altera un viaje del hecho, el cuadre contra el Parquet lo detecta."""
    try:
        cn = conectar(autocommit=False)
    except pyodbc.Error as e:  # pragma: no cover
        pytest.skip(f"SQL Server no disponible: {e}")
    try:
        cur = cn.cursor()
        cur.execute("UPDATE TOP (1) dw.fact_viaje SET total = total + 1 WHERE fecha_key = 20240315;")
        cur.execute("EXEC qa.sp_validar_calidad @lanzar_error = 0;")
        filas = {r.orden: r.estado for r in cur.fetchall()}
        assert filas[3] == "ALERTA"          # suma de total_amount de marzo ya no cuadra
        with pytest.raises(pyodbc.Error, match="ALERTA"):
            cur.execute("EXEC qa.sp_validar_calidad;")
            while cur.nextset():
                pass
    finally:
        cn.rollback()   # deja un delta store OPEN vacío en marzo: los controles solo cuentan los que tienen filas
        cn.close()


def test_cuadre_independiente_contra_json(cn):
    """Las cifras de control salen del Parquet vía Python; aquí se comparan con hecho + cuarentena."""
    control = json.loads((RAIZ / "data" / "cifras_control.json").read_text(encoding="utf-8"))["meses"]
    df = consultar("SELECT periodo, filas_hecho + filas_cuarentena AS filas FROM rpt.cuadre_fuente", cn)
    sql = dict(zip(df["periodo"], df["filas"].astype(int)))
    assert len(control) == 12
    assert sum(m["filas"] for m in control.values()) == 41_169_720
    for periodo, m in control.items():
        assert sql[periodo] == m["filas"], periodo

    totales = consultar("SELECT (SELECT SUM(total) FROM dw.fact_viaje) + (SELECT SUM(ISNULL(total, 0)) "
                        "FROM qa.cuarentena_viaje) AS total", cn)
    esperado = sum(Decimal(m["suma_total_amount"]) for m in control.values())
    assert Decimal(str(totales.at[0, "total"])) == esperado


def test_particiones_un_mes_cada_una_y_puntas_vacias(cn):
    p = consultar("SELECT particion, desde_key, hasta_key, filas FROM lab.v_particiones_hecho ORDER BY particion", cn)
    assert len(p) == 14
    assert p.iloc[0]["filas"] == 0 and p.iloc[-1]["filas"] == 0      # requisito de SPLIT/MERGE sin mover datos
    meses = p.iloc[1:-1]
    assert list(meses["desde_key"]) == [20240000 + m * 100 + 1 for m in range(1, 13)]
    assert (meses["filas"] > 2_500_000).all()


def test_columnstore_ordenado_y_comprimido(cn):
    df = consultar("""
        SELECT i.type_desc, COUNT(*) AS grupos, SUM(IIF(g.state_desc = 'COMPRESSED', 1, 0)) AS comprimidos,
               MAX(g.total_rows) AS max_filas
        FROM sys.indexes AS i
        JOIN sys.dm_db_column_store_row_group_physical_stats AS g
          ON g.object_id = i.object_id AND g.index_id = i.index_id
        WHERE i.object_id = OBJECT_ID('dw.fact_viaje') AND g.total_rows > 0
        GROUP BY i.type_desc""", cn)
    assert df.at[0, "type_desc"] == "CLUSTERED COLUMNSTORE"
    assert df.at[0, "grupos"] == df.at[0, "comprimidos"]
    assert df.at[0, "max_filas"] == 1_048_576           # grupos de filas llenos


def test_carga_idempotente_omite_mes_ya_cargado(cn):
    antes = consultar("SELECT COUNT_BIG(*) AS n FROM dw.fact_viaje WHERE fecha_key BETWEEN 20240201 AND 20240229", cn)
    cn.cursor().execute("EXEC etl.sp_cargar_mes @periodo = '2024-02', @carpeta_datos = ?", CARPETA_DATOS)
    ultima = consultar("SELECT TOP (1) estado FROM qa.auditoria_carga WHERE periodo = '2024-02' ORDER BY carga_id DESC", cn)
    despues = consultar("SELECT COUNT_BIG(*) AS n FROM dw.fact_viaje WHERE fecha_key BETWEEN 20240201 AND 20240229", cn)
    assert ultima.at[0, "estado"] == "OMITIDO"
    assert int(despues.at[0, "n"]) == int(antes.at[0, "n"])


def test_recarga_forzada_deja_el_mismo_resultado(cn):
    """Recargar un mes completo (@forzar = 1) reemplaza su partición y deja exactamente las mismas cifras."""
    if not (RAIZ / "data" / "raw" / "yellow_tripdata_2024-02.csv").exists():
        pytest.skip("Falta el CSV de 2024-02 en data/raw: sin él la recarga dejaría un ERROR en la auditoría")
    sql = ("SELECT COUNT_BIG(*) AS n, SUM(total) AS t FROM dw.fact_viaje WHERE fecha_key BETWEEN 20240201 AND 20240229")
    antes = consultar(sql, cn)
    cuarentena_antes = consultar("SELECT COUNT(*) AS n FROM qa.cuarentena_viaje WHERE periodo = '2024-02'", cn)
    cur = cn.cursor()
    cur.execute("EXEC etl.sp_cargar_mes @periodo = '2024-02', @carpeta_datos = ?, @forzar = 1", CARPETA_DATOS)
    while cur.nextset():
        pass
    despues = consultar(sql, cn)
    cuarentena_despues = consultar("SELECT COUNT(*) AS n FROM qa.cuarentena_viaje WHERE periodo = '2024-02'", cn)
    assert antes.equals(despues)
    assert int(cuarentena_antes.at[0, "n"]) == int(cuarentena_despues.at[0, "n"])
    assert consultar("EXEC qa.sp_validar_calidad @lanzar_error = 0;", cn)["estado"].eq("OK").all()


def test_cuarentena_por_regla_coincide_con_la_clasificacion(cn):
    df = consultar("SELECT regla, COUNT(*) AS n FROM qa.cuarentena_viaje GROUP BY regla", cn)
    reglas = set(consultar("SELECT codigo FROM qa.regla_calidad", cn)["codigo"])
    assert set(df["regla"]) <= reglas
    assert df["n"].sum() < 41_169_720 * 0.03          # menos del 3 % en cuarentena


def test_ventana_deslizante_registrada_y_solo_metadatos(cn):
    log = consultar("SELECT operacion, filas, ms FROM lab.ventana_log ORDER BY id", cn)
    assert list(log["operacion"]) == ["SPLIT", "SWITCH OUT", "MERGE", "SPLIT", "SWITCH IN", "MERGE"]
    assert int(log.loc[log["operacion"] == "SWITCH OUT", "filas"].iloc[0]) > 2_900_000
    assert log["ms"].max() < 5_000                    # millones de filas movidas en milisegundos


def test_horas_pico_y_ventanas(cn):
    hp = consultar("SELECT dia_semana, rank_en_el_dia, pct_del_dia FROM mart.demanda_dia_hora", cn)
    assert len(hp) == 7 * 24
    assert (hp.groupby("dia_semana")["pct_del_dia"].sum().round(0) == 100).all()
    assert (hp[hp["rank_en_el_dia"] == 1].groupby("dia_semana").size() >= 1).all()
    dd = consultar("SELECT viajes, media_movil_7d FROM mart.demanda_diaria ORDER BY fecha", cn)
    assert float(dd["media_movil_7d"].iloc[6]) == pytest.approx(dd["viajes"].iloc[:7].mean(), abs=0.1)


def test_rutas_pareto(cn):
    r = consultar("SELECT rank_global, pct_acumulado FROM mart.ruta ORDER BY rank_global", cn)
    assert r["rank_global"].is_unique
    assert r["pct_acumulado"].is_monotonic_increasing
    assert float(r["pct_acumulado"].iloc[-1]) == pytest.approx(100, abs=0.01)


@pytest.mark.parametrize("vista", [
    "rpt.fact_viajes", "rpt.dim_fecha", "rpt.dim_hora", "rpt.dim_zona_origen", "rpt.dim_zona_destino",
    "rpt.dim_proveedor", "rpt.dim_tipo_pago", "rpt.dim_tarifa", "rpt.kpi_mensual", "rpt.horas_pico",
    "rpt.demanda_diaria", "rpt.rutas_top", "rpt.propinas_por_pago", "rpt.propinas_por_zona", "rpt.aeropuertos",
    "rpt.precio_por_milla", "rpt.auditoria_cargas", "rpt.cuarentena_por_mes", "rpt.cuadre_fuente",
    "rpt.benchmark_almacenamiento",
])
def test_vistas_powerbi_consultables(cn, vista):
    df = consultar(f"SELECT TOP (5) * FROM {vista}", cn)
    assert len(df) > 0
