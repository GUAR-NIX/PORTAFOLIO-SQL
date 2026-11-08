"""
Pruebas del pipeline contra la base ImdbGrafos ya cargada
(ejecuta antes sql/00_EJECUTAR_TODO.sql). Si no hay SQL Server, se omiten.

    .venv\\Scripts\\python -m pytest -q
"""
from __future__ import annotations

import json
import warnings
from pathlib import Path

import pandas as pd
import pyodbc
import pytest

from conexion import conectar, consultar

RAIZ = Path(__file__).resolve().parents[1]
RAW = RAIZ / "data" / "raw"


@pytest.fixture(scope="module")
def cn():
    try:
        conexion = conectar()
    except pyodbc.Error as e:  # pragma: no cover - depende del entorno
        pytest.skip(f"SQL Server no disponible: {e}")
    yield conexion
    conexion.close()


def escalar(cn, sql: str):
    return cn.execute(sql).fetchone()[0]


# ---------- Calidad y conteos ----------

def test_controles_de_calidad_todos_ok(cn):
    df = consultar("EXEC qa.sp_validar_calidad @lanzar_error = 0;", cn)
    assert len(df) == 29
    alertas = df[df["estado"] != "OK"]
    assert alertas.empty, alertas[["orden", "control", "valor"]].to_string()


def test_auditoria_coincide_con_cifras_de_control_de_python(cn):
    """Las filas de cada TSV las cuenta Python al descomprimir; el motor debe leer las mismas."""
    control = json.loads((RAIZ / "data" / "cifras_control.json").read_text(encoding="utf-8"))
    aud = consultar("SELECT archivo, filas_fuente, filas_leidas, filas_cargadas FROM rpt.auditoria_carga", cn)
    aud = aud.set_index("archivo")
    assert set(aud.index) == set(control["archivos"])
    # filas_fuente es lo que contó Python en la descarga con la que se cargó esta base (03_carga_bulk.sql)
    for archivo, fila in aud.iterrows():
        assert fila["filas_leidas"] == fila["filas_fuente"], archivo
    # El filtro deja exactamente una fila de crew por película filtrada
    assert aud.loc["title.crew", "filas_cargadas"] == escalar(cn, "SELECT COUNT(*) FROM stg.pelicula_filtro")
    # IMDb publica datos nuevos cada día: el JSON del repositorio puede ser de otra descarga que la de la base
    otros = [a for a, info in control["archivos"].items() if aud.loc[a, "filas_fuente"] != info["filas_datos"]]
    if otros:
        warnings.warn(f"La base se cargó de otra descarga de IMDb que data/cifras_control.json: {otros}", stacklevel=1)


def test_filtro_recalculado_en_python_desde_los_tsv(cn):
    """Prueba independiente del motor: pandas aplica el mismo filtro sobre los TSV crudos."""
    if not (RAW / "title.basics.tsv").exists():
        pytest.skip("Faltan los TSV en data/raw (ejecuta scripts/descargar_datos.py)")
    votos = pd.read_csv(RAW / "title.ratings.tsv", sep="\t", usecols=["tconst", "numVotes"])
    votos = votos[votos["numVotes"] >= 1000]
    peliculas = set()
    for trozo in pd.read_csv(RAW / "title.basics.tsv", sep="\t", usecols=["tconst", "titleType", "isAdult"],
                             dtype=str, quoting=3, chunksize=2_000_000):
        sel = trozo[(trozo["titleType"] == "movie") & (trozo["isAdult"] == "0")]
        peliculas.update(sel["tconst"])
    esperado = len(peliculas & set(votos["tconst"]))
    assert escalar(cn, "SELECT COUNT(*) FROM dw.pelicula") == esperado


def test_conteos_del_grafo(cn):
    nodos = escalar(cn, "SELECT COUNT(*) FROM grafo.Persona")
    pares = escalar(cn, "SELECT COUNT(*) FROM grafo.TrabajoCon")
    assert escalar(cn, "SELECT COUNT(*) FROM grafo.Pelicula") == escalar(cn, "SELECT COUNT(*) FROM dw.pelicula")
    assert nodos > 150_000
    assert pares % 2 == 0                       # cada colaboración en los dos sentidos
    assert escalar(cn, "SELECT COUNT(*) FROM dw.colaboracion") == pares


# ---------- Grafo ----------

def grados(cn, origen: str, destino: str) -> pd.DataFrame:
    return consultar(f"""
        DECLARE @o INT = grafo.fn_buscar_persona('{origen}'), @d INT = grafo.fn_buscar_persona('{destino}');
        EXEC grafo.sp_grados_separacion @origen = @o, @destino = @d;""", cn)


def test_camino_conocido_bacon_hanks_apollo_13(cn):
    camino = grados(cn, "Kevin Bacon", "Tom Hanks")
    assert len(camino) == 1
    assert camino.loc[0, "grados"] == 1
    assert camino.loc[0, "pelicula"] == "Apollo 13"


def test_camino_mas_corto_bacon_shah_rukh_khan(cn):
    camino = grados(cn, "Kevin Bacon", "Shah Rukh Khan")
    assert camino["grados"].iloc[0] == 3 == len(camino)
    assert camino["desde"].iloc[0] == "Kevin Bacon" and camino["hacia"].iloc[-1] == "Shah Rukh Khan"
    # Cada salto es una coincidencia real en una película (verificado en el modelo relacional)
    for r in camino.itertuples():
        comun = escalar(cn, f"""
            SELECT COUNT(*) FROM dw.participacion AS a
            JOIN dw.participacion AS b ON b.pelicula_id = a.pelicula_id
            WHERE a.persona_id = {r.desde_id} AND b.persona_id = {r.hacia_id}""")
        assert comun > 0, r


