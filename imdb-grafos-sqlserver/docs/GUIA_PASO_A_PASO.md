# Guía paso a paso (en tu PC)

**Tu entorno:** SQL Server 2025 Express (instancia `SQLEXPRESS`) + SSMS + Python 3.14.
**Datos:** IMDb Non-Commercial Datasets (6 TSV, ~11 GB descomprimidos, 205 M de filas en total)

El pipeline de datos es **100 % T-SQL**. Python solo descarga y descomprime los TSV, cuenta sus filas (cifras de control), exporta los resultados, dibuja las figuras y corre las pruebas.

---

## Paso 1 · Entorno de Python y datos (5–10 min)

```powershell
cd imdb-grafos-sqlserver
py -3.14 -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
.venv\Scripts\python scripts\descargar_datos.py
```

✅ Deberías ver una línea por archivo, por ejemplo:

```
Descomprimiendo title.principals.tsv.gz ...
  102,413,745 filas · 4.58 GB · 11 s
Cifras de control: ...\data\cifras_control.json
```

El script es **reanudable**: baja a un `.part` y, si se corta (apagón, internet), la siguiente ejecución pide solo los bytes que faltan con la cabecera HTTP `Range`. Un `.gz` completo o un `.tsv` ya contado no se vuelven a procesar.

> **¿Por qué contar las filas en Python?** Es la cifra de control independiente del motor: si `BULK INSERT` pierde filas por un error de formato, la auditoría lo muestra (filas del TSV ≠ filas leídas).

---

## Paso 2 · Permisos para el servicio de SQL Server (1 min)

`BULK INSERT` y `OPENROWSET(BULK)` leen los archivos con la cuenta del servicio (`NT Service\MSSQL$SQLEXPRESS`), no con tu usuario:

```powershell
New-Item -ItemType Directory -Force data\errores | Out-Null
icacls data /grant 'NT Service\MSSQL$SQLEXPRESS:(OI)(CI)RX' /T
icacls data\errores /grant 'NT Service\MSSQL$SQLEXPRESS:(OI)(CI)M'
icacls sql /grant 'NT Service\MSSQL$SQLEXPRESS:(OI)(CI)RX' /T
```

