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

# Paleta categórica en orden fijo (validada para daltonismo en pares adyacentes) y tokens de texto
AZUL, NARANJA, AQUA, AMARILLO = "#2a78d6", "#eb6834", "#1baf7a", "#eda100"
GRIS_CONTEXTO = "#c9c8c2"
SUPERFICIE, TEXTO, TEXTO_2, REJILLA = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e0"
RAMPA_AZUL = ["#f3f8fe", "#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"]

plt.rcParams.update({
    "figure.facecolor": SUPERFICIE, "axes.facecolor": SUPERFICIE, "savefig.facecolor": SUPERFICIE,
    "axes.edgecolor": REJILLA, "axes.labelcolor": TEXTO_2, "axes.titlecolor": TEXTO,
    "axes.titlesize": 12, "axes.titleweight": "bold", "axes.titlelocation": "left",
    "xtick.color": TEXTO_2, "ytick.color": TEXTO_2, "text.color": TEXTO,
    "font.family": "DejaVu Sans", "font.size": 9.5,
    "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": REJILLA, "grid.linewidth": 0.7,
})

MESES = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]


def coma(texto: str) -> str:
    """Formato numérico en español: 1,234.5 -> 1.234,5"""
    return texto.replace(",", "_").replace(".", ",").replace("_", ".")


miles = FuncFormatter(lambda v, _: coma(f"{v:,.0f}"))
millones = FuncFormatter(lambda v, _: coma(f"{v / 1e6:.1f} M"))


def guardar(fig: plt.Figure, nombre: str) -> None:
    fig.savefig(FIGURAS / nombre, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  {nombre}")


def nota(fig: plt.Figure, texto: str) -> None:
    fig.text(0.01, -0.02, texto, fontsize=8, color=TEXTO_2, ha="left", va="top")


def fig_kpi_mensual() -> None:
    df = consultar("SELECT periodo, viajes, viajes_por_dia, ingreso_total, ticket_medio FROM rpt.kpi_mensual ORDER BY periodo")
    df.to_csv(TABLAS / "kpi_mensual.csv", index=False)
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(12, 4.2))
    x = np.arange(len(df))
    a1.bar(x, df["viajes_por_dia"], color=AZUL, width=0.7)
    a1.set_xticks(x, [MESES[int(p[5:]) - 1] for p in df["periodo"]])
    a1.yaxis.set_major_formatter(miles)
    a1.set_title("Viajes por día, por mes")
    for xi, v in zip(x, df["viajes_por_dia"]):
        a1.annotate(coma(f"{v / 1e3:.0f} mil"), (xi, v), xytext=(0, 3), textcoords="offset points",
                    ha="center", fontsize=8, color=TEXTO_2)
    a1.set_ylim(0, df["viajes_por_dia"].max() * 1.15)
    a2.plot(x, df["ticket_medio"], color=AZUL, lw=2, marker="o", ms=5)
    a2.set_xticks(x, [MESES[int(p[5:]) - 1] for p in df["periodo"]])
    a2.yaxis.set_major_formatter(FuncFormatter(lambda v, _: coma(f"${v:.2f}")))
    a2.set_title("Ticket medio por viaje (total cobrado, USD)")
    for i in (0, len(df) - 1):
        a2.annotate(coma(f"${df['ticket_medio'].iloc[i]:.2f}"), (x[i], df["ticket_medio"].iloc[i]),
                    xytext=(0, 7), textcoords="offset points", ha="center", fontsize=8.5, color=TEXTO)
    fig.tight_layout()
    guardar(fig, "01_kpi_mensual.png")


