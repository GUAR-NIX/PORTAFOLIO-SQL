# Guía paso a paso

Esta guía explica **qué hace cada script y por qué**. Las cifras están en el [README](../README.es.md), que se genera desde `reports/` con `scripts/generar_readme.py`; aquí casi no se repiten números para que no haya dos versiones de un mismo dato.

## 1. Cómo correrlo

Requisitos: Docker Desktop encendido, Python 3.12 o superior y unos 6 GB libres para el volumen de PostgreSQL.

```bash
python -m venv .venv
.venv/Scripts/python -m pip install -r requirements.txt     # en Linux/macOS: .venv/bin/python
.venv/Scripts/python scripts/ejecutar_todo.py               # 12 meses: ~10 min de descarga + ~12 min de proceso
.venv/Scripts/python -m pytest -p no:cacheprovider          # con el contenedor encendido
docker compose down                                         # apaga PostgreSQL y conserva el volumen
```

- `--meses 1-6` carga solo enero a junio (para equipos con menos disco o memoria).
- `--desde 07` retoma desde `sql/07_analisis.sql` sin repetir la carga.
- Si la PC se apaga a mitad de la carga, volver a ejecutar el mismo comando continúa: la descarga reanuda el `.part` con una petición HTTP `Range` y la carga salta los meses que ya están en `control.carga_mes` con estado `OK`.
- Para empezar desde cero: `docker compose down -v` (borra el volumen) y otra vez `ejecutar_todo.py`.

La base queda en `127.0.0.1:55432` (usuario `analista`, base `vuelos`; la contraseña de este contenedor local está en `docker-compose.yml`). Se puede abrir con DBeaver, pgAdmin o `docker compose exec db psql -U analista -d vuelos`.

## 2. El recorrido de los datos

| Paso | Script | Qué hace |
| :--- | :--- | :--- |
| Descarga | `scripts/descargar_datos.py` | Baja 12 ZIP de BTS, las tablas de búsqueda de aeropuertos y aerolíneas, y la zona horaria de cada aeropuerto. Calcula las **cifras de control** leyendo los CSV con Python (`data/cifras_control.json`). |
| Esquemas | `sql/01_esquemas.sql` | `stg`, `ref`, `control`, `calidad`, `dw`, `analisis`, `lab`, `perf`. |
| Carga | `sql/02_staging_y_carga.sql` | `COPY ... FROM PROGRAM 'unzip -p ...'` a `stg.vuelo_crudo` (110 columnas de texto), conversión de tipos a `stg.vuelo`, auditoría (`control.carga_mes`) y cifras de control en SQL (`control.cifras_mes`). |
| Referencias | `sql/03_referencias.sql` | Tablas de BTS (en ISO-8859-1) y zonas horarias. |
| Modelo | `sql/04_modelo_estrella.sql` | Dimensiones (aerolínea, aeropuerto con zona IANA, fecha con feriados) y el hecho `dw.fact_vuelo` con `PARTITION BY RANGE (fecha_vuelo)`: 12 particiones mensuales y una `DEFAULT` que debe quedar vacía. |
| Calidad | `sql/05_calidad_y_carga_dw.sql` | Evalúa 17 reglas en una pasada, manda a cuarentena lo imposible, convierte horas locales a UTC y carga el hecho. |
| Índices y vista | `sql/06_indices_y_vista.sql` | BRIN, índices parciales y `dw.mv_puntualidad_diaria`. |
| Análisis | `sql/07_analisis.sql` | Rankings, hora × día, causas, rutas, serie diaria, feriados. |
| Cadenas | `sql/08_cadenas_retraso.sql` | Tramos de cada avión y la CTE recursiva. |
| Laboratorio | `sql/09_laboratorio_brin.sql` | Copia sin particionar; tamaño y tiempo de creación de BRIN y B-tree. |
| Rendimiento | `sql/10_rendimiento.sql` | P1–P6 con `EXPLAIN (ANALYZE, BUFFERS)`, 1 calentamiento + 7 corridas, mediana. |
| Verificación | `sql/11_verificaciones.sql` | Controles que detienen el proceso con `RAISE EXCEPTION` si algo no cuadra. |
| Reportes | `scripts/exportar_reportes.py`, `generar_graficos.py`, `generar_readme.py` | CSV, planes, figuras y README. |

## 3. Conceptos que usa el proyecto

