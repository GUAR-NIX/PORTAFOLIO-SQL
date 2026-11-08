"""La CTE recursiva de retrasos en cadena, probada con un avión inventado.

Los tramos de prueba se insertan en dw.tramo_avion dentro de una transacción
(fecha 2099-01-01, matrícula TEST1) y se descartan con ROLLBACK al terminar.

Día del avión TEST1 (retraso de salida / de llegada, en minutos):
    1  AAA→BBB   0 /  5   a tiempo
    2  BBB→CCC  50 / 60   raíz: llega tarde y el tramo anterior llegó a tiempo
    3  CCC→DDD  30 / 20   paso 1: sale tarde porque el avión llegó tarde
    4  DDD→EEE  10 /  0   recupera el horario: la cadena se corta
    5  EEE→FFF  25 / 30   nueva raíz
    6  XXX→YYY  40 / 45   no sale de FFF (otro aeropuerto): no es paso de la cadena
                          y tampoco raíz, porque el tramo anterior llegó tarde
"""
from __future__ import annotations

import pytest

pytestmark = pytest.mark.db

TRAMOS = [
    # n, origen, destino, ret_salida, ret_llegada, continua
    (1, 9001, 9002, 0, 5, False),
    (2, 9002, 9003, 50, 60, True),
    (3, 9003, 9004, 30, 20, True),
    (4, 9004, 9005, 10, 0, True),
    (5, 9005, 9006, 25, 30, True),
    (6, 9100, 9101, 40, 45, False),
]


@pytest.fixture
def avion_de_prueba(con):
    with con.cursor() as cur:
        anterior = None
        for n, o, d, rs, rl, continua in TRAMOS:
            cur.execute(
                """INSERT INTO dw.tramo_avion
                       (matricula, fecha_vuelo, n_tramo, tramos_del_dia, id_vuelo, aerolinea,
                        origen_id, destino_id, hora_salida_local,
                        salida_prog_utc, llegada_prog_utc, retraso_salida, retraso_llegada,
                        retraso_avion_previo, retraso_llegada_anterior, holgura_prog_min, continua)
                   VALUES ('TEST1', DATE '2099-01-01', %s, 6, %s, 'ZZ', %s, %s, 6 + 2 * %s,
                           TIMESTAMPTZ '2099-01-01 06:00+00' + make_interval(hours => 2 * %s),
                           TIMESTAMPTZ '2099-01-01 07:15+00' + make_interval(hours => 2 * %s),
                           %s, %s, 0, %s, 45, %s)""",
                (n, -n, o, d, n, n, n, rs, rl, anterior, continua))
            anterior = rl
    yield
    con.rollback()


def _cadena(con, umbral=15):
    with con.cursor() as cur:
        cur.execute("""SELECT tramo_raiz, paso, n_tramo, retraso_raiz
                         FROM analisis.cadenas_retraso(DATE '2099-01-01', DATE '2099-01-01', %s)
                        WHERE matricula = 'TEST1'
                        ORDER BY tramo_raiz, paso""", (umbral,))
        return cur.fetchall()


def test_cadena_conocida(con, avion_de_prueba):
    assert _cadena(con) == [
        (2, 0, 2, 60),   # raíz
        (2, 1, 3, 60),   # el retraso de 60 min pasa al tramo 3
        (5, 0, 5, 30),   # segunda raíz; el tramo 6 no continúa (otro aeropuerto)
    ]


def test_umbral_mas_alto_corta_la_cadena(con, avion_de_prueba):
    # Con 60 min, el tramo 2 sigue siendo raíz, pero el 3 sale solo 30 min tarde.
    assert _cadena(con, umbral=60) == [(2, 0, 2, 60)]


def test_sin_retrasos_no_hay_cadenas(con, avion_de_prueba):
    assert _cadena(con, umbral=1000) == []


def test_resumen_del_anio_es_coherente(con):
    with con.cursor() as cur:
        cur.execute("SELECT metrica, valor FROM analisis.cadena_resumen")
        r = {m: float(v) for m, v in cur.fetchall()}
        cur.execute("SELECT sum(vuelos) FILTER (WHERE paso > 0), max(vuelos) FILTER (WHERE paso = 0) "
                    "FROM analisis.cadena_por_paso")
        aguas_abajo, raices = cur.fetchone()
    assert r["raices"] == raices
    assert r["vuelos_afectados_aguas_abajo"] == aguas_abajo
    assert 0 < r["pct_propagan"] < 100
    assert r["largo_maximo"] >= 3