def fig_horas_pico() -> None:
    df = consultar("SELECT dia_semana, nombre_dia, hora, viajes_por_dia, rank_en_el_dia, velocidad_media_mph "
                   "FROM rpt.horas_pico")
    df.to_csv(TABLAS / "horas_pico.csv", index=False)
    matriz = df.pivot(index="dia_semana", columns="hora", values="viajes_por_dia").sort_index()
    nombres = df.drop_duplicates("dia_semana").set_index("dia_semana").sort_index()["nombre_dia"]
    fig, ax = plt.subplots(figsize=(13, 4.2))
    cmap = LinearSegmentedColormap.from_list("azul", RAMPA_AZUL)
    im = ax.imshow(matriz.values, aspect="auto", cmap=cmap)
    ax.set_yticks(range(7), [n.capitalize() for n in nombres])
    ax.set_xticks(range(24), [f"{h:02d}" for h in range(24)])
    ax.set_xlabel("Hora de recogida")
    ax.grid(False)
    for spine in ax.spines.values():
        spine.set_visible(False)
    tope = matriz.values.max()
    for (i, h), v in np.ndenumerate(matriz.values):
        ax.text(h, i, coma(f"{v / 1e3:.1f}"), ha="center", va="center", fontsize=6.8,
                color="white" if v > tope * 0.6 else TEXTO)
    # Recuadro en la hora pico de cada día
    for i, dia in enumerate(matriz.index):
        h = int(df[(df["dia_semana"] == dia) & (df["rank_en_el_dia"] == 1)]["hora"].iloc[0])
        ax.add_patch(plt.Rectangle((h - 0.5, i - 0.5), 1, 1, fill=False, ec=NARANJA, lw=2))
    ax.set_title("Horas pico: viajes por hora en un día promedio (miles) · recuadro = hora pico de cada día")
    cb = fig.colorbar(im, ax=ax, fraction=0.02, pad=0.01, format=miles)
    cb.outline.set_visible(False)
    guardar(fig, "02_horas_pico.png")


def fig_estacionalidad() -> None:
    df = consultar("SELECT fecha, viajes, media_movil_7d, es_feriado, feriado, rank_anio FROM rpt.demanda_diaria ORDER BY fecha")
    df["fecha"] = pd.to_datetime(df["fecha"])
    df.to_csv(TABLAS / "demanda_diaria.csv", index=False)
    fig, ax = plt.subplots(figsize=(13, 4.4))
    ax.plot(df["fecha"], df["viajes"], color=GRIS_CONTEXTO, lw=1, label="Viajes del día")
    ax.plot(df["fecha"], df["media_movil_7d"], color=AZUL, lw=2, label="Media móvil 7 días")
    for _, r in df[df["es_feriado"] == 1].iterrows():
        ax.plot(r["fecha"], r["viajes"], "o", color=NARANJA, ms=6, mec=SUPERFICIE, mew=1.5)
    for _, r in df[df["feriado"].isin(["Acción de Gracias", "Navidad", "Día de la Independencia", "Año Nuevo"])].iterrows():
        ax.annotate(r["feriado"], (r["fecha"], r["viajes"]), xytext=(0, -14), textcoords="offset points",
                    ha="center", fontsize=8, color=TEXTO_2)
    top = df.loc[df["viajes"].idxmax()]
    ax.annotate(coma(f"Día récord: {top['fecha']:%d/%m} · {top['viajes']:,.0f}"), (top["fecha"], top["viajes"]),
                xytext=(0, 6), textcoords="offset points", ha="center", fontsize=8.5, color=TEXTO)
    ax.yaxis.set_major_formatter(miles)
    ax.xaxis.set_major_formatter(matplotlib.dates.DateFormatter("%b"))
    ax.plot([], [], "o", color=NARANJA, label="Feriado federal")
    ax.set_ylim(df["viajes"].min() * 0.85, df["viajes"].max() * 1.12)
    ax.legend(loc="upper left", frameon=False, ncol=3)
    ax.set_title("Estacionalidad: viajes diarios en 2024 y media móvil de 7 días")
    guardar(fig, "03_estacionalidad_diaria.png")


