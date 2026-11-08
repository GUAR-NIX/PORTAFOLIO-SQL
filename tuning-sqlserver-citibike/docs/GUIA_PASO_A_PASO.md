# Guía paso a paso: cómo leer el laboratorio de rendimiento

Esta guía explica **qué hace cada experimento y por qué**. No repite cifras: todas las mediciones están en el [README](../README.md) (generado desde `reports/` por `scripts/generar_readme.py`) y en `reports/tablas/experimentos_tuning.csv`. Así no hay dos versiones de un mismo número.

## 1. Conceptos básicos

- **Página de 8 KB.** SQL Server lee y escribe las tablas rowstore en páginas de 8 KB. Una **lectura lógica** es pedir una página a la memoria (buffer pool); una **lectura física** es traerla del disco porque no estaba en memoria.
- **Por qué medir lecturas lógicas además del tiempo.** Para un mismo plan y los mismos datos, las lecturas lógicas son casi fijas; el tiempo depende de la CPU, del disco y de qué haya en memoria. Por eso el laboratorio reporta las dos cosas.
- **En caliente y en frío.** *En caliente*: las páginas ya están en memoria (lo habitual en un servidor con uso continuo). *En frío*: antes de cada corrida se ejecuta `CHECKPOINT` + `DBCC DROPCLEANBUFFERS`, que vacía la caché de datos y obliga a leer del disco (lo que ve la primera consulta del día o una consulta sobre datos poco usados). `DROPCLEANBUFFERS` afecta a **toda la instancia**: solo se usa en una instancia de laboratorio.
- **Mediana de 5 corridas.** Cada variante se ejecuta una vez para calentar y compilar, luego 5 veces en caliente y 5 en frío. Se reporta la mediana, que no se deja arrastrar por una corrida aislada lenta. La figura 03 muestra cada corrida.

## 2. Las estructuras del laboratorio (`sql/05_estructuras_laboratorio.sql`)

Las mismas filas válidas se copian en cuatro tablas:

| Tabla | Diseño | Para qué sirve |
| :--- | :--- | :--- |
| `lab.viaje_heap` | Heap, sin índices | Línea base: cualquier filtro obliga a un `Table Scan`. |
| `lab.viaje_rowstore_nocov` | Agrupado `(fecha_inicio, id_viaje)` + `IX_nocov_origen_fecha (estacion_origen_id, fecha_inicio)` + `IX_nocov_duracion (duracion_seg)`, sin `INCLUDE` | Provocar *Key Lookups* y *parameter sniffing*. |
| `lab.viaje_rowstore` | Mismo agrupado + `IX_cov_origen_fecha_inc` con `INCLUDE` + índice filtrado `IX_filt_casual_largo` | La tabla afinada. |
| `lab.viaje_columnstore` | Clustered Columnstore | Agregaciones grandes en modo *batch*. |

Además, `lab.serie_diaria_estacion` guarda los viajes por estación y día **con todos los días del trimestre** (0 cuando no hubo salidas). Esto es lo que permite que E6 compare dos consultas que devuelven exactamente lo mismo.

## 3. Los experimentos

**E1 · Índice cubriente.** Viajes de la estación más activa en marzo. El heap lee toda la tabla. El índice no cubriente encuentra las filas rápido, pero por cada una hace un *Key Lookup* al índice agrupado para traer `duracion_seg` y `distancia_m`. El índice con `INCLUDE` ya tiene esas columnas en sus hojas: no hay lookups.

**E2 · SARGability (diseño 2×2).** `YEAR(fecha_inicio) = 2024 AND MONTH(...) = 3 AND DAY(...) BETWEEN 4 AND 10` frente a `fecha_inicio >= '2024-03-04' AND fecha_inicio < '2024-03-11'`, cada una sobre el heap y sobre la tabla agrupada por fecha. Una función aplicada a la columna impide buscar en el índice; un rango no sirve de nada si la tabla no está ordenada por fecha. Solo la combinación de ambos cambios reduce las lecturas.

**E3 · Columnstore.** Agregación de todo el trimestre por mes, hora, tipo de bici y membresía. El rowstore lee todas las columnas de todas las páginas; el columnstore lee solo las columnas que usa la consulta, comprimidas, y procesa en modo *batch* (bloques de filas en lugar de una a una).

**E4 · Índice filtrado.** Viajes de usuarios ocasionales de 30 minutos o más. El índice `WHERE es_miembro = 0 AND duracion_seg >= 1800` solo contiene esas filas, así que es pequeño y no hay que recorrer el resto.

