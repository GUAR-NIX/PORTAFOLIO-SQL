"""Genera las figuras de reports/figures/ a partir de reports/tablas/*.csv."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

RAIZ = Path(__file__).resolve().parents[1]
TABLAS = RAIZ / "reports" / "tablas"
FIGURAS = RAIZ / "reports" / "figures"

# Paleta categórica validada (orden fijo) y tintas de texto
AZUL, NARANJA, AQUA, AMARILLO, MAGENTA, VERDE, VIOLETA, ROJO = (
    "#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948")
GRIS, TINTA, TINTA2 = "#b9b8b1", "#0b0b0b", "#52514e"
MESES = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]
plt.rcParams.update({
    "figure.dpi": 110, "savefig.dpi": 130, "savefig.bbox": "tight",
    "font.size": 10, "axes.titlesize": 12, "axes.titleweight": "bold",
    "axes.edgecolor": GRIS, "axes.labelcolor": TINTA2, "xtick.color": TINTA2, "ytick.color": TINTA2,
    "axes.spines.top": False, "axes.spines.right": False, "axes.grid": True,
    "grid.color": "#e6e5e0", "grid.linewidth": 0.7, "axes.axisbelow": True,
    "figure.facecolor": "white", "axes.facecolor": "white",
})


def leer(nombre: str) -> pd.DataFrame:
    return pd.read_csv(TABLAS / f"{nombre}.csv")


def miles(x: float) -> str:
    return f"{x:,.0f}".replace(",", ".")


def guardar(fig, nombre: str) -> None:
    fig.savefig(FIGURAS / nombre)
    plt.close(fig)


def fig_aerolineas() -> None:
    df = leer("ranking_aerolineas").sort_values("pct_puntuales")
    fig, ax = plt.subplots(figsize=(8.5, 5.2))
    y = np.arange(len(df))
    ax.barh(y, df["pct_puntuales"], color=AZUL, height=0.62)
    for yi, (pct, canc) in enumerate(zip(df["pct_puntuales"], df["pct_cancelados"])):
        ax.text(pct + 0.4, yi, f"{pct:.1f} %  ·  {canc:.1f} % cancelados".replace(".", ","),
                va="center", fontsize=8.5, color=TINTA2)
    ax.set_yticks(y, [f"{a} · {n[:28]}" for a, n in zip(df["aerolinea"], df["nombre"])], fontsize=8.5)
    ax.set_xlim(0, 100)
    ax.set_xlabel("% de vuelos programados que llegan con menos de 15 min de retraso")
    ax.set_title("Puntualidad por aerolínea, 2024 (cancelados y desviados cuentan como no puntuales)")
    ax.grid(axis="y", visible=False)
    guardar(fig, "01_puntualidad_aerolineas.png")


def fig_hora_dia() -> None:
    df = leer("hora_dia_semana")
    tabla = df.pivot(index="dia_semana", columns="hora", values="pct_salidas_retrasadas")
    vuelos = df.pivot(index="dia_semana", columns="hora", values="programados")
    tabla = tabla.where(vuelos >= 500)  # horas con muy pocos vuelos (madrugada) quedan en blanco
    nombres = df.drop_duplicates("dia_semana").set_index("dia_semana")["nombre_dia"]
    fig, ax = plt.subplots(figsize=(10, 3.6))
    im = ax.imshow(tabla.values, cmap="Blues", aspect="auto", vmin=0)
    ax.set_xticks(range(tabla.shape[1]), tabla.columns)
    ax.set_yticks(range(tabla.shape[0]), [nombres[i] for i in tabla.index])
    ax.grid(False)
    for i in range(tabla.shape[0]):
        for j in range(tabla.shape[1]):
            v = tabla.values[i, j]
            if not np.isnan(v):
                ax.text(j, i, f"{v:.0f}", ha="center", va="center", fontsize=7,
                        color="white" if v > np.nanmax(tabla.values) * 0.6 else TINTA)
    ax.set_xlabel("Hora programada de salida (local del aeropuerto de origen)")
    ax.set_title("% de salidas con 15+ min de retraso por hora y día de la semana")
    fig.colorbar(im, ax=ax, fraction=0.025, pad=0.01, label="%")
    guardar(fig, "02_retraso_hora_dia_semana.png")


def fig_causas() -> None:
    df = leer("causas_mes")
    orden = ["avion_previo", "aerolinea", "nas", "clima", "seguridad"]
    etiquetas = {"avion_previo": "Avión anterior tarde", "aerolinea": "Aerolínea",
                 "nas": "Sistema aéreo (NAS)", "clima": "Clima extremo", "seguridad": "Seguridad"}
    colores = [AZUL, NARANJA, AQUA, AMARILLO, MAGENTA]
    tabla = df.pivot(index="mes", columns="causa", values="minutos")[orden] / 1e6
    meses = [MESES[m - 1] for m in pd.to_datetime(tabla.index).month]
    fig, ax = plt.subplots(figsize=(9, 4.4))
    abajo = np.zeros(len(tabla))
    for causa, color in zip(orden, colores):
        ax.bar(meses, tabla[causa], bottom=abajo, color=color, width=0.7,
               edgecolor="white", linewidth=1.5, label=etiquetas[causa])
        abajo += tabla[causa].values
    ax.set_ylabel("Millones de minutos de retraso")
    ax.set_title("Minutos de retraso por causa y mes (llegadas con 15+ min)")
    ax.legend(frameon=False, ncol=3, fontsize=8.5, loc="upper left")
    ax.grid(axis="x", visible=False)
    guardar(fig, "03_causas_retraso_mes.png")


def fig_serie() -> None:
    df = leer("serie_diaria")
    df["fecha"] = pd.to_datetime(df["fecha"])
    fig, ax = plt.subplots(figsize=(11, 4.4))
    ax.plot(df["fecha"], df["pct_puntuales"], color=GRIS, linewidth=1, label="Día")
    ax.plot(df["fecha"], df["pct_puntuales_media_7d"], color=AZUL, linewidth=2, label="Media móvil 7 días")
    fer = df[df["feriado"].notna()]
    ax.scatter(fer["fecha"], fer["pct_puntuales"], color=NARANJA, s=36, zorder=3,
               edgecolor="white", linewidth=1.5, label="Feriado federal")
    # Peor día de cada episodio (días peores separados por al menos 3 semanas)
    elegidos = []
    for _, f in df.sort_values("pct_puntuales").iterrows():
        if all(abs((f["fecha"] - e["fecha"]).days) > 21 for e in elegidos):
            elegidos.append(f)
        if len(elegidos) == 3:
            break
    for f in elegidos:
        ax.annotate(f"{f['fecha'].day} {MESES[f['fecha'].month - 1]}: {f['pct_puntuales']:.0f} %",
                    (f["fecha"], f["pct_puntuales"]), xytext=(7, -3), textcoords="offset points",
                    fontsize=8.5, color=TINTA)
    ax.set_ylabel("% puntuales")
    ax.set_title("Puntualidad diaria en 2024")
    ax.legend(frameon=False, fontsize=8.5, loc="lower right")
    guardar(fig, "04_puntualidad_diaria_feriados.png")


def fig_cadenas() -> None:
    paso = leer("cadena_por_paso")
    hora = leer("cadena_por_hora_raiz")
    hora = hora[hora["raices"] >= 500]
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 4.2))
    p = paso[paso["paso"] <= 6]
    a1.bar(p["paso"], p["pct_de_raices"], color=AZUL, width=0.6)
    for x, v, ms in zip(p["paso"], p["pct_de_raices"], p["retraso_salida_medio"]):
        a1.text(x, v + 1.5, f"{v:.1f} %\n{ms:.0f} min".replace(".", ","), ha="center", fontsize=8, color=TINTA2)
    a1.set_xlabel("Tramos después del retraso raíz")
    a1.set_ylabel("% de retrasos raíz que siguen propagándose")
    a1.set_ylim(0, 115)
    a1.set_title("¿Hasta dónde llega un retraso?")
    a1.grid(axis="x", visible=False)
    a2.plot(hora["hora_raiz"], hora["vuelos_afectados_por_raiz"], color=NARANJA, linewidth=2, marker="o", ms=5)
    a2.set_xlabel("Hora local de salida del tramo con el retraso raíz")
    a2.set_ylabel("Vuelos posteriores afectados por raíz")
    a2.set_title("Un retraso temprano arrastra más vuelos")
    guardar(fig, "05_retrasos_en_cadena.png")


def fig_rendimiento() -> None:
    res = json.loads((RAIZ / "reports" / "resultados.json").read_text(encoding="utf-8"))["rendimiento"]
    df = pd.DataFrame(res)
    titulos = {"P1": "P1 · Poda de particiones (1 mes)", "P2": "P2 · BRIN vs B-tree (1 semana)",
               "P3": "P3 · BRIN sin correlación", "P4": "P4 · Índice parcial (cancelados)",
               "P5": "P5 · Historial de un avión", "P6": "P6 · Vista materializada"}
    color_rol = {"Antes": GRIS, "Intermedio": AMARILLO, "Alternativa": NARANJA, "Después": AZUL}
    fig, ejes = plt.subplots(2, 3, figsize=(13, 6.6))
    for ax, (exp, g) in zip(ejes.flat, df.groupby("experimento")):
        g = g.sort_values("orden")
        y = np.arange(len(g))[::-1]
        ax.barh(y, g["ms_mediana"], color=[color_rol[r] for r in g["rol"]], height=0.6)
        ax.set_xscale("log")
        ax.set_yticks(y, [v.replace(", ", ",\n") for v in g["variante"]], fontsize=8)
        for yi, ms, x in zip(y, g["ms_mediana"], g["x_vs_antes"]):
            txt = f"{ms:,.1f} ms".replace(",", "X").replace(".", ",").replace("X", ".")
            if x != 1:
                txt += f"  ({x:,.1f}x)".replace(".", ",")
            ax.text(ms * 1.15, yi, txt, va="center", fontsize=8, color=TINTA2)
        ax.set_xlim(right=g["ms_mediana"].max() * 40)
        ax.set_title(titulos[exp], fontsize=10.5)
        ax.grid(axis="y", visible=False)
    for ax in ejes[1]:
        ax.set_xlabel("ms (mediana de 7 corridas, escala log)")
    fig.suptitle("EXPLAIN (ANALYZE, BUFFERS): antes (gris) y después (azul)", fontweight="bold")
    fig.tight_layout()
    guardar(fig, "06_rendimiento_antes_despues.png")


def fig_brin() -> None:
    idx = leer("indices_lab")
    idx = idx[idx["columna"] == "fecha_vuelo"].copy()
    idx["etiqueta"] = np.where(idx["tipo"] == "BRIN", "BRIN " + idx["pages_per_range"].astype("Int64").astype(str) + " pág.", "B-tree")
    res = pd.DataFrame(json.loads((RAIZ / "reports" / "resultados.json").read_text(encoding="utf-8"))["rendimiento"])
    p2 = res[res["experimento"] == "P2"].set_index("variante")["ms_mediana"]
    consulta = {"B-tree": p2.get("B-tree (fecha)"), "BRIN 128 pág.": p2.get("BRIN 128 páginas"),
                "BRIN 32 pág.": p2.get("BRIN 32 páginas")}
    fig, ejes = plt.subplots(1, 3, figsize=(12, 3.6))
    datos = [("Tamaño del índice (MB, log)", idx["mb"], True),
             ("Tiempo de creación (s)", idx["segundos_creacion_mediana"], False),
             ("Consulta de una semana (ms)", idx["etiqueta"].map(consulta), False)]
    colores = [NARANJA if t == "B-tree" else AZUL for t in idx["tipo"]]
    for ax, (titulo, valores, log) in zip(ejes, datos):
        ax.bar(idx["etiqueta"], valores, color=colores, width=0.6)
        if log:
            ax.set_yscale("log")
        for x, v in enumerate(valores):
            ax.text(x, v * (1.15 if log else 1.02), f"{v:,.3g}".replace(".", ","), ha="center", fontsize=8.5, color=TINTA2)
        ax.set_title(titulo, fontsize=10.5)
        ax.grid(axis="x", visible=False)
    fig.suptitle("BRIN frente a B-tree sobre fecha_vuelo (lab.vuelo_plano, ~7 M filas sin particionar)",
                 fontweight="bold")
    fig.tight_layout()
    guardar(fig, "07_brin_vs_btree.png")


def fig_calidad() -> None:
    df = leer("calidad_reglas")
    df = df[df["vuelos"] > 0].sort_values("vuelos")
    fig, ax = plt.subplots(figsize=(9, 4.6))
    colores = [NARANJA if t == "cuarentena" else AZUL for t in df["tipo"]]
    ax.barh(df["codigo"], df["vuelos"], color=colores, height=0.6)
    ax.set_xscale("log")
    for y, v in enumerate(df["vuelos"]):
        ax.text(v * 1.15, y, miles(v), va="center", fontsize=8.5, color=TINTA2)
    ax.set_xlim(right=df["vuelos"].max() * 8)
    ax.set_xlabel("Vuelos (escala log)")
    ax.set_title("Reglas de calidad: cuarentena (naranja) y marcas (azul)")
    ax.grid(axis="y", visible=False)
    guardar(fig, "08_calidad_reglas.png")


def fig_rutas_aeropuertos() -> None:
    ap = leer("ranking_aeropuertos")
    sel = pd.concat([ap.head(8), ap.tail(8)]).sort_values("pct_salidas_puntuales")
    fig, ax = plt.subplots(figsize=(8.5, 5))
    colores = [NARANJA if r > len(ap) / 2 else AZUL for r in sel["rango_nacional"]]
    ax.barh(sel["iata"], sel["pct_salidas_puntuales"], color=colores, height=0.6)
    for y, (v, r) in enumerate(zip(sel["pct_salidas_puntuales"], sel["rango_nacional"])):
        ax.text(v + 0.4, y, f"{v:.1f} % · puesto {r} de {len(ap)}".replace(".", ",", 1), va="center", fontsize=8, color=TINTA2)
    ax.set_xlim(0, 100)
    ax.set_xlabel("% de salidas con menos de 15 min de retraso")
    ax.set_title(f"Los 8 mejores (azul) y 8 peores (naranja) de {len(ap)} aeropuertos con 20.000+ salidas")
    ax.grid(axis="y", visible=False)
    guardar(fig, "09_ranking_aeropuertos.png")


def main() -> int:
    FIGURAS.mkdir(parents=True, exist_ok=True)
    for f in (fig_aerolineas, fig_hora_dia, fig_causas, fig_serie, fig_cadenas,
              fig_rendimiento, fig_brin, fig_calidad, fig_rutas_aeropuertos):
        f()
    print(f"{len(list(FIGURAS.glob('*.png')))} figuras en reports/figures")
    return 0


if __name__ == "__main__":
    sys.exit(main())
