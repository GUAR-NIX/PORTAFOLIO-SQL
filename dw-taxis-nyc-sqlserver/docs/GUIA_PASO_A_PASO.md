# Guía paso a paso (en tu PC)

**Tu entorno:** SQL Server 2025 Express (instancia `SQLEXPRESS`) + SSMS + Python 3.14.
**Datos:** viajes de taxi amarillo de Nueva York, enero a diciembre de 2024: **41.169.720 viajes** en 12 Parquet.

El data warehouse es **100 % T-SQL**. Python solo baja los Parquet, los convierte a CSV (SQL Server no lee Parquet), calcula las cifras de control, dibuja las figuras y corre las pruebas.

---

## Paso 1 · Entorno de Python y datos (~5 min)

```powershell
cd dw-taxis-nyc-sqlserver
py -3.14 -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
.venv\Scripts\python scripts\descargar_datos.py
```

✅ Deberías ver una línea por mes y el total:

```
2024-01: 2,964,624 filas - CSV 363 MB - 15 s
...
2024-12: 3,668,371 filas - CSV 448 MB - 17 s
Total: 41,169,720 viajes en 12 meses -> ...\data\cifras_control.json
```

Quedan en `data/raw/` los 12 Parquet (~680 MB) y los 12 CSV (~5 GB), y en `data/cifras_control.json` las cifras de cada archivo: filas, suma de `total_amount`, `fare_amount`, `tip_amount`, `trip_distance`, pasajeros nulos, viajes fuera del mes y el `sha256` del Parquet.

> **¿Qué hace la conversión?** Pasa los nombres a minúsculas, agrega `fila_origen` (linaje), convierte el dinero de `double` a `DECIMAL(12,2)` (así la suma de control es exacta al centavo) y escribe las fechas como `AAAA-MM-DD HH:MM:SS`. Si algún valor tuviera más de 2 decimales lo cuenta (en 2024 no hay ninguno), y si una fecha tuviera fracciones de segundo el script falla en vez de perderlas.

> **Truco de rendimiento:** `pc.strftime` tardaba ~70 s por columna; `pc.cast(timestamp, string)` da el mismo texto en 0,3 s. La conversión de un mes tarda ~15 s (con `strftime` serían ~190 s).

---

## Paso 2 · Permiso para el servicio de SQL Server (1 min)

`BULK INSERT` y `OPENROWSET` leen los archivos con la cuenta del servicio (`NT Service\MSSQL$SQLEXPRESS`), no con tu usuario:

```powershell
icacls data /grant 'NT Service\MSSQL$SQLEXPRESS:(OI)(CI)RX' /T
```

---

## Paso 3 · Ejecutar el pipeline (~1 h 10 min con el laboratorio)

```powershell
.\ejecutar.ps1                  # añade -SinBenchmark para saltar el laboratorio
```

El lanzador calcula la ruta de la carpeta y se la pasa a `sqlcmd` como la variable `Proyecto`; el SQL no fija ninguna ruta. Es equivalente a este comando de `cmd` (comillas obligatorias, ruta sin espacios):

```bat
sqlcmd -S "localhost\SQLEXPRESS" -E -C -I -b -f 65001 -v Proyecto="%CD%" BenchmarkCompleto=1 -i sql\00_EJECUTAR_TODO.sql
```

| Opción | Para qué |
|---|---|
| `-v Proyecto=…` | Ruta de esta carpeta: de ahí leen el `BULK INSERT` y el JSON de cifras de control |
| `-v BenchmarkCompleto=…` | `1` con laboratorio rowstore/columnstore, `0` sin él |
| `-I` | `QUOTED_IDENTIFIER ON` (lo exigen los índices sobre columnas calculadas y las vistas) |
| `-b` | Si algo falla, `sqlcmd` termina con error (no sigue a ciegas) |
| `-f 65001` | Lee los .sql como UTF-8 (tildes y ñ) |

Qué vas a ver, etapa por etapa:

1. **Estructura**: base `TaxisNYC`, esquemas, dimensiones (fecha con feriados, hora, 265 zonas, proveedor, tipo de pago, tarifa), función y esquema de partición, hecho con columnstore, cuarentena y procedimientos.
2. **Cifras de control**: `Cifras de control: 12 meses, 41.169.720 viajes` (leídas del JSON con `OPENROWSET … SINGLE_CLOB` + `OPENJSON`).
3. **Carga incremental**: una línea por mes, por ejemplo `2024-01: OK · 2.923.191 al hecho · 41.433 a cuarentena · 187 s`.
4. **Análisis**: `Análisis materializado en mart.*`.
5. **Controles**: `Controles de calidad: 27/27 OK`.
6. **Ventana deslizante**: mueve la ventana a 2025-01 y la deshace; imprime cuántos milisegundos tomó.
7. **Laboratorio rowstore vs columnstore**: crea una copia rowstore de las ~40 M filas, la mide, la comprime con PAGE, la vuelve a medir y la borra. Si tienes prisa, usa `.\ejecutar.ps1 -SinBenchmark`.