def fig_rutas_top() -> None:
    df = consultar("SELECT TOP (15) rank_global, zona_origen, zona_destino, viajes, ticket_medio, es_misma_zona, "
                   "pct_acumulado FROM rpt.rutas_top ORDER BY rank_global")
    consultar("SELECT * FROM rpt.rutas_top ORDER BY rank_global").to_csv(TABLAS / "rutas_top500.csv", index=False)
    df = df.iloc[::-1]
    fig, ax = plt.subplots(figsize=(11, 5.6))
    y = np.arange(len(df))
    colores = [GRIS_CONTEXTO if m == 1 else AZUL for m in df["es_misma_zona"]]
    ax.barh(y, df["viajes"], color=colores, height=0.65)
    etiquetas = [f"{o}  →  {d}" if o != d else f"{o}  (dentro de la zona)" for o, d in zip(df["zona_origen"], df["zona_destino"])]
    ax.set_yticks(y, etiquetas, fontsize=8.5)
    ax.xaxis.set_major_formatter(miles)
    for yi, v, t in zip(y, df["viajes"], df["ticket_medio"]):
        ax.text(v, yi, coma(f"  {v:,.0f} · ${t:.2f}"), va="center", fontsize=8, color=TEXTO_2)
    ax.set_xlim(0, df["viajes"].max() * 1.22)
    ax.grid(axis="y", visible=False)
    ax.set_title("Top 15 rutas origen → destino (viajes 2024 · ticket medio)")
    nota(fig, "Gris = viajes que empiezan y terminan en la misma zona (Upper East Side domina los trayectos cortos).")
    guardar(fig, "04_rutas_top.png")


def fig_propinas() -> None:
    pago = consultar("SELECT tipo_pago, viajes, pct_viajes, pct_con_propina, propina_pct_tarifa FROM rpt.propinas_por_pago "
                     "ORDER BY viajes DESC")
    pago.to_csv(TABLAS / "propinas_por_pago.csv", index=False)
    zona = consultar("SELECT distrito, zona, viajes_tarjeta, propina_pct_tarifa, dif_vs_ciudad_pp, quintil_propina "
                     "FROM rpt.propinas_por_zona ORDER BY propina_pct_tarifa DESC")
    zona.to_csv(TABLAS / "propinas_por_zona.csv", index=False)
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(13, 5.2), gridspec_kw={"width_ratios": [1, 1.25]})
    p = pago.iloc[::-1]
    y = np.arange(len(p))
    a1.barh(y, p["propina_pct_tarifa"], color=AZUL, height=0.6)
    a1.set_yticks(y, [f"{t}\n({coma(f'{v:.1f}')} % de viajes)" for t, v in zip(p["tipo_pago"], p["pct_viajes"])], fontsize=8)
    for yi, v in zip(y, p["propina_pct_tarifa"]):
        a1.text(v, yi, coma(f"  {v:.1f} %"), va="center", fontsize=8.5, color=TEXTO)
    a1.set_xlim(0, max(p["propina_pct_tarifa"].max(), 1) * 1.25)
    a1.grid(axis="y", visible=False)
    a1.set_title("Propina como % de la tarifa, por tipo de pago")
    sel = pd.concat([zona.head(8), zona.tail(8)]).iloc[::-1]
    y2 = np.arange(len(sel))
    colores = [AZUL if d > 0 else NARANJA for d in sel["dif_vs_ciudad_pp"]]
    a2.barh(y2, sel["dif_vs_ciudad_pp"], color=colores, height=0.6)
    a2.axvline(0, color=TEXTO_2, lw=0.8)
    a2.set_yticks(y2, [f"{z} ({d})" for z, d in zip(sel["zona"], sel["distrito"])], fontsize=8)
    for yi, d, v in zip(y2, sel["dif_vs_ciudad_pp"], sel["propina_pct_tarifa"]):
        a2.text(d, yi, coma(f"  {v:.1f} %  ") if d > 0 else coma(f"  {v:.1f} %  "), va="center",
                ha="left" if d > 0 else "right", fontsize=8, color=TEXTO_2)
    lim = sel["dif_vs_ciudad_pp"].abs().max() * 1.45
    a2.set_xlim(-lim, lim)
    a2.grid(axis="y", visible=False)
    a2.set_xlabel("Diferencia vs. el promedio de la ciudad (puntos porcentuales)")
    a2.set_title("Zonas de origen más y menos generosas (solo tarjeta)")
    nota(fig, "El efectivo no registra la propina en el taxímetro: su 0 % es un vacío del dato, no tacañería. "
              "Zonas con ≥ 5.000 viajes pagados con tarjeta.")
    fig.tight_layout()
    guardar(fig, "05_propinas.png")


