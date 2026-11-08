"""Exporta tablas y planes desde SQL Server (CitiBikeTuning), guarda resultados.json y genera las figuras.

Salidas:
  reports/tablas/*.csv        vistas rpt.* y qa.* de la corrida que está en la base
  reports/planes/*.sqlplan    plan real de cada variante (se abre en SSMS o Azure Data Studio)
  reports/resultados.json     resumen en JSON
  reports/figures/*.png       10 figuras
"""

from __future__ import annotations

import json
import textwrap
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

from conexion import conectar, consultar  # noqa: E402

RAIZ = Path(__file__).resolve().parents[1]
DIR_REPORTES = RAIZ / "reports"
DIR_FIGURAS = DIR_REPORTES / "figures"
DIR_TABLAS = DIR_REPORTES / "tablas"
DIR_PLANES = DIR_REPORTES / "planes"

PALETA = {
    "antes": "#dc2626",
    "intermedio": "#d97706",
    "despues": "#15803d",
    "primario": "#0f4c81",
    "secundario": "#0284c7",
    "acento": "#ea580c",
    "neutro": "#64748b",
}
COLOR_ROL = {
    "ANTES": PALETA["antes"],
    "INTERMEDIO": PALETA["intermedio"],
    "SOLO_REESCRITURA": PALETA["intermedio"],
    "SOLO_INDICE": "#a16207",
    "ALTERNATIVA": PALETA["secundario"],
    "REFERENCIA": PALETA["neutro"],
    "DESPUES": PALETA["despues"],
}

CONSULTAS = {
    "experimentos_tuning": "SELECT * FROM rpt.resumen_experimentos_tuning ORDER BY id_experimento;",
    "mediciones_corridas": "SELECT * FROM rpt.mediciones_corridas ORDER BY codigo_experimento, modo, corrida;",
    "tiempos_carga": "SELECT * FROM rpt.tiempos_carga ORDER BY mediana_ms_total;",
    "demo_plan_forzado": "SELECT * FROM rpt.demo_plan_forzado ORDER BY paso;",
    "curva_tipping_point": "SELECT * FROM rpt.curva_tipping_point ORDER BY id_punto;",
    "huella_almacenamiento": "SELECT * FROM rpt.huella_almacenamiento ORDER BY orden;",
    "auditoria_query_store": "SELECT * FROM rpt.auditoria_query_store ORDER BY query_id, plan_id;",
    "kpi_mensual": "SELECT * FROM rpt.kpi_mensual ORDER BY anio, mes;",
    "perfil_horario_semanal": "SELECT * FROM rpt.perfil_horario_semanal ORDER BY es_fin_de_semana, hora;",
    "desbalance_estaciones": "SELECT * FROM rpt.desbalance_estaciones_rebalanceo ORDER BY movimiento_total DESC, estacion_id;",
    "top_rutas": "SELECT * FROM rpt.top_rutas_origen_destino ORDER BY viajes DESC, origen_id, destino_id;",
    "resumen_limpieza": "SELECT * FROM rpt.resumen_limpieza_calidad ORDER BY filas DESC;",
    "controles_calidad": "SELECT * FROM qa.resultado_control ORDER BY orden;",
    "bitacora_etl": "SELECT etapa, filas_afectadas, duracion_ms FROM etl.bitacora_carga ORDER BY id_carga;",
}


def configurar_estilo() -> None:
    plt.rcParams.update(
        {
            "figure.dpi": 110,
            "savefig.dpi": 160,
            "savefig.bbox": "tight",
            "savefig.pad_inches": 0.25,
            "figure.facecolor": "#ffffff",
            "axes.facecolor": "#ffffff",
            "axes.edgecolor": "#d1d5db",
            "axes.grid": True,
            "grid.color": "#e5e7eb",
            "axes.spines.top": False,
            "axes.spines.right": False,
            "font.sans-serif": ["Segoe UI", "DejaVu Sans", "Arial"],
            "axes.titlesize": 12,
            "axes.titleweight": "bold",
            "axes.labelsize": 10,
            "xtick.labelsize": 9,
            "ytick.labelsize": 9,
        }
    )


def miles(x: float) -> str:
    return f"{x:,.0f}".replace(",", ".")


def dec(x: float, n: int = 1) -> str:
    return f"{x:,.{n}f}".replace(",", "X").replace(".", ",").replace("X", ".")