**E5 · Parameter sniffing.** La consulta `WHERE duracion_seg >= @p` se compila primero con `@p = 80.000` (casi ninguna fila): el optimizador elige `IX_nocov_duracion` + *Key Lookup*. Ese plan queda en caché y se reutiliza con `@p = 1.200`, que devuelve cientos de miles de filas: un lookup por fila. Soluciones medidas: `OPTION (RECOMPILE)` (compila con el valor real en cada ejecución; cuesta una compilación por llamada) y `OPTION (OPTIMIZE FOR UNKNOWN)` (compila para un valor "promedio" según la densidad; es estable, pero puede no ser óptimo para valores extremos). Un índice cubriente también lo evitaría (ver E1), a costa de espacio.

**E6 · Subconsulta correlacionada vs. función de ventana.** Media móvil de 7 días por estación. Ojo con `ROWS 6 PRECEDING` sobre una tabla con días faltantes: "6 filas antes" no es "6 días antes" y el resultado cambia. Por eso se usa la serie diaria densa (con 0 en los días sin salidas), y con ella ambas consultas calculan lo mismo; el control `qa` lo comprueba fila a fila con `EXCEPT` en los dos sentidos.

**E7 · Top-N por grupo (diseño 2×2).** Últimos 10 viajes de las 10 estaciones más activas con `ROW_NUMBER()` y con `CROSS APPLY (SELECT TOP (10) ... ORDER BY fecha_inicio DESC, id_viaje DESC)`, sobre el heap y sobre la tabla con índice `(estacion_origen_id, fecha_inicio)`. El desempate por `id_viaje` en ambas versiones garantiza el mismo resultado. Sin índice, `CROSS APPLY` es peor: recorre la tabla una vez por estación.

**E8 · Cursor vs. operación en conjunto.** Suma acumulada de viajes por estación y día: un cursor `FAST_FORWARD` que recorre la serie fila a fila frente a `SUM() OVER (PARTITION BY ... ORDER BY ... ROWS UNBOUNDED PRECEDING)`.

**E9 · Regresión y plan forzado con Query Store.** Se usa la consulta de E5 con un texto idéntico en tres pasos, para que Query Store la reconozca como un único `query_id`:
1. Se compila con el valor típico (`@p = 1.200`): plan con escaneo, el "bueno".
2. Se saca el plan de caché y la siguiente compilación usa `@p = 80.000`: aparece el plan con *Key Lookup* y la consulta típica empeora (regresión).
3. Se ejecuta `sp_query_store_force_plan` con el plan del paso 1 y se repite la secuencia del paso 2. Query Store aplica el plan forzado aunque el primer valor sea el atípico. Al final se quita el forzado para dejar la base como estaba; `perf.demo_plan_forzado` guarda los `plan_id` y el estado de cada paso.

**Curva del punto de inflexión.** Para las 8 estaciones más activas se amplía la ventana de 1 a 91 días. Con pocas filas, *seek + lookup* lee menos que recorrer todo el heap; a partir de cierto porcentaje de la tabla, cada lookup (varias páginas por fila) suma más que el escaneo completo. El índice cubriente no tiene ese problema.

**Tiempo de carga con y sin índices.** Las mismas filas se copian a una tabla de prueba (3 corridas por estrategia, en orden rotado): sin índices, con los índices creados antes del `INSERT` y con los índices creados después.

## 4. Cómo verificar los resultados

- `qa.sp_validar_calidad` revisa reconciliación, equivalencia de resultados y la dirección de cada mejora (por ejemplo, "el índice cubriente lee menos del 5 % de las páginas del heap"). Falla con `THROW` si algo no cuadra.
- `tests/test_pipeline_sql.py` vuelve a revisar todo contra la base y comprueba que los CSV de `reports/` son los de la corrida que está en la base.
- `tests/test_readme_cifras.py` comprueba que el README es exactamente el que produce `scripts/generar_readme.py` a partir de `reports/`, y recalcula algunas cifras clave por su cuenta.
- Los planes reales están en `reports/planes/*.sqlplan` (se abren con SSMS o Azure Data Studio).

## 5. Preguntas típicas de entrevista

