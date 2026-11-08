"""Pruebas de integración sobre la base CitiBikeTuning en SQL Server Express."""

from __future__ import annotations

import json
from pathlib import Path

import pyodbc
import pytest

from conexion import conectar, consultar

RAIZ = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def cn():
    try:
        conexion = conectar()
    except pyodbc.Error as exc:  # pragma: no cover
        pytest.skip(f"SQL Server no disponible: {exc}")
    yield conexion
    conexion.close()


def test_controles_de_calidad_en_ok(cn) -> None:
    df = consultar("EXEC qa.sp_validar_calidad @lanzar_error = 0;", cn)
    assert len(df) >= 30
    alertas = df[df["estado"] != "OK"]
    assert alertas.empty, alertas[["orden", "control", "valor_observado", "valor_esperado"]].to_string()


def test_prueba_negativa_alteracion_dispara_alerta_y_revierte() -> None:
    """Si alguien altera una fila en lab.viaje_rowstore, el control de reconciliación lanza ALERTA."""
    try:
        cn_tx = conectar(autocommit=False)
    except pyodbc.Error as exc:  # pragma: no cover
        pytest.skip(f"SQL Server no disponible: {exc}")
    try:
        cur = cn_tx.cursor()
        cur.execute("UPDATE TOP (1) lab.viaje_rowstore SET duracion_seg = duracion_seg + 100;")
        cur.execute("EXEC qa.sp_validar_calidad @lanzar_error = 0;")
        filas = cur.fetchall()
        estado = {r.control: r.estado for r in filas}
        clave = next(c for c in estado if c.startswith("Suma de duración idéntica"))
        assert estado[clave] == "ALERTA"
        with pytest.raises(pyodbc.Error, match="ALERTA"):
            cur.execute("EXEC qa.sp_validar_calidad @lanzar_error = 1;")
            while cur.nextset():
                pass
    finally:
        cn_tx.rollback()
        cn_tx.close()


def test_reconciliacion_exacta_python_vs_sql(cn) -> None:
    """Conteos por motivo de exclusión, filas brutas y válidas: Python (pandas) = SQL Server."""
    control = json.loads((RAIZ / "data" / "cifras_control.json").read_text(encoding="utf-8"))
    df_sql = consultar("SELECT estado_calidad, filas FROM rpt.resumen_limpieza_calidad;", cn)
    observado = {r["estado_calidad"]: int(r["filas"]) for _, r in df_sql.iterrows()}
    assert observado == control["desglose_motivos"]
    brutas = consultar(
        "SELECT TOP (1) filas_afectadas FROM etl.bitacora_carga WHERE etapa = 'BULK_INSERT_STAGING' ORDER BY id_carga DESC;",
        cn,
    ).iloc[0, 0]
    assert int(brutas) == control["filas_totales_brutas"]
    validas = consultar("SELECT COUNT_BIG(*) FROM dw.fact_viaje;", cn).iloc[0, 0]
    assert int(validas) == control["filas_validas"]


def test_todas_las_variantes_devuelven_el_mismo_resultado(cn) -> None:
    """Ningún experimento se excluye: cada variante = mismas filas y mismo checksum que su ANTES."""
    df = consultar("SELECT * FROM rpt.resumen_experimentos_tuning ORDER BY id_experimento;", cn)
    assert df["grupo_experimento"].nunique() == 9
    for grupo, sub in df.groupby("grupo_experimento"):
        antes = sub[sub["rol_comparacion"] == "ANTES"]
        assert len(antes) == 1, grupo
        antes = antes.iloc[0]
        for _, fila in sub.iterrows():
            assert int(fila["filas_devueltas"]) == int(antes["filas_devueltas"]), (grupo, fila["codigo_experimento"])
            assert int(fila["checksum_resultado"]) == int(antes["checksum_resultado"]), (grupo, fila["codigo_experimento"])
        assert (sub["checksums_distintos"] == 1).all(), grupo


def test_despues_lee_menos_que_antes(cn) -> None:
    df = consultar("SELECT * FROM rpt.resumen_experimentos_tuning;", cn)
    for grupo, sub in df.groupby("grupo_experimento"):
        antes = int(sub.loc[sub["rol_comparacion"] == "ANTES", "lecturas_logicas"].iloc[0])
        despues = int(sub.loc[sub["rol_comparacion"] == "DESPUES", "lecturas_logicas"].iloc[0])
        assert despues < antes, grupo