def exportar_tablas_y_json() -> dict[str, pd.DataFrame]:
    for d in (DIR_FIGURAS, DIR_TABLAS, DIR_PLANES):
        d.mkdir(parents=True, exist_ok=True)
    cn = conectar()
    try:
        tablas = {nombre: consultar(sql, cn) for nombre, sql in CONSULTAS.items()}
        planes = consultar(
            "SELECT codigo_experimento, CAST(plan_xml AS NVARCHAR(MAX)) AS plan_xml "
            "FROM perf.experimento_resultado WHERE plan_xml IS NOT NULL;",
            cn,
        )
    finally:
        cn.close()

    for viejo in DIR_TABLAS.glob("*.csv"):
        viejo.unlink()
    for nombre, df in tablas.items():
        df.to_csv(DIR_TABLAS / f"{nombre}.csv", index=False, encoding="utf-8")

    for viejo in DIR_PLANES.glob("*.sqlplan"):
        viejo.unlink()
    for _, fila in planes.iterrows():
        (DIR_PLANES / f"{fila['codigo_experimento']}.sqlplan").write_text(fila["plan_xml"], encoding="utf-8")

    resumen = {
        "proyecto": "SQL_06_tuning_citibike",
        "base_datos": "CitiBikeTuning (SQL Server 2025 Express)",
        "datos": "Citi Bike Nueva York, enero–marzo 2024",
        **{k: v.to_dict(orient="records") for k, v in tablas.items() if k != "mediciones_corridas"},
    }
    (DIR_REPORTES / "resultados.json").write_text(
        json.dumps(resumen, indent=2, ensure_ascii=False, default=str), encoding="utf-8"
    )
    return tablas


def _guardar(fig: plt.Figure, nombre: str) -> Path:
    ruta = DIR_FIGURAS / nombre
    fig.savefig(ruta)
    plt.close(fig)
    return ruta


def _etiqueta_grupo(grupo: str) -> str:
    codigo, texto = [p.strip() for p in grupo.split("·", 1)]
    return f"{codigo} · " + "\n".join(textwrap.wrap(texto, 30))


def fig_01_antes_despues(df: pd.DataFrame) -> Path:
    """Lecturas lógicas y duración (mediana en caliente y en frío): variante ANTES frente a DESPUÉS."""
    configurar_estilo()
    antes = df[df["rol_comparacion"] == "ANTES"].set_index("grupo_experimento")
    despues = df[df["rol_comparacion"] == "DESPUES"].set_index("grupo_experimento")
    grupos = list(antes.index)
    etiquetas = [_etiqueta_grupo(g) for g in grupos]
    y = np.arange(len(grupos))
    h = 0.38

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(15, 8.2), sharey=True)
    la = antes.loc[grupos, "lecturas_logicas"].astype(float)
    ld = despues.loc[grupos, "lecturas_logicas"].astype(float)
    ax1.barh(y - h / 2, la, height=h, color=PALETA["antes"], label="Antes")
    ax1.barh(y + h / 2, ld, height=h, color=PALETA["despues"], label="Después")
    ax1.set_xscale("log")
    ax1.set_yticks(y, etiquetas)
    ax1.invert_yaxis()
    ax1.set_xlabel("Lecturas lógicas, páginas de 8 KB (escala log)")
    ax1.set_title("Páginas leídas", loc="left")
    ax1.set_xlim(right=la.max() * 30)
    for i, g in enumerate(grupos):
        ax1.text(max(la[g], ld[g]) * 1.3, y[i], f"{miles(la[g])} → {miles(ld[g])}", va="center", fontsize=8.5)
    ax1.legend(loc="lower left", bbox_to_anchor=(0, 1.04), ncol=2, frameon=False)

    sc = despues.loc[grupos, "speedup_caliente_x"].astype(float)
    sf = despues.loc[grupos, "speedup_frio_x"].astype(float)
    ax2.barh(y - h / 2, sc, height=h, color=PALETA["primario"], label="En caliente (mediana de 5)")
    ax2.barh(y + h / 2, sf, height=h, color=PALETA["secundario"], label="En frío (mediana de 5)")
    ax2.set_xscale("log")
    ax2.axvline(1, color="#374151", linestyle="--", linewidth=1)
    ax2.set_xlabel("Veces más rápido: duración antes / duración después (escala log)")
    ax2.set_title("Aceleración del tiempo de respuesta", loc="left")
    ax2.set_xlim(right=max(sc.max(), sf.max()) * 12)
    for i, g in enumerate(grupos):
        ax2.text(max(sc[g], sf[g]) * 1.3, y[i], f"{dec(sc[g])}x / {dec(sf[g])}x", va="center", fontsize=8.5)
    ax2.legend(loc="lower left", bbox_to_anchor=(0, 1.04), ncol=2, frameon=False)
    fig.suptitle("E1–E9: variante sin afinar frente a la afinada (mismos resultados en ambas)", x=0.01, ha="left", fontsize=13, fontweight="bold")
    fig.tight_layout()
    return _guardar(fig, "01_antes_despues_lecturas_y_tiempo.png")