1. **¿Por qué un índice no siempre ayuda?** Si la consulta devuelve muchas filas y el índice no cubre las columnas pedidas, cada fila exige un *Key Lookup*; pasado el punto de inflexión, escanear es más barato.
2. **¿Qué es un predicado SARGable?** Uno que deja la columna "limpia" a un lado del operador (`col >= valor`), de modo que el motor puede buscar en el índice. `YEAR(col) = 2024` no lo es.
3. **¿Cómo detectas parameter sniffing?** El mismo procedimiento es rápido con unos valores y lento con otros; el plan en caché muestra filas estimadas muy distintas de las reales. Query Store muestra varios planes para el mismo `query_id`.
4. **RECOMPILE vs. OPTIMIZE FOR UNKNOWN vs. forzar plan.** RECOMPILE da el mejor plan para cada valor, pero compila en cada llamada (malo para consultas muy frecuentes). OPTIMIZE FOR UNKNOWN da un plan estable y medio. Forzar un plan con Query Store corrige una regresión sin tocar el código de la aplicación, pero hay que revisarlo cuando cambian los datos.
5. **¿Cuándo usar columnstore?** Para consultas que leen muchas filas y pocas columnas (agregaciones, reportes). Para buscar pocas filas por clave, un índice rowstore suele ser mejor.
6. **¿Por qué medir en frío y en caliente?** Porque responden a preguntas distintas: en caliente se mide el trabajo de CPU y memoria; en frío se suma la E/S de disco, que es donde un diseño que lee menos páginas gana más.
7. **¿Qué es un Key Lookup y cómo lo eliminas?** Es la búsqueda adicional que hace el motor en el índice agrupado (o en el heap) para traer las columnas que el índice no cubriente no tiene, una vez por cada fila encontrada. Se elimina con un índice cubriente (`INCLUDE` de las columnas pedidas) o, si hay pocas columnas, añadiéndolas a la clave. En E1 se ve en el plan como `Key Lookup` y desaparece con el índice con `INCLUDE`.
8. **¿Qué es el punto de inflexión (tipping point)?** El porcentaje de la tabla a partir del cual escanear es más barato que hacer *seek + lookup*: cada lookup cuesta varias páginas, así que con pocas filas gana el índice y con muchas gana el escaneo. La curva del laboratorio amplía la ventana de 1 a 91 días y marca dónde se cruzan las lecturas. Por eso el optimizador deja de usar un índice no cubriente cuando la consulta devuelve "demasiadas" filas.
9. **¿Índice cubriente o índice filtrado?** El cubriente evita los lookups para *todas* las filas que cumplan la clave de búsqueda, pero ocupa espacio por cada fila de la tabla. El filtrado indexa solo un subconjunto (`WHERE es_miembro = 0 AND duracion_seg >= 1800` en E4): es pequeño y barato de mantener, pero solo sirve a consultas cuyo predicado esté contenido en el filtro. Se elige según qué parte de las consultas toca siempre el mismo subconjunto.
10. **¿Por qué un cursor es más lento que una operación en conjunto?** El cursor procesa fila a fila con una iteración del motor por fila, y mantiene estado entre llamadas; la operación en conjunto (`SUM() OVER (... ROWS UNBOUNDED PRECEDING)`) deja que el optimizador procese bloques de filas de una sola vez. En E8 ambas dan la misma suma acumulada; la diferencia está en el tiempo, y crece con el número de filas. El cursor solo se justifica cuando hay lógica que no se puede expresar en conjunto.
11. **¿Qué es Query Store y para qué sirve?** Es una función de SQL Server que guarda por cada consulta (`query_id`) sus planes (`plan_id`) y sus estadísticas de ejecución a lo largo del tiempo, en la propia base. Permite ver qué consultas empeoraron, comparar planes y detectar regresiones sin depender de la caché de planes, que se pierde al reiniciar. Aquí está activo desde `01_crear_base.sql` y lo usa E9.
12. **¿Cuándo y cómo se fuerza un plan, y qué riesgos tiene?** Cuando una consulta cambia a un plan peor (regresión por *parameter sniffing*, estadísticas o cambios de versión) y el plan bueno aún existe en Query Store, se fija con `sp_query_store_force_plan @query_id, @plan_id` sin tocar el código de la aplicación. El riesgo es que el plan forzado deje de ser adecuado si los datos cambian, o que falle el forzado (si el índice ya no existe) y vuelva a compilar libremente: hay que vigilar `last_force_failure_reason` y revisar el forzado periódicamente. En E9 se fuerza el plan bueno y al final se quita con `sp_query_store_unforce_plan`.
