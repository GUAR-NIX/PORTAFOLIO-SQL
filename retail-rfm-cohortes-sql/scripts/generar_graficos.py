"""
generar_graficos.py
Lee las vistas rpt de SQL Server y genera las figuras del README en reports/figures/
y las tablas de resultados en reports/tablas/.

Uso:  .venv\\Scripts\\python scripts\\generar_graficos.py
"""
from __future__ import annotations

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.colors import LinearSegmentedColormap
from matplotlib.ticker import FuncFormatter

from conexion import consultar

RAIZ = Path(__file__).resolve().parents[1]
FIGURAS = RAIZ / "reports" / "figures"
TABLAS = RAIZ / "reports" / "tablas"

# Paleta (validada para daltonismo en pares adyacentes) y tokens de texto
AZUL, NARANJA, AQUA = "#2a78d6", "#eb6834", "#1baf7a"
GRIS_CONTEXTO = "#c9c8c2"
SUPERFICIE, TEXTO, TEXTO_2, REJILLA = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e0"
RAMPA_AZUL = ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"]

plt.rcParams.update({
    "figure.facecolor": SUPERFICIE, "axes.facecolor": SUPERFICIE, "savefig.facecolor": SUPERFICIE,
    "axes.edgecolor": REJILLA, "axes.labelcolor": TEXTO_2, "axes.titlecolor": TEXTO,
    "axes.titlesize": 12, "axes.titleweight": "bold", "axes.titlelocation": "left",
    "xtick.color": TEXTO_2, "ytick.color": TEXTO_2, "text.color": TEXTO,
    "font.family": "DejaVu Sans", "font.size": 9.5,
    "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": REJILLA, "grid.linewidth": 0.7,
})

gbp = FuncFormatter(lambda v, _: coma(f"£{v / 1e6:.1f} M") if abs(v) >= 1e6 else f"£{v / 1e3:.0f} k")
miles = FuncFormatter(lambda v, _: f"{v:,.0f}".replace(",", "."))
libras = FuncFormatter(lambda v, _: f"£{v:,.0f}".replace(",", "."))
MESES = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]


def coma(texto: str) -> str:
    """Formato numérico en español: 1,234.5 -> 1.234,5"""
    return texto.replace(",", "_").replace(".", ",").replace("_", ".")


def guardar(fig: plt.Figure, nombre: str) -> None:
    fig.savefig(FIGURAS / nombre, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  {nombre}")


def fig_ventas_mensuales() -> None:
    df = consultar("SELECT mes, ventas_netas, clientes_activos FROM rpt.kpi_mensual ORDER BY mes")
    df["mes"] = pd.to_datetime(df["mes"])
    df.to_csv(TABLAS / "kpi_mensual.csv", index=False)
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(10, 5.6), sharex=True, height_ratios=[3, 2])
    a1.bar(df["mes"], df["ventas_netas"], width=24, color=AZUL)
    a1.yaxis.set_major_formatter(gbp)
    a1.grid(axis="x", visible=False)
    a1.set_title("Ventas netas por mes (GBP)")
    for _, r in df.nlargest(2, "ventas_netas").iterrows():
        a1.annotate(f"£{r.ventas_netas / 1e6:.2f} M".replace(".", ",") + f"\n{MESES[r.mes.month - 1]}-{r.mes.year}",
                    (r.mes, r.ventas_netas),
                    xytext=(0, 4), textcoords="offset points", ha="center", fontsize=8.5, color=TEXTO_2)
    a1.set_ylim(0, df["ventas_netas"].max() * 1.22)
    a2.plot(df["mes"], df["clientes_activos"], color=AZUL, lw=2, marker="o", ms=4)
    a2.set_title("Clientes identificados que compraron en el mes")
    a2.yaxis.set_major_formatter(miles)
    a2.text(df["mes"].iloc[-1], df["clientes_activos"].iloc[-1], "  dic-2011: solo 9 días",
            fontsize=8, color=TEXTO_2, va="center")
    fig.text(0, -0.02, "Fuente: UCI Online Retail II. Picos en noviembre: compras mayoristas para Navidad.",
             fontsize=8, color=TEXTO_2)
    fig.tight_layout()
    guardar(fig, "01_ventas_mensuales.png")


