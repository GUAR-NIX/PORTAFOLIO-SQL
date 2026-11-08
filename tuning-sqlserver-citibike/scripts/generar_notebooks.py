"""Genera y ejecuta los 3 notebooks del proyecto a partir de reports/tablas (no necesitan SQL Server).

Uso:
  python scripts/generar_notebooks.py

Cada notebook se arma con nbformat y se ejecuta con nbclient, de modo que las salidas
(tablas y gráficos) que se ven en GitHub son las de la última corrida de reports/.
"""

from __future__ import annotations

from pathlib import Path

import nbformat
from nbclient import NotebookClient

RAIZ = Path(__file__).resolve().parents[1]
DIR_NB = RAIZ / "notebooks"

PREAMBULO = """\
from pathlib import Path
import json
import matplotlib.pyplot as plt
import pandas as pd

pd.set_option("display.max_columns", 30)
pd.set_option("display.width", 160)
RAIZ = Path.cwd().parent if Path.cwd().name == "notebooks" else Path.cwd()
TABLAS = RAIZ / "reports" / "tablas"

def leer(nombre: str) -> pd.DataFrame:
    return pd.read_csv(TABLAS / f"{nombre}.csv")

def miles(x) -> str:
    return f"{x:,.0f}".replace(",", ".")

def dec(x, n=1) -> str:
    return f"{x:,.{n}f}".replace(",", "X").replace(".", ",").replace("X", ".")
"""


def md(texto: str):
    return nbformat.v4.new_markdown_cell(texto)


def code(texto: str):
    return nbformat.v4.new_code_cell(texto)


def notebook_01() -> nbformat.NotebookNode:
    return nbformat.v4.new_notebook(cells=[
        md("# 01 · Ingesta, limpieza y reconciliación\n\n"
           "Citi Bike Nueva York, enero–marzo 2024. El script `descargar_datos.py` consolida los 3 ZIP mensuales en un TSV, "
           "SQL Server lo carga con `BULK INSERT` y `etl.sp_limpiar` marca cada fila con su motivo de exclusión. "
           "Aquí se comprueba que Python y SQL Server cuentan exactamente lo mismo."),
        code(PREAMBULO),
        md("## 1. Bitácora del ETL\nDuración de cada etapa en la corrida que generó `reports/`."),
        code("bitacora = leer('bitacora_etl')\n"
             "bitacora['segundos'] = (bitacora['duracion_ms'] / 1000).round(1)\n"
             "bitacora[['etapa', 'filas_afectadas', 'segundos']]"),
        md("## 2. Reconciliación Python vs. SQL Server\n"
           "`data/cifras_control.json` lo calcula pandas leyendo los CSV originales; `resumen_limpieza.csv` sale de `rpt.resumen_limpieza_calidad`."),
        code("control = json.loads((RAIZ / 'data' / 'cifras_control.json').read_text(encoding='utf-8'))\n"
             "limpieza = leer('resumen_limpieza')\n"
             "sql = dict(zip(limpieza['estado_calidad'], limpieza['filas']))\n"
             "comparacion = pd.DataFrame({'python': pd.Series(control['desglose_motivos']), 'sql_server': pd.Series(sql)})\n"
             "comparacion['diferencia'] = comparacion['python'] - comparacion['sql_server']\n"
             "print('Filas brutas:', miles(control['filas_totales_brutas']), '| válidas:', miles(control['filas_validas']),\n"
             "      f\"({dec(control['tasa_retencion_pct'], 2)} %)\")\n"
             "assert (comparacion['diferencia'] == 0).all()\n"
             "comparacion"),
        code("excl = limpieza[limpieza['estado_calidad'] != 'VALIDO'].sort_values('filas')\n"
             "fig, ax = plt.subplots(figsize=(9, 3))\n"
             "ax.barh(excl['estado_calidad'], excl['filas'], color='#ea580c')\n"
             "for i, n in enumerate(excl['filas']):\n"
             "    ax.text(n, i, ' ' + miles(n), va='center')\n"
             "ax.set_xlabel('Filas excluidas')\n"
             "ax.set_title('Motivos de exclusión (las filas se conservan en limpio.viaje)', loc='left')\n"
             "plt.show()"),
        md("**Lectura:** casi todas las exclusiones son viajes sin estación o coordenadas de destino (bicicletas que no se "
           "devolvieron en una estación o registros incompletos). Representan menos del 0,3 % del total, así que no sesgan "
           "el análisis; aun así quedan en `limpio.viaje` con su motivo para poder auditarlas."),
        md("## 3. Controles automáticos (`qa.sp_validar_calidad`)"),
        code("qa = leer('controles_calidad')\n"
             "print(f\"{(qa['estado'] == 'OK').sum()} de {len(qa)} controles en OK\")\n"
             "qa.groupby('categoria')['estado'].value_counts().unstack(fill_value=0)"),
        code("qa[['orden', 'categoria', 'control', 'valor_observado', 'valor_esperado', 'estado']]"),
    ])


