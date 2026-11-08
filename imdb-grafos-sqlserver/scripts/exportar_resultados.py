"""
exportar_resultados.py
Lee los resultados ya calculados en SQL Server (vistas rpt y tablas qa/mart)
y los guarda en reports/: tablas CSV y reports/metricas.json, que es de donde
salen todas las cifras del README.

Uso:  .venv\\Scripts\\python scripts\\exportar_resultados.py
"""
from __future__ import annotations

import json
from pathlib import Path

from conexion import conectar, consultar

RAIZ = Path(__file__).resolve().parents[1]
REPORTES = RAIZ / "reports"
TABLAS = REPORTES / "tablas"

CONSULTAS_CSV = {
    "auditoria_carga": "SELECT * FROM rpt.auditoria_carga ORDER BY inicio",
    "bitacora_pasos": "SELECT paso, filas, ms FROM qa.bitacora WHERE paso_id IN "
                      "(SELECT MAX(paso_id) FROM qa.bitacora GROUP BY paso) ORDER BY paso_id",
    "conteo_tablas": """
        SELECT s.name + '.' + t.name AS tabla,
               CASE WHEN t.is_node = 1 THEN 'NODE' WHEN t.is_edge = 1 THEN 'EDGE' ELSE 'tabla' END AS tipo,
               SUM(p.rows) AS filas,
               CAST(SUM(a.total_pages) * 8 / 1024.0 AS DECIMAL(9,1)) AS mb
        FROM sys.tables AS t JOIN sys.schemas AS s ON s.schema_id = t.schema_id
        JOIN sys.partitions AS p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
        JOIN (SELECT object_id, SUM(total_pages) AS total_pages FROM sys.allocation_units AS au
              JOIN sys.partitions AS pp ON pp.partition_id = au.container_id GROUP BY object_id) AS a
          ON a.object_id = t.object_id
        WHERE s.name IN ('stg', 'dw', 'grafo', 'busqueda', 'mart')
        GROUP BY s.name, t.name, t.is_node, t.is_edge ORDER BY s.name, t.name""",
    "peliculas_por_decada": "SELECT * FROM rpt.peliculas_por_decada ORDER BY decada",
    "genero_resumen": "SELECT * FROM rpt.genero_resumen ORDER BY calificacion_media DESC",
    "genero_decada": "SELECT * FROM rpt.genero_decada ORDER BY genero, decada",
    "mejor_decada_genero": "SELECT * FROM rpt.mejor_decada_genero ORDER BY decada, genero, puesto",
    "actor_prolifico_decada": "SELECT * FROM rpt.actor_prolifico_decada ORDER BY decada, puesto, nombre",
    "percentil_votos": "SELECT * FROM rpt.percentil_votos ORDER BY decada",
    "decil_votos": "SELECT * FROM rpt.decil_votos ORDER BY decil",
    "numero_bacon_distribucion": "SELECT * FROM rpt.numero_bacon_distribucion ORDER BY grados",
    "numero_bacon_mas_lejanos": """
        SELECT TOP 20 nb.grados, gp.nombre, gp.peliculas, nb.camino
        FROM mart.numero_bacon AS nb JOIN grafo.Persona AS gp ON gp.persona_id = nb.persona_id
        ORDER BY nb.grados DESC, gp.peliculas DESC""",
    "ejemplo_separacion": "SELECT * FROM rpt.ejemplo_separacion ORDER BY ejemplo, salto",
    "top_colaboradores": "SELECT * FROM rpt.top_colaboradores ORDER BY posicion",
    "elenco_fiel_top": "SELECT TOP 50 * FROM rpt.elenco_fiel ORDER BY peliculas DESC, director, actor",
    "director_elenco_fiel": """
        SELECT TOP 20 director, COUNT(*) AS actores_fieles, MAX(peliculas) AS max_peliculas_mismo_actor
        FROM rpt.elenco_fiel GROUP BY director ORDER BY COUNT(*) DESC, director""",
    "nucleo_talento_top": "SELECT TOP 15 * FROM rpt.nucleo_talento_resumen ORDER BY personas DESC",
    "rendimiento": "SELECT * FROM rpt.medicion ORDER BY prueba, ms_mediana",
    "controles_calidad": "EXEC qa.sp_validar_calidad @lanzar_error = 0",
}