def fig_segmentos() -> None:
    df = consultar("SELECT orden, segmento, clientes, pct_clientes, monto, pct_monto, recencia_promedio, "
                   "frecuencia_promedio, monto_promedio, accion_sugerida FROM rpt.rfm_segmentos ORDER BY orden")
    df.to_csv(TABLAS / "rfm_segmentos.csv", index=False)
    y = np.arange(len(df))[::-1]
    alto = 0.38
    fig, ax = plt.subplots(figsize=(10, 5.4))
    ax.barh(y + alto / 2 + 0.01, df["pct_clientes"] * 100, height=alto, color=AZUL, label="% de clientes")
    ax.barh(y - alto / 2 - 0.01, df["pct_monto"] * 100, height=alto, color=NARANJA, label="% del ingreso neto")
    for yi, pc, pm in zip(y, df["pct_clientes"], df["pct_monto"]):
        ax.text(pc * 100 + 0.6, yi + alto / 2, coma(f"{pc:.1%}"), va="center", fontsize=8, color=TEXTO_2)
        ax.text(pm * 100 + 0.6, yi - alto / 2, coma(f"{pm:.1%}"), va="center", fontsize=8, color=TEXTO)
    ax.set_yticks(y, [f"{s}  ({c:,})".replace(",", ".") for s, c in zip(df["segmento"], df["clientes"])])
    ax.set_xlabel("%")
    ax.grid(axis="y", visible=False)
    ax.set_xlim(0, max(df["pct_monto"].max(), df["pct_clientes"].max()) * 100 * 1.12)
    ax.legend(loc="lower right", frameon=False)
    ax.set_title("Segmentos RFM: peso en clientes vs. peso en ingreso (5.852 clientes)")
    fig.tight_layout()
    guardar(fig, "02_segmentos_rfm.png")


def fig_heatmap_retencion() -> None:
    df = consultar("SELECT cohorte, tamano_cohorte, mes_desde, tasa_retencion, censurada_izquierda, mes_incompleto "
                   "FROM rpt.cohorte_retencion WHERE mes_desde <= 12")
    matriz = df.pivot(index="cohorte", columns="mes_desde", values="tasa_retencion").sort_index()
    incompleto = df.pivot(index="cohorte", columns="mes_desde", values="mes_incompleto").sort_index()
    tamanos = df.groupby("cohorte")["tamano_cohorte"].first().sort_index()
    (matriz * 100).round(1).to_csv(TABLAS / "matriz_retencion.csv")

    valores = matriz.drop(columns=0).astype(float)          # el mes 0 siempre es 100 %
    fig, ax = plt.subplots(figsize=(11, 8.2))
    cmap = LinearSegmentedColormap.from_list("azul", RAMPA_AZUL)
    cmap.set_bad(SUPERFICIE)
    im = ax.imshow(np.ma.masked_invalid(valores.values), cmap=cmap, vmin=0, vmax=0.5, aspect="auto")
    ax.grid(False)
    for i in range(valores.shape[0]):
        for j in range(valores.shape[1]):
            v = valores.iat[i, j]
            if np.isnan(v):
                continue
            texto = f"{v * 100:.0f}"
            if incompleto.iat[i, j + 1] == 1:
                texto += "*"
            ax.text(j, i, texto, ha="center", va="center", fontsize=7.5,
                    color="white" if v >= 0.26 else TEXTO)
    ax.set_xticks(range(valores.shape[1]), [f"M{m}" for m in valores.columns])
    etiquetas = [f"{c}  (n={tamanos[c]})" for c in valores.index]
    etiquetas[0] += " †"
    ax.set_yticks(range(len(etiquetas)), etiquetas)
    ax.tick_params(length=0)
    for s in ax.spines.values():
        s.set_visible(False)
    ax.set_xlabel("Meses desde la primera compra")
    ax.set_title("Retención mensual por cohorte (% de clientes de la cohorte que vuelven a comprar)")
    cb = fig.colorbar(im, ax=ax, fraction=0.025, pad=0.01, format=FuncFormatter(lambda v, _: f"{v:.0%}"))
    cb.outline.set_visible(False)
    fig.text(0.01, 0.01, "† dic-2009 está censurada: el archivo empieza ese mes y mezcla clientes antiguos.   "
             "* dic-2011 solo tiene 9 días.", fontsize=8, color=TEXTO_2)
    fig.tight_layout(rect=(0, 0.02, 1, 1))
    guardar(fig, "03_retencion_cohortes.png")