**`COPY` y `FROM PROGRAM`.** `COPY` es la forma más rápida de meter filas en PostgreSQL: lee el archivo en el servidor sin pasar fila por fila por el cliente. `FROM PROGRAM` ejecuta un comando en el servidor y lee su salida; aquí, `unzip -p` descomprime el CSV al vuelo, así que nunca se escribe el CSV descomprimido (unos 250 MB por mes) en disco. Requiere ser superusuario o tener el rol `pg_execute_server_program`, algo aceptable en un contenedor local y no en un servidor compartido.

**Staging `UNLOGGED`.** Las tablas `UNLOGGED` no escriben en el WAL (el registro que permite recuperar la base tras una caída): cargan más rápido, pero se vacían si el servidor se cae. Para datos que se pueden volver a leer del ZIP es el compromiso correcto; el hecho `dw.fact_vuelo` sí es una tabla normal.

**Procedimientos con `COMMIT`.** `control.cargar_rango` es un `PROCEDURE` (no una función) porque puede confirmar la transacción después de cada mes. Así un corte a mitad del año no deshace los meses ya cargados.

**Horas locales y UTC.** BTS da las horas en hora local del aeropuerto y en formato `hhmm` (donde `2400` es la medianoche del día siguiente). Para restar horas entre aeropuertos de zonas distintas (por ejemplo, la holgura entre la llegada a Denver y la salida siguiente hacia Chicago) todo se pasa a `timestamptz` con `hora_local AT TIME ZONE 'America/Denver'`. Usar el nombre IANA y no un desfase fijo (UTC−7) importa por dos razones: el horario de verano cambia el desfase dos veces al año, y Arizona y Hawái no lo aplican. La zona asignada a cada aeropuerto se valida con los propios datos: salida programada + duración programada tiene que dar la llegada programada en la zona del destino.

**Particionado declarativo.** `PARTITION BY RANGE (fecha_vuelo)` divide el hecho en una tabla física por mes. El planificador descarta (poda) las particiones que no pueden contener filas del filtro, pero solo si el filtro compara la columna de partición con valores conocidos: `fecha_vuelo >= '2024-07-01' AND fecha_vuelo < '2024-08-01'` poda; `extract(month FROM fecha_vuelo) = 7` no (experimento P1). La clave primaria tiene que incluir la columna de partición. Otras ventajas: borrar o archivar un mes es `DETACH PARTITION` (instantáneo) en vez de un `DELETE` de 600.000 filas, y `VACUUM`/`ANALYZE` trabajan por partición.

**BRIN.** *Block Range INdex*: por cada bloque de N páginas (`pages_per_range`) guarda solo el mínimo y el máximo de la columna. Es diminuto y se crea rápido, pero solo descarta bloques si los valores están **ordenados físicamente** en la tabla (correlación cercana a 1 en `pg_stats`). En una tabla de hechos que se carga en orden de fecha es ideal; sobre una columna desordenada como la distancia no descarta nada (experimento P3). El resultado siempre es un *Bitmap Heap Scan* con `Recheck`: BRIN dice "puede estar en este bloque" y PostgreSQL revisa cada fila del bloque.

**Índice parcial.** `CREATE INDEX ... WHERE cancelado` solo indexa las filas que cumplen la condición. Si la consulta repite esa condición, el planificador lo usa; como solo tiene un pequeño porcentaje de las filas, ocupa una fracción de un índice completo y cuesta menos mantenerlo en cada `INSERT`.

**Vista materializada.** Guarda el resultado de una consulta como tabla. `dw.mv_puntualidad_diaria` resume el hecho por día × aerolínea × aeropuerto y el reporte lee de ahí. `REFRESH MATERIALIZED VIEW CONCURRENTLY` la recalcula sin bloquear lecturas, y para eso necesita un índice único.

**CTE recursiva.** `WITH RECURSIVE` tiene una parte ancla (las raíces) y una parte recursiva que se une con el resultado del paso anterior hasta que no produce filas. Aquí cada paso avanza un tramo en el día del mismo avión. Detalle en la sección 5.

**`EXPLAIN (ANALYZE, BUFFERS)`.** `ANALYZE` ejecuta la consulta de verdad y muestra filas y tiempos reales por nodo; `BUFFERS` muestra cuántas páginas de 8 KB se encontraron en `shared_buffers` (*hit*) y cuántas se pidieron al sistema operativo (*read*, que pueden venir de la caché del sistema operativo o del disco). Las páginas son casi deterministas para un mismo plan; el tiempo depende de la máquina y del estado de la caché.