def fig_aeropuertos() -> None:
    df = consultar("SELECT periodo, aeropuerto, SUM(viajes) AS viajes, SUM(ingreso_total) AS ingreso, "
                   "SUM(pct_viajes_mes) AS pct_viajes, SUM(pct_ingreso_mes) AS pct_ingreso "
                   "FROM rpt.aeropuertos GROUP BY periodo, aeropuerto ORDER BY periodo")
    consultar("SELECT * FROM rpt.aeropuertos ORDER BY periodo, aeropuerto, sentido").to_csv(
        TABLAS / "aeropuertos_mensual.csv", index=False)
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(13, 4.4))
    for aero, color in (("JFK", AZUL), ("LaGuardia", NARANJA), ("Newark", AQUA)):
        g = df[df["aeropuerto"] == aero]
        x = [int(p[5:]) - 1 for p in g["periodo"]]
        a1.plot(x, g["viajes"], color=color, lw=2, marker="o", ms=4)
        a1.text(x[-1] + 0.2, g["viajes"].iloc[-1], aero, va="center", fontsize=8.5, color=TEXTO)
        a2.plot(x, g["pct_ingreso"], color=color, lw=2, marker="o", ms=4, label=aero)
    for ax in (a1, a2):
        ax.set_xticks(range(12), MESES)
        ax.set_xlim(-0.4, 12)
    a1.yaxis.set_major_formatter(miles)
    a1.set_title("Viajes desde o hacia cada aeropuerto")
    a2.yaxis.set_major_formatter(FuncFormatter(lambda v, _: coma(f"{v:.0f} %")))
    a2.set_title("Participación en el ingreso total del mes")
    a2.legend(frameon=False, loc="center right")
    fig.tight_layout()
    guardar(fig, "06_aeropuertos.png")


def fig_precio_milla() -> None:
    df = consultar("SELECT periodo, banda_orden, banda_distancia, tarifa_por_milla, mediana_tarifa_por_milla, "
                   "velocidad_media_mph, var_vs_enero_pct FROM rpt.precio_por_milla ORDER BY banda_orden, periodo")
    df.to_csv(TABLAS / "precio_por_milla.csv", index=False)
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(13, 4.4))
    for (orden, banda), g in df.groupby(["banda_orden", "banda_distancia"]):
        color = [AZUL, NARANJA, AQUA, AMARILLO][int(orden) - 1]
        x = [int(p[5:]) - 1 for p in g["periodo"]]
        a1.plot(x, g["tarifa_por_milla"], color=color, lw=2, marker="o", ms=4)
        a1.text(11.2, g["tarifa_por_milla"].iloc[-1], banda, va="center", fontsize=8.5, color=TEXTO)
        a2.plot(x, g["velocidad_media_mph"], color=color, lw=2, marker="o", ms=4)
        a2.text(11.2, g["velocidad_media_mph"].iloc[-1], banda, va="center", fontsize=8.5, color=TEXTO)
    for ax in (a1, a2):
        ax.set_xticks(range(12), MESES)
        ax.set_xlim(-0.4, 12.4)
    a1.yaxis.set_major_formatter(FuncFormatter(lambda v, _: coma(f"${v:.2f}")))
    a1.set_title("Tarifa base por milla (tarifa estándar de taxímetro)")
    a2.set_title("Velocidad media (mph)")
    nota(fig, "Tarifa por milla = suma de tarifa base / suma de millas, por banda de distancia del viaje. "
              "Los viajes cortos cuestan más por milla por la bajada de bandera y el tiempo detenido.")
    fig.tight_layout()
    guardar(fig, "07_precio_por_milla.png")