def test_shortest_path_coincide_con_bfs_iterativo(cn):
    """Dos algoritmos distintos (SHORTEST_PATH del motor y un BFS en T-SQL) dan la misma distancia."""
    for origen, destino in [("Kevin Bacon", "Shah Rukh Khan"), ("Penélope Cruz", "Bruce Lee"),
                            ("Ricardo Darín", "Toshirô Mifune")]:
        sp = grados(cn, origen, destino)["grados"].iloc[0]
        bfs = escalar(cn, f"""
            SET NOCOUNT ON;
            DECLARE @o INT = grafo.fn_buscar_persona('{origen}'), @d INT = grafo.fn_buscar_persona('{destino}'), @g INT;
            EXEC grafo.sp_grados_bfs @origen = @o, @destino = @d, @grados = @g OUTPUT;
            SELECT @g;""")
        assert sp == bfs, (origen, destino)


def test_numero_bacon_uno_son_sus_colaboradores_directos(cn):
    directos = consultar("EXEC grafo.sp_colaboradores @persona_id = 102, @top = 100000;", cn)
    bacon1 = escalar(cn, "SELECT COUNT(*) FROM mart.numero_bacon WHERE grados = 1")
    assert len(directos) == bacon1
    assert "Tom Hanks" in set(directos["nombre"])


def test_elenco_fiel_tiene_tres_o_mas_peliculas(cn):
    assert escalar(cn, "SELECT MIN(peliculas) FROM mart.elenco_fiel") >= 3
    kurosawa = escalar(cn, """SELECT peliculas FROM mart.elenco_fiel
                              WHERE director = 'Akira Kurosawa' AND actor = 'Toshirô Mifune'""")
    assert kurosawa >= 10


def test_control_detecta_arista_asimetrica():
    """Prueba negativa: si falta la arista inversa de TrabajoCon, el control 20 lo detecta (y se revierte)."""
    try:
        cn = conectar(autocommit=False)
    except pyodbc.Error as e:  # pragma: no cover
        pytest.skip(f"SQL Server no disponible: {e}")
    try:
        cur = cn.cursor()
        cur.execute("DELETE TOP (1) FROM grafo.TrabajoCon;")
        cur.execute("EXEC qa.sp_validar_calidad @lanzar_error = 0;")
        filas = {r.orden: r.estado for r in cur.fetchall()}
        assert filas[20] == "ALERTA"
        assert filas[22] == "ALERTA"         # la suma de pesos tampoco cuadra
    finally:
        cn.rollback()
        cn.close()


# ---------- Búsqueda de texto ----------

def buscar(cn, consulta: str, modo: str = "todas", top: int = 1000) -> pd.DataFrame:
    return consultar(f"EXEC busqueda.sp_buscar @consulta = '{consulta}', @modo = '{modo}', @top = {top};", cn)


def test_busqueda_padrino_encuentra_the_godfather_por_titulo_alternativo(cn):
    r = buscar(cn, "padrino")
    assert r["titulo"].iloc[0] == "The Godfather"
    assert {"The Godfather", "The Godfather Part II", "The Godfather Part III"} <= set(r["titulo"])


def test_busqueda_ignora_tildes_y_admite_prefijo(cn):
    assert "Amélie" in set(buscar(cn, "amelie")["titulo"])
    r = buscar(cn, "señor anill*")
    assert r["titulo"].iloc[0].startswith("The Lord of the Rings")


def test_like_trae_falsos_positivos_que_el_indice_no(cn):
    """LIKE '%war%' también encuentra 'Warrior', 'Edward', 'Stewart'...; el índice busca la palabra."""
    indice = buscar(cn, "war", top=100000)
    like = consultar("EXEC busqueda.sp_buscar_like @texto = 'war', @top = 100000;", cn)
    assert len(like) > len(indice)
    falsos = set(like["pelicula_id"]) - set(indice["pelicula_id"])
    textos = like[like["pelicula_id"].isin(falsos)]["texto_encontrado"].str.lower()
    assert textos.str.contains(r"\w+war|war\w+", regex=True).any()


def test_full_text_o_alternativa_disponible(cn):
    instalado = escalar(cn, "SELECT CAST(FULLTEXTSERVICEPROPERTY('IsFullTextInstalled') AS INT)")
    if instalado == 1:
        assert escalar(cn, "SELECT COUNT(*) FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID('busqueda.titulo')") == 1
    else:
        assert escalar(cn, "SELECT COUNT(*) FROM busqueda.indice") > 1_000_000


# ---------- Analítica ----------

def test_mejor_drama_de_los_90_es_shawshank(cn):
    titulo = escalar(cn, """SELECT titulo FROM mart.mejor_decada_genero
                            WHERE decada = 1990 AND genero = 'Drama' AND puesto = 1""")
    assert titulo == "The Shawshank Redemption"


def test_percentiles_ordenados(cn):
    p = consultar("SELECT * FROM rpt.percentil_votos WHERE decada = 0", cn).iloc[0]
    assert 1000 <= p["p25"] <= p["p50"] <= p["p75"] <= p["p90"] <= p["p99"] <= p["maximo"]


def test_vistas_powerbi_responden(cn):
    vistas = consultar("SELECT name FROM sys.views WHERE schema_id = SCHEMA_ID('rpt')", cn)["name"]
    assert len(vistas) >= 19
    for v in vistas:
        cn.execute(f"SELECT TOP (1) * FROM rpt.[{v}]").fetchall()