> **Si se corta a la mitad** (apagón, Ctrl+C): vuelve a ejecutar el mismo comando. Los meses que ya terminaron en `OK` se **omiten** (mismo `sha256`), y el mes interrumpido se recarga desde cero porque su partición se reemplaza entera. La carga que quedó `EN CURSO` en la bitácora la detecta el control 10.

### Recargar un mes a mano

```sql
USE TaxisNYC;
EXEC etl.sp_cargar_mes @periodo = '2024-02', @carpeta_datos = N'<ruta del proyecto>\data';              -- OMITIDO
EXEC etl.sp_cargar_mes @periodo = '2024-02', @carpeta_datos = N'<ruta del proyecto>\data', @forzar = 1; -- recarga
SELECT * FROM rpt.auditoria_cargas ORDER BY carga_id DESC;
```

---

## Paso 4 · Figuras y pruebas (~10 min)

```powershell
.venv\Scripts\python scripts\generar_graficos.py
.venv\Scripts\python -m pytest
```

Las pruebas incluyen una **recarga forzada de febrero** (unos 4 minutos) que verifica que recargar deja exactamente las mismas cifras.

---

## Paso 5 · Revisar en SSMS

```sql
USE TaxisNYC;
SELECT * FROM rpt.cuadre_fuente ORDER BY periodo;              -- diferencias en 0 contra los Parquet
SELECT * FROM rpt.cuarentena_por_mes ORDER BY periodo, regla;  -- qué se apartó y por qué
SELECT * FROM lab.v_particiones_hecho ORDER BY particion;      -- 14 particiones, puntas vacías
SELECT * FROM rpt.benchmark_almacenamiento ORDER BY consulta, almacenamiento;
SELECT * FROM lab.ventana_log ORDER BY id;                     -- SPLIT / SWITCH / MERGE en milisegundos
SELECT * FROM rpt.horas_pico WHERE es_hora_pico = 1 ORDER BY dia_semana, rank_en_el_dia;
```

Para ver la **eliminación de segmentos** del columnstore ordenado:

```sql
SET STATISTICS IO ON;
SELECT COUNT_BIG(*) FROM dw.fact_viaje
WHERE recogida >= '2024-07-04T20:00' AND recogida < '2024-07-04T22:00';
-- En la pestaña Mensajes: "Segment reads 1, segment skipped 43"
```

---

## Paso 6 · Power BI

1. *Obtener datos → SQL Server* → servidor `localhost\SQLEXPRESS`, base `TaxisNYC`.
2. Con 41 M filas, usa **DirectQuery** para `rpt.fact_viajes` (el columnstore responde en segundos) o **Import** solo de las vistas de resumen (`rpt.kpi_mensual`, `rpt.horas_pico`, `rpt.rutas_top`, `rpt.aeropuertos`, `rpt.precio_por_milla`...), que pesan unos pocos KB.
3. Relaciones: `fact_viajes[fecha_key] → dim_fecha`, `[hora] → dim_hora`, `[zona_origen_id] → dim_zona_origen`, `[zona_destino_id] → dim_zona_destino`, y los tres catálogos. La zona está **dos veces** (rol de origen y de destino) para no usar relaciones inactivas ni `USERELATIONSHIP`.

---

## Preguntas de entrevista (con respuesta)

**1. ¿Por qué un índice columnstore agrupado en la tabla de hechos?**
Porque las consultas de BI leen pocas columnas de muchas filas. El columnstore guarda cada columna por separado y comprimida (diccionarios y codificación por valor), así que una consulta que suma `total` por mes lee solo dos columnas. Además procesa en **modo batch** (≈900 filas por operación en vez de una). Aquí ocupa ~30 bytes por viaje frente a ~100 de un rowstore, y las agregaciones van de varias veces a decenas de veces más rápido (tabla del README).