def notebook_02() -> nbformat.NotebookNode:
    return nbformat.v4.new_notebook(cells=[
        md("# 02 · Laboratorio de rendimiento: índices, planes y Query Store\n\n"
           "Cada variante se ejecutó 5 veces en caliente y 5 en frío (con `DBCC DROPCLEANBUFFERS` antes de cada corrida). "
           "Las tablas muestran la **mediana**. Todas las variantes de un experimento devuelven el mismo número de filas y el mismo checksum."),
        code(PREAMBULO),
        code("exp = leer('experimentos_tuning')\n"
             "cols = ['codigo_experimento', 'rol_comparacion', 'operador_principal', 'lecturas_logicas',\n"
             "        'duracion_ms_caliente', 'duracion_ms_frio', 'speedup_caliente_x', 'speedup_frio_x', 'filas_devueltas']\n"
             "exp[cols]"),
        md("## 1. ¿Cuánto se repite la medición?\nDispersión de las 5 corridas de cada variante: si la mediana es estable, los puntos quedan juntos."),
        code("med = leer('mediciones_corridas')\n"
             "disp = (med.groupby(['codigo_experimento', 'modo'])['duracion_ms']\n"
             "          .agg(['median', 'min', 'max']).unstack('modo'))\n"
             "disp.columns = [f'{a}_{b.lower()}' for a, b in disp.columns]\n"
             "disp['rango_relativo_caliente_%'] = ((disp['max_caliente'] - disp['min_caliente']) / disp['median_caliente'] * 100).round(1)\n"
             "disp.round(1)"),
        code("fig, ax = plt.subplots(figsize=(12, 4.5))\n"
             "codigos = list(exp['codigo_experimento'])\n"
             "for modo, color, d in (('CALIENTE', '#0f4c81', -0.18), ('FRIO', '#ea580c', 0.18)):\n"
             "    datos = [med[(med['codigo_experimento'] == c) & (med['modo'] == modo)]['duracion_ms'] for c in codigos]\n"
             "    ax.boxplot(datos, positions=[i + d for i in range(len(codigos))], widths=0.3,\n"
             "               patch_artist=True, boxprops=dict(facecolor=color, alpha=0.4), medianprops=dict(color=color))\n"
             "ax.set_yscale('log')\n"
             "ax.set_xticks(range(len(codigos)), codigos, rotation=70, fontsize=7)\n"
             "ax.set_ylabel('ms por ejecución (log)')\n"
             "ax.set_title('Caliente (azul) vs. frío (naranja)', loc='left')\n"
             "plt.show()"),
        md("## 2. Aislar el efecto de cada cambio (E2 y E7)\n"
           "En un diseño 2×2 se ve qué parte de la mejora viene del índice y qué parte de la reescritura."),
        code("for pref in ('E2_', 'E7_'):\n"
             "    sub = exp[exp['codigo_experimento'].str.startswith(pref)][['variante', 'rol_comparacion', 'lecturas_logicas', 'duracion_ms_caliente', 'duracion_ms_frio']]\n"
             "    display(sub)"),
        code("e2 = exp[exp['codigo_experimento'].str.startswith('E2_')].set_index('rol_comparacion')\n"
             "base = e2.loc['ANTES', 'lecturas_logicas']\n"
             "for rol in ('SOLO_REESCRITURA', 'SOLO_INDICE', 'DESPUES'):\n"
             "    print(f\"E2 {rol:<17}: {dec(e2.loc[rol, 'lecturas_logicas'] / base * 100, 1)} % de las páginas del heap\")"),
        md("**Lectura:** en E2 ni la reescritura sola (el heap no está ordenado por fecha) ni el índice solo (la función sobre la "
           "columna impide buscar en él) reducen las páginas leídas; la reescritura sola sí ahorra CPU porque deja de evaluar "
           "tres funciones por fila. Las lecturas solo bajan con los dos cambios juntos. En E7 el índice por estación hace la mayor "
           "parte del trabajo; `CROSS APPLY` sin índice es peor que la consulta original porque recorre la tabla una vez por estación."),
        md("## 3. Punto de inflexión del Key Lookup"),
        code("tp = leer('curva_tipping_point')\n"
             "display(tp[['etiqueta_ventana', 'filas_calificadas', 'pct_tabla', 'lecturas_heap_scan', 'lecturas_forzado_lookup',\n"
             "            'lecturas_nocov_natural', 'operador_nocov_natural', 'lecturas_covering_seek', 'lecturas_columnstore']])\n"
             "fig, ax = plt.subplots(figsize=(9, 4.5))\n"
             "ax.plot(tp['pct_tabla'], tp['lecturas_forzado_lookup'], 'o-', color='#dc2626', label='Seek + Key Lookup forzado')\n"
             "ax.plot(tp['pct_tabla'], tp['lecturas_heap_scan'], 's--', color='#64748b', label='Table Scan del heap')\n"
             "ax.plot(tp['pct_tabla'], tp['lecturas_covering_seek'], 'D-', color='#15803d', label='Índice cubriente')\n"
             "ax.set_xscale('log'); ax.set_yscale('log')\n"
             "ax.set_xlabel('% de la tabla que cumple el filtro'); ax.set_ylabel('Lecturas lógicas')\n"
             "ax.legend(); plt.show()"),
        code("import numpy as np\n"
             "# Punto de cruce aproximado (interpolación log-log entre las dos ventanas que lo rodean)\n"
             "d = np.log(tp['lecturas_forzado_lookup']) - np.log(tp['lecturas_heap_scan'])\n"
             "i = int(np.argmax(d.to_numpy() > 0))\n"
             "x0, x1 = np.log(tp.loc[i - 1, 'pct_tabla']), np.log(tp.loc[i, 'pct_tabla'])\n"
             "cruce = np.exp(x0 + (0 - d[i - 1]) * (x1 - x0) / (d[i] - d[i - 1]))\n"
             "print(f'El Key Lookup forzado empieza a leer más páginas que el scan completo hacia el {dec(cruce, 2)} % de la tabla')"),
        md("## 4. Parameter sniffing (E5) y plan forzado con Query Store (E9)"),
        code("display(exp[exp['codigo_experimento'].str.match('E5_|E9_')][['codigo_experimento', 'variante', 'operador_principal',\n"
             "        'filas_estimadas_acceso', 'filas_reales_acceso', 'lecturas_logicas', 'duracion_ms_caliente', 'duracion_ms_frio']])\n"
             "leer('demo_plan_forzado')"),
        md("**Lectura:** el plan compilado para un umbral de 80.000 s estima casi ninguna fila y elige *Index Seek + Key Lookup*; "
           "reutilizado con 1.200 s hace un lookup por cada fila. `RECOMPILE` y `OPTIMIZE FOR UNKNOWN` vuelven al escaneo. "
           "En E9 la misma regresión se corrige sin tocar el código: `sp_query_store_force_plan` fija el plan original y, aunque "
           "la consulta se recompile con el valor atípico, Query Store aplica el plan forzado."),
        md("## 5. Almacenamiento y tiempo de carga"),
        code("display(leer('huella_almacenamiento'))\n"
             "carga = leer('tiempos_carga')\n"
             "carga[['estrategia', 'descripcion', 'corridas', 'mediana_ms_insercion', 'mediana_ms_indices', 'mediana_ms_total', 'min_ms_total', 'max_ms_total']]"),
    ])