def fig_ingreso_cohortes() -> None:
    df = consultar("SELECT cohorte, mes_desde, ingreso_acum_por_cliente, mes_incompleto FROM rpt.cohorte_retencion "
                   "WHERE cohorte >= '2010-01' AND mes_incompleto = 0")
    df.pivot(index="cohorte", columns="mes_desde", values="ingreso_acum_por_cliente").to_csv(
        TABLAS / "ingreso_acumulado_por_cliente.csv")
    destacadas = {"2010-01": AZUL, "2010-06": NARANJA, "2010-11": AQUA}
    fig, ax = plt.subplots(figsize=(10, 5))
    for c, g in df.groupby("cohorte"):
        if c not in destacadas:
            ax.plot(g["mes_desde"], g["ingreso_acum_por_cliente"], color=GRIS_CONTEXTO, lw=1, zorder=1)
    for c, color in destacadas.items():
        g = df[df["cohorte"] == c]
        ax.plot(g["mes_desde"], g["ingreso_acum_por_cliente"], color=color, lw=2.2, zorder=3, label=f"Cohorte {c}")
        u = g.iloc[-1]
        ax.text(u.mes_desde + 0.3, u.ingreso_acum_por_cliente, coma(f"{c}: £{u.ingreso_acum_por_cliente:,.0f}"),
                va="center", fontsize=8.5, color=TEXTO)
    ax.yaxis.set_major_formatter(libras)
    ax.set_xlabel("Meses desde la primera compra")
    ax.set_title("Ingreso neto acumulado por cliente según cohorte (gris: resto de cohortes 2010–2011)")
    ax.legend(frameon=False, loc="upper left")
    ax.set_xlim(0, df["mes_desde"].max() + 4)
    fig.tight_layout()
    guardar(fig, "04_ingreso_acumulado_cohortes.png")


def fig_devoluciones() -> None:
    tiempo = consultar("SELECT rango, orden, lineas, importe FROM rpt.devoluciones_tiempo ORDER BY orden")
    prod = consultar("SELECT TOP (8) codigo_producto, descripcion, importe_vendido, importe_devuelto, "
                     "tasa_devolucion_importe FROM rpt.devoluciones_producto ORDER BY importe_devuelto DESC")
    prod.to_csv(TABLAS / "devoluciones_top_productos.csv", index=False)
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(12, 4.6), width_ratios=[1, 1.35])
    a1.bar(tiempo["rango"], tiempo["importe"], color=AZUL, width=0.6)
    tot = tiempo["importe"].sum()
    for x, v in enumerate(tiempo["importe"]):
        a1.text(x, v, f"{v / tot:.0%}", ha="center", va="bottom", fontsize=8.5, color=TEXTO)
    a1.yaxis.set_major_formatter(gbp)
    a1.grid(axis="x", visible=False)
    a1.set_title("Importe devuelto según días desde la compra")
    a1.tick_params(axis="x", labelsize=8)
    plt.setp(a1.get_xticklabels(), rotation=18, ha="right")

    y = np.arange(len(prod))[::-1]
    colores = [NARANJA if t >= 0.9 else AZUL for t in prod["tasa_devolucion_importe"]]
    a2.barh(y, prod["importe_devuelto"], color=colores, height=0.6)
    for yi, (v, t) in zip(y, prod[["importe_devuelto", "tasa_devolucion_importe"]].values):
        a2.text(v, yi, f"  £{v / 1e3:.0f} k ({t:.0%} de lo vendido)", va="center", fontsize=8, color=TEXTO_2)
    a2.set_yticks(y, [d.title()[:34] for d in prod["descripcion"]], fontsize=8)
    a2.xaxis.set_major_formatter(gbp)
    a2.set_xlim(0, prod["importe_devuelto"].max() * 1.55)
    a2.grid(axis="y", visible=False)
    a2.set_title("Productos con más importe devuelto")
    a2.text(0.98, 0.04, "naranja = pedido gigante anulado\n(error de digitación, no insatisfacción)",
            transform=a2.transAxes, ha="right", fontsize=8, color=TEXTO_2)
    fig.tight_layout()
    guardar(fig, "05_devoluciones.png")


def fig_canasta() -> None:
    df = consultar("SELECT TOP (12) producto_a, producto_b, facturas_ab, soporte, confianza_a_b, confianza_b_a, lift "
                   "FROM rpt.canasta_pares ORDER BY facturas_ab DESC")
    consultar("SELECT TOP (50) * FROM rpt.canasta_pares ORDER BY facturas_ab DESC").to_csv(
        TABLAS / "canasta_top50_pares.csv", index=False)
    y = np.arange(len(df))[::-1]
    fig, ax = plt.subplots(figsize=(11, 5.6))
    ax.barh(y, df["facturas_ab"], color=AZUL, height=0.6)
    for yi, r in zip(y, df.itertuples()):
        ax.text(r.facturas_ab, yi, coma(f"  lift {r.lift:.1f} · conf. {max(r.confianza_a_b, r.confianza_b_a):.0%}"),
                va="center", fontsize=8, color=TEXTO_2)
    ax.set_yticks(y, [f"{a.title()[:36]}  +  {b.title()[:36]}" for a, b in zip(df["producto_a"], df["producto_b"])],
                  fontsize=8)
    ax.xaxis.set_major_formatter(miles)
    ax.set_xlim(0, df["facturas_ab"].max() * 1.3)
    ax.grid(axis="y", visible=False)
    ax.set_xlabel("Facturas que contienen ambos productos (de 39.516)")
    ax.set_title("Pares de productos que más se compran juntos")
    fig.tight_layout()
    guardar(fig, "06_canasta_pares.png")