**2. ¿Para qué particionar si ya tengo columnstore?**
No es por velocidad de consulta (el columnstore ya salta segmentos), es por **gestión**: cargar, recargar o retirar un mes son operaciones de metadatos (`SWITCH`, `TRUNCATE … WITH (PARTITIONS)`), que tardan milisegundos sin importar si el mes tiene 3 millones de filas. Además, el filtro por la clave de partición hace *partition elimination*.

**3. ¿Cómo hiciste la carga idempotente?**
Cada mes se carga en una tabla de trabajo con la misma estructura del hecho, un `CHECK` del rango del mes y su propio columnstore. Luego, en una transacción, `TRUNCATE TABLE dw.fact_viaje WITH (PARTITIONS (n))` y `ALTER TABLE … SWITCH TO dw.fact_viaje PARTITION n`. Recargar el mismo mes reemplaza la partición entera: nunca duplica. Además, la bitácora guarda el `sha256` del Parquet: si el archivo no cambió, el mes se omite.

**4. ¿Qué es la ventana deslizante y por qué las puntas deben estar vacías?**
Mantener solo los últimos N meses: cada mes se agrega una partición a la derecha (`SPLIT`) y se retira la más vieja (`SWITCH OUT` + `MERGE`). Si se hace `SPLIT` o `MERGE` sobre una partición **con datos**, SQL Server mueve físicamente las filas (lento y con mucho log). Por eso la función tiene una partición vacía en cada punta y los procedimientos abortan si detectan datos donde no debería haberlos.

**5. ¿Por qué el `SWITCH` exige un `CHECK`?**
Para que SQL Server pueda confiar, sin leer los datos, en que todas las filas de la tabla de trabajo caben en el rango de la partición destino. Sin el `CHECK` (de confianza, `WITH CHECK`) el `SWITCH` falla.

**6. ¿Qué es la eliminación de segmentos y qué hace `ORDER (recogida)`?**
Cada segmento de ~1 M filas guarda el mínimo y máximo de cada columna. Si el filtro cae fuera de ese rango, el segmento ni se lee. Con `ORDER (recogida)` (columnstore ordenado, SQL Server 2022+) cada segmento cubre un rango de fechas estrecho, así que filtrar dos horas de un día lee 1 segmento de 44 (medido con SET STATISTICS IO).

**7. ¿Cómo garantizas que no perdiste ni inventaste viajes?**
Las cifras de control salen del Parquet con Python (independiente de SQL Server) y por cada mes debe cumplirse: filas del Parquet = hecho + cuarentena, y lo mismo para la suma de `total_amount`, `fare_amount`, `tip_amount` y `trip_distance` **al centavo**. Además, el número de viajes fuera del mes que cuenta Python debe ser igual al que la regla R01 manda a cuarentena en SQL. Hay una prueba negativa que altera un viaje y verifica que el control lo detecta.

**8. ¿Por qué cuarentena y no borrar los viajes malos?**
Porque se pueden auditar y revertir, y porque permiten cuadrar contra la fuente. Las reglas (umbrales incluidos) están en la tabla `qa.regla_calidad`: cambiar un umbral no requiere tocar código.

**9. ¿Por qué no declaraste claves foráneas en el hecho?**
El `SWITCH` exige que la tabla de trabajo y el hecho sean idénticos (incluidas las restricciones), y con 41 M filas la verificación de FK en cada carga cuesta. La integridad referencial se valida con controles después de cada carga (controles 17–19), que es lo habitual en un DW.

**10. ¿Por qué `APPROX_PERCENTILE_CONT` para la mediana del precio por milla?**
`PERCENTILE_CONT` es una función de ventana que ordena todas las filas de cada grupo (millones) y en Express se derrama a `tempdb`. `APPROX_PERCENTILE_CONT` (SQL Server 2022+) es un agregado con error garantizado bajo (~1,33 % de rango) y no ordena: perfecta para tendencias.

**11. ¿Qué limitaciones de SQL Server Express encontraste?**
El buffer pool está limitado a ~1,4 GB y el paralelismo de las consultas en modo batch está restringido, así que todo corre prácticamente en un hilo. El límite de tamaño por base de SQL Server 2025 Express es de 50 GB (las versiones anteriores de Express llegaban a 10 GB; lo comprobé creando una base de 12 GB). De todas formas el diseño cabe con holgura en 10 GB: el hecho de 41 M filas ocupa ~1 GB en columnstore.

**12. ¿Por qué las propinas en efectivo salen en 0 %?**
Porque el taxímetro solo registra la propina cuando se paga con tarjeta. No es que los pasajeros en efectivo no den propina: es un vacío del dato. Por eso el análisis de propinas por zona usa solo pagos con tarjeta.