def fig_02_aislamiento_2x2(df: pd.DataFrame) -> Path:
    """E2 y E7: efecto del índice solo, de la reescritura sola y de ambos."""
    configurar_estilo()
    fig, ejes = plt.subplots(1, 2, figsize=(14.5, 5.6))
    orden = ["ANTES", "SOLO_REESCRITURA", "SOLO_INDICE", "DESPUES"]
    nombres = {"ANTES": "Ninguno", "SOLO_REESCRITURA": "Solo reescritura", "SOLO_INDICE": "Solo índice", "DESPUES": "Índice + reescritura"}
    for ax, prefijo, titulo in zip(
        ejes,
        ("E2_", "E7_"),
        ("E2 · Filtro de una semana: YEAR()/MONTH() vs. rango", "E7 · Últimos 10 viajes: ROW_NUMBER() vs. CROSS APPLY"),
    ):
        sub = df[df["codigo_experimento"].str.startswith(prefijo)].set_index("rol_comparacion").loc[orden]
        x = np.arange(4)
        barras = ax.bar(x, sub["lecturas_logicas"].astype(float), color=[COLOR_ROL[r] for r in orden], width=0.6)
        ax.set_yscale("log")
        ax.set_xticks(x, [nombres[r] for r in orden])
        ax.set_ylabel("Lecturas lógicas (escala log)")
        ax.set_title(titulo, loc="left")
        ax.set_ylim(top=sub["lecturas_logicas"].max() * 8)
        for b, (_, f) in zip(barras, sub.iterrows()):
            ax.text(b.get_x() + b.get_width() / 2, b.get_height() * 1.25,
                    f"{miles(f['lecturas_logicas'])} pág.\n{dec(f['duracion_ms_caliente'])} ms",
                    ha="center", fontsize=8.5)
    fig.suptitle("Aislar el efecto de cada cambio (diseño 2×2, mediana en caliente)", x=0.01, ha="left", fontsize=13, fontweight="bold")
    fig.tight_layout()
    return _guardar(fig, "02_aislamiento_indice_vs_reescritura.png")


def fig_03_frio_vs_caliente(df: pd.DataFrame, med: pd.DataFrame) -> Path:
    """Duración en frío frente a caliente por variante, con la dispersión de las 5 corridas."""
    configurar_estilo()
    fig, ax = plt.subplots(figsize=(15, 6.2))
    codigos = list(df["codigo_experimento"])
    x = np.arange(len(codigos))
    for desplaz, modo, color in ((-0.18, "CALIENTE", PALETA["primario"]), (0.18, "FRIO", PALETA["acento"])):
        for i, c in enumerate(codigos):
            v = med[(med["codigo_experimento"] == c) & (med["modo"] == modo)]["duracion_ms"].astype(float)
            ax.scatter(np.full(len(v), x[i] + desplaz), v, s=12, color=color, alpha=0.55)
            ax.hlines(v.median(), x[i] + desplaz - 0.14, x[i] + desplaz + 0.14, color=color, linewidth=2.2)
    ax.set_yscale("log")
    ax.set_xticks(x, [c.replace("_", " ", 1) for c in codigos], rotation=60, ha="right", fontsize=8)
    ax.set_ylabel("Duración por ejecución, ms (escala log)")
    ax.set_title("Cada corrida (puntos) y su mediana (línea): caliente en azul, frío (DROPCLEANBUFFERS) en naranja", loc="left")
    fig.tight_layout()
    return _guardar(fig, "03_frio_vs_caliente_dispersion.png")