def fig_calidad() -> None:
    q = consultar("SELECT periodo, regla, regla_nombre, viajes, pct_del_archivo FROM rpt.cuarentena_por_mes")
    q.to_csv(TABLAS / "cuarentena_por_mes.csv", index=False)
    cuadre = consultar("SELECT * FROM rpt.cuadre_fuente ORDER BY periodo")
    cuadre.to_csv(TABLAS / "cuadre_fuente.csv", index=False)
    por_regla = q.groupby(["regla", "regla_nombre"], as_index=False)["viajes"].sum().sort_values("regla", ascending=False)
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(13, 4.4), gridspec_kw={"width_ratios": [1.1, 1]})
    y = np.arange(len(por_regla))
    a1.barh(y, por_regla["viajes"], color=AZUL, height=0.6)
    a1.set_yticks(y, [f"{r} · {n}" for r, n in zip(por_regla["regla"], por_regla["regla_nombre"])], fontsize=8.5)
    a1.set_xscale("log")
    for yi, v in zip(y, por_regla["viajes"]):
        a1.text(v, yi, coma(f"  {v:,.0f}"), va="center", fontsize=8, color=TEXTO_2)
    a1.set_xlim(1, por_regla["viajes"].max() * 8)
    a1.xaxis.set_major_formatter(miles)
    a1.grid(axis="y", visible=False)
    a1.set_title("Viajes en cuarentena por regla (escala log)")
    x = np.arange(len(cuadre))
    a2.bar(x, cuadre["pct_cuarentena"], color=AZUL, width=0.7)
    a2.set_xticks(x, [MESES[int(p[5:]) - 1] for p in cuadre["periodo"]])
    a2.yaxis.set_major_formatter(FuncFormatter(lambda v, _: coma(f"{v:.1f} %")))
    a2.set_title("% del archivo mensual enviado a cuarentena")
    ok = (cuadre[["dif_filas", "dif_total", "dif_tarifa_base", "dif_propina", "dif_distancia"]] == 0).all().all()
    nota(fig, "Cuadre por mes contra el Parquet (filas, total, tarifa, propina y distancia): "
              + ("diferencia 0 en los 12 meses." if ok else "HAY DIFERENCIAS, revisar rpt.cuadre_fuente."))
    fig.tight_layout()
    guardar(fig, "08_calidad_cuarentena.png")


def fig_benchmark() -> None:
    b = consultar("SELECT consulta, descripcion, almacenamiento, ms_frio, ms_caliente, reservado_mb, bytes_por_fila "
                  "FROM rpt.benchmark_almacenamiento ORDER BY consulta, almacenamiento")
    if b.empty:
        print("  (sin benchmark: se omite 09)")
        return
    b.to_csv(TABLAS / "benchmark_almacenamiento.csv", index=False)
    orden = [a for a in ("ROWSTORE", "ROWSTORE PAGE", "COLUMNSTORE") if a in set(b["almacenamiento"])]
    colores = {"ROWSTORE": NARANJA, "ROWSTORE PAGE": AMARILLO, "COLUMNSTORE": AZUL}
    nombres = {"ROWSTORE": "Rowstore", "ROWSTORE PAGE": "Rowstore + PAGE", "COLUMNSTORE": "Columnstore"}
    fig, axs = plt.subplots(1, 3, figsize=(15, 4.8), gridspec_kw={"width_ratios": [0.7, 1.15, 1.15]})
    esp = b.drop_duplicates("almacenamiento").set_index("almacenamiento").loc[orden]
    axs[0].bar(range(len(orden)), esp["reservado_mb"] / 1024, color=[colores[a] for a in orden], width=0.6)
    axs[0].set_xticks(range(len(orden)), [nombres[a] for a in orden], fontsize=8.5)
    for i, (gb, bpf) in enumerate(zip(esp["reservado_mb"] / 1024, esp["bytes_por_fila"])):
        axs[0].text(i, gb, coma(f"{gb:.2f} GB\n{bpf:.0f} B/fila"), ha="center", va="bottom", fontsize=8.5)
    axs[0].set_ylim(0, esp["reservado_mb"].max() / 1024 * 1.25)
    axs[0].set_title("Espacio en disco")
    consultas = sorted(b["consulta"].unique())
    alto = 0.8 / len(orden)
    for ax, col, titulo in ((axs[1], "ms_frio", "En frío (caché vacía), ms · escala log"),
                            (axs[2], "ms_caliente", "En caliente (mejor de 3), ms · escala log")):
        for j, a in enumerate(orden):
            g = b[b["almacenamiento"] == a].set_index("consulta").loc[consultas]
            y = np.arange(len(consultas)) + (j - (len(orden) - 1) / 2) * alto
            ax.barh(y, g[col].clip(lower=1), height=alto * 0.9, color=colores[a], label=nombres[a])
        ax.set_xscale("log")
        ax.set_yticks(range(len(consultas)), consultas)
        ax.invert_yaxis()
        ax.grid(axis="y", visible=False)
        ax.xaxis.set_major_formatter(miles)
        ax.set_title(titulo)
    fig.legend(*axs[2].get_legend_handles_labels(), frameon=False, ncol=3, loc="upper center",
               bbox_to_anchor=(0.62, 1.05))
    desc = b.drop_duplicates("consulta").set_index("consulta")["descripcion"]
    nota(fig, "   ".join(f"{c}: {d}." for c, d in desc.items()))
    fig.tight_layout()
    guardar(fig, "09_rowstore_vs_columnstore.png")


