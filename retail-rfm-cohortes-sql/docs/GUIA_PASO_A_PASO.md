# Guía paso a paso (en tu PC)

**Tu entorno:** SQL Server Express (instancia `SQLEXPRESS`) + SSMS + Python 3.14.
**Datos:** UCI Online Retail II, 1.067.371 líneas (dic-2009 a dic-2011)

El pipeline de datos es **100 % T-SQL**. Python solo descarga el Excel, lo convierte a CSV, calcula las cifras de control, dibuja las figuras y corre las pruebas.

---

## Paso 1 · Entorno de Python y datos (5 min)

Abre PowerShell en la carpeta del proyecto:

```powershell
cd retail-rfm-cohortes-sql
py -3.14 -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
.venv\Scripts\python scripts\descargar_datos.py
```

✅ Deberías ver:

```
hoja Year 2009-2010: 525,461 filas
hoja Year 2010-2011: 541,910 filas
CSV: ...\data\raw\online_retail_ii.csv (116.2 MB)
```

Quedan `data/raw/online_retail_ii.csv` (para `BULK INSERT`) y `data/cifras_control.json` (filas, unidades e importe de cada hoja). El JSON es el "contrato" contra el que SQL Server se reconcilia.

> **¿Por qué convertir a CSV?** `BULK INSERT` no lee Excel. Además, al convertir con `dtype=str` pandas no reinterpreta los códigos: `85123A` sigue siendo texto y `Customer ID` no termina como `13085.0`.

---

## Paso 2 · Permiso para el servicio de SQL Server (1 min)

`BULK INSERT` y `OPENROWSET` leen los archivos con la cuenta del servicio (`NT Service\MSSQL$SQLEXPRESS`), no con tu usuario:

```powershell
icacls data /grant 'NT Service\MSSQL$SQLEXPRESS:(OI)(CI)RX' /T
```

✅ `Se procesaron correctamente N archivos; error al procesar 0 archivos`. No necesitas abrir PowerShell como administrador porque la carpeta es tuya.

---

## Paso 3 · Ejecutar el pipeline

### Opción A — Línea de comandos (recomendada)

```powershell
.\ejecutar.ps1
```

El lanzador calcula la ruta de la carpeta y se la pasa a `sqlcmd` como la variable `Proyecto`; el SQL no fija ninguna ruta. Es equivalente a este comando de `cmd` (comillas obligatorias, ruta sin espacios):

```bat
sqlcmd -S "localhost\SQLEXPRESS" -E -C -I -b -f 65001 -v Proyecto="%CD%" -i sql\00_EJECUTAR_TODO.sql
```

| Opción | Para qué |
|---|---|
| `-v Proyecto=…` | Ruta de esta carpeta: de ahí lee `BULK INSERT` el CSV y el JSON de cifras de control |
| `-I` | `QUOTED_IDENTIFIER ON`: lo exigen las columnas calculadas persistidas |
| `-b` | Si algo falla, `sqlcmd` termina con error (no sigue a ciegas) |
| `-f 65001` | Lee los .sql como UTF-8 (tildes y ñ) |

Tarda unos 5 minutos desde cero. Al final debe decir `Controles de calidad: 27 OK, 0 en ALERTA.`

### Opción B — SSMS, paso a paso

1. Conéctate a `localhost\SQLEXPRESS` (Windows Authentication, *Trust server certificate* ✅).
2. Abre y ejecuta (F5) en orden:

| # | Archivo | Qué hace | Deberías ver |
|---|---|---|---|
| 1 | `01_crear_base.sql` | Base `RetailAnalitica` y 7 esquemas | `Base lista: RetailAnalitica` |
| 2 | `02_staging.sql` | Staging de texto, bitácora y cifras de control | `Staging y auditoría listos.` |
| 3 | `03_carga_bulk.sql` | `etl.sp_cargar_staging` | `Procedimiento de carga creado.` |
| 4 | `04_limpieza.sql` | Códigos especiales, países y `etl.sp_limpiar` | `Limpieza creada.` |
| 5 | `05_modelo_estrella.sql` | 4 dimensiones, hecho columnstore y `etl.sp_cargar_modelo` | `Modelo estrella creado.` |
| 6 | `06_rfm.sql` | Reglas de segmento y `etl.sp_calcular_rfm` | `RFM creado.` |
| 7 | `07_cohortes.sql` | `etl.sp_calcular_cohortes` y `etl.sp_matriz_retencion` | `Cohortes creadas.` |
| 8 | `08_devoluciones.sql` | `etl.sp_calcular_devoluciones` | `Devoluciones creadas.` |
| 9 | `09_canasta.sql` | `etl.sp_calcular_canasta` | `Canasta creada.` |
| 10 | `10_vistas_powerbi.sql` | 13 vistas `rpt` | `Vistas de reporte (rpt) creadas.` |
| 11 | `11_calidad.sql` | `qa.sp_validar_calidad` | `Controles de calidad creados.` |