BUSQUEDAS = [("padrino", "todas"), ("amelie", "todas"), ("señor anill*", "todas"),
             ("war", "todas"), ("ciudad de dios", "libre")]


def main() -> None:
    TABLAS.mkdir(parents=True, exist_ok=True)
    datos = {}
    for nombre, sql in CONSULTAS_CSV.items():
        df = consultar(sql)
        df.to_csv(TABLAS / f"{nombre}.csv", index=False, encoding="utf-8")
        datos[nombre] = df
        print(f"  {nombre}.csv ({len(df)} filas)")

    # Ejemplos de búsqueda: índice invertido frente a LIKE (resultados, no tiempos)
    cn = conectar()
    ejemplos = []
    for consulta, modo in BUSQUEDAS:
        ind = consultar(f"EXEC busqueda.sp_buscar @consulta = '{consulta}', @modo = '{modo}', @top = 5", cn)
        like_txt = consulta.replace("*", "").replace(" ", "%")
        lik = consultar(f"EXEC busqueda.sp_buscar_like @texto = '{like_txt}', @top = 5", cn)
        ejemplos.append({
            "consulta": consulta, "modo": modo,
            "peliculas_indice": int(ind["total_peliculas"].iloc[0]) if len(ind) else 0,
            "peliculas_like": int(lik["total_peliculas"].iloc[0]) if len(lik) else 0,
            "top_indice": [f"{r.titulo} ({r.anio}) ← «{r.texto_encontrado}»" for r in ind.itertuples()],
            "top_like": [f"{r.titulo} ({r.anio}) ← «{r.texto_encontrado}»" for r in lik.itertuples()],
        })
    fts = consultar("SELECT CAST(FULLTEXTSERVICEPROPERTY('IsFullTextInstalled') AS INT) AS instalado", cn)
    cn.close()

    aud = datos["auditoria_carga"]
    conteo = datos["conteo_tablas"].set_index("tabla")
    bacon = datos["numero_bacon_distribucion"]
    controles = datos["controles_calidad"]
    alcanzados = int(bacon.loc[bacon["grados"] > 0, "personas"].sum())
    nodos_persona = int(conteo.loc["grafo.Persona", "filas"])
    metricas = {
        "filtro": consultar("SELECT nombre, valor FROM etl.parametro").set_index("nombre")["valor"].to_dict(),
        "carga": aud[["archivo", "metodo", "filas_fuente", "filas_leidas", "filas_cargadas",
                      "filas_rechazadas", "filas_filtradas", "segundos"]].to_dict(orient="records"),
        "filas_por_tabla": conteo["filas"].astype(int).to_dict(),
        "mb_por_tabla": conteo["mb"].astype(float).to_dict(),
        "grafo": {
            "nodos_persona": nodos_persona,
            "nodos_pelicula": int(conteo.loc["grafo.Pelicula", "filas"]),
            "aristas_actuo_en": int(conteo.loc["grafo.ActuoEn", "filas"]),
            "aristas_dirigio": int(conteo.loc["grafo.Dirigio", "filas"]),
            "aristas_trabajo_con": int(conteo.loc["grafo.TrabajoCon", "filas"]),
            "pares_colaboradores": int(conteo.loc["grafo.TrabajoCon", "filas"]) // 2,
        },
        "bacon": {
            "distribucion": bacon.to_dict(orient="records"),
            "alcanzados": alcanzados,
            "pct_red_alcanzada": round(100 * (alcanzados + 1) / nodos_persona, 2),
            "pct_hasta_3_grados": round(100 * int(bacon.loc[bacon["grados"].between(1, 3), "personas"].sum())
                                        / nodos_persona, 2),
            "promedio_grados": round(float((bacon["grados"] * bacon["personas"]).sum()) / alcanzados, 3),
        },
        "busqueda": {"full_text_instalado": int(fts["instalado"].iloc[0]), "ejemplos": ejemplos},
        "rendimiento": datos["rendimiento"].to_dict(orient="records"),
        "controles": {"total": len(controles), "ok": int((controles["estado"] == "OK").sum())},
    }
    (REPORTES / "metricas.json").write_text(json.dumps(metricas, indent=2, ensure_ascii=False, default=str),
                                            encoding="utf-8")
    print(f"  metricas.json · controles {metricas['controles']['ok']}/{metricas['controles']['total']} OK")


if __name__ == "__main__":
    main()