def fig_04_tipping_point(df_tp: pd.DataFrame) -> Path:
    configurar_estilo()
    fig, ax = plt.subplots(figsize=(11.5, 5.8))
    x = df_tp["pct_tabla"].astype(float)
    ax.plot(x, df_tp["lecturas_forzado_lookup"], "o-", color=PALETA["antes"], lw=2.3, label="Índice no cubriente forzado (Seek + Key Lookup)")
    ax.plot(x, df_tp["lecturas_heap_scan"], "s--", color=PALETA["neutro"], lw=2, label="Heap: Table Scan completo")
    ax.plot(x, df_tp["lecturas_nocov_natural"], "^-", color=PALETA["intermedio"], lw=2, label="Elección del optimizador (rowstore sin cubrir)")
    ax.plot(x, df_tp["lecturas_covering_seek"], "D-", color=PALETA["despues"], lw=2.4, label="Índice cubriente (INCLUDE)")
    ax.plot(x, df_tp["lecturas_columnstore"], "P-", color=PALETA["primario"], lw=2, label="Columnstore")
    ax.set_xscale("log")
    ax.set_yscale("log")
    for _, f in df_tp.iterrows():
        ax.annotate(f["etiqueta_ventana"].split(" (")[0], (f["pct_tabla"], f["lecturas_forzado_lookup"]),
                    textcoords="offset points", xytext=(0, 8), ha="center", fontsize=8)
    ax.set_xlabel("% de filas de la tabla que cumplen el filtro (8 estaciones, ventana creciente; escala log)")
    ax.set_ylabel("Lecturas lógicas (escala log)")
    ax.set_title("Punto de inflexión: cuándo el Key Lookup deja de convenir", loc="left")
    ax.legend(fontsize=8.5, loc="upper left")
    fig.tight_layout()
    return _guardar(fig, "04_curva_tipping_point.png")


def fig_05_almacenamiento_y_carga(df_alm: pd.DataFrame, df_carga: pd.DataFrame) -> Path:
    configurar_estilo()
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(15, 5.4))
    y = np.arange(len(df_alm))
    datos = df_alm["datos_mb"].astype(float)
    sec = df_alm["indices_secund_mb"].astype(float)
    ax1.barh(y, datos, height=0.55, color=PALETA["primario"], label="Tabla / índice agrupado")
    ax1.barh(y, sec, left=datos, height=0.55, color=PALETA["acento"], label="Índices secundarios")
    ax1.set_yticks(y, ["\n".join(textwrap.wrap(a, 28)) for a in df_alm["arquitectura"]])
    ax1.invert_yaxis()
    ax1.set_xlabel("MB en disco")
    ax1.set_title("Espacio de cada diseño físico (mismas filas)", loc="left")
    ax1.set_xlim(0, (datos + sec).max() * 1.35)
    for i, (d, s) in enumerate(zip(datos, sec)):
        ax1.text(d + s + 8, i, f"{dec(d + s)} MB", va="center", fontsize=8.5)
    ax1.legend(loc="lower right", fontsize=8.5)

    c = df_carga.sort_values("mediana_ms_total")
    yc = np.arange(len(c))
    ins = c["mediana_ms_insercion"].astype(float) / 1000
    idx = c["mediana_ms_indices"].astype(float) / 1000
    ax2.barh(yc, ins, height=0.55, color=PALETA["primario"], label="INSERT")
    ax2.barh(yc, idx, left=ins, height=0.55, color=PALETA["acento"], label="CREATE INDEX posterior")
    ax2.set_yticks(yc, ["\n".join(textwrap.wrap(d, 34)) for d in c["descripcion"]])
    ax2.invert_yaxis()
    ax2.set_xlabel("Segundos (mediana de 3 corridas)")
    ax2.set_title("Tiempo de carga con y sin índices", loc="left")
    ax2.set_xlim(0, (ins + idx).max() * 1.3)
    for i, t in enumerate(ins + idx):
        ax2.text(t + 0.3, i, f"{dec(t)} s", va="center", fontsize=8.5)
    ax2.legend(loc="lower right", fontsize=8.5)
    fig.tight_layout()
    return _guardar(fig, "05_almacenamiento_y_tiempo_de_carga.png")


def fig_06_sniffing_y_query_store(df: pd.DataFrame) -> Path:
    configurar_estilo()
    fig, ejes = plt.subplots(1, 2, figsize=(14.5, 5.6))
    for ax, prefijo, titulo in zip(
        ejes,
        ("E5_", "E9_"),
        ("E5 · Parameter sniffing y sus soluciones", "E9 · Regresión provocada y plan forzado con Query Store"),
    ):
        sub = df[df["codigo_experimento"].str.startswith(prefijo)]
        x = np.arange(len(sub))
        barras = ax.bar(x, sub["duracion_ms_caliente"].astype(float), color=[COLOR_ROL[r] for r in sub["rol_comparacion"]], width=0.6)
        ax.set_xticks(x, ["\n".join(textwrap.wrap(v, 24, break_long_words=False)) for v in sub["variante"]], fontsize=8.5)
        ax.set_ylabel("Duración en caliente, ms (mediana de 5)")
        ax.set_title(titulo, loc="left")
        ax.set_ylim(0, sub["duracion_ms_caliente"].max() * 1.3)
        for b, (_, f) in zip(barras, sub.iterrows()):
            ax.text(b.get_x() + b.get_width() / 2, b.get_height() * 1.02,
                    f"{dec(f['duracion_ms_caliente'])} ms\n{miles(f['lecturas_logicas'])} pág.\n{f['operador_principal']}",
                    ha="center", va="bottom", fontsize=7.8)
    fig.tight_layout()
    return _guardar(fig, "06_parameter_sniffing_y_query_store.png")