3. En una consulta nueva:

```sql
USE RetailAnalitica;
EXEC etl.sp_cargar_staging @carpeta_datos = N'<ruta del proyecto>\data';
EXEC etl.sp_limpiar;               -- muestra el resumen por motivo de exclusión
EXEC etl.sp_cargar_modelo;
EXEC etl.sp_calcular_rfm;
EXEC etl.sp_calcular_cohortes;
EXEC etl.sp_calcular_devoluciones;
EXEC etl.sp_calcular_canasta;      -- ~1 min
EXEC qa.sp_validar_calidad;        -- 27 OK
```

---

## Paso 4 · Verificar que todo cuadra

Compara con **[cifras_control.md](cifras_control.md)**:

| Verificación | Valor esperado |
|---|---|
| Staging | **1.067.371** filas |
| Líneas en `dw.fact_linea` | **1.021.254** |
| Duplicados (entre hojas) | **34.335** (22.523) |
| Clientes en RFM | **5.852** |
| `qa.sp_validar_calidad` | **27 OK, 0 ALERTA** |

Prueba la **idempotencia**: vuelve a correr `EXEC etl.sp_limpiar; EXEC etl.sp_cargar_modelo;`. Las cifras no cambian porque cada procedimiento vacía su destino antes de cargarlo.

Prueba el **linaje**, desde una línea del hecho hasta la fila exacta del Excel:

```sql
SELECT TOP (5) l.hoja, l.fila_origen, f.factura, f.cantidad, f.importe
FROM dw.fact_linea f JOIN limpio.factura_linea l ON l.linea_id = f.linea_id
ORDER BY f.importe DESC;
```

Mira la bitácora de tiempos:

```sql
SELECT * FROM qa.bitacora_carga ORDER BY carga_id DESC;
```

---

## Paso 5 · Análisis (`12_hallazgos.sql`)

Ejecuta cada bloque por separado: selecciónalo y presiona F5.

| Bloque | Pregunta | Técnica |
|---|---|---|
| H1 | ¿Cuánto se vendió, devolvió y cuánto ingreso no tiene cliente? | agregación condicional |
| H2 | ¿Qué se excluyó y por qué? | `GROUP BY` sobre `motivo_exclusion` |
| H3 | Ventas por año y meses pico | vista `rpt.kpi_mensual` |
| H4 | Pareto de clientes | `ROW_NUMBER` + `SUM() OVER (ROWS UNBOUNDED PRECEDING)` |
| H5 | Segmentos RFM | `NTILE(5)` + tabla de reglas |
| H6 | Retención promedio a 1, 3, 6 y 12 meses | cohortes, excluyendo la censurada |
| H7 | Valor acumulado por cliente y matriz de cohortes | `PIVOT` dinámico (`etl.sp_matriz_retencion`) |
| H8 | Devoluciones por tiempo, producto y país | `PERCENTILE_CONT`, ventana acumulada |
| H9 | Pares de productos | auto-join, soporte, confianza y lift |
| H10 | Mercados | `SUM(SUM()) OVER ()` para participación |

---

## Paso 6 · Figuras y pruebas

```powershell
.venv\Scripts\python scripts\generar_graficos.py   # 8 PNG en reports\figures y CSV en reports\tablas
.venv\Scripts\python -m pytest                       # 27 pruebas
```

Las pruebas incluyen una **prueba negativa**: dentro de una transacción altera el importe de una línea del hecho, verifica que el control 8 se pone en ALERTA y que el procedimiento lanza error, y luego hace `ROLLBACK`.

---

## Paso 7 · Power BI (opcional)

*Obtener datos → SQL Server* → servidor `localhost\SQLEXPRESS`, base `RetailAnalitica`, modo **Importar**. Selecciona solo vistas del esquema `rpt`:

- Relaciones: `rpt.fact_ventas[clave_fecha]` → `rpt.dim_fecha`, y lo mismo para cliente, producto y país (1:* , filtro simple).
- Matriz de retención: visual *Matriz* con `cohorte` en filas, `mes_desde` en columnas, `tasa_retencion` en valores y formato condicional de escala de color.
- Medida base: `Ventas netas = SUM(rpt_fact_ventas[importe])`.

---

## Problemas comunes

| Síntoma | Causa y solución |
|---|---|
| `Cannot bulk load because the file could not be opened. Operating system error code 5` | Falta el permiso del paso 2 |
| `CREATE TABLE failed because ... 'QUOTED_IDENTIFIER'` | Corriste `sqlcmd` sin `-I` |
| Tildes rotas en los mensajes de `sqlcmd` | Falta `-f 65001`. Si solo se ven mal en la consola, son los datos de la página de códigos de la terminal, no de la base |
| `Warning: Null value is eliminated by an aggregate` | Informativo: `MAX(CASE WHEN ... END)` ignora los NULL a propósito |
| `qa.sp_validar_calidad` lanza `Hay controles de calidad en ALERTA` | Revisa `SELECT * FROM qa.resultado_control WHERE estado = 'ALERTA'` |

