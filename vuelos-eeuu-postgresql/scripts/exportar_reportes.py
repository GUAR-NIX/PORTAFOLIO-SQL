"""Exporta los resultados de la base a reports/.

- reports/tablas/*.csv  : una tabla por resultado (control, calidad, análisis, rendimiento)
- reports/planes/*.txt  : plan de EXPLAIN (ANALYZE, BUFFERS) de cada variante
- reports/resultados.json : cifras clave que usan el README, las figuras y las pruebas
"""
from __future__ import annotations

import json
import re
import sys
import unicodedata
from decimal import Decimal
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from conexion import conectar  # noqa: E402

RAIZ = Path(__file__).resolve().parents[1]
TABLAS = RAIZ / "reports" / "tablas"
PLANES = RAIZ / "reports" / "planes"

EXPORTAR = {
    "carga_mes": "SELECT anio_mes, filas_copiadas, filas_tipadas, segundos_copy, segundos_tipado, estado FROM control.carga_mes ORDER BY anio_mes",
    "cifras_control_sql": "SELECT * FROM control.cifras_mes ORDER BY anio_mes",
    "reconciliacion": "SELECT * FROM control.v_reconciliacion",
    "verificaciones": "SELECT control, esperado, obtenido, ok FROM control.verificacion ORDER BY control",
    "calidad_reglas": "SELECT * FROM calidad.conteo_regla",
    "kpi_general": "SELECT * FROM analisis.kpi_general",
    "mensual": "SELECT * FROM analisis.mensual",
    "ranking_aerolineas": "SELECT * FROM analisis.ranking_aerolineas",
    "ranking_aeropuertos": "SELECT * FROM analisis.ranking_aeropuertos",
    "hora_dia_semana": "SELECT * FROM analisis.hora_dia_semana",
    "causas_mes": "SELECT * FROM analisis.causas_mes",
    "rutas_problematicas": "SELECT * FROM analisis.rutas_problematicas",
    "serie_diaria": "SELECT * FROM analisis.serie_diaria",
    "feriados": "SELECT * FROM analisis.feriados",
    "aerolinea_dia": "SELECT * FROM analisis.aerolinea_dia",
    "feriados_por_distancia": "SELECT * FROM analisis.feriados_por_distancia",
    "validacion_zona_horaria": "SELECT * FROM analisis.validacion_zona_horaria",
    "cadena_resumen": "SELECT * FROM analisis.cadena_resumen",
    "cadena_por_paso": "SELECT * FROM analisis.cadena_por_paso",
    "cadena_por_tamano_raiz": "SELECT * FROM analisis.cadena_por_tamano_raiz",
    "cadena_por_hora_raiz": "SELECT * FROM analisis.cadena_por_hora_raiz",
    "cadena_por_aerolinea": "SELECT * FROM analisis.cadena_por_aerolinea",
    "cadena_ejemplo": "SELECT * FROM analisis.cadena_ejemplo",
    "indices_lab": "SELECT * FROM lab.v_indice_resumen",
    "correlacion_fisica": "SELECT * FROM lab.correlacion ORDER BY correlacion DESC",
    "indices_hecho": "SELECT * FROM perf.indice_tamano ORDER BY bytes DESC",
    "rendimiento_resumen": "SELECT experimento, variante, rol, orden, descripcion, filas, corridas, ms_mediana, ms_min, ms_max, ms_planificacion, bloques_mediana FROM perf.v_resumen",
    "rendimiento_corridas": "SELECT experimento, variante, corrida, ms_ejecucion, ms_planificacion, bloques_cache, bloques_leidos FROM perf.medicion ORDER BY experimento, variante, corrida",
    "tiempos_operacion": "SELECT * FROM perf.tiempo_operacion",
}


def _a_json(valor):
    if isinstance(valor, Decimal):
        return int(valor) if valor == valor.to_integral_value() else float(valor)
    if hasattr(valor, "isoformat"):
        return valor.isoformat()
    return valor


def _nodos(plan: dict):
    yield plan
    for hijo in plan.get("Plans", []):
        yield from _nodos(hijo)


def _nombre_indice(nombre: str, padres: dict[str, str]) -> str:
    """Nombre del índice padre (en una tabla particionada, cada partición tiene el suyo)."""
    if nombre in padres:
        return padres[nombre]
    # Índices ya borrados (variantes temporales): se quita el prefijo de la partición
    return re.sub(r"^fact_vuelo_(2024_\d\d|fuera_de_rango)_", "", nombre)


def resumir_plan(plan_json: list, padres: dict[str, str]) -> dict:
    """Operadores de lectura del plan, tablas leídas y filas descartadas."""
    raiz = plan_json[0]["Plan"]
    lecturas, tablas, indices = [], set(), []
    descartadas_recheck = descartadas_filtro = bloques_lossy = 0
    for n in _nodos(raiz):
        tipo = n["Node Type"]
        indice = _nombre_indice(n["Index Name"], padres) if n.get("Index Name") else None
        if tipo == "Bitmap Index Scan":
            if indice not in indices:
                indices.append(indice)
        elif "Scan" in tipo:
            nombre = f"{tipo} ({indice})" if indice else tipo
            if nombre not in lecturas:
                lecturas.append(nombre)
        if n.get("Relation Name"):
            tablas.add(n["Relation Name"])
        descartadas_recheck += n.get("Rows Removed by Index Recheck", 0)
        descartadas_filtro += n.get("Rows Removed by Filter", 0)
        bloques_lossy += n.get("Lossy Heap Blocks", 0)
    operador = " + ".join(lecturas)
    if indices:
        operador += " ← Bitmap Index Scan (" + ", ".join(indices) + ")"
    return {
        "operador": operador,
        "tablas_leidas": len(tablas),
        "filas_descartadas_recheck": descartadas_recheck,
        "filas_descartadas_filtro": descartadas_filtro,
        "bloques_lossy": bloques_lossy,
    }


