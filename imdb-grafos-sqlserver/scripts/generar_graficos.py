"""
generar_graficos.py
Genera las figuras del README en reports/figures/ a partir de las vistas rpt
y de reports/metricas.json (ejecuta antes exportar_resultados.py).

Uso:  .venv\\Scripts\\python scripts\\generar_graficos.py
"""
from __future__ import annotations

import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import networkx as nx
import pandas as pd
from matplotlib.ticker import FuncFormatter

from conexion import consultar

RAIZ = Path(__file__).resolve().parents[1]
FIGURAS = RAIZ / "reports" / "figures"
METRICAS = RAIZ / "reports" / "metricas.json"

# Paleta categórica validada (validate_palette.js: PASS) y tokens de texto
AZUL, NARANJA, AQUA, MORADO = "#2a78d6", "#eb6834", "#1baf7a", "#7c5cd6"
GRIS_CONTEXTO = "#c9c8c2"
SUPERFICIE, TEXTO, TEXTO_2, REJILLA = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e0"

plt.rcParams.update({
    "figure.facecolor": SUPERFICIE, "axes.facecolor": SUPERFICIE, "savefig.facecolor": SUPERFICIE,
    "axes.edgecolor": REJILLA, "axes.labelcolor": TEXTO_2, "axes.titlecolor": TEXTO,
    "axes.titlesize": 12, "axes.titleweight": "bold", "axes.titlelocation": "left",
    "xtick.color": TEXTO_2, "ytick.color": TEXTO_2, "text.color": TEXTO,
    "font.family": "DejaVu Sans", "font.size": 9.5,
    "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": REJILLA, "grid.linewidth": 0.7,
})

miles = FuncFormatter(lambda v, _: f"{v:,.0f}".replace(",", "."))
FUENTE = "Fuente: IMDb Non-Commercial Datasets (uso personal y no comercial). Películas con ≥ 1.000 votos."


def n_es(valor: float, decimales: int = 0) -> str:
    """Formato numérico en español: 1234.5 -> 1.234,5"""
    return f"{valor:,.{decimales}f}".replace(",", "_").replace(".", ",").replace("_", ".")