---

## Preguntas de entrevista que este proyecto te prepara para responder

**1. ¿Cómo calculaste RFM y qué problema tiene `NTILE`?**
Recencia = días desde la última compra hasta el día siguiente a la última factura del archivo. Frecuencia = facturas de venta distintas. Monto = ventas netas de producto. Cada uno se puntúa de 1 a 5 con `NTILE(5)`. El problema es que `NTILE` hace grupos del mismo tamaño aunque haya empates: el 27,6 % de los clientes tiene frecuencia 1, así que gente idéntica cae en quintiles distintos según el orden físico. Lo resolví desempatando F por monto y terminando todos los `ORDER BY` en `cliente_id`, así el resultado es determinista. La alternativa sería `PERCENT_RANK` o cortes fijos de negocio (1, 2–3, 4–7, 8+ facturas).

**2. ¿Por qué la cohorte de diciembre de 2009 tiene tanta retención?**
Por **censura a la izquierda**: el archivo empieza en diciembre de 2009, así que todos los clientes que ya existían aparecen como "nuevos" ese mes. Son clientes fieles de antes y retienen 35–50 %. La marqué con `censurada_izquierda = 1` y la excluyo de los promedios. Pasa lo mismo al final: diciembre de 2011 solo tiene 9 días (mes incompleto).

**3. ¿Por qué no borraste las devoluciones?**
Porque son dinero real que vuelve. Entran al hecho con importe negativo, y así `SUM(importe)` da ventas netas. Lo que sí excluí fueron los movimientos de bodega (cantidad negativa sin factura `C`, precio 0), que no son devoluciones de clientes.

**4. ¿Qué hiciste con los clientes nulos?**
Los dejé en el hecho con la clave `-1` porque son el 13,6 % del ingreso. Quitarlos subestimaría las ventas. Solo se excluyen de RFM y cohortes, donde sin cliente no hay nada que medir.

**5. ¿Cómo encontraste los duplicados entre hojas?**
En el perfilado vi que la hoja 2009-2010 termina el 9 de diciembre de 2010 y la 2010-2011 empieza el 1 de diciembre: hay 9 días en ambas. Con `ROW_NUMBER() OVER (PARTITION BY` las 8 columnas `ORDER BY hoja, fila)` marqué 22.523 duplicados entre hojas, exactamente las líneas del solapamiento. Un control de calidad lo verifica.

**6. ¿Cómo sabes que no perdiste datos en la limpieza?**
Ninguna fila se borra: cada línea lleva un `motivo_exclusion`. Los controles comprueban que fuente = modelo + excluidas en filas, unidades e importe, con diferencia 0. Las cifras de la fuente las calcula Python directamente del Excel, no SQL Server, así que el control es independiente.

**7. ¿Qué es el lift y por qué no basta la confianza?**
Confianza(A→B) = P(B | A). Si B es un producto que casi todos compran, la confianza sale alta aunque A no tenga nada que ver. El lift divide entre P(B): lift = P(A y B) / (P(A)·P(B)), así que 1 = independencia y > 1 = afinidad real. Por ejemplo, vasos y platos *Skull* tienen lift 77.

**8. ¿Cómo evitaste que el auto-join de canasta explotara?**
El número de pares crece con el cuadrado de los productos por factura. Filtré productos que aparecen en al menos 200 facturas, pasé factura × producto distinto a una tabla temporal con índice agrupado, uní con `b.producto > a.producto` (cada par una sola vez) y guardé solo pares con 100 o más facturas. Tarda menos de 1 minuto.

**9. ¿Para qué sirve la matriz de cohortes además de la retención?**
Sirve para el valor del cliente en el tiempo: un cliente de enero de 2010 vale £2.136 a 12 meses y uno de noviembre de 2010, £1.035. Con eso se decide cuánto se puede pagar por adquirir un cliente según la temporada.

**10. Si mañana llega un archivo nuevo, ¿qué cambia?**
Nada en el código: cada procedimiento es idempotente (vacía y recarga). Para volúmenes grandes lo cambiaría a carga incremental: staging por lote, `MERGE` en dimensiones y recálculo de RFM solo para los clientes con movimiento.

**11. ¿Por qué columnstore en una tabla de 1 millón de filas?**
Las consultas de este proyecto son agregaciones sobre pocas columnas (importe, cliente, fecha). Columnstore lee solo esas columnas comprimidas y en modo batch. La PK no agrupada sobre `linea_id` mantiene la unicidad y el linaje.