def _slug(texto: str) -> str:
    t = unicodedata.normalize("NFKD", texto).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "_", t.lower()).strip("_")


def main() -> int:
    TABLAS.mkdir(parents=True, exist_ok=True)
    PLANES.mkdir(parents=True, exist_ok=True)
    for viejo in PLANES.glob("*.txt"):  # que no queden planes de variantes renombradas
        viejo.unlink()
    resultados: dict = {}
    with conectar() as con, con.cursor() as cur:
        for nombre, sql in EXPORTAR.items():
            cur.execute(sql)
            columnas = [c.name for c in cur.description]
            df = pd.DataFrame(cur.fetchall(), columns=columnas)
            df.to_csv(TABLAS / f"{nombre}.csv", index=False, encoding="utf-8")

        cur.execute("""SELECT c.relname, p.relname FROM pg_inherits i
                         JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_class p ON p.oid = i.inhparent
                        WHERE c.relkind = 'i'""")
        padres = dict(cur.fetchall())

        # Plan de la corrida mediana de cada variante (la corrida 1 tiene el mismo plan)
        cur.execute("""SELECT r.experimento, r.variante, r.rol, r.orden, r.descripcion, r.filas,
                              r.ms_mediana, r.ms_min, r.ms_max, r.bloques_mediana, m.plan, t.plan
                         FROM perf.v_resumen r
                         JOIN perf.medicion m ON m.experimento = r.experimento
                                             AND m.variante = r.variante AND m.corrida = 1
                         JOIN perf.plan_texto t ON t.experimento = r.experimento AND t.variante = r.variante
                        ORDER BY r.experimento, r.orden""")
        rendimiento = []
        for exp, var, rol, orden, desc, filas, ms, ms_min, ms_max, bloques, plan, texto in cur.fetchall():
            nombre = f"{exp}_{orden}_{_slug(var)}"
            (PLANES / f"{nombre}.txt").write_text(texto, encoding="utf-8")
            rendimiento.append({"experimento": exp, "variante": var, "rol": rol, "orden": orden,
                                "descripcion": desc, "filas": filas, "ms_mediana": _a_json(ms),
                                "ms_min": _a_json(ms_min), "ms_max": _a_json(ms_max),
                                "bloques": _a_json(bloques), "archivo_plan": f"reports/planes/{nombre}.txt",
                                **resumir_plan(plan, padres)})
        base = {r["experimento"]: r["ms_mediana"] for r in rendimiento if r["orden"] == 1}
        base_bloques = {r["experimento"]: r["bloques"] for r in rendimiento if r["orden"] == 1}
        for r in rendimiento:
            r["x_vs_antes"] = round(base[r["experimento"]] / r["ms_mediana"], 2)
            r["pct_bloques_vs_antes"] = round(100 * r["bloques"] / base_bloques[r["experimento"]], 2)
        pd.DataFrame(rendimiento).drop(columns=["descripcion"]).to_csv(
            TABLAS / "rendimiento_planes.csv", index=False, encoding="utf-8")
        resultados["rendimiento"] = rendimiento

        cur.execute("SELECT metrica, valor FROM analisis.kpi_general")
        resultados["kpi"] = {m: _a_json(v) for m, v in cur.fetchall()}
        cur.execute("SELECT metrica, valor FROM analisis.cadena_resumen")
        resultados["cadenas"] = {m: _a_json(v) for m, v in cur.fetchall()}
        cur.execute("""SELECT sum(filas_copiadas), count(*), sum(segundos_copy), sum(segundos_tipado),
                              (SELECT count(*) FROM dw.fact_vuelo), (SELECT count(*) FROM calidad.vuelo_cuarentena),
                              min(anio_mes), max(anio_mes)
                         FROM control.carga_mes""")
        copiadas, meses, s_copy, s_tipado, hecho, cuarentena, desde, hasta = cur.fetchone()
        resultados["datos"] = {"filas_copiadas": copiadas, "meses": meses, "segundos_copy": _a_json(s_copy),
                               "segundos_tipado": _a_json(s_tipado), "filas_hecho": hecho,
                               "filas_cuarentena": cuarentena, "desde": desde, "hasta": hasta}
        cur.execute("""SELECT count(*) FROM pg_inherits WHERE inhparent = 'dw.fact_vuelo'::regclass""")
        resultados["datos"]["particiones"] = cur.fetchone()[0]
        cur.execute("""SELECT version(), current_setting('shared_buffers'), current_setting('work_mem'),
                              current_setting('maintenance_work_mem'), current_setting('effective_cache_size'),
                              current_setting('max_parallel_workers_per_gather'),
                              pg_database_size(current_database())""")
        version, sb, wm, mwm, ecs, par, tam = cur.fetchone()
        resultados["entorno"] = {"postgres": version.split(" on ")[0], "shared_buffers": sb, "work_mem": wm,
                                 "maintenance_work_mem": mwm, "effective_cache_size": ecs,
                                 "max_parallel_workers_per_gather": par, "bytes_base": tam}
        cur.execute("SELECT count(*), count(*) FILTER (WHERE ok) FROM control.verificacion")
        total, ok = cur.fetchone()
        resultados["verificaciones"] = {"total": total, "ok": ok}

    (RAIZ / "reports" / "resultados.json").write_text(
        json.dumps(resultados, indent=2, ensure_ascii=False, default=_a_json), encoding="utf-8")
    print(f"Exportadas {len(EXPORTAR) + 1} tablas y {len(rendimiento)} planes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