## 4. Reglas de calidad

Cada vuelo se evalúa contra todas las reglas a la vez y guarda la lista de reglas que dispara (`text[]`); un vuelo puede disparar varias. Las de **cuarentena** (`Q_`) describen datos imposibles o que no se pueden situar en el tiempo: el vuelo completo va a `calidad.vuelo_cuarentena` en JSON, con sus motivos, y no entra al hecho. Las **marcas** (`M_`) describen casos válidos pero especiales: cancelados, desviados, horas escritas como `2400`, vuelos que llegan al día siguiente, retrasos que empujan la salida pasada la medianoche y vuelos en el aire durante el cambio de horario de verano. Estos entran al hecho y se cuentan.

Los datos de BTS ya vienen depurados, así que la cuarentena es pequeña. Lo que más aparece son horarios programados que no cuadran por algunos minutos (la aerolínea cambió la hora de llegada sin cambiar la duración); si la zona horaria de un aeropuerto estuviera mal, fallarían casi todos sus vuelos, y `analisis.validacion_zona_horaria` muestra que no pasa.

## 5. Retrasos en cadena

1. `dw.tramo_avion` numera los vuelos operados de cada matrícula y día por hora de salida en UTC y calcula, con `LAG`, la holgura programada (salida programada menos llegada programada del tramo anterior), el retraso de llegada del tramo anterior y si el tramo sale del aeropuerto donde llegó el anterior (`continua`).
2. **Raíz:** un tramo que llega con 15 min o más de retraso cuando el tramo anterior del día llegó a tiempo (o es el primero del día). El retraso "nace" ahí.
3. **Paso:** el tramo siguiente del mismo avión, si sale de donde llegó el anterior, el anterior llegó con 15+ min de retraso y este sale con 15+ min de retraso.
4. La cadena se corta cuando el avión recupera el horario.

Para cada raíz se mide el largo de la cadena y los minutos de retraso de salida que hubo aguas abajo. El *multiplicador* es minutos aguas abajo / minutos de la raíz. Como contraste se usa la causa "avión anterior tarde" (`LateAircraftDelay`) que reporta BTS. La función `analisis.cadenas_retraso(desde, hasta, umbral)` encapsula la CTE para poder probarla con un avión inventado (`tests/test_cadena_retraso.py`).

## 6. Preguntas de entrevista

**1. ¿Por qué PostgreSQL y no SQL Server o DuckDB para este proyecto?**
PostgreSQL es gratuito, corre igual en Docker en cualquier sistema y ofrece justo las piezas que se querían practicar: particionado declarativo, índices BRIN y parciales, vistas materializadas, CTE recursivas y `EXPLAIN (ANALYZE, BUFFERS)` muy detallado. DuckDB sería más rápido para agregar 7 M de filas (es columnar), pero no es un motor transaccional ni tiene índices BRIN o parciales; SQL Server tiene particionado y columnstore, pero la edición gratuita limita memoria y tamaño de base.

**2. ¿Qué es la poda de particiones y cuándo no ocurre?**
Es cuando el planificador descarta particiones que no pueden tener filas del filtro, porque conoce el rango de cada una. Ocurre si el filtro compara la columna de partición con constantes o parámetros (`fecha_vuelo >= X AND fecha_vuelo < Y`). No ocurre si se aplica una función a la columna (`extract(month FROM fecha_vuelo) = 7`) ni si se filtra por otra columna (por ejemplo, la matrícula en P5): en ambos casos se recorren todas las particiones.

**3. ¿Cuándo usarías BRIN en vez de B-tree?**
En tablas grandes donde la columna está ordenada físicamente, como la fecha en un hecho que se carga en orden cronológico o un id autoincremental en una tabla de solo inserciones. BRIN ocupa una fracción mínima del B-tree y se crea en mucho menos tiempo. No sirve si la columna está desordenada, si se buscan pocas filas sueltas (ahí B-tree gana) o si hay muchas actualizaciones que desordenan la tabla. La correlación en `pg_stats` dice si conviene.

