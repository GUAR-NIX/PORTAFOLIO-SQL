"""Formato de números en español (miles con punto, decimales con coma)."""
from __future__ import annotations


def num(valor, decimales: int = 0) -> str:
    texto = f"{float(valor):,.{decimales}f}"
    return texto.replace(",", "X").replace(".", ",").replace("X", ".")


def pct(valor, decimales: int = 1) -> str:
    return f"{num(valor, decimales)} %"


def ms(valor) -> str:
    """Milisegundos con 3 cifras significativas aproximadas."""
    v = float(valor)
    if v >= 100:
        return num(v, 0)
    if v >= 10:
        return num(v, 1)
    return num(v, 2)


def veces(valor) -> str:
    v = float(valor)
    return f"{num(v, 0 if v >= 100 else 1)}x"


def mb(bytes_) -> str:
    v = float(bytes_) / 1048576
    return num(v, 0 if v >= 100 else (1 if v >= 1 else 3))