def fig_07_mensual(df_mes: pd.DataFrame) -> Path:
    configurar_estilo()
    df_mes = df_mes[df_mes["anio"] == 2024].reset_index(drop=True)  # sin los viajes iniciados el 31-12-2023
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13.5, 5))
    x = np.arange(len(df_mes))
    elec = df_mes["viajes_electrica"].astype(float) / 1e6
    clas = df_mes["viajes_clasica"].astype(float) / 1e6
    ax1.bar(x, elec, color=PALETA["secundario"], label="Eléctrica")
    ax1.bar(x, clas, bottom=elec, color=PALETA["primario"], label="Clásica")
    ax1.set_xticks(x, df_mes["nombre_mes"])
    ax1.set_ylabel("Millones de viajes válidos")
    ax1.set_title("Viajes por mes y tipo de bicicleta", loc="left")
    for i, t in enumerate(elec + clas):
        ax1.text(i, t + 0.03, dec(t, 2) + " M", ha="center", fontsize=9)
    ax1.set_ylim(0, (elec + clas).max() * 1.15)
    ax1.legend()
    ax2.plot(x, df_mes["pct_electrica"].astype(float), "o-", color=PALETA["secundario"], lw=2.3, label="% eléctrica")
    ax2.plot(x, df_mes["pct_miembro"].astype(float), "s--", color=PALETA["despues"], lw=2.2, label="% miembros")
    ax2.set_xticks(x, df_mes["nombre_mes"])
    ax2.set_ylim(0, 100)
    ax2.set_ylabel("% de los viajes del mes")
    ax2.set_title("Participación de e-bikes y de miembros", loc="left")
    ax2.legend(loc="lower right")
    fig.tight_layout()
    return _guardar(fig, "07_viajes_por_mes_y_ebikes.png")


def fig_08_perfil_horario(df_hor: pd.DataFrame) -> Path:
    configurar_estilo()
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13.5, 5))
    lab = df_hor[df_hor["es_fin_de_semana"] == 0].sort_values("hora")
    fin = df_hor[df_hor["es_fin_de_semana"] == 1].sort_values("hora")
    ax1.plot(lab["hora"], lab["total_viajes"] / 1000, "o-", color=PALETA["primario"], lw=2.3, label="Lunes a viernes")
    ax1.plot(fin["hora"], fin["total_viajes"] / 1000, "s--", color=PALETA["acento"], lw=2.2, label="Sábado y domingo")
    ax1.set_xticks(range(0, 24, 2))
    ax1.set_xlabel("Hora de inicio")
    ax1.set_ylabel("Miles de viajes en el trimestre")
    ax1.set_title("Viajes por hora", loc="left")
    ax1.legend()
    ax2.plot(lab["hora"], lab["duracion_media_min"].astype(float), "o-", color=PALETA["primario"], lw=2.2, label="Lunes a viernes")
    ax2.plot(fin["hora"], fin["duracion_media_min"].astype(float), "s--", color=PALETA["acento"], lw=2.2, label="Sábado y domingo")
    ax2.set_xticks(range(0, 24, 2))
    ax2.set_xlabel("Hora de inicio")
    ax2.set_ylabel("Duración media (min)")
    ax2.set_title("Duración media por hora", loc="left")
    ax2.legend()
    fig.tight_layout()
    return _guardar(fig, "08_perfil_horario_laboral_vs_finde.png")