def fig_reconciliacion() -> None:
    df = consultar("SELECT ISNULL(motivo_exclusion, 'VALIDA') AS motivo, COUNT_BIG(*) AS lineas, SUM(importe) AS importe "
                   "FROM limpio.factura_linea GROUP BY motivo_exclusion")
    df.to_csv(TABLAS / "limpieza_por_motivo.csv", index=False)
    total = int(df["lineas"].sum())
    nombres = {"DUPLICADO": "Duplicados\n(22.523 por el\nsolapamiento de hojas)",
               "CODIGO_NO_PRODUCTO": "Envío, comisiones\ny ajustes",
               "MOVIMIENTO_INVENTARIO": "Mermas de\nbodega", "PRECIO_CERO": "Precio 0",
               "AJUSTE_DEUDA": "Ajuste de\ndeuda"}
    excl = df[df["motivo"] != "VALIDA"].sort_values("lineas", ascending=False)
    pasos = [("Archivo\n(2 hojas)", total, 0, AZUL)]
    nivel = total
    for r in excl.itertuples():
        nivel -= r.lineas
        pasos.append((nombres.get(r.motivo, r.motivo), r.lineas, nivel, NARANJA))
    pasos.append(("Modelo\nestrella", nivel, 0, AZUL))
    fig, ax = plt.subplots(figsize=(11, 4.8))
    for x, (nombre, alto, base, color) in enumerate(pasos):
        ax.bar(x, alto, bottom=base, color=color, width=0.62)
        signo = "" if color == AZUL else "−"
        ax.text(x, base + alto, f"{signo}{alto:,.0f}".replace(",", "."), ha="center", va="bottom", fontsize=8.5)
    ax.set_xticks(range(len(pasos)), [p[0] for p in pasos], fontsize=8)
    ax.set_ylim(980_000, total * 1.008)
    ax.yaxis.set_major_formatter(miles)
    ax.grid(axis="x", visible=False)
    ax.set_title("De 1.067.371 líneas del archivo a 1.021.254 en el modelo: nada se pierde en silencio")
    fig.text(0, -0.03, "Eje Y recortado desde 980.000 para que se vean las exclusiones pequeñas. "
             "Importe: fuente £19.287.250,57 = modelo + excluidas (diferencia 0,00).", fontsize=8, color=TEXTO_2)
    fig.tight_layout()
    guardar(fig, "07_reconciliacion_limpieza.png")


def fig_controles() -> None:
    df = consultar("SELECT orden, bloque, control, valor, esperado, estado FROM qa.resultado_control "
                   "WHERE ejecucion = (SELECT MAX(ejecucion) FROM qa.resultado_control) ORDER BY orden")
    df.to_csv(TABLAS / "controles_calidad.csv", index=False)
    fig, ax = plt.subplots(figsize=(11, 0.32 * len(df) + 1))
    ax.axis("off")
    filas = [[f"{r.orden}", r.bloque, r.control, f"{r.valor:,.0f}".replace(",", "."), r.esperado,
              ("✔ " if r.estado == "OK" else "✖ ") + r.estado] for r in df.itertuples()]
    tabla = ax.table(cellText=filas, colLabels=["#", "Bloque", "Control", "Valor", "Esperado", "Estado"],
                     colWidths=[0.04, 0.06, 0.68, 0.07, 0.08, 0.09], loc="upper left", cellLoc="left")
    tabla.auto_set_font_size(False)
    tabla.set_fontsize(8)
    for (fila, col), celda in tabla.get_celld().items():
        celda.set_edgecolor(REJILLA)
        celda.set_height(0.9 / (len(df) + 1))
        if fila == 0:
            celda.set_text_props(weight="bold", color=TEXTO)
            celda.set_facecolor("#f0efec")
        elif col == 5:
            celda.set_text_props(color="#008300" if "OK" in celda.get_text().get_text() else "#e34948",
                                 weight="bold")
    ok = (df["estado"] == "OK").sum()
    ax.set_title(f"EXEC qa.sp_validar_calidad  →  {ok} de {len(df)} controles en OK", loc="left")
    guardar(fig, "08_controles_calidad.png")


def main() -> None:
    FIGURAS.mkdir(parents=True, exist_ok=True)
    TABLAS.mkdir(parents=True, exist_ok=True)
    print("Generando figuras desde las vistas rpt...")
    fig_ventas_mensuales()
    fig_segmentos()
    fig_heatmap_retencion()
    fig_ingreso_cohortes()
    fig_devoluciones()
    fig_canasta()
    fig_reconciliacion()
    fig_controles()


if __name__ == "__main__":
    main()
