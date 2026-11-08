"""Genera README.md a partir de docs/plantilla_README.md y de los datos de reports/ y data/.

Todas las cifras del README salen de aquí: si se vuelve a correr el pipeline, basta con
ejecutar este script para que el README quede al día. `tests/test_readme_cifras.py`
comprueba que README.md es exactamente lo que produce `renderizar()`.

Uso:
  python scripts/generar_readme.py
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import numpy as np
import pandas as pd

RAIZ = Path(__file__).resolve().parents[1]
TABLAS = RAIZ / "reports" / "tablas"
PLANTILLA = RAIZ / "docs" / "plantilla_README.md"
README = RAIZ / "README.md"


def miles(x: float) -> str:
    return f"{float(x):,.0f}".replace(",", ".")


def dec(x: float, n: int = 1) -> str:
    return f"{float(x):,.{n}f}".replace(",", "X").replace(".", ",").replace("X", ".")


def pct(x: float) -> str:
    """Porcentaje con 1 decimal, o 2 si el valor queda muy cerca de 0 o de 100."""
    x = float(x)
    return dec(x, 2) if abs(x) < 1 or 99 < abs(x) < 100 else dec(x, 1)


def ms(x: float) -> str:
    """Milisegundos con precisión adaptada al tamaño."""
    x = float(x)
    if x >= 100:
        return miles(x)
    if x >= 10:
        return dec(x, 1)
    return dec(x, 2)


def veces(x: float) -> str:
    x = float(x)
    if not np.isfinite(x):
        return "—"
    return (miles(x) if x >= 100 else dec(x, 1)) + "x"


def leer(nombre: str) -> pd.DataFrame:
    return pd.read_csv(TABLAS / f"{nombre}.csv")


def _tabla(encabezado: list[str], alineacion: list[str], filas: list[list[str]]) -> str:
    lineas = ["| " + " | ".join(encabezado) + " |", "| " + " | ".join(alineacion) + " |"]
    lineas += ["| " + " | ".join(f) + " |" for f in filas]
    return "\n".join(lineas)


ROL = {
    "ANTES": "Antes",
    "INTERMEDIO": "Intermedio",
    "SOLO_REESCRITURA": "Solo reescritura",
    "SOLO_INDICE": "Solo índice",
    "ALTERNATIVA": "Alternativa",
    "REFERENCIA": "Referencia",
    "DESPUES": "**Después**",
}


def tabla_experimentos(exp: pd.DataFrame) -> str:
    filas = []
    for _, f in exp.iterrows():
        red = "—" if f["rol_comparacion"] == "ANTES" else f"{pct(f['reduccion_lecturas_pct'])} %"
        sc = "—" if f["rol_comparacion"] == "ANTES" else veces(f["speedup_caliente_x"])
        sf = "—" if f["rol_comparacion"] == "ANTES" else veces(f["speedup_frio_x"])
        filas.append([
            f["codigo_experimento"].split("_")[0],
            ROL[f["rol_comparacion"]],
            re.sub(r"^(Solo reescritura|Solo índice|Ambos): ", "", f["variante"]),
            f"`{f['operador_principal']}`",
            f["modo_ejecucion"] if isinstance(f["modo_ejecucion"], str) else "—",
            miles(f["lecturas_logicas"]),
            ms(f["duracion_ms_caliente"]),
            ms(f["duracion_ms_frio"]),
            miles(f["memoria_kb"]) if pd.notna(f["memoria_kb"]) else "—",
            red,
            sc,
            sf,
        ])
    return _tabla(
        ["Exp.", "Rol", "Variante", "Operador principal (plan real)", "Modo", "Lecturas lógicas",
         "ms caliente", "ms frío", "Memoria KB", "Δ lecturas", "x caliente", "x frío"],
        [":---", ":---", ":---", ":---", ":---:", "---:", "---:", "---:", "---:", "---:", "---:", "---:"],
        filas,
    )


def tabla_2x2(exp: pd.DataFrame, prefijo: str) -> str:
    sub = exp[exp["codigo_experimento"].str.startswith(prefijo)].set_index("rol_comparacion")
    base = sub.loc["ANTES"]
    filas = []
    for rol, cambio in (("ANTES", "Ninguno"), ("SOLO_REESCRITURA", "Solo reescritura"),
                        ("SOLO_INDICE", "Solo índice"), ("DESPUES", "Índice + reescritura")):
        f = sub.loc[rol]
        filas.append([
            cambio,
            re.sub(r"^(Solo reescritura|Solo índice|Ambos): ", "", f["variante"]),
            miles(f["lecturas_logicas"]),
            f"{pct(f['lecturas_logicas'] / base['lecturas_logicas'] * 100)} %",
            ms(f["duracion_ms_caliente"]),
            ms(f["duracion_ms_frio"]),
            "1,0x" if rol == "ANTES" else veces(f["speedup_caliente_x"]),
        ])
    return _tabla(
        ["Cambio aplicado", "Variante", "Lecturas lógicas", "% de la base", "ms caliente", "ms frío", "x caliente"],
        [":---", ":---", "---:", "---:", "---:", "---:", "---:"],
        filas,
    )


def tabla_tipping(tp: pd.DataFrame) -> str:
    filas = []
    for _, f in tp.iterrows():
        filas.append([
            f["etiqueta_ventana"], miles(f["filas_calificadas"]), f"{dec(f['pct_tabla'], 2)} %",
            miles(f["lecturas_heap_scan"]), miles(f["lecturas_forzado_lookup"]),
            f"{miles(f['lecturas_nocov_natural'])} · {f['operador_nocov_natural']}",
            miles(f["lecturas_covering_seek"]), miles(f["lecturas_columnstore"]),
        ])
    return _tabla(
        ["Ventana", "Filas", "% tabla", "Heap (scan)", "Seek + Key Lookup forzado",
         "Rowstore sin cubrir (elección del optimizador)", "Índice cubriente", "Columnstore"],
        [":---", "---:", "---:", "---:", "---:", ":---", "---:", "---:"],
        filas,
    )


def tabla_huella(alm: pd.DataFrame) -> str:
    filas = []
    for _, f in alm.iterrows():
        filas.append([
            f["arquitectura"], f"`{f['objeto_sql']}`", dec(f["datos_mb"], 1), dec(f["indices_secund_mb"], 1),
            dec(f["datos_mb"] + f["indices_secund_mb"], 1), dec(f["bytes_por_fila"], 1), dec(f["ratio_compresion_vs_heap"], 2) + "x",
        ])
    return _tabla(
        ["Diseño", "Tabla", "Datos (MB)", "Índices secundarios (MB)", "Total (MB)", "Bytes por fila", "Compresión vs. heap"],
        [":---", ":---", "---:", "---:", "---:", "---:", "---:"],
        filas,
    )


def tabla_carga(carga: pd.DataFrame) -> str:
    filas = []
    for _, f in carga.sort_values("mediana_ms_total").iterrows():
        filas.append([
            f["descripcion"], dec(f["mediana_ms_insercion"] / 1000, 1), dec(f["mediana_ms_indices"] / 1000, 1),
            dec(f["mediana_ms_total"] / 1000, 1), f"{dec(f['min_ms_total'] / 1000, 1)} – {dec(f['max_ms_total'] / 1000, 1)}",
        ])
    return _tabla(
        ["Estrategia", "INSERT (s)", "CREATE INDEX (s)", "Total (s, mediana)", "Rango de las 3 corridas (s)"],
        [":---", "---:", "---:", "---:", "---:"],
        filas,
    )


def tabla_qs(exp: pd.DataFrame, demo: pd.DataFrame) -> str:
    sub = exp[exp["codigo_experimento"].str.startswith("E9_")].reset_index(drop=True)
    filas = []
    for i, f in sub.iterrows():
        d = demo.loc[demo["paso"] == i + 1].iloc[0]
        filas.append([
            str(i + 1), f["variante"], str(int(d["plan_id"])), "Sí" if d["es_plan_forzado"] else "No",
            f"`{f['operador_principal']}`", miles(f["lecturas_logicas"]), ms(f["duracion_ms_caliente"]), ms(f["duracion_ms_frio"]),
        ])
    return _tabla(
        ["Paso", "Situación", "plan_id", "¿Forzado?", "Operador", "Lecturas lógicas", "ms caliente", "ms frío"],
        [":---:", ":---", "---:", ":---:", ":---", "---:", "---:", "---:"],
        filas,
    )


def tabla_estaciones(est: pd.DataFrame, n: int = 3) -> str:
    filas = []
    for etiqueta, sub in (("Se vacía", est.nsmallest(n, "balance_neto_manana_6_10h")),
                          ("Se llena", est.nlargest(n, "balance_neto_manana_6_10h"))):
        for _, f in sub.iterrows():
            filas.append([
                etiqueta, f["estacion_nombre"], f"`{f['estacion_id']}`",
                f"{int(f['balance_neto_manana_6_10h']):+,}".replace(",", "."),
                f"{int(f['balance_neto_tarde_16_20h']):+,}".replace(",", "."),
            ])
    return _tabla(
        ["Mañana", "Estación", "ID", "Llegadas − salidas 06–10 h", "Llegadas − salidas 16–20 h"],
        [":---", ":---", ":---", "---:", "---:"],
        filas,
    )


def calcular_valores() -> dict[str, str]:
    control = json.loads((RAIZ / "data" / "cifras_control.json").read_text(encoding="utf-8"))
    exp = leer("experimentos_tuning")
    tp = leer("curva_tipping_point")
    alm = leer("huella_almacenamiento")
    carga = leer("tiempos_carga").set_index("estrategia")
    demo = leer("demo_plan_forzado")
    mes = leer("kpi_mensual")
    hor = leer("perfil_horario_semanal")
    est = leer("desbalance_estaciones")
    qa = leer("controles_calidad")
    bit = leer("bitacora_etl").set_index("etapa")
    rutas = leer("top_rutas")
    med = leer("mediciones_corridas")
    e = exp.set_index("codigo_experimento")

    v: dict[str, str] = {}
    v["filas_brutas"] = miles(control["filas_totales_brutas"])
    v["filas_validas"] = miles(control["filas_validas"])
    v["filas_excluidas"] = miles(control["filas_excluidas"])
    v["pct_retencion"] = dec(control["tasa_retencion_pct"], 2)
    v["mb_tsv"] = miles(control["bytes_tsv"] / 1024**2)
    v["mb_zips"] = miles(sum(m["bytes_zip"] for m in control["meses"].values()) / 1024**2)
    for per, m in control["meses"].items():
        v[f"filas_{per}"] = miles(m["filas"])
    v["estaciones_origen"] = miles(control["estaciones_origen_unicas_validas"])
    v["seg_bulk"] = dec(bit.loc["BULK_INSERT_STAGING", "duracion_ms"] / 1000, 1)
    v["seg_limpieza"] = dec(bit.loc["LIMPIEZA_Y_REGLAS_CALIDAD", "duracion_ms"] / 1000, 1)
    v["min_benchmark"] = dec(bit.loc["BENCHMARK_LABORATORIO_TUNING", "duracion_ms"] / 60000, 1)

    v["qa_ok"] = str(int((qa["estado"] == "OK").sum()))
    v["qa_total"] = str(len(qa))
    v["n_variantes"] = str(len(exp))
    v["n_corridas"] = str(len(med))

    # Experimentos individuales
    base_grupo = exp[exp["rol_comparacion"] == "ANTES"].set_index("grupo_experimento")["lecturas_logicas"]
    for cod in e.index:
        f = e.loc[cod]
        clave = cod.lower()
        v[f"{clave}_pct"] = pct(f["lecturas_logicas"] / base_grupo[f["grupo_experimento"]] * 100)
        v[f"{clave}_lec"] = miles(f["lecturas_logicas"])
        v[f"{clave}_msc"] = ms(f["duracion_ms_caliente"])
        v[f"{clave}_msf"] = ms(f["duracion_ms_frio"])
        v[f"{clave}_filas"] = miles(f["filas_devueltas"])
        if f["rol_comparacion"] != "ANTES":
            v[f"{clave}_red"] = pct(f["reduccion_lecturas_pct"])
            v[f"{clave}_xc"] = veces(f["speedup_caliente_x"])
            v[f"{clave}_xf"] = veces(f["speedup_frio_x"])
        v[f"{clave}_est"] = miles(f["filas_estimadas_acceso"]) if pd.notna(f["filas_estimadas_acceso"]) else "—"
        v[f"{clave}_real"] = miles(f["filas_reales_acceso"]) if pd.notna(f["filas_reales_acceso"]) else "—"

    despues = exp[exp["rol_comparacion"] == "DESPUES"]
    v["min_red"] = dec(despues["reduccion_lecturas_pct"].min(), 2)
    v["max_red"] = dec(despues["reduccion_lecturas_pct"].max(), 2)
    v["e1_lookup_vs_heap"] = dec(e.loc["E1_B_KEYLOOKUP", "lecturas_logicas"] / e.loc["E1_A_HEAP", "lecturas_logicas"], 1)
    v["e5_lookup_vs_recompile"] = dec(e.loc["E5_A_SNIFF_MALO", "lecturas_logicas"] / e.loc["E5_B_RECOMPILE", "lecturas_logicas"], 1)
    v["e9_regresion_x"] = dec(e.loc["E9_B_REGRESION", "duracion_ms_caliente"] / e.loc["E9_A_PLAN_ORIGINAL", "duracion_ms_caliente"], 1)

    # Punto de cruce de la curva (interpolación log-log)
    d = np.log(tp["lecturas_forzado_lookup"].astype(float)) - np.log(tp["lecturas_heap_scan"].astype(float))
    i = int(np.argmax(d.to_numpy() > 0))
    x0, x1 = np.log(tp.loc[i - 1, "pct_tabla"]), np.log(tp.loc[i, "pct_tabla"])
    v["tp_cruce_pct"] = dec(np.exp(x0 + (0 - d[i - 1]) * (x1 - x0) / (d[i] - d[i - 1])), 2)
    v["tp_cruce_entre"] = f"{tp.loc[i - 1, 'etiqueta_ventana']} y {tp.loc[i, 'etiqueta_ventana']}"
    ult = tp.iloc[-1]
    v["tp_91_lookup"] = miles(ult["lecturas_forzado_lookup"])
    v["tp_91_heap"] = miles(ult["lecturas_heap_scan"])
    v["tp_91_cov"] = miles(ult["lecturas_covering_seek"])
    v["tp_91_ratio"] = dec(ult["lecturas_forzado_lookup"] / ult["lecturas_heap_scan"], 1)

    a = alm.set_index("orden")
    v["heap_mb"] = dec(a.loc[1, "datos_mb"], 1)
    v["cci_mb"] = dec(a.loc[4, "datos_mb"], 1)
    v["cci_ratio"] = dec(a.loc[4, "ratio_compresion_vs_heap"], 2)
    v["nocov_idx_mb"] = dec(a.loc[2, "indices_secund_mb"], 1)
    v["cov_idx_mb"] = dec(a.loc[3, "indices_secund_mb"], 1)

    v["carga_heap_s"] = dec(carga.loc["HEAP", "mediana_ms_total"] / 1000, 1)
    v["carga_despues_s"] = dec(carga.loc["INDICES_DESPUES", "mediana_ms_total"] / 1000, 1)
    v["carga_antes_s"] = dec(carga.loc["INDICES_ANTES", "mediana_ms_total"] / 1000, 1)
    v["carga_antes_vs_despues"] = dec(carga.loc["INDICES_ANTES", "mediana_ms_total"] / carga.loc["INDICES_DESPUES", "mediana_ms_total"], 2)
    v["carga_antes_vs_heap"] = dec(carga.loc["INDICES_ANTES", "mediana_ms_total"] / carga.loc["HEAP", "mediana_ms_total"], 1)

    v["qs_query_id"] = str(int(demo["query_id"].iloc[0]))
    v["qs_plan_bueno"] = str(int(demo.loc[demo["paso"] == 1, "plan_id"].iloc[0]))
    v["qs_plan_malo"] = str(int(demo.loc[demo["paso"] == 2, "plan_id"].iloc[0]))

    # Analítica
    # El archivo de enero trae viajes que empezaron el 31-12-2023: cuentan en el total, no en los meses
    v["viajes_dic2023"] = miles(mes.loc[mes["anio"] == 2023, "total_viajes"].sum())
    tot = mes[["total_viajes", "viajes_electrica", "viajes_miembro"]].sum()
    mes = mes[mes["anio"] == 2024].reset_index(drop=True)
    v["viajes_t1"] = miles(tot["total_viajes"])
    v["pct_ebike_t1"] = dec(tot["viajes_electrica"] / tot["total_viajes"] * 100, 1)
    v["pct_miembro_t1"] = dec(tot["viajes_miembro"] / tot["total_viajes"] * 100, 1)
    for _, f in mes.iterrows():
        k = f["nombre_mes"].lower()
        v[f"viajes_{k}"] = miles(f["total_viajes"])
        v[f"ebike_{k}"] = dec(f["pct_electrica"], 1)
    v["crec_ene_mar"] = dec((mes["total_viajes"].iloc[-1] / mes["total_viajes"].iloc[0] - 1) * 100, 1)
    lab = hor[hor["es_fin_de_semana"] == 0]
    fin = hor[hor["es_fin_de_semana"] == 1]
    pico_m = lab[lab["hora"] < 12].nlargest(1, "total_viajes").iloc[0]
    pico_t = lab[lab["hora"] >= 12].nlargest(1, "total_viajes").iloc[0]
    pico_f = fin.nlargest(1, "total_viajes").iloc[0]
    v["pico_manana_h"] = f"{int(pico_m['hora']):02d}:00"
    v["pico_manana_n"] = miles(pico_m["total_viajes"])
    v["pico_tarde_h"] = f"{int(pico_t['hora']):02d}:00"
    v["pico_tarde_n"] = miles(pico_t["total_viajes"])
    v["pico_finde_h"] = f"{int(pico_f['hora']):02d}:00"
    dur_lab = (lab["duracion_media_min"] * lab["total_viajes"]).sum() / lab["total_viajes"].sum()
    dur_fin = (fin["duracion_media_min"] * fin["total_viajes"]).sum() / fin["total_viajes"].sum()
    v["dur_lab"] = dec(dur_lab, 1)
    v["dur_fin"] = dec(dur_fin, 1)
    v["dur_fin_vs_lab"] = dec((dur_fin / dur_lab - 1) * 100, 0)
    v["corr_manana_tarde"] = dec(est["balance_neto_manana_6_10h"].corr(est["balance_neto_tarde_16_20h"]), 2)
    r1 = rutas.iloc[0]
    v["ruta1"] = f"{r1['origen_nombre']} → {r1['destino_nombre']}"
    v["ruta1_n"] = miles(r1["viajes"])

    v["tabla_experimentos"] = tabla_experimentos(exp)
    v["tabla_e2"] = tabla_2x2(exp, "E2_")
    v["tabla_e7"] = tabla_2x2(exp, "E7_")
    v["tabla_tipping"] = tabla_tipping(tp)
    v["tabla_huella"] = tabla_huella(alm)
    v["tabla_carga"] = tabla_carga(leer("tiempos_carga"))
    v["tabla_qs"] = tabla_qs(exp, demo)
    v["tabla_estaciones"] = tabla_estaciones(est)
    return v


def renderizar() -> str:
    plantilla = PLANTILLA.read_text(encoding="utf-8")
    valores = calcular_valores()
    faltantes = sorted(set(re.findall(r"\{\{(\w+)\}\}", plantilla)) - set(valores))
    if faltantes:
        raise KeyError(f"La plantilla usa claves sin valor: {faltantes}")
    texto = re.sub(r"\{\{(\w+)\}\}", lambda m: valores[m.group(1)], plantilla)
    return texto.replace("<!-- PLANTILLA: no editar README.md a mano -->\n", "")


def main() -> None:
    README.write_text(renderizar(), encoding="utf-8", newline="\n")
    print(f"[ok] README.md generado desde {PLANTILLA.relative_to(RAIZ)} y reports/")


if __name__ == "__main__":
    main()