def notebook_03() -> nbformat.NotebookNode:
    return nbformat.v4.new_notebook(cells=[
        md("# 03 · Analítica operativa: Citi Bike Nueva York, enero–marzo 2024\n\n"
           "Consultas sobre el modelo estrella (`dw.fact_viaje` en columnstore). El trimestre es invierno: no sirve para hablar "
           "de estacionalidad anual, pero sí del crecimiento mes a mes, del uso de e-bikes y del desbalance diario de estaciones."),
        code(PREAMBULO),
        md("## 1. Viajes por mes"),
        code("mes_todo = leer('kpi_mensual')\n"
             "print('Viajes del archivo de enero que empezaron el 31-12-2023:', miles(mes_todo.loc[mes_todo['anio'] == 2023, 'total_viajes'].sum()))\n"
             "mes = mes_todo[mes_todo['anio'] == 2024].reset_index(drop=True)\n"
             "mes['crec_vs_mes_anterior_%'] = (mes['total_viajes'].pct_change() * 100).round(1)\n"
             "mes[['nombre_mes', 'total_viajes', 'crec_vs_mes_anterior_%', 'pct_electrica', 'pct_miembro', 'duracion_media_min', 'distancia_media_m']]"),
        code("fig, ax = plt.subplots(figsize=(8, 4))\n"
             "ax.bar(mes['nombre_mes'], mes['viajes_electrica'] / 1e6, color='#0284c7', label='Eléctrica')\n"
             "ax.bar(mes['nombre_mes'], mes['viajes_clasica'] / 1e6, bottom=mes['viajes_electrica'] / 1e6, color='#0f4c81', label='Clásica')\n"
             "ax.set_ylabel('Millones de viajes'); ax.legend(); ax.set_title('Viajes válidos por mes', loc='left')\n"
             "plt.show()\n"
             "tot = mes_todo[['total_viajes', 'viajes_electrica', 'viajes_miembro']].sum()\n"
             "print(f\"Trimestre: {miles(tot['total_viajes'])} viajes; e-bike {dec(tot['viajes_electrica'] / tot['total_viajes'] * 100)} %; \"\n"
             "      f\"miembros {dec(tot['viajes_miembro'] / tot['total_viajes'] * 100)} %\")"),
        md("## 2. Perfil horario: días laborales vs. fin de semana"),
        code("hor = leer('perfil_horario_semanal')\n"
             "piv = hor.pivot(index='hora', columns='tipo_dia', values='total_viajes')\n"
             "ax = piv.plot(figsize=(9, 4), marker='o')\n"
             "ax.set_ylabel('Viajes en el trimestre'); ax.set_title('Viajes por hora de inicio', loc='left')\n"
             "plt.show()\n"
             "for tipo, sub in hor.groupby('tipo_dia'):\n"
             "    top = sub.nlargest(2, 'total_viajes')\n"
             "    dur = (sub['duracion_media_min'] * sub['total_viajes']).sum() / sub['total_viajes'].sum()\n"
             "    print(f\"{tipo}: horas pico {', '.join(f'{h:02d}:00' for h in top['hora'])}; duración media {dec(dur, 2)} min\")"),
        md("**Lectura:** los días laborales tienen dos picos (mañana y tarde) propios de viajes al trabajo; el fin de semana "
           "se concentra a media tarde y los viajes son más largos."),
        md("## 3. Desbalance de estaciones en la mañana"),
        code("est = leer('desbalance_estaciones')\n"
             "cols = ['estacion_id', 'estacion_nombre', 'total_salidas', 'total_llegadas', 'balance_neto_trimestre',\n"
             "        'balance_neto_manana_6_10h', 'balance_neto_tarde_16_20h']\n"
             "print('Se vacían en la mañana (más salidas que llegadas):')\n"
             "display(est.nsmallest(5, 'balance_neto_manana_6_10h')[cols])\n"
             "print('Se llenan en la mañana (más llegadas que salidas):')\n"
             "display(est.nlargest(5, 'balance_neto_manana_6_10h')[cols])"),
        code("fig, ax = plt.subplots(figsize=(6.5, 6))\n"
             "ax.scatter(est['balance_neto_manana_6_10h'], est['balance_neto_tarde_16_20h'], s=8, alpha=0.4, color='#0f4c81')\n"
             "ax.axhline(0, color='grey', lw=0.8); ax.axvline(0, color='grey', lw=0.8)\n"
             "ax.set_xlabel('Balance mañana (06–10 h)'); ax.set_ylabel('Balance tarde (16–20 h)')\n"
             "ax.set_title('Cada punto es una estación', loc='left')\n"
             "plt.show()\n"
             "r = est['balance_neto_manana_6_10h'].corr(est['balance_neto_tarde_16_20h'])\n"
             "print(f'Correlación mañana vs. tarde: {dec(r, 2)} (negativa = la tarde invierte el flujo de la mañana)')"),
        md("## 4. Rutas más frecuentes"),
        code("rutas = leer('top_rutas')\n"
             "rutas.head(10)[['origen_nombre', 'destino_nombre', 'viajes', 'pct_electrica', 'pct_miembro', 'duracion_media_min']]"),
    ])


def ejecutar(nb: nbformat.NotebookNode, ruta: Path) -> None:
    nb.metadata["kernelspec"] = {"name": "python3", "display_name": "Python 3", "language": "python"}
    NotebookClient(nb, timeout=600, kernel_name="python3", resources={"metadata": {"path": str(DIR_NB)}}).execute()
    nbformat.write(nb, ruta)
    print(f"[ok] {ruta.relative_to(RAIZ)} ejecutado sin errores")


def main() -> None:
    DIR_NB.mkdir(exist_ok=True)
    for vieja in DIR_NB.glob("*.ipynb"):
        vieja.unlink()
    ejecutar(notebook_01(), DIR_NB / "01_ingesta_limpieza_y_reconciliacion.ipynb")
    ejecutar(notebook_02(), DIR_NB / "02_laboratorio_indices_planes_y_query_store.ipynb")
    ejecutar(notebook_03(), DIR_NB / "03_analitica_operativa_citibike_2024T1.ipynb")


if __name__ == "__main__":
    main()