def fig_cargas() -> None:
    a = consultar("SELECT periodo, seg_bulk_insert, seg_clasificacion, seg_columnstore, ms_switch, seg_total, filas_archivo "
                  "FROM rpt.auditoria_cargas WHERE estado = 'OK' AND carga_id IN "
                  "(SELECT MAX(carga_id) FROM rpt.auditoria_cargas WHERE estado = 'OK' GROUP BY periodo) ORDER BY periodo")
    consultar("SELECT * FROM rpt.auditoria_cargas ORDER BY carga_id").to_csv(TABLAS / "auditoria_cargas.csv", index=False)
    fig, ax = plt.subplots(figsize=(12, 4.2))
    x = np.arange(len(a))
    base = np.zeros(len(a))
    for col, color, nombre in (("seg_bulk_insert", AZUL, "BULK INSERT del CSV"),
                               ("seg_clasificacion", NARANJA, "Reglas: cuarentena + tabla de trabajo"),
                               ("seg_columnstore", AQUA, "Índice columnstore ordenado")):
        ax.bar(x, a[col], bottom=base, color=color, width=0.7, label=nombre, edgecolor=SUPERFICIE, linewidth=1)
        base += a[col].to_numpy(dtype=float)
    for xi, t, ms in zip(x, a["seg_total"], a["ms_switch"]):
        ax.text(xi, t, coma(f"{t:.0f} s\nswitch {ms} ms"), ha="center", va="bottom", fontsize=7.5, color=TEXTO_2)
    ax.set_xticks(x, [MESES[int(p[5:]) - 1] for p in a["periodo"]])
    ax.set_ylim(0, a["seg_total"].max() * 1.3)
    ax.set_ylabel("segundos")
    ax.legend(frameon=False, ncol=3, loc="upper left")
    ax.set_title("Carga incremental: tiempo por mes y por etapa (el SWITCH de la partición tarda milisegundos)")
    guardar(fig, "10_tiempos_de_carga.png")


def main() -> None:
    FIGURAS.mkdir(parents=True, exist_ok=True)
    TABLAS.mkdir(parents=True, exist_ok=True)
    print("Figuras:")
    for f in (fig_kpi_mensual, fig_horas_pico, fig_estacionalidad, fig_rutas_top, fig_propinas, fig_aeropuertos,
              fig_precio_milla, fig_calidad, fig_benchmark, fig_cargas):
        f()
    consultar("SELECT * FROM lab.ventana_log ORDER BY id").to_csv(TABLAS / "ventana_deslizante_log.csv", index=False)
    consultar("SELECT orden, control, valor, esperado, estado FROM qa.resultado_control "
              "WHERE ejecucion = (SELECT MAX(ejecucion) FROM qa.resultado_control) ORDER BY orden").to_csv(
        TABLAS / "controles_calidad.csv", index=False)


if __name__ == "__main__":
    main()