`sql\formatos\*.fmt` son los *format files* de `OPENROWSET`; `data\errores\` recibe los archivos de error de `BULK INSERT`. No hace falta PowerShell de administrador porque las carpetas son tuyas.

---

## Paso 3 · Ejecutar el pipeline (~20 min la primera vez)

```powershell
.\ejecutar.ps1
```

El lanzador calcula la ruta de la carpeta y se la pasa a `sqlcmd` como la variable `Proyecto`; el SQL no fija ninguna ruta. Es equivalente a este comando de `cmd` (comillas obligatorias, ruta sin espacios):

```bat
sqlcmd -S "localhost\SQLEXPRESS" -E -C -I -b -f 65001 -v Proyecto="%CD%" -i sql\00_EJECUTAR_TODO.sql
```

| Opción | Para qué |
|---|---|
| `-v Proyecto=…` | Ruta de esta carpeta: de ahí leen `BULK INSERT`, `OPENROWSET` y los format files |
| `-E -C` | Autenticación de Windows y confiar en el certificado local |
| `-I` | `QUOTED_IDENTIFIER ON`: lo exigen las columnas calculadas persistidas y los índices |
| `-b` | Si algo falla, `sqlcmd` termina con error |
| `-f 65001` | Lee los .sql como UTF-8 (tildes, ñ) |

Lo que hace, en orden:

| Paso | Procedimiento | Tiempo medido |
|---|---|---|
| Carga de los 6 TSV con auditoría | `etl.sp_cargar_staging` | ~10 min (principals: 5 min) |
| Modelo relacional | `etl.sp_cargar_modelo` | ~35 s |
| Grafo NODE/EDGE | `etl.sp_cargar_grafo` | ~1 min |
| Índice de búsqueda, ventanas, Bacon, elenco fiel, núcleos | `etl.sp_cargar_busqueda`, `etl.sp_calcular_analitica`, `etl.sp_calcular_grafo` | ~2 min |
| 29 controles de calidad | `qa.sp_validar_calidad` | ~30 s |
| Banco de rendimiento (5 repeticiones) | `qa.sp_medir_rendimiento` | ~8 min (el CTE recursivo tarda ~1 min por corrida) |

**Si se corta a mitad de la carga:** vuelve a lanzar el mismo comando. `02_staging.sql` solo crea las tablas que no existen y `etl.sp_cargar_staging @reanudar = 1` se salta los archivos cuya última carga terminó con el mismo filtro y cuyas filas siguen en staging.

---

## Paso 4 · Resultados, figuras y pruebas

```powershell
.venv\Scripts\python scripts\exportar_resultados.py
.venv\Scripts\python scripts\generar_graficos.py
.venv\Scripts\python -m pytest
```

- `reports/metricas.json` y `reports/tablas/*.csv`: de aquí salen todas las cifras del README.
- `reports/figures/*.png`: las 7 figuras.
- pytest: pruebas del script de descarga (sin internet) y del pipeline contra la base (se omiten si no hay SQL Server). Una de ellas recalcula el filtro con pandas directamente desde los TSV.

---

## Paso 5 · Probar las consultas en SSMS

```sql
USE ImdbGrafos;

-- Colaboradores directos (MATCH)
DECLARE @bacon INT = grafo.fn_buscar_persona('Kevin Bacon');
EXEC grafo.sp_colaboradores @persona_id = @bacon, @top = 10;

-- Grados de separación (SHORTEST_PATH) con la película de cada salto
DECLARE @o INT = grafo.fn_buscar_persona('Ricardo Darín'),
        @d INT = grafo.fn_buscar_persona('Toshiro Mifune');
EXEC grafo.sp_grados_separacion @origen = @o, @destino = @d;

-- Búsqueda de títulos (también por título en español)
EXEC busqueda.sp_buscar @consulta = 'señor anill*';           -- ~ CONTAINS con AND y prefijo
EXEC busqueda.sp_buscar @consulta = 'ciudad dios', @modo = 'libre';   -- ~ FREETEXT, ordenado por TF-IDF
EXEC busqueda.sp_buscar_like @texto = 'war';                  -- línea base LIKE '%war%'

-- Directores con elenco fiel
SELECT TOP 20 director, actor, peliculas, titulos FROM rpt.elenco_fiel ORDER BY peliculas DESC;
```

Para ver el grafo en SSMS: en el Explorador de objetos, `Tablas > Tablas de grafos`. Las columnas `$node_id`, `$from_id` y `$to_id` son JSON generado por el motor.

---

## Paso 6 · Power BI

Conéctate a `localhost\SQLEXPRESS`, base `ImdbGrafos`, modo **Importar**, y usa solo las vistas `rpt.*`:

| Página sugerida | Vistas |
|---|---|
| Catálogo | `rpt.pelicula`, `rpt.pelicula_genero`, `rpt.peliculas_por_decada`, `rpt.genero_resumen`, `rpt.decil_votos` |
| Épocas y géneros | `rpt.genero_decada` (línea por género), `rpt.mejor_decada_genero` (matriz década × género) |
| Talento | `rpt.persona`, `rpt.top_colaboradores`, `rpt.elenco_fiel`, `rpt.actor_prolifico_decada`, `rpt.nucleo_talento_resumen` |
| Red | `rpt.colaboracion_frecuente` (visual de red, p. ej. *Network Navigator*), `rpt.numero_bacon_distribucion`, `rpt.ejemplo_separacion` |
| Calidad | `rpt.auditoria_carga`, `rpt.medicion` |

Relaciones: `rpt.pelicula[pelicula_id]` 1—* `rpt.participacion`, 1—* `rpt.pelicula_genero`; `rpt.persona[persona_id]` 1—* `rpt.participacion`.

---

## Problemas comunes

| Mensaje | Causa y solución |
|---|---|
| `Cannot bulk load because the file could not be opened. Operating system error code 5` | Falta el permiso del paso 2 |
| `Bulk load data conversion error (truncation) ... column 3 (writers)` | Se intentó leer `title.crew` con `OPENROWSET`: un format file no pasa de `VARCHAR(8000)` y 4 series de TV tienen más guionistas que eso. Por eso crew va con `BULK INSERT` completo a `stg.title_crew_completo` (`VARCHAR(MAX)`) y luego se filtra |
| Títulos japoneses o rusos con caracteres raros | Se leyó con `OPENROWSET` sin `CODEPAGE = 'RAW'` (ver la nota en `03_carga_bulk.sql`) |
| `FULLTEXTSERVICEPROPERTY('IsFullTextInstalled') = 0` | Express se instaló sin Full-Text. Para tenerlo: instalador de SQL Server → *Agregar características* → *Full-Text and Semantic Extractions for Search* (requiere administrador). Luego vuelve a ejecutar `EXEC etl.sp_cargar_busqueda;` y se crea el catálogo |
| `Controles de calidad con ALERTA: N` | Revisa `SELECT * FROM qa.resultado_control WHERE estado = 'ALERTA'` |

---

## Preguntas de entrevista (con respuesta)

**1. ¿Qué es SQL Graph y en qué se diferencia de una tabla normal?**
Son tablas normales con columnas extra que administra el motor: una tabla `AS NODE` tiene `$node_id` y una `AS EDGE` tiene `$from_id` y `$to_id`. Permiten escribir patrones con `MATCH(a-(e)->b)` y caminos con `SHORTEST_PATH`. Por dentro siguen siendo tablas con índices: `MATCH` se traduce a joins. No es más rápido por sí mismo: en este proyecto, la red a dos saltos tardó 107 ms con `MATCH` y 22 ms con el `JOIN` equivalente sobre una tabla de enteros, porque cada salto de `MATCH` pasa por la tabla de nodos para resolver `$node_id`.

**2. ¿Por qué guardaste `TrabajoCon` en los dos sentidos?**
En SQL Graph las aristas son dirigidas y `MATCH`/`SHORTEST_PATH` siguen la flecha. Una colaboración es simétrica. Con una sola dirección, Bacon→Hanks existiría, pero el camino Hanks→Bacon no. Guardar las dos duplica el espacio (4,8 M aristas para 2,4 M pares), a cambio de consultas simples y correctas. Un control verifica que toda arista tenga su inversa con el mismo peso.

**3. ¿Qué devuelve exactamente `SHORTEST_PATH` y qué cuidado tuviste?**
Hace una búsqueda en anchura desde el nodo de origen y devuelve un camino más corto (sin pesos: cuenta saltos) hacia cada nodo alcanzable. Las columnas del camino se leen con funciones de agregado `WITHIN GROUP (GRAPH PATH)`: `STRING_AGG`, `LAST_VALUE`, `COUNT`. Dos cuidados: (a) no se puede filtrar el destino dentro de `MATCH`, así que se calcula desde el origen y se filtra afuera; (b) también devuelve el ciclo que vuelve al origen, que hubo que excluir (al principio causó una clave duplicada en `mart.numero_bacon`). Para acotar el costo se usa `{1,6}` y el filtro de ≥ 1.000 votos.

**4. ¿Cuándo conviene el grafo y cuándo SQL relacional?**
Para 1–2 saltos fijos, el relacional es igual o más rápido (22 ms frente a 107 ms a dos saltos): `MATCH` se traduce a joins y además resuelve los `$node_id`; lo que aporta es legibilidad. Para profundidad variable, `SHORTEST_PATH` evita escribir un algoritmo: el CTE recursivo no recuerda qué nodos ya visitó y explota (12,6 M de filas intermedias y ~62 s para llegar a 3 grados), mientras `SHORTEST_PATH` tarda ~2,1 s. Un BFS iterativo con tabla de visitados fue todavía más rápido (~1,2 s) porque se detiene al encontrar el destino, pero es código que hay que mantener. Regla: grafo para recorridos de longitud variable y para que la consulta se lea como la pregunta; relacional para agregaciones masivas, que es donde SQL Server es más fuerte.

**5. ¿Por qué el filtro de ≥ 1.000 votos y qué sesgo introduce?**
Sin filtro, `title.principals` tiene 102 M de filas y la red tendría millones de nodos: no cabe cómodo en Express y `SHORTEST_PATH` sería muy lento. Con el filtro quedan 49.320 películas, 203.547 personas en el grafo y los datos ocupan ~2,5 GB. El sesgo: se pierde el cine poco votado (cine regional, documentales pequeños), así que los grados de separación reales con todo IMDb serían distintos y la red está centrada en el cine popular en IMDb (inglés e India sobre todo). Está documentado y el umbral es un parámetro (`etl.parametro`).

**6. ¿Cómo filtraste 102 M de filas sin cargarlas todas?**
Con `OPENROWSET(BULK ..., FORMATFILE = ...)` dentro de un `INSERT ... SELECT ... WHERE EXISTS (película filtrada)`: el motor lee el TSV como si fuera una tabla y solo escribe las 981.137 filas que importan. Se hace una pasada previa con `COUNT_BIG(*)` para auditar cuántas filas pudo leer (102.413.745, igual que Python). Cargar todo con `BULK INSERT` habría necesitado ~6 GB solo para staging. La excepción es `title.crew`: el primer intento con `OPENROWSET` rechazó 4 filas (series de TV con más de 8.000 bytes de guionistas, el tope de un format file), y la auditoría lo hizo visible. Como pesa solo 0,4 GB, se carga completo con `BULK INSERT` a una tabla `VARCHAR(MAX)` de paso y se filtra: cero rechazos.

**7. Encontraste un problema de codificación, ¿cuál?**
`BULK INSERT` con `CODEPAGE = '65001'` escribe UTF-8 perfecto en columnas `VARCHAR` con intercalación UTF-8. Pero `OPENROWSET(BULK)` devuelve `VARCHAR` con la intercalación del servidor (`Modern_Spanish`, página 1252) y estropeaba los títulos japoneses (`美しき虚言者` salía con basura). La solución: leer con `CODEPAGE = 'RAW'` (bytes tal cual) y reinterpretar con `CAST(CAST(col AS VARBINARY) AS VARCHAR)` en la base UTF-8. Lo verifiqué comparando los bytes con el TSV.

**8. ¿Qué hiciste sin Full-Text Search?**
Primero lo verifiqué: `FULLTEXTSERVICEPROPERTY('IsFullTextInstalled') = 0`. El código que crea el catálogo y el índice full-text quedó escrito y se ejecuta solo si el componente existe. Como alternativa construí un índice invertido en T-SQL (680.894 textos, 360.706 palabras, 2 M de entradas): `sp_buscar` en modo `todas` imita `CONTAINS` (AND y prefijo con `*`) y en modo `libre` imita `FREETEXT` (OR ordenado por TF-IDF). Frente a `LIKE '%war%'`, que no puede usar índices y trae falsos positivos (Warrior, Edward, Stewart), el índice busca palabras completas y responde en milisegundos. Limitaciones: no hay *stemming* (war ≠ wars) ni sinónimos, que sí trae el full-text real.

**9. ¿Por qué una intercalación `CI_AI_SC_UTF8` en la base?**
`UTF8` permite guardar cualquier alfabeto en `VARCHAR` ocupando 1 byte por carácter latino (la mitad que `NVARCHAR`). `CI_AI` hace que las comparaciones ignoren mayúsculas y tildes: buscar "amelie" encuentra "Amélie" y `fn_buscar_persona('Toshiro Mifune')` encuentra a "Toshirô Mifune". El costo: `tempdb` tiene otra intercalación, así que las tablas temporales con texto necesitan `COLLATE DATABASE_DEFAULT`.

**10. ¿Qué es la calificación ponderada y por qué usarla?**
Es la fórmula bayesiana del Top 250 de IMDb: `WR = v/(v+m)·R + m/(v+m)·C`. Mezcla la calificación de la película con la media del catálogo según cuántos votos tiene: una película de 9,5 con 1.200 votos se acerca a la media, una de 9,0 con 2 millones casi no se mueve. Sin ella, el "mejor drama de cada década" lo ganarían películas con pocos votos de fans.

**11. ¿Cómo validas que el grafo está bien construido?**
Con 29 controles: nodos = filas del modelo relacional, cero aristas huérfanas, cero autociclos, simetría de `TrabajoCon`, y una identidad matemática: la suma de los pesos debe ser Σ k·(k−1) por película (k = personas de la red en la película). Para el número de Bacon, una propiedad del BFS: quien está a k grados tiene algún vecino a k−1 y ninguno más cerca. Además pytest compara `SHORTEST_PATH` con un BFS independiente y una prueba negativa borra una arista (en una transacción que se revierte) y verifica que dos controles salten.

**12. ¿Qué son los "núcleos de talento" y cómo los calculaste?**
Son las componentes conexas de la red de lazos fuertes (pares con 3+ películas juntos). Se calculan con propagación de etiquetas en un `WHILE`: cada persona toma la menor etiqueta entre sus vecinos hasta que nada cambia (22 vueltas). Salen 935 núcleos; el más grande reúne 5.433 personas de Hollywood y el segundo es el cine indio. Para una plataforma, un núcleo indica elencos que funcionan juntos y mercados con su propia red de talento.
