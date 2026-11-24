"""Escribe README.es.md a partir de reports/ y data/cifras_control.json.

Todas las cifras del README salen de estos archivos; tests/test_readme_cifras.py
comprueba que el README es exactamente el que produce este script.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from formato import mb, ms, num, pct, veces  # noqa: E402

RAIZ = Path(__file__).resolve().parents[1]
TABLAS = RAIZ / "reports" / "tablas"
MESES = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
         "septiembre", "octubre", "noviembre", "diciembre"]
CAUSAS = {"avion_previo": "Avión anterior tarde", "aerolinea": "Aerolínea (tripulación, mantenimiento, limpieza...)",
          "nas": "Sistema aéreo nacional (NAS: tráfico, aeropuerto, clima no extremo)",
          "clima": "Clima extremo", "seguridad": "Seguridad"}


def leer(nombre: str) -> pd.DataFrame:
    return pd.read_csv(TABLAS / f"{nombre}.csv")


def fecha_larga(texto: str) -> str:
    f = pd.Timestamp(texto)
    return f"{f.day} de {MESES[f.month - 1]}"


def tabla_md(encabezado: list[str], filas: list[list], alineacion: str) -> str:
    lineas = ["| " + " | ".join(encabezado) + " |",
              "| " + " | ".join({"l": ":---", "r": "---:", "c": ":---:"}[a] for a in alineacion) + " |"]
    lineas += ["| " + " | ".join(str(c) for c in fila) + " |" for fila in filas]
    return "\n".join(lineas)


def contexto() -> dict:
    res = json.loads((RAIZ / "reports" / "resultados.json").read_text(encoding="utf-8"))
    control = json.loads((RAIZ / "data" / "cifras_control.json").read_text(encoding="utf-8"))
    return {"res": res, "control": control}


def render() -> str:
    c = contexto()
    res, control = c["res"], c["control"]
    k, d, cad, ent = res["kpi"], res["datos"], res["cadenas"], res["entorno"]
    rend = pd.DataFrame(res["rendimiento"])
    meses_txt = "enero a diciembre" if d["meses"] == 12 else f"{d['meses']} meses"
    bytes_zip = sum(m["bytes_zip"] for m in control["meses"].values())

    aer = leer("ranking_aerolineas")
    mejor_a, peor_a = aer.iloc[0], aer.iloc[-1]
    mensual = leer("mensual")
    mensual["mes_nombre"] = [MESES[pd.Timestamp(m).month - 1] for m in mensual["mes"]]
    mejor_m = mensual.loc[mensual["pct_puntuales"].idxmax()]
    peor_m = mensual.loc[mensual["pct_puntuales"].idxmin()]
    serie = leer("serie_diaria").sort_values("rango_peor_dia")
    peor_d = serie.iloc[0]
    aer_dia = leer("aerolinea_dia")
    pico = aer_dia.sort_values("rango_cancelados_anio").iloc[0]
    episodio = aer_dia[(aer_dia["aerolinea"] == pico["aerolinea"])
                       & (aer_dia["fecha"].between("2024-07-19", "2024-07-24"))]
    hd = leer("hora_dia_semana")
    por_hora = hd.groupby("hora").apply(
        lambda g: (g["programados"] * g["pct_salidas_retrasadas"]).sum() / g["programados"].sum(),
        include_groups=False)
    vol_hora = hd.groupby("hora")["programados"].sum()
    horas_ok = por_hora[vol_hora >= 50000]
    por_dia = hd.groupby(["dia_semana", "nombre_dia"]).apply(
        lambda g: (g["programados"] * g["pct_salidas_retrasadas"]).sum() / g["programados"].sum(),
        include_groups=False).reset_index(name="pct")
    causas = leer("causas_mes").drop_duplicates("causa").set_index("causa")["pct_del_anio"]
    rutas = leer("rutas_problematicas")
    aerop = leer("ranking_aeropuertos")
    feriados = leer("feriados")
    fer_dist = leer("feriados_por_distancia")
    por_paso = leer("cadena_por_paso")
    por_tam = leer("cadena_por_tamano_raiz")
    por_hora_raiz = leer("cadena_por_hora_raiz")
    por_hora_raiz = por_hora_raiz[por_hora_raiz["raices"] >= 2000]
    pico_hora = por_hora_raiz.loc[por_hora_raiz["vuelos_afectados_por_raiz"].idxmax()]
    cad_aer = leer("cadena_por_aerolinea")
    ejemplo = leer("cadena_ejemplo")
    calidad = leer("calidad_reglas")
    idx_lab = leer("indices_lab")
    idx_hecho = leer("indices_hecho").set_index("indice")["bytes"]
    corr = leer("correlacion_fisica").set_index("columna")["correlacion"]
    verif = res["verificaciones"]
    zonas = leer("validacion_zona_horaria")
    op = leer("tiempos_operacion").set_index("operacion")["segundos"]
    archivo_tiempos = TABLAS / "tiempos_pipeline.csv"
    minutos = round(pd.read_csv(archivo_tiempos)["segundos"].sum() / 60) if archivo_tiempos.exists() else 25

    def r(exp: str, orden: int) -> pd.Series:
        return rend[(rend["experimento"] == exp) & (rend["orden"] == orden)].iloc[0]

    brin_f = idx_lab[(idx_lab["columna"] == "fecha_vuelo")].set_index("indice")
    btree_mb, brin128_mb = brin_f.loc["lab_btree_fecha", "bytes"], brin_f.loc["lab_brin_fecha_128", "bytes"]
    q_total = int(calidad.loc[calidad["tipo"] == "cuarentena", "vuelos"].sum())

    s = []
    s.append(f"""🇪🇸 **Español** · 🇺🇸 [English (summary)](README.md)