**4. ¿Qué es un índice parcial y qué condición debe cumplir la consulta para usarlo?**
Un índice con `WHERE` que solo incluye las filas que cumplen esa condición. La consulta tiene que incluir un predicado que implique el del índice (por ejemplo, `WHERE cancelado AND aerolinea = 'DL'` para un índice `WHERE cancelado`). Es útil cuando se consulta siempre un subconjunto pequeño: cancelados, pedidos pendientes, filas no procesadas.

**5. ¿Qué diferencia hay entre `EXPLAIN` y `EXPLAIN ANALYZE`, y qué agrega `BUFFERS`?**
`EXPLAIN` muestra el plan con estimaciones, sin ejecutar. `EXPLAIN ANALYZE` ejecuta la consulta y agrega filas reales, tiempo real por nodo y número de iteraciones (cuidado con `INSERT`/`UPDATE`: se ejecutan de verdad). `BUFFERS` agrega las páginas leídas desde la caché de PostgreSQL y desde el sistema operativo. Comparar filas estimadas y reales ayuda a detectar estadísticas desactualizadas.

**6. ¿Por qué medir la mediana de varias corridas y no una sola?**
La primera ejecución puede incluir lecturas de disco y planificación; las siguientes pueden coincidir con otro proceso, el autovacuum o el recolector del sistema. La mediana de 7 corridas tras un calentamiento no se deja arrastrar por una corrida rara. Se guardan todas las corridas (`reports/tablas/rendimiento_corridas.csv`) para ver la dispersión.

**7. ¿Cómo funciona una CTE recursiva y cómo evitas un bucle infinito?**
Tiene una parte ancla y una parte recursiva unidas con `UNION ALL`; PostgreSQL ejecuta la parte recursiva sobre las filas nuevas del paso anterior hasta que no salen filas. Aquí no puede haber bucle porque cada paso avanza `n_tramo + 1` y el día de un avión tiene un número finito de tramos. En grafos con ciclos se guarda el camino recorrido (un arreglo o la cláusula `CYCLE` de PostgreSQL 14+) y se corta al repetir un nodo.

**8. ¿Por qué guardar las horas en UTC si BTS las da en hora local?**
Porque un avión cruza zonas horarias: para calcular la holgura entre una llegada a Denver y la salida siguiente hacia Chicago, o para ordenar los tramos de un día, hay que restar instantes en una misma referencia. Con `timestamptz` y el nombre IANA de la zona, PostgreSQL aplica el horario de verano correcto en cada fecha. La hora local solo se usa para agrupar por "hora del día" tal como la vive el pasajero.

**9. ¿Cómo garantizas que no se perdieron ni duplicaron filas en la carga?**
Con tres capas: cifras de control calculadas en Python sobre los CSV originales, sin pasar por PostgreSQL (filas, cancelados, sumas de retrasos y distancias por mes); las mismas cifras calculadas en SQL sobre el texto crudo; y la reconciliación `filas copiadas = hecho + cuarentena` por mes. Las pruebas comparan las tres.

**10. ¿Qué ventaja tiene la vista materializada y cuál es su costo?**
Lee unas cien veces menos filas que el hecho para el reporte (P6). El costo es que queda desactualizada hasta el siguiente `REFRESH` y ocupa espacio. `REFRESH ... CONCURRENTLY` evita bloquear a quien la lee, pero necesita un índice único y tarda más que un refresh normal porque compara el resultado nuevo con el anterior.

**11. ¿Qué configuración de memoria elegiste para el contenedor y por qué?**
El contenedor tiene 4 GB. `shared_buffers = 1GB` (cerca del 25 %, la recomendación habitual; el resto queda para la caché del sistema operativo, que PostgreSQL también aprovecha), `effective_cache_size = 3GB` (le dice al planificador cuánta caché total esperar, no reserva memoria), `work_mem = 64MB` (por cada ordenamiento o hash; una consulta con varios nodos y workers paralelos puede usarlo varias veces, por eso no se pone más alto) y `maintenance_work_mem = 512MB` para crear índices rápido.

**12. ¿Qué harías distinto en producción?**
Carga incremental por mes con `ATTACH PARTITION` (cargar en una tabla aparte, crear índices y validarla, y luego adjuntarla), crear las particiones futuras con anticipación (o con `pg_partman`), no usar `COPY FROM PROGRAM` con un superusuario sino `\copy` desde el cliente o un rol con permisos mínimos, y programar el `REFRESH` de la vista después de cada carga.