def test_medicion_tiene_frio_y_caliente_con_5_corridas(cn) -> None:
    df = consultar("SELECT codigo_experimento, modo, COUNT(*) AS n FROM perf.medicion GROUP BY codigo_experimento, modo;", cn)
    assert set(df["modo"]) == {"CALIENTE", "FRIO"}
    assert (df["n"] == 5).all()
    neg = consultar("SELECT COUNT(*) FROM perf.medicion WHERE cpu_us < 0 OR lecturas_logicas < 0;", cn).iloc[0, 0]
    assert int(neg) == 0


def test_curva_tipping_point(cn) -> None:
    df = consultar("SELECT * FROM rpt.curva_tipping_point ORDER BY dias_ventana;", cn)
    assert len(df) == 6
    assert int(df.iloc[0]["lecturas_forzado_lookup"]) < int(df.iloc[0]["lecturas_heap_scan"])
    assert int(df.iloc[-1]["lecturas_forzado_lookup"]) > int(df.iloc[-1]["lecturas_heap_scan"])
    assert (df["lecturas_covering_seek"] < df["lecturas_forzado_lookup"]).all()
    assert (df["lecturas_covering_seek"] < df["lecturas_heap_scan"]).all()


def test_plan_forzado_con_query_store(cn) -> None:
    df = consultar("SELECT * FROM rpt.demo_plan_forzado ORDER BY paso;", cn)
    assert len(df) == 3
    assert int(df.loc[df["paso"] == 3, "plan_id"].iloc[0]) == int(df.loc[df["paso"] == 1, "plan_id"].iloc[0])
    assert bool(df.loc[df["paso"] == 3, "es_plan_forzado"].iloc[0])
    assert not bool(df.loc[df["paso"] == 3, "tiene_key_lookup"].iloc[0])


def test_tiempos_de_carga_registrados(cn) -> None:
    df = consultar("SELECT * FROM rpt.tiempos_carga;", cn)
    assert set(df["estrategia"]) == {"HEAP", "INDICES_DESPUES", "INDICES_ANTES"}
    assert (df["corridas"] == 3).all()


def test_compresion_columnstore(cn) -> None:
    df = consultar("SELECT * FROM rpt.huella_almacenamiento ORDER BY orden;", cn)
    assert len(df) == 4
    assert float(df.loc[df["orden"] == 4, "ratio_compresion_vs_heap"].iloc[0]) >= 3.0


@pytest.mark.parametrize(
    "vista",
    [
        "rpt.resumen_experimentos_tuning",
        "rpt.mediciones_corridas",
        "rpt.tiempos_carga",
        "rpt.demo_plan_forzado",
        "rpt.curva_tipping_point",
        "rpt.huella_almacenamiento",
        "rpt.auditoria_query_store",
        "rpt.kpi_mensual",
        "rpt.perfil_horario_semanal",
        "rpt.desbalance_estaciones_rebalanceo",
        "rpt.top_rutas_origen_destino",
        "rpt.resumen_limpieza_calidad",
    ],
)
def test_vistas_responden(cn, vista: str) -> None:
    assert len(consultar(f"SELECT TOP (5) * FROM {vista};", cn)) > 0


def test_reportes_coinciden_con_la_base(cn) -> None:
    """Los CSV de reports/ son los de la corrida que está en la base (no de otra corrida)."""
    import pandas as pd

    csv = pd.read_csv(RAIZ / "reports" / "tablas" / "experimentos_tuning.csv")
    sql = consultar("SELECT codigo_experimento, lecturas_logicas, duracion_ms_caliente FROM rpt.resumen_experimentos_tuning;", cn)
    unido = csv.merge(sql, on="codigo_experimento", suffixes=("_csv", "_sql"))
    assert len(unido) == len(sql)
    lecturas_iguales = (unido["lecturas_logicas_csv"] == unido["lecturas_logicas_sql"]).all()
    tiempos_iguales = (unido["duracion_ms_caliente_csv"].round(3) == unido["duracion_ms_caliente_sql"].astype(float).round(3)).all()
    if not (lecturas_iguales and tiempos_iguales):
        edicion = str(consultar("SELECT CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) AS edicion;", cn).iloc[0, 0])
        if "Express" not in edicion:  # las mediciones publicadas son de Express: en otra edición no son comparables
            pytest.skip(f"Reportes medidos en Express y base en {edicion}; compáralos con scripts/generar_graficos.py")
    assert lecturas_iguales
    assert tiempos_iguales


def test_planes_sqlplan_exportados() -> None:
    planes = list((RAIZ / "reports" / "planes").glob("*.sqlplan"))
    assert len(planes) >= 20
    for p in planes:
        texto = p.read_text(encoding="utf-8")
        assert "ShowPlanXML" in texto