def guardar(fig: plt.Figure, nombre: str) -> None:
    fig.savefig(FIGURAS / nombre, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  {nombre}")


def fig_peliculas_por_decada() -> None:
    df = consultar("SELECT decada, peliculas, calificacion_media FROM rpt.peliculas_por_decada "
                   "WHERE decada >= 1910 ORDER BY decada")
    fig, ax = plt.subplots(figsize=(10, 4.4))
    etiquetas = [f"{d}s\n★ {n_es(m, 2)}" for d, m in zip(df["decada"], df["calificacion_media"])]
    ax.bar(etiquetas, df["peliculas"], color=AZUL, width=0.75)
    for x, n in enumerate(df["peliculas"]):
        ax.annotate(n_es(n), (x, n), xytext=(0, 3), textcoords="offset points", ha="center", fontsize=8.5)
    ax.yaxis.set_major_formatter(miles)
    ax.grid(axis="x", visible=False)
    ax.set_title("Películas del catálogo filtrado por década (★ = calificación media)")
    ax.set_ylim(0, df["peliculas"].max() * 1.12)
    fig.text(0, -0.03, FUENTE + " La década de 2020 está incompleta (hasta oct-2026).", fontsize=8, color=TEXTO_2)
    guardar(fig, "01_peliculas_por_decada.png")


def fig_calificacion_por_genero() -> None:
    df = consultar("SELECT genero, peliculas, calificacion_media FROM rpt.genero_resumen "
                   "WHERE peliculas >= 100 ORDER BY calificacion_media")
    media = float(consultar("SELECT AVG(CAST(calificacion AS FLOAT)) AS m FROM dw.calificacion")["m"].iloc[0])
    fig, ax = plt.subplots(figsize=(9, 6.6))
    colores = [AZUL if v >= media else GRIS_CONTEXTO for v in df["calificacion_media"]]
    ax.barh(df["genero"], df["calificacion_media"] - 4, left=4, color=colores, height=0.72)
    for y, (v, n) in enumerate(zip(df["calificacion_media"], df["peliculas"])):
        ax.annotate(f"{n_es(v, 2)}  ·  {n_es(n)} películas", (v, y), xytext=(4, 0),
                    textcoords="offset points", va="center", fontsize=8, color=TEXTO_2)
    ax.axvline(media, color=TEXTO_2, lw=1, ls="--")
    ax.text(media, len(df) - 0.4, f" media del catálogo {n_es(media, 2)}", fontsize=8, color=TEXTO_2)
    ax.set_xlim(4, 8.6)
    ax.grid(axis="y", visible=False)
    ax.set_title("Calificación media por género (azul = sobre la media)")
    ax.set_xlabel("Calificación media de IMDb (1–10)")
    fig.text(0, -0.02, FUENTE + " Una película puede tener hasta 3 géneros.", fontsize=8, color=TEXTO_2)
    guardar(fig, "02_calificacion_por_genero.png")


def fig_evolucion_genero() -> None:
    generos = {"Drama": AZUL, "Comedy": NARANJA, "Horror": AQUA, "Sci-Fi": MORADO}
    df = consultar("SELECT genero, decada, calificacion_media, media_movil_3 FROM rpt.genero_decada "
                   f"WHERE genero IN ({','.join(repr(g) for g in generos)}) AND decada >= 1930 ORDER BY decada")
    fig, ax = plt.subplots(figsize=(10, 4.6))
    for g, color in generos.items():
        d = df[df["genero"] == g]
        ax.plot(d["decada"], d["calificacion_media"], color=color, lw=2, marker="o", ms=5, label=g)
        ax.annotate(f" {g}", (d["decada"].iloc[-1], d["calificacion_media"].iloc[-1]),
                    va="center", fontsize=9, color=TEXTO)
    ax.set_xticks(sorted(df["decada"].unique()))
    ax.set_xticklabels([f"{d}s" for d in sorted(df["decada"].unique())])
    ax.set_xlim(df["decada"].min() - 3, df["decada"].max() + 9)
    ax.set_title("Calificación media por década: todos los géneros bajan; terror y ciencia ficción, siempre al fondo")
    ax.set_ylabel("Calificación media")
    ax.legend(frameon=False, ncols=4, loc="lower left")
    fig.text(0, -0.03, FUENTE + " Solo celdas género-década con ≥ 20 películas.", fontsize=8, color=TEXTO_2)
    guardar(fig, "03_evolucion_calificacion_genero.png")


def fig_numero_bacon(m: dict) -> None:
    df = pd.DataFrame(m["bacon"]["distribucion"])
    df = df[df["grados"] > 0]
    fig, ax = plt.subplots(figsize=(9, 4.2))
    ax.bar(df["grados"].astype(str), df["personas"], color=AZUL, width=0.7)
    for x, (n, p) in enumerate(zip(df["personas"], df["pct_red"])):
        ax.annotate(f"{n_es(n)}\n{n_es(p, 1)} %", (x, n), xytext=(0, 3), textcoords="offset points",
                    ha="center", fontsize=8.5)
    ax.yaxis.set_major_formatter(miles)
    ax.grid(axis="x", visible=False)
    ax.set_ylim(0, df["personas"].max() * 1.22)
    ax.set_xlabel("Grados de separación con Kevin Bacon (SHORTEST_PATH sobre TrabajoCon)")
    ax.set_title(f"Número de Bacon: el {n_es(m['bacon']['pct_hasta_3_grados'], 1)} % de la red está a 3 grados o menos")
    fig.text(0, -0.04, FUENTE + f" Promedio: {n_es(m['bacon']['promedio_grados'], 2)} grados.",
             fontsize=8, color=TEXTO_2)
    guardar(fig, "04_numero_bacon.png")


def fig_subred_colaboracion() -> None:
    """Subred de Kevin Bacon: sus colaboradores con 2+ películas juntos y los lazos fuertes entre ellos."""
    nodos = consultar("""
        SELECT gp.persona_id, gp.nombre, c.peliculas_en_comun
        FROM dw.colaboracion AS c JOIN grafo.Persona AS gp ON gp.persona_id = c.persona_b
        WHERE c.persona_a = 102 AND c.peliculas_en_comun >= 2""")
    ids = ",".join(str(i) for i in nodos["persona_id"]) or "0"
    lazos = consultar(f"""
        SELECT persona_a, persona_b, peliculas_en_comun FROM dw.colaboracion
        WHERE persona_a IN ({ids}) AND persona_b IN ({ids}) AND persona_a < persona_b""")
    g = nx.Graph()
    g.add_node(102, nombre="Kevin Bacon")
    for r in nodos.itertuples():
        g.add_node(r.persona_id, nombre=r.nombre)
        g.add_edge(102, r.persona_id, peso=r.peliculas_en_comun, bacon=True)
    for r in lazos.itertuples():
        g.add_edge(r.persona_a, r.persona_b, peso=r.peliculas_en_comun, bacon=False)

    pos = nx.spring_layout(g, seed=7, k=1.1, weight="peso")
    fig, ax = plt.subplots(figsize=(11, 8.5))
    ax.axis("off")
    otros = [(u, v) for u, v, d in g.edges(data=True) if not d["bacon"]]
    del_bacon = [(u, v) for u, v, d in g.edges(data=True) if d["bacon"]]
    nx.draw_networkx_edges(g, pos, edgelist=otros, ax=ax, edge_color=GRIS_CONTEXTO,
                           width=[0.6 + 0.4 * g[u][v]["peso"] for u, v in otros])
    nx.draw_networkx_edges(g, pos, edgelist=del_bacon, ax=ax, edge_color=AZUL, alpha=0.55,
                           width=[0.8 + 0.8 * g[u][v]["peso"] for u, v in del_bacon])
    grado = dict(g.degree())
    nx.draw_networkx_nodes(g, pos, ax=ax, node_color=[NARANJA if n == 102 else AZUL for n in g.nodes],
                           node_size=[900 if n == 102 else 60 + 25 * grado[n] for n in g.nodes],
                           edgecolors=SUPERFICIE, linewidths=1.5)
    etiquetas = {n: g.nodes[n]["nombre"] for n in g.nodes}
    nx.draw_networkx_labels(g, pos, labels=etiquetas, ax=ax, font_size=7.5, font_color=TEXTO,
                            verticalalignment="bottom")
    ax.set_title(f"Subred de Kevin Bacon: {len(nodos)} colaboradores con 2 o más películas juntos y "
                 f"{len(lazos)} lazos entre ellos", loc="left")
    fig.text(0.02, 0.02, "Azul: lazo con Bacon (grosor = películas en común). Gris: lazos entre sus "
             "colaboradores. Tamaño del nodo = conexiones dentro de la subred.\n" + FUENTE,
             fontsize=8, color=TEXTO_2)
    guardar(fig, "05_subred_kevin_bacon.png")


def fig_rendimiento(m: dict) -> None:
    df = pd.DataFrame(m["rendimiento"])
    df["etiqueta"] = df["variante"]
    pruebas = list(dict.fromkeys(sorted(df["prueba"])))
    fig, ejes = plt.subplots(len(pruebas), 1, figsize=(10, 1.0 + 1.05 * len(df)),
                             height_ratios=[len(df[df["prueba"] == p]) for p in pruebas])
    for ax, p in zip(ejes, pruebas):
        d = df[df["prueba"] == p].sort_values("ms_mediana", ascending=False)
        rapido = d["ms_mediana"].min()
        colores = [AZUL if v == rapido else GRIS_CONTEXTO for v in d["ms_mediana"]]
        # Las consultas de menos de 1 ms se dibujan en 1 ms (el log no admite 0) y se rotulan "< 1 ms"
        ax.barh(d["etiqueta"], d["ms_mediana"].clip(lower=1), left=0.5, color=colores, height=0.65)
        ax.set_xscale("log")
        for y, (v, f) in enumerate(zip(d["ms_mediana"], d["filas"])):
            texto = "< 1 ms" if v < 1 else f"{n_es(v)} ms"
            ax.annotate(f"{texto} · resultado {n_es(f)}", (0.5 + max(v, 1), y), xytext=(4, 0),
                        textcoords="offset points", va="center", fontsize=8, color=TEXTO_2)
        ax.set_title(p, fontsize=10)
        ax.grid(axis="y", visible=False)
        ax.set_xlim(0.5, df["ms_mediana"].max() * 12)
    ejes[-1].set_xlabel("Mediana de 5 corridas con caché caliente, en ms (escala logarítmica)")
    fig.text(0, -0.01, "SQL Server 2025 Express (1 núcleo efectivo). Azul = la variante más rápida de cada prueba.",
             fontsize=8, color=TEXTO_2)
    fig.tight_layout()
    guardar(fig, "06_rendimiento_grafo_vs_relacional.png")


def fig_deciles_votos() -> None:
    df = consultar("SELECT decil, votos_min, votos_max, calificacion_media, participacion_votos "
                   "FROM rpt.decil_votos ORDER BY decil")
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 4))
    a1.bar(df["decil"].astype(str), df["participacion_votos"], color=AZUL)
    a1.annotate(f"{n_es(df['participacion_votos'].iloc[-1], 1)} %", (9, df["participacion_votos"].iloc[-1]),
                xytext=(0, 3), textcoords="offset points", ha="center", fontsize=9)
    a1.set_title("% de todos los votos por decil de popularidad")
    a1.set_xlabel("Decil de votos (1 = menos votadas)")
    a1.grid(axis="x", visible=False)
    a2.plot(df["decil"], df["calificacion_media"], color=AZUL, lw=2, marker="o", ms=6)
    for d, v in zip(df["decil"], df["calificacion_media"]):
        a2.annotate(n_es(v, 2), (d, v), xytext=(0, 6), textcoords="offset points", ha="center", fontsize=8)
    a2.set_title("Calificación media por decil")
    a2.set_xlabel("Decil de votos")
    a2.set_xticks(df["decil"])
    a2.set_ylim(df["calificacion_media"].min() - 0.3, df["calificacion_media"].max() + 0.3)
    fig.text(0, -0.04, FUENTE + " Deciles con NTILE(10) sobre el número de votos.", fontsize=8, color=TEXTO_2)
    fig.tight_layout()
    guardar(fig, "07_deciles_votos.png")


def main() -> None:
    FIGURAS.mkdir(parents=True, exist_ok=True)
    m = json.loads(METRICAS.read_text(encoding="utf-8"))
    fig_peliculas_por_decada()
    fig_calificacion_por_genero()
    fig_evolucion_genero()
    fig_numero_bacon(m)
    fig_subred_colaboracion()
    fig_rendimiento(m)
    fig_deciles_votos()


if __name__ == "__main__":
    main()
