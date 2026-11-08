"""La base cuadra con los CSV de BTS (cifras calculadas en Python, sin pasar por PostgreSQL)."""
from __future__ import annotations

import pytest

pytestmark = pytest.mark.db

METRICAS = ["filas", "cancelados", "desviados", "con_retraso_15", "suma_retraso_llegada",
            "suma_retraso_salida", "suma_distancia", "suma_late_aircraft", "sin_matricula",
            "dias", "aerolineas"]


def _cifras_sql(con) -> dict:
    with con.cursor() as cur:
        cur.execute(f"SELECT anio_mes, {', '.join(METRICAS)}, fecha_min, fecha_max FROM control.cifras_mes")
        columnas = [c.name for c in cur.description]
        return {f"{r[0] // 100}-{r[0] % 100:02d}": dict(zip(columnas, r)) for r in cur.fetchall()}


def test_mismos_meses_en_csv_y_en_base(con, cifras_csv):
    assert set(_cifras_sql(con)) == set(cifras_csv["meses"])


@pytest.mark.parametrize("metrica", METRICAS)
def test_cifra_de_control_por_mes(con, cifras_csv, metrica):
    sql = _cifras_sql(con)
    for mes, csv_mes in cifras_csv["meses"].items():
        assert float(sql[mes][metrica]) == pytest.approx(csv_mes[metrica], abs=0.05), (mes, metrica)


def test_rango_de_fechas_por_mes(con, cifras_csv):
    sql = _cifras_sql(con)
    for mes, csv_mes in cifras_csv["meses"].items():
        assert sql[mes]["fecha_min"].isoformat() == csv_mes["fecha_min"]
        assert sql[mes]["fecha_max"].isoformat() == csv_mes["fecha_max"]


def test_csv_de_bts_tiene_109_columnas_mas_coma_final(cifras_csv):
    assert {m["columnas_csv"] for m in cifras_csv["meses"].values()} == {110}


def test_auditoria_de_carga(con, cifras_csv):
    with con.cursor() as cur:
        cur.execute("SELECT count(*), count(*) FILTER (WHERE estado = 'OK'), sum(filas_copiadas), "
                    "sum(filas_tipadas) FROM control.carga_mes")
        meses, ok, copiadas, tipadas = cur.fetchone()
    assert meses == ok == len(cifras_csv["meses"])
    assert copiadas == tipadas == sum(m["filas"] for m in cifras_csv["meses"].values())


def test_copiadas_igual_a_hecho_mas_cuarentena(con):
    with con.cursor() as cur:
        cur.execute("SELECT count(*) FILTER (WHERE diferencia <> 0), sum(filas_hecho + filas_cuarentena), "
                    "sum(filas_copiadas) FROM control.v_reconciliacion")
        descuadres, hecho_mas_q, copiadas = cur.fetchone()
    assert descuadres == 0
    assert hecho_mas_q == copiadas


def test_cancelados_y_desviados_del_hecho_cuadran_con_el_csv(con, cifras_csv):
    """Ningún cancelado ni desviado cayó en cuarentena sin dejar rastro."""
    with con.cursor() as cur:
        cur.execute("""SELECT (SELECT count(*) FROM dw.fact_vuelo WHERE cancelado)
                            + (SELECT count(*) FROM calidad.vuelo_cuarentena
                                WHERE (fila_staging->>'cancelado')::boolean),
                              (SELECT count(*) FROM dw.fact_vuelo WHERE desviado)
                            + (SELECT count(*) FROM calidad.vuelo_cuarentena
                                WHERE (fila_staging->>'desviado')::boolean)""")
        cancelados, desviados = cur.fetchone()
    assert cancelados == sum(m["cancelados"] for m in cifras_csv["meses"].values())
    assert desviados == sum(m["desviados"] for m in cifras_csv["meses"].values())


def test_todas_las_verificaciones_sql_pasan(con):
    with con.cursor() as cur:
        cur.execute("SELECT control FROM control.verificacion WHERE NOT ok")
        assert cur.fetchall() == []
        cur.execute("SELECT count(*) FROM control.verificacion")
        assert cur.fetchone()[0] >= 14
