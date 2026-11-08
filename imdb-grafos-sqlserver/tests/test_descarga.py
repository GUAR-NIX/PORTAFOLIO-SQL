"""Pruebas del script de descarga sin internet: descompresión, conteo y reanudación."""
from __future__ import annotations

import gzip
import json

import pytest

import descargar_datos as dd


@pytest.fixture()
def carpeta(tmp_path, monkeypatch):
    monkeypatch.setattr(dd, "CARPETA_RAW", tmp_path)
    return tmp_path


def escribir_gz(ruta, lineas: list[str]) -> None:
    with gzip.open(ruta, "wt", encoding="utf-8", newline="") as f:
        f.write("".join(lineas))


def test_descomprime_y_cuenta_filas_sin_cabecera(carpeta):
    escribir_gz(carpeta / "title.ratings.tsv.gz",
                ["tconst\taverageRating\tnumVotes\n", "tt0000001\t5.7\t2237\n", "tt0000002\t5.4\t327\n"])
    datos = dd.descomprimir_y_contar("title.ratings.tsv.gz")
    assert datos["filas_datos"] == 2
    assert datos["columnas"] == ["tconst", "averageRating", "numVotes"]
    assert (carpeta / "title.ratings.tsv").read_text(encoding="utf-8").startswith("tconst\t")


def test_conserva_utf8_y_el_nulo_de_imdb(carpeta):
    escribir_gz(carpeta / "name.basics.tsv.gz", ["nconst\tprimaryName\n", "nm1\tToshirô Mifune\n", "nm2\t\\N\n"])
    dd.descomprimir_y_contar("name.basics.tsv.gz")
    texto = (carpeta / "name.basics.tsv").read_text(encoding="utf-8")
    assert "Toshirô Mifune" in texto and "\\N" in texto


def test_no_reprocesa_si_ya_hay_marca_de_conteo(carpeta):
    (carpeta / "title.crew.tsv").write_text("x", encoding="utf-8")
    (carpeta / "title.crew.conteo.json").write_text(json.dumps({"filas_datos": 99}), encoding="utf-8")
    assert dd.descomprimir_y_contar("title.crew.tsv.gz")["filas_datos"] == 99   # el .gz ni existe


def test_descarga_completa_se_omite(carpeta, monkeypatch):
    (carpeta / "title.akas.tsv.gz").write_bytes(b"12345")
    monkeypatch.setattr(dd, "tamano_remoto", lambda url: (5, "hoy"))
    def no_descargar(*a, **k):  # pragma: no cover - no debe llamarse
        raise AssertionError("no debía descargar")
    monkeypatch.setattr(dd.urllib.request, "urlopen", no_descargar)
    assert dd.descargar("title.akas.tsv.gz")["bytes_gz"] == 5


def test_descarga_parcial_pide_solo_lo_que_falta(carpeta, monkeypatch):
    """Reanudación: con 3 de 8 bytes en .part, la petición lleva Range: bytes=3-."""
    (carpeta / "title.basics.tsv.gz.part").write_bytes(b"abc")
    monkeypatch.setattr(dd, "tamano_remoto", lambda url: (8, "hoy"))
    pedidos = []

    class Respuesta:
        status = 206
        def __init__(self): self._datos = [b"defgh"]
        def read(self, n=-1): return self._datos.pop() if self._datos else b""
        def __enter__(self): return self
        def __exit__(self, *a): return False

    def falso_urlopen(peticion, timeout=None):
        pedidos.append(peticion.get_header("Range"))
        return Respuesta()

    monkeypatch.setattr(dd.urllib.request, "urlopen", falso_urlopen)
    dd.descargar("title.basics.tsv.gz")
    assert pedidos == ["bytes=3-"]
    assert (carpeta / "title.basics.tsv.gz").read_bytes() == b"abcdefgh"