def fig_09_desbalance(df_est: pd.DataFrame, df_rutas: pd.DataFrame) -> Path:
    configurar_estilo()
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(15.5, 6))
    orden = df_est.sort_values(["balance_neto_manana_6_10h", "estacion_id"])
    ext = pd.concat([orden.head(6), orden.tail(6)], ignore_index=True)
    y = np.arange(len(ext))
    v = ext["balance_neto_manana_6_10h"].astype(int)
    ax1.barh(y, v, color=[PALETA["antes"] if a < 0 else PALETA["despues"] for a in v], height=0.6)
    ax1.axvline(0, color="#374151", lw=1)
    ax1.set_yticks(y, [textwrap.shorten(n, 34, placeholder="…") for n in ext["estacion_nombre"]])
    ax1.set_xlabel("Llegadas − salidas entre 06:00 y 10:59 (trimestre)")
    ax1.set_title("Estaciones que se vacían (rojo) y se llenan (verde) en la mañana", loc="left")
    top = df_rutas.head(10)
    yr = np.arange(len(top))
    ax2.barh(yr, top["viajes"], color=PALETA["primario"], height=0.6)
    ax2.set_yticks(yr, [textwrap.shorten(f"{o} → {d}", 48, placeholder="…") for o, d in zip(top["origen_nombre"], top["destino_nombre"])])
    ax2.invert_yaxis()
    ax2.set_xlabel("Viajes en el trimestre")
    ax2.set_title("10 rutas origen → destino más frecuentes", loc="left")
    ax2.set_xlim(0, top["viajes"].max() * 1.2)
    for i, n in enumerate(top["viajes"]):
        ax2.text(n * 1.01, i, miles(n), va="center", fontsize=8.5)
    fig.tight_layout()
    return _guardar(fig, "09_desbalance_estaciones_y_rutas.png")


def fig_10_calidad(df_lim: pd.DataFrame, df_qa: pd.DataFrame) -> Path:
    configurar_estilo()
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 4.8))
    excl = df_lim[df_lim["estado_calidad"] != "VALIDO"].sort_values("filas")
    y = np.arange(len(excl))
    ax1.barh(y, excl["filas"], color=PALETA["acento"], height=0.55)
    ax1.set_yticks(y, excl["estado_calidad"])
    ax1.set_xlabel("Filas excluidas (quedan en limpio.viaje con su motivo)")
    ax1.set_title("Motivos de exclusión", loc="left")
    ax1.set_xlim(0, excl["filas"].max() * 1.25)
    for i, n in enumerate(excl["filas"]):
        ax1.text(n * 1.02, i, miles(n), va="center", fontsize=9)
    res = df_qa.groupby("categoria").agg(total=("orden", "count"), ok=("estado", lambda s: int((s == "OK").sum()))).sort_values("total")
    yc = np.arange(len(res))
    ax2.barh(yc, res["total"], color="#e5e7eb", height=0.55)
    ax2.barh(yc, res["ok"], color=PALETA["despues"], height=0.55)
    ax2.set_yticks(yc, res.index)
    ax2.set_xlabel("Controles")
    ax2.set_title(f"Controles automáticos en T-SQL: {int(res['ok'].sum())} de {int(res['total'].sum())} en OK", loc="left")
    for i, (t, o) in enumerate(zip(res["total"], res["ok"])):
        ax2.text(t + 0.1, i, f"{o}/{t}", va="center", fontsize=9)
    ax2.set_xlim(0, res["total"].max() * 1.2)
    fig.tight_layout()
    return _guardar(fig, "10_calidad_y_controles.png")


def generar_figuras(t: dict[str, pd.DataFrame]) -> list[Path]:
    for vieja in DIR_FIGURAS.glob("*.png"):
        vieja.unlink()
    exp = t["experimentos_tuning"]
    return [
        fig_01_antes_despues(exp),
        fig_02_aislamiento_2x2(exp),
        fig_03_frio_vs_caliente(exp, t["mediciones_corridas"]),
        fig_04_tipping_point(t["curva_tipping_point"]),
        fig_05_almacenamiento_y_carga(t["huella_almacenamiento"], t["tiempos_carga"]),
        fig_06_sniffing_y_query_store(exp),
        fig_07_mensual(t["kpi_mensual"]),
        fig_08_perfil_horario(t["perfil_horario_semanal"]),
        fig_09_desbalance(t["desbalance_estaciones"], t["top_rutas"]),
        fig_10_calidad(t["resumen_limpieza"], t["controles_calidad"]),
    ]


def main() -> None:
    tablas = exportar_tablas_y_json()
    rutas = generar_figuras(tablas)
    n_planes = len(list(DIR_PLANES.glob("*.sqlplan")))
    print(f"[ok] {len(tablas)} tablas, {n_planes} planes .sqlplan y {len(rutas)} figuras en reports/")


if __name__ == "__main__":
    main()