# Puntualidad de los vuelos comerciales de EE. UU. en PostgreSQL (2024)

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17.11_(Docker)-336791?logo=postgresql&logoColor=white)](docker-compose.yml)
[![Vuelos](https://img.shields.io/badge/Vuelos_2024-{num(d['filas_copiadas']).replace('.', '%2E')}-0f4c81)](data/cifras_control.json)
[![Particiones](https://img.shields.io/badge/Particiones-{d['particiones']}_(RANGE_por_mes)-6250d6)](sql/04_modelo_estrella.sql)
[![Controles](https://img.shields.io/badge/Controles_SQL-{verif['ok']}%2F{verif['total']}_OK-16a34a)](sql/11_verificaciones.sql)
[![Pruebas](https://img.shields.io/badge/pytest-psycopg-0284c7)](tests/)

**Pregunta:** ¿qué aerolíneas, aeropuertos, horas y rutas concentran los retrasos de los vuelos de EE. UU., por qué se retrasan y cuánto se propaga un retraso a los vuelos siguientes del mismo avión? Y, del lado técnico: ¿cuánto ayudan el particionado, los índices BRIN y parciales y una vista materializada en PostgreSQL, medido con `EXPLAIN (ANALYZE, BUFFERS)`?

**Datos:** {num(d['filas_copiadas'])} vuelos de {meses_txt} de 2024 de las {num(k['aerolineas'])} aerolíneas que reportan al Departamento de Transporte (*Reporting Carrier On-Time Performance*, Bureau of Transportation Statistics). Se cargan los 12 ZIP mensuales ({num(bytes_zip / 1e6)} MB) con `COPY` en PostgreSQL {ent['postgres'].split()[1]} dentro de Docker; {num(d['filas_hecho'])} vuelos pasan los controles de calidad y {num(d['filas_cuarentena'])} ({pct(100 * d['filas_cuarentena'] / d['filas_copiadas'], 3)}) quedan en cuarentena.

> Las cifras de este README las escribe `scripts/generar_readme.py` a partir de `reports/` y `data/cifras_control.json`; una prueba comprueba que el README coincide con esos archivos. Contenedor con 4 GB de memoria, `shared_buffers = {ent['shared_buffers']}`, `work_mem = {ent['work_mem']}` y hasta {ent['max_parallel_workers_per_gather']} workers paralelos, en un Ryzen 5 4600G con disco SSD. Los milisegundos dependen del equipo; las páginas leídas, casi no.

---

## 1. Resultados

| Indicador (2024) | Valor |
| :--- | ---: |
| Vuelos programados (después de la cuarentena) | {num(k['vuelos_programados'])} |
| Puntuales (llegan con menos de 15 min de retraso) | **{pct(k['pct_puntuales'], 2)}** |
| Cancelados | {num(k['vuelos_cancelados'])} ({pct(k['pct_cancelados'], 2)}) |
| Desviados | {num(k['vuelos_desviados'])} ({pct(k['pct_desviados'], 2)}) |
| Retraso medio de llegada (vuelos que llegaron) | {num(k['retraso_medio_llegada_min'], 2)} min |
| Aeropuertos de origen · días | {num(k['aeropuertos_origen'])} · {num(k['dias'])} |

- **Aerolíneas:** la más puntual es {mejor_a['nombre']} ({mejor_a['aerolinea']}, {pct(mejor_a['pct_puntuales'])}) y la menos puntual {peor_a['nombre']} ({peor_a['aerolinea']}, {pct(peor_a['pct_puntuales'])}): {num(mejor_a['pct_puntuales'] - peor_a['pct_puntuales'], 1)} puntos de diferencia.
- **Peor día del año:** el {fecha_larga(peor_d['fecha'])} solo llegó a tiempo el {pct(peor_d['pct_puntuales'])} de los vuelos y se canceló el {pct(peor_d['pct_cancelados'])}. Coincide con la falla informática mundial de ese día (una actualización defectuosa de CrowdStrike dejó fuera de servicio equipos con Windows). {aer.set_index('aerolinea').loc[pico['aerolinea'], 'nombre'].replace(' Inc.', '')} ({pico['aerolinea']}) canceló {num(episodio['cancelados'].sum())} vuelos entre el 19 y el 24 de julio y tuvo los cuatro peores días de cancelaciones de cualquier aerolínea en el año.
- **Hora del día:** el retraso se acumula a lo largo del día: a las 6:00 sale con 15+ min de retraso el {pct(horas_ok.loc[6])} de los vuelos y a las {int(horas_ok.idxmax())}:00 el {pct(horas_ok.max())}.
- **Causas:** de los minutos de retraso de las llegadas con 15+ min, el {pct(causas['avion_previo'])} se debe a que **el avión llegó tarde de su vuelo anterior**, el {pct(causas['aerolinea'])} a la propia aerolínea y el {pct(causas['nas'])} al sistema aéreo nacional; el clima extremo explica el {pct(causas['clima'])}.
- **Retrasos en cadena (CTE recursiva):** de {num(cad['raices'])} retrasos que nacen en un vuelo, el **{pct(cad['pct_propagan'])}** se propaga al menos al vuelo siguiente del mismo avión; en total arrastran a {num(cad['vuelos_afectados_aguas_abajo'])} vuelos más. Un retraso en el vuelo de las {int(pico_hora['hora_raiz'])}:00 afecta en promedio a {num(pico_hora['vuelos_afectados_por_raiz'], 2)} vuelos posteriores; uno después de las 21:00, a casi ninguno.
- **Rendimiento:** la poda de particiones lee el {pct(r('P1', 3)['pct_bloques_vs_antes'])} de las páginas que lee la tabla sin particionar ({veces(r('P1', 3)['x_vs_antes'])}); el índice BRIN sobre la fecha ocupa {mb(brin128_mb)} MB frente a {mb(btree_mb)} MB del B-tree y responde la consulta de una semana en {ms(r('P2', 3)['ms_mediana'])} ms frente a {ms(r('P2', 2)['ms_mediana'])} ms; el índice parcial de cancelados acelera su consulta {veces(r('P4', 3)['x_vs_antes'])} ocupando {mb(idx_hecho['fact_vuelo_cancelados'])} MB.

![Puntualidad por aerolínea](reports/figures/01_puntualidad_aerolineas.png)

## 2. Arquitectura

```mermaid
flowchart LR
    subgraph BTS["Fuentes públicas"]
        Z["12 ZIP mensuales BTS<br/>On-Time Performance 2024"]
        L["Tablas de búsqueda BTS<br/>aeropuertos · aerolíneas"]
        T["Zonas horarias IANA<br/>mwgg/Airports (MIT)"]
    end
    subgraph PY["Python"]
        D["descargar_datos.py<br/>reanudable (HTTP Range)<br/>cifras_control.json"]
    end
    subgraph PG["PostgreSQL 17 en Docker"]
        C["stg.vuelo_crudo (UNLOGGED)<br/>COPY FROM PROGRAM unzip -p<br/>control.carga_mes"]
        S["stg.vuelo tipado<br/>control.cifras_mes"]
        Q["calidad.* · {len(calidad)} reglas<br/>cuarentena en JSON"]
        F["dw.fact_vuelo<br/>PARTITION BY RANGE (mes)<br/>BRIN + índices parciales"]
        DIM["dw.dim_aerolinea<br/>dw.dim_aeropuerto (zona IANA)<br/>dw.dim_fecha (feriados)"]
        MV["dw.mv_puntualidad_diaria<br/>vista materializada"]
        TR["dw.tramo_avion<br/>WITH RECURSIVE"]
        A["analisis.*<br/>RANK · PERCENT_RANK · NTILE · LAG"]
        P["perf.medicion<br/>EXPLAIN (ANALYZE, BUFFERS) × 7"]
    end
    R["reports/<br/>CSV · planes · figuras · README"]
    Z --> D --> C --> S --> Q --> F
    L --> DIM
    T --> DIM --> Q
    F --> MV --> A
    F --> TR --> A
    F --> P
    A --> R
    P --> R
```

## 3. Puntualidad: aerolíneas, aeropuertos, horas, rutas y temporadas

Puntual = llega menos de 15 minutos después de la hora programada; los cancelados y desviados cuentan como no puntuales, igual que en el *Air Travel Consumer Report* del DOT. Los porcentajes se calculan sobre vuelos programados.

### 3.1 Aerolíneas (`RANK` y `PERCENT_RANK`)

""")
    filas = [[int(a.rango_puntualidad), f"{a.nombre} ({a.aerolinea})", num(a.programados), pct(a.pct_del_mercado),
              f"**{pct(a.pct_puntuales)}**", pct(a.pct_cancelados, 2), num(a.retraso_medio_llegada, 1),
              num(a.percentil_puntualidad, 3), int(a.rango_menos_cancelaciones)] for a in aer.itertuples()]
    s.append(tabla_md(["Rango", "Aerolínea", "Vuelos", "Mercado", "Puntuales", "Cancelados",
                       "Retraso medio (min)", "PERCENT_RANK", "Rango en cancelaciones (1 = la que menos cancela)"], filas, "clrrrrrrr"))
    dl = aer.set_index("aerolinea").loc["DL"]
    wn = aer.set_index("aerolinea").loc["WN"]
    s.append(f"""

Delta (DL) queda en el puesto {int(dl['rango_puntualidad'])} de puntualidad pese al episodio de julio. Southwest (WN), la que más vuela ({pct(wn['pct_del_mercado'])} del mercado), es la que menos cancela ({pct(wn['pct_cancelados'], 2)}). Tres regionales que operan vuelos para las grandes (Republic, Endeavor y SkyWest) están entre las cinco más puntuales.

### 3.2 Aeropuertos de origen

{len(aerop)} aeropuertos con 20.000 salidas o más en el año (unas 55 al día), ordenados por % de salidas puntuales. Además del rango nacional se calcula el cuartil (`NTILE(4)`) y el rango dentro del estado (`RANK() OVER (PARTITION BY estado ...)`).

""")
    sel = pd.concat([aerop.head(5), aerop.tail(5)])
    filas = [[int(a.rango_nacional), f"{a.iata} · {a.nombre}", a.estado, num(a.programados),
              pct(a.pct_salidas_puntuales), num(a.retraso_medio_salida, 1), num(a.percentil, 3), int(a.cuartil),
              f"{int(a.rango_en_estado)} de {int(a.aeropuertos_en_estado)}"] for a in sel.itertuples()]
    s.append(tabla_md(["Rango", "Aeropuerto", "Estado", "Salidas", "Salidas puntuales", "Retraso medio salida (min)",
                       "PERCENT_RANK", "Cuartil", "Rango en el estado"], filas, "rllrrrrcc"))
    dia_mejor = por_dia.loc[por_dia["pct"].idxmin()]
    dia_peor = por_dia.loc[por_dia["pct"].idxmax()]
    s.append(f"""

Los dos aeropuertos de Hawái encabezan la lista; al final quedan {", ".join(f"{x.iata} ({x.nombre})" for x in aerop.tail(4).iloc[::-1].itertuples())}.

![Ranking de aeropuertos](reports/figures/09_ranking_aeropuertos.png)

### 3.3 Hora del día y día de la semana

El porcentaje de salidas con 15+ min de retraso sube casi sin pausa de la mañana a la noche: los primeros vuelos salen con el avión ya en la puerta desde la noche anterior, y cada vuelo posterior hereda lo que se acumuló antes (sección 4). El {dia_mejor['nombre_dia']} es el día con menos salidas retrasadas ({pct(dia_mejor['pct'])}) y el {dia_peor['nombre_dia']} el que más ({pct(dia_peor['pct'])}).

![Hora y día de la semana](reports/figures/02_retraso_hora_dia_semana.png)

### 3.4 Causas del retraso

BTS reparte los minutos de cada llegada con 15+ min de retraso entre cinco causas; en todo el año suman {num(k['minutos_con_causa'] / 1e6, 1)} millones de minutos.

""")
    filas = [[CAUSAS[cz], pct(causas[cz], 2)] for cz in ["avion_previo", "aerolinea", "nas", "clima", "seguridad"]]
    s.append(tabla_md(["Causa", "% de los minutos de retraso"], filas, "lr"))
    s.append(f"""

"Avión anterior tarde" no es una causa original, sino la consecuencia de un retraso anterior del mismo avión: por eso la sección 4 la sigue tramo a tramo.

![Causas por mes](reports/figures/03_causas_retraso_mes.png)

### 3.5 Rutas más problemáticas

{num(rutas['rutas_evaluadas'].iloc[0])} rutas con 1.500 vuelos o más en el año (unos 4 al día), ordenadas de menor a mayor puntualidad:

""")
    filas = [[int(x.rango_peor_puntualidad), f"{x.origen} → {x.destino}", num(x.programados), pct(x.pct_puntuales),
              pct(x.pct_cancelados, 2), num(x.retraso_medio_llegada, 1), num(x.p90_retraso_llegada)]
             for x in rutas.head(8).itertuples()]
    s.append(tabla_md(["Rango", "Ruta", "Vuelos", "Puntuales", "Cancelados", "Retraso medio (min)",
                       "Percentil 90 del retraso (min)"], filas, "clrrrrr"))
    n_sfo = int((rutas.head(10)["destino"] == "SFO").sum())
    s.append(f"""

{n_sfo} de las 10 rutas menos puntuales llegan a San Francisco (SFO), un aeropuerto con pistas paralelas muy juntas que reduce las llegadas cuando hay niebla o nubes bajas.

### 3.6 Estacionalidad, episodios y feriados

""")
    filas = [[m.mes_nombre, num(m.programados), pct(m.pct_puntuales), pct(m.pct_cancelados, 2),
              num(m.retraso_medio_llegada, 1),
              "—" if pd.isna(m.cambio_pp_vs_mes_anterior) else num(m.cambio_pp_vs_mes_anterior, 2),
              int(m.rango_puntualidad)] for m in mensual.itertuples()]
    s.append(tabla_md(["Mes", "Vuelos", "Puntuales", "Cancelados", "Retraso medio (min)",
                       "Cambio vs. mes anterior (pp, LAG)", "Rango"], filas, "lrrrrrc"))
    peores = serie.head(5)
    n_julio = int(peores["fecha"].str.startswith("2024-07").sum())
    n_enero = int(peores["fecha"].between("2024-01-01", "2024-01-16").sum())
    s.append(f"""

El mejor mes es {mejor_m['mes_nombre']} ({pct(mejor_m['pct_puntuales'])}) y el peor {peor_m['mes_nombre']} ({pct(peor_m['pct_puntuales'])}): julio suma el mayor volumen del año y la falla del día 19. Los cinco peores días del año:

""")
    filas = [[int(x.rango_peor_dia), fecha_larga(x.fecha), x.nombre_dia, num(x.programados), pct(x.pct_puntuales),
              pct(x.pct_cancelados), "" if pd.isna(x.feriado) else x.feriado] for x in peores.itertuples()]
    s.append(tabla_md(["Rango", "Fecha", "Día", "Vuelos", "Puntuales", "Cancelados", "Feriado"], filas, "cllrrrl"))
    mlk = feriados.set_index("feriado").loc["Martin Luther King Jr."]
    s.append(f"""

{n_julio} de los cinco caen en el episodio de julio y {n_enero} en la primera quincena de enero, que coincide con la ola de frío ártico de esa semana; el feriado de Martin Luther King (15 de enero) cayó en plena ola de frío.

**Feriados federales.** Para cada feriado se toma la ventana de ±3 días (`dw.dim_fecha.ventana_feriado`) y se compara con el año completo:

""")
    filas = [[x.feriado, f"{fecha_larga(x.desde)} – {fecha_larga(x.hasta)}", num(x.vuelos_por_dia),
              num(x.pct_vuelos_vs_promedio, 1), pct(x.pct_puntuales), num(x.dif_pp_vs_anual, 2),
              pct(x.pct_cancelados, 2)] for x in feriados.itertuples()]
    s.append(tabla_md(["Feriado", "Ventana", "Vuelos por día", "Vuelos vs. promedio (%)", "Puntuales",
                       "Diferencia vs. año (pp)", "Cancelados"], filas, "llrrrrr"))
    d0 = fer_dist.set_index("dias_al_feriado")
    s.append(f"""

El feriado en sí no empeora la puntualidad: promediando los {int(d0.loc[0, 'dias'])} feriados, el día del feriado llega a tiempo el {pct(d0.loc[0, 'pct_puntuales'])} de los vuelos, por encima del promedio anual ({pct(k['pct_puntuales'])}), y el tercer día antes es el peor de la ventana ({pct(d0.loc[-3, 'pct_puntuales'])}). Las tres ventanas peores son Martin Luther King ({num(mlk['dif_pp_vs_anual'], 1)} pp, la ola de frío), Memorial Day y Navidad.

![Serie diaria](reports/figures/04_puntualidad_diaria_feriados.png)

## 4. Retrasos en cadena: seguir un avión a lo largo del día (`WITH RECURSIVE`)

`dw.tramo_avion` numera los {num(cad['tramos_analizados'])} vuelos operados con matrícula por avión y día ({num(cad['aviones'])} aviones, {num(cad['tramos_por_avion_dia'], 2)} tramos por avión y día en promedio) y calcula con `LAG` la holgura programada en tierra entre un tramo y el siguiente. La función `analisis.cadenas_retraso()` contiene la CTE recursiva:

```sql
WITH RECURSIVE cadena AS (
    -- Raíz: llega con 15+ min de retraso y el tramo anterior del día llegó a tiempo
    SELECT t.matricula, t.fecha_vuelo, t.n_tramo AS tramo_raiz, 0 AS paso, t.n_tramo, ...
      FROM dw.tramo_avion t
     WHERE t.retraso_llegada >= 15 AND coalesce(t.retraso_llegada_anterior, 0) < 15
    UNION ALL
    -- Paso: siguiente tramo del mismo avión, que sale de donde llegó el anterior y sale tarde
    SELECT s.matricula, s.fecha_vuelo, c.tramo_raiz, c.paso + 1, s.n_tramo, ...
      FROM cadena c
      JOIN dw.tramo_avion s ON s.matricula = c.matricula AND s.fecha_vuelo = c.fecha_vuelo
                           AND s.n_tramo = c.n_tramo + 1
     WHERE c.retraso_llegada >= 15 AND s.continua AND s.retraso_salida >= 15
)
SELECT * FROM cadena;
```

| Resultado | Valor |
| :--- | ---: |
| Retrasos raíz (nacen en ese vuelo) | {num(cad['raices'])} |
| Se propagan al menos un tramo | {num(cad['raices_que_propagan'])} ({pct(cad['pct_propagan'], 2)}) |
| Tramos afectados por propagación | {num(cad['vuelos_afectados_aguas_abajo'])} |
| Largo medio de la cadena cuando se propaga | {num(cad['largo_medio_si_propaga'], 2)} tramos |
| Cadena más larga | {num(cad['largo_maximo'])} tramos |
| Minutos de retraso de salida aguas abajo por cada minuto de retraso raíz | {num(cad['multiplicador'], 3)} |

""")
    filas = [[int(x.paso), num(x.vuelos), pct(x.pct_de_raices), num(x.retraso_salida_medio, 1),
              "—" if pd.isna(x.holgura_media) else num(x.holgura_media, 1), pct(x.pct_con_avion_previo_bts)]
             for x in por_paso[por_paso["paso"] <= 6].itertuples()]
    s.append(tabla_md(["Paso", "Vuelos", "% de las raíces", "Retraso medio de salida (min)",
                       "Holgura programada media (min)", "Con causa «avión anterior» en BTS"], filas, "crrrrr"))
    t15 = por_tam.iloc[0]
    t240 = por_tam.iloc[-1]
    wn_c = cad_aer.set_index("aerolinea").loc["WN"]
    ua_c = cad_aer.set_index("aerolinea").loc["UA"]
    filas_ej = [[int(x.n_tramo), f"{x.origen} → {x.destino}", x.salida_prog_local,
                 "—" if pd.isna(x.holgura_prog_min) else num(x.holgura_prog_min), num(x.retraso_salida),
                 num(x.retraso_llegada), "raíz" if x.paso == 0 else ("—" if pd.isna(x.paso) else int(x.paso))]
                for x in ejemplo.itertuples()]
    e0 = ejemplo.iloc[0]
    s.append(f"""

- **El tamaño de la raíz importa, pero no de forma lineal.** Un retraso de 15–29 min se propaga en el {pct(t15['pct_propagan'])} de los casos; uno de 60–119 min, en el {pct(por_tam.iloc[2]['pct_propagan'])}; uno de 4 horas o más, solo en el {pct(t240['pct_propagan'])}: con retrasos tan grandes la aerolínea suele cambiar de avión o cancelar los tramos siguientes, y la cadena "se rompe" en los datos.
- **La hora define cuántos vuelos quedan por delante.** El pico está en las {int(pico_hora['hora_raiz'])}:00 ({num(pico_hora['vuelos_afectados_por_raiz'], 2)} vuelos afectados por raíz); a partir de las 21:00 casi no quedan tramos ese día.
- **El modelo de negocio se nota.** Southwest (WN), con {num(wn_c['tramos_dia_medios'], 1)} tramos por avión y día y rotaciones cortas, tiene el mayor multiplicador ({num(wn_c['multiplicador'], 2)} minutos aguas abajo por minuto raíz); United (UA), con {num(ua_c['tramos_dia_medios'], 1)} tramos, el menor ({num(ua_c['multiplicador'], 2)}).
- **Contraste con BTS:** los minutos de "avión anterior tarde" que BTS registra en los tramos de las cadenas son el {pct(cad['pct_avion_previo_bts_sobre_total'])} de todos los minutos de esa causa en el año. El resto queda fuera por la definición de cadena usada (sección 8).

**Ejemplo:** la cadena más larga del año (desempate por mayor retraso raíz), el avión {e0['matricula']} de {e0['aerolinea']} el {fecha_larga(e0['fecha_vuelo'])}, hora local:

""")
    s.append(tabla_md(["Tramo", "Ruta", "Salida programada", "Holgura (min)", "Retraso salida", "Retraso llegada",
                       "Paso"], filas_ej, "clcrrrc"))
    s.append("""

![Retrasos en cadena](reports/figures/05_retrasos_en_cadena.png)

## 5. Rendimiento: `EXPLAIN (ANALYZE, BUFFERS)` antes y después

Cada variante se ejecuta 1 vez para calentar la caché y 7 veces con `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`; se reporta la **mediana** (`perf.medir` en `sql/10_rendimiento.sql`). "Páginas" son bloques de 8 KB leídos de `shared_buffers` o del sistema operativo. Todas las variantes de un experimento devuelven las mismas filas: un control compara el `md5` de cada resultado. Los planes completos están en [`reports/planes/`](reports/planes/) y cada corrida en `reports/tablas/rendimiento_corridas.csv`.

""")
    filas = []
    for x in rend.itertuples():
        filas.append([x.experimento, x.rol, x.variante, f"`{x.operador}`", num(x.tablas_leidas), num(x.bloques),
                      ms(x.ms_mediana), f"{ms(x.ms_min)} – {ms(x.ms_max)}",
                      "—" if x.orden == 1 else veces(x.x_vs_antes)])
    s.append(tabla_md(["Exp.", "Rol", "Variante", "Lectura en el plan", "Tablas leídas", "Páginas",
                       "ms (mediana)", "Rango (ms)", "x vs. antes"], filas, "lllllrrrr"))
    p2b, p2_128 = r("P2", 2), r("P2", 3)
    p3f = r("P3", 3)
    p3l = r("P3", 2)
    if p3l["operador"].startswith("Seq Scan"):
        p3_planificador = "el planificador ve la correlación en `pg_stats` y ni siquiera usa el BRIN"
    else:
        p3_planificador = (f"el planificador igual elige el BRIN (su estimación de costo es optimista) "
                           f"y la consulta pasa de {ms(r('P3', 1)['ms_mediana'])} a {ms(p3l['ms_mediana'])} ms")
    serie_f = leer("serie_diaria")
    semana = int(serie_f[serie_f["fecha"].between("2024-07-15", "2024-07-21")]["programados"].sum())
    s.append(f"""

- **P1 · Poda de particiones.** Julio con un rango sobre `fecha_vuelo` lee 1 de las {d['particiones']} particiones ({num(r('P1', 3)['bloques'])} páginas frente a {num(r('P1', 1)['bloques'])}). Con `extract(month FROM fecha_vuelo) = 7` el planificador no puede podar: lee las {int(r('P1', 2)['tablas_leidas'])} particiones y además evalúa dos funciones por fila, así que es {num(r('P1', 2)['ms_mediana'] / r('P1', 1)['ms_mediana'], 1)} veces más lento que la tabla sin particionar ({ms(r('P1', 2)['ms_mediana'])} ms frente a {ms(r('P1', 1)['ms_mediana'])} ms).
- **P2 · BRIN frente a B-tree (una semana, {num(semana)} vuelos).** Con BRIN el plan es un *Bitmap Heap Scan* que revisa todas las filas de los bloques candidatos: descarta {num(p2_128['filas_descartadas_recheck'])} filas por *recheck* ({pct(100 * p2_128['filas_descartadas_recheck'] / (semana + p2_128['filas_descartadas_recheck']), 1)} de lo que revisa). Lee casi las mismas páginas que el B-tree ({num(p2_128['bloques'])} frente a {num(p2b['bloques'])}) y es más rápido ({ms(p2_128['ms_mediana'])} ms frente a {ms(p2b['ms_mediana'])} ms) porque recorre bloques contiguos en vez de buscar entrada por entrada.
- **P3 · BRIN sin correlación.** Sobre `distancia_millas` (correlación física {num(corr['distancia_millas'], 4)}) {p3_planificador}. Forzado con `enable_seqscan = off`, no descarta ningún bloque: lee {num(p3f['bloques'])} páginas, revisa {num(p3f['filas_descartadas_recheck'])} filas de más y tarda {ms(p3f['ms_mediana'])} ms, más que el *Seq Scan*. Ahí el B-tree sí sirve.
- **P4 · Índice parcial.** Las cancelaciones de Delta del 18 al 25 de julio: el índice `WHERE cancelado` permite un *Index Only Scan* de {num(r('P4', 3)['bloques'])} páginas. Un B-tree completo sobre las mismas columnas es casi igual de rápido ({ms(r('P4', 2)['ms_mediana'])} ms), pero ocupa {mb(idx_hecho['fact_vuelo_aerolinea_fecha_completo'])} MB frente a {mb(idx_hecho['fact_vuelo_cancelados'])} MB y hay que mantenerlo en cada `INSERT`.
- **P5 · Historial de un avión.** La matrícula no es la clave de partición, así que no hay poda; el índice `(matricula, salida_prog_utc)` hace un *Index Scan* en cada partición y entrega las filas ya ordenadas (sin *Sort*). Es parcial (`WHERE matricula IS NOT NULL AND NOT cancelado`), aunque aquí deja fuera solo el {pct(k['pct_cancelados'])} de las filas: ocupa {mb(idx_hecho['fact_vuelo_avion'])} MB.
- **P6 · Vista materializada.** El reporte anual por aerolínea lee {num(r('P6', 2)['bloques'])} páginas de la vista frente a {num(r('P6', 1)['bloques'])} del hecho. Refrescarla con `REFRESH MATERIALIZED VIEW CONCURRENTLY` tarda {num(op['REFRESH MATERIALIZED VIEW CONCURRENTLY'], 1)} s.

![Rendimiento antes y después](reports/figures/06_rendimiento_antes_despues.png)

### 5.1 BRIN frente a B-tree: tamaño y tiempo de creación

Misma tabla sin particionar (`lab.vuelo_plano`, {mb(brin_f['bytes_tabla'].iloc[0])} MB, ordenada por hora de salida); cada índice se crea 3 veces y se toma la mediana.

""")
    filas = [[f"`{x.indice}`", x.tipo, x.columna, "—" if pd.isna(x.pages_per_range) else int(x.pages_per_range),
              mb(x.bytes), num(x.segundos_creacion_mediana, 2), num(corr[x.columna], 4)]
             for x in idx_lab.itertuples()]
    s.append(tabla_md(["Índice", "Tipo", "Columna", "pages_per_range", "Tamaño (MB)", "Creación (s)",
                       "Correlación física"], filas, "lllrrrr"))
    s.append(f"""

El BRIN de 128 páginas ocupa {num(btree_mb / brin128_mb)} veces menos que el B-tree y se crea en {num(brin_f.loc['lab_brin_fecha_128', 'segundos_creacion_mediana'], 2)} s frente a {num(brin_f.loc['lab_btree_fecha', 'segundos_creacion_mediana'], 2)} s. Con 32 páginas por rango el índice crece, pero cada rango candidato es más chico: el *recheck* descarta {num(r('P2', 4)['filas_descartadas_recheck'])} filas en vez de {num(p2_128['filas_descartadas_recheck'])}.

![BRIN frente a B-tree](reports/figures/07_brin_vs_btree.png)

## 6. Calidad de datos y reconciliación

Cada vuelo se evalúa contra {len(calidad)} reglas en una sola pasada. Las de **cuarentena** describen datos imposibles: el vuelo va completo (en JSON, con sus motivos) a `calidad.vuelo_cuarentena` y no entra al hecho. Las **marcas** describen casos válidos pero especiales que entran al hecho y se cuentan.

""")
    filas = [[f"`{x.codigo}`", x.tipo, x.descripcion, num(x.vuelos), pct(x.pct, 4)] for x in calidad.itertuples()]
    s.append(tabla_md(["Regla", "Tipo", "Qué detecta", "Vuelos", "% del total"], filas, "lllrr"))
    zmax = zonas["max_pct_aeropuerto"].max()
    s.append(f"""

- **Horas `2400` y medianoche.** BTS escribe la medianoche como `2400`; convertir `hhmm` a minutos y sumarlos a la fecha la lleva sola a las 00:00 del día siguiente. Las llegadas programadas al día siguiente y las salidas reales pasada la medianoche quedan marcadas.
- **Zonas horarias.** Las horas de BTS son locales. Cada aeropuerto recibe su zona IANA (`America/Chicago`, `Pacific/Honolulu`...) y todas las horas se guardan también en UTC (`timestamptz`); {num(calidad.set_index('codigo').loc['M_CAMBIO_HORA_EN_VUELO', 'vuelos'])} vuelos estaban en el aire durante un cambio de horario de verano. La asignación se valida con los propios datos: si la zona de un aeropuerto estuviera mal, casi todos sus vuelos fallarían `Q_ZONA_INCONSISTENTE`; el aeropuerto con más fallos tiene el {pct(zmax, 2)} de sus vuelos en esa regla.
- **Cuarentena total:** {num(q_total)} disparos de reglas en {num(d['filas_cuarentena'])} vuelos. La mayoría ({num(calidad.set_index('codigo').loc['Q_ZONA_INCONSISTENTE', 'vuelos'])}) son horarios en los que la llegada programada no coincide con la salida programada más la duración programada.

**Reconciliación.** Tres capas, todas automáticas: (1) `scripts/descargar_datos.py` calcula con Python, leyendo cada CSV dentro de su ZIP, las filas, cancelados, desviados y sumas de retrasos y distancias por mes; (2) `control.cifras_mes` calcula lo mismo en SQL sobre el texto copiado; (3) por mes, filas copiadas = hecho + cuarentena. Las pruebas comparan (1) con (2) métrica por métrica y `sql/11_verificaciones.sql` revisa {verif['total']} controles ({verif['ok']} OK).

""")
    cm = leer("carga_mes").merge(leer("reconciliacion"), on=["anio_mes", "filas_copiadas"])
    filas = [[MESES[x.anio_mes % 100 - 1], num(control['meses'][f"{x.anio_mes // 100}-{x.anio_mes % 100:02d}"]['filas']),
              num(x.filas_copiadas), num(x.filas_hecho), num(x.filas_cuarentena), num(x.diferencia),
              num(x.segundos_copy, 1)] for x in cm.itertuples()]
    s.append(tabla_md(["Mes", "Filas en el CSV (Python)", "Filas copiadas (COPY)", "Hecho", "Cuarentena",
                       "Diferencia", "COPY (s)"], filas, "lrrrrrr"))
    s.append(f"""

`COPY ... FROM PROGRAM 'unzip -p ...'` carga los {num(d['filas_copiadas'])} vuelos en {num(d['segundos_copy'], 0)} s en total, sin descomprimir los CSV en disco.

![Reglas de calidad](reports/figures/08_calidad_reglas.png)

## 7. Decisiones técnicas

- **¿Por qué PostgreSQL?** Es gratuito, corre igual en Docker en cualquier sistema operativo y tiene las piezas que este proyecto quería practicar: particionado declarativo, BRIN, índices parciales, vistas materializadas, CTE recursivas y `EXPLAIN (ANALYZE, BUFFERS)`. Un motor columnar como DuckDB agregaría los 7 M de filas más rápido, pero no tiene índices BRIN ni parciales y no es un motor transaccional; la versión se fija (`postgres:17.11-bookworm`) para que los planes sean reproducibles.
- **¿Por qué BRIN sobre la fecha?** Los vuelos se cargan en orden cronológico, así que la correlación física de la fecha es {num(corr['fecha_vuelo'], 4)}. En ese caso un BRIN ocupa kilobytes en lugar de decenas de megabytes, se crea en una fracción del tiempo, casi no encarece los `INSERT` y para rangos de días o semanas responde igual o mejor que un B-tree (P2). No se usaría para buscar un vuelo suelto ni sobre columnas sin orden físico (P3).
- **Particionado por mes.** Los análisis y las cargas son mensuales: la poda lee solo los meses pedidos y una carga o un borrado de un mes toca una sola partición (`DETACH PARTITION` en vez de `DELETE`). La partición `DEFAULT` existe para que una fecha fuera de rango no rompa la carga y un control exige que quede vacía.
- **Staging `UNLOGGED` y carga por mes con `COMMIT`.** El staging se puede reconstruir desde el ZIP, así que no necesita WAL. El procedimiento `control.cargar_rango` confirma cada mes: si la PC se apaga, la siguiente corrida salta los meses en estado `OK`.
- **UTC para la cadena, hora local para el pasajero.** La hora local agrupa por "hora del día"; las restas entre aeropuertos (holgura, orden de los tramos) se hacen en `timestamptz`.
- **Cuarentena en JSON, no `DELETE`.** `to_jsonb(fila)` guarda el vuelo completo con sus motivos: se puede auditar o reprocesar sin volver al ZIP.
- **Vista materializada para el reporte.** El reporte se recalcula en milisegundos desde un resumen de {num(idx_hecho['mv_puntualidad_diaria'] / 1048576, 0)} MB; el costo es refrescarla después de cada carga.
- **Configuración del contenedor.** 4 GB de memoria, `shared_buffers` ~25 % del total, `work_mem` moderado porque cada nodo de ordenamiento o hash de cada worker puede usarlo, `random_page_cost = 1.1` para SSD y `jit = off` para que los tiempos no dependan de la compilación JIT.

## 8. Limitaciones

- Los tiempos se miden **en caliente** (después de una corrida de calentamiento); no se vacía la caché del sistema operativo entre corridas, así que "páginas leídas" puede incluir lecturas de la caché del sistema y no del disco.
- La cadena de retrasos solo sigue a un avión **dentro del mismo día** (fecha local del vuelo): un retraso que viene de la noche anterior aparece como raíz. Se corta también si un tramo se cancela, se desvía o no tiene matrícula.
- La propagación se mide con horas reales (sale tarde porque llegó tarde), no con un modelo causal: un tramo puede salir tarde por otra razón aunque el anterior haya llegado tarde.
- Solo incluye a las aerolíneas obligadas a reportar al DOT (las de mayores ingresos) y vuelos dentro de EE. UU. y sus territorios. Las zonas horarias vienen de una tabla externa (mwgg/Airports) y se validan con los horarios, pero un error de unos minutos en un horario programado manda el vuelo a cuarentena aunque sea real.
- Las referencias a la falla informática del 19 de julio y a la ola de frío de enero son contexto externo; los datos solo muestran el efecto.

## 9. Cómo reproducir

```bash
python -m venv .venv
.venv/Scripts/python -m pip install -r requirements.txt     # Linux/macOS: .venv/bin/python
.venv/Scripts/python scripts/ejecutar_todo.py               # Docker encendido; ~{minutos} min + 10 de descarga
.venv/Scripts/python -m pytest -p no:cacheprovider          # con el contenedor encendido
docker compose down                                         # conserva el volumen; -v lo borra
```

`ejecutar_todo.py --meses 1-6` carga solo el primer semestre y `--desde 07` retoma desde un script SQL. Detalle paso a paso, conceptos y preguntas de entrevista en [docs/GUIA_PASO_A_PASO.md](docs/GUIA_PASO_A_PASO.md).

```
├── docker-compose.yml          PostgreSQL 17.11, 4 GB, configuración de memoria
├── docker/Dockerfile           imagen oficial + unzip (para COPY FROM PROGRAM)
├── sql/01 … 11                 esquemas → carga → modelo → calidad → índices → análisis → cadenas → laboratorio → rendimiento → verificaciones
├── scripts/                    descarga, ejecución completa, exportación, figuras y README
├── tests/                      pytest + psycopg
├── data/cifras_control.json    cifras de control calculadas sobre los CSV
└── reports/                    tablas CSV, planes de EXPLAIN, figuras y resultados.json
```

## 10. Fuente y licencia

- **Vuelos:** Bureau of Transportation Statistics (U.S. Department of Transportation), *Reporting Carrier On-Time Performance (1987–present)*, archivos mensuales de 2024 en [transtats.bts.gov/PREZIP](https://transtats.bts.gov/PREZIP/). Tablas de búsqueda `L_AIRPORT_ID` y `L_UNIQUE_CARRIERS` de [TranStats](https://www.transtats.bts.gov/). Obra del gobierno de EE. UU., de **dominio público**.
- **Zonas horarias de aeropuertos:** [mwgg/Airports](https://github.com/mwgg/Airports), licencia MIT.
- **Código:** licencia MIT (ver [LICENSE](LICENSE)). Los datos conservan la licencia de su fuente.
""")
    return "".join(s)


def main() -> int:
    (RAIZ / "README.es.md").write_text(render(), encoding="utf-8")
    print("README.es.md generado")
    return 0


if __name__ == "__main__":
    sys.exit(main())
