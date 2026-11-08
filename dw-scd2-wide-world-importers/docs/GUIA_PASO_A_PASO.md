# Guía paso a paso

## 1. Preparación

Requisitos: SQL Server Express, ODBC Driver 18, `sqlcmd` y Python 3.14. Desde la raíz:

```powershell
py -3.14 -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
.venv\Scripts\python scripts\descargar_datos.py
icacls data\raw /grant 'NT Service\MSSQL$SQLEXPRESS:(OI)(CI)RX' /T
$bak=(Resolve-Path data\raw\WideWorldImporters-Full.bak); $variable='BackupPath="'+$bak+'"'
sqlcmd -S "localhost\SQLEXPRESS" -E -C -b -v $variable -i sql\01_restaurar_fuente.sql
```

El restaurador no sobrescribe una base existente. Para repetir todo desde una fuente limpia, elimine la copia de laboratorio y restaure el `.bak`:

```powershell
sqlcmd -S "localhost\SQLEXPRESS" -E -C -b -Q "ALTER DATABASE WideWorldImporters SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE WideWorldImporters;"
sqlcmd -S "localhost\SQLEXPRESS" -E -C -b -v $variable -i sql\01_restaurar_fuente.sql
```

Opcional, con la fuente limpia y antes de la carga completa, medir tiempos (5 repeticiones por escenario; deja `DW_WWI` sin vistas, por eso va antes del paso 2):

```powershell
.venv\Scripts\python scripts\medir_tiempos.py
```

## 2. Carga completa

```powershell
sqlcmd -S "localhost\SQLEXPRESS" -E -C -I -b -f 65001 -i sql\00_EJECUTAR_TODO.sql
```

El script reconstruye `DW_WWI`, crea `stg`, `dw`, `etl`, `audit` y `rpt`, carga dimensiones y hechos, ejecuta controles (`06_calidad.sql`) y consultas de demostración. No modifica el OLTP.

`stg` son vistas sobre el OLTP de la misma instancia: fijan columnas y grano sin copiar datos. Con la fuente en otro servidor se materializarían como tablas de aterrizaje.

**No vuelva a ejecutarlo después de la simulación sin restaurar el `.bak`:** la carga completa tomaría los atributos ya modificados como versión inicial y se perdería la historia SCD2.

## 3. Probar cambios e incremental

```powershell
sqlcmd -S "localhost\SQLEXPRESS" -E -C -I -b -f 65001 -i sql\08_simular_cambios.sql
```

La simulación, idempotente mediante los PO `SQL03-SIM-*`, cambia 50 categorías de cliente (de *Novelty Shop* a *Agent*), aumenta 5 % el precio de 100 productos e inserta 5 facturas/15 líneas. Después ejecuta la incremental y calidad. Es el único script que modifica de forma persistente la copia del OLTP; `medir_tiempos.py` y las pruebas trabajan en transacciones que se revierten.

La incremental registra en `audit.ejecucion` 50 cierres y 50 aperturas de cliente, y 100 cierres y 100 aperturas de producto: 50 y 100 versiones nuevas. La diferencia de 15,56 M entre categoría histórica y actual es consecuencia directa de este cambio artificial; sirve para demostrar el mecanismo, no como hallazgo de negocio.

```powershell
.venv\Scripts\python scripts\generar_reportes.py
.venv\Scripts\python -m pytest
```

## 4. Cómo funciona la incremental

`audit.marca_agua` conserva un corte por fuente. La extracción usa el intervalo abierto-cerrado `(marca_anterior, corte]`. El corte se toma una sola vez al comenzar la transacción y solo se avanza al confirmar. Las claves naturales y `NOT EXISTS` evitan duplicar hechos. Una ejecución inmediata debe registrar cero filas y cero versiones.

Para SCD2 se usa `UPDATE` + `INSERT` dentro de una transacción, no `MERGE`: primero cierra la versión cuyo SHA-256 cambió y luego abre la nueva. Es más explícito, fácil de depurar y evita varios riesgos históricos de concurrencia de `MERGE`. `MERGE` solo se usa para el snapshot y la pequeña tabla de marcas de agua, donde la clave de coincidencia es única.

## Preguntas de entrevista

1. **¿Por qué SCD2?** Porque una venta debe conservar la categoría y el precio descriptivo conocidos cuando ocurrió, aunque hoy hayan cambiado.
2. **¿Por qué una clave sustituta?** La clave natural identifica al cliente o producto, pero no una versión; la sustituta permite que dos versiones convivan y sean referenciadas por hechos distintos.
3. **¿Cómo se detecta un cambio?** Con SHA-256 sobre los atributos rastreados. Evita comparar muchas columnas y normaliza la decisión en una sola expresión.
4. **¿Por qué `UPDATE` + `INSERT` en vez de `MERGE` para SCD2?** Separa cierre y apertura, hace visibles los conteos (`cliente_cierres`, `cliente_aperturas`…) y reduce ambigüedad ante concurrencia.
5. **¿Qué hace idempotente la carga?** Marca de agua transaccional, claves únicas y antijoin por identificador de línea.
6. **¿Por qué el intervalo es `(anterior, corte]`?** No reprocesa el límite ya confirmado y tampoco pierde filas creadas durante la carga después del corte.
7. **¿Cómo se comprueba que no hay historia inválida?** Un control exige una sola versión actual y otro busca cualquier intersección entre intervalos de la misma clave natural.
8. **¿Qué diferencia hay entre categoría histórica y actual?** Histórica sale de la clave sustituta grabada en el hecho; actual vuelve a unir la clave natural con la versión vigente.
9. **¿Por qué guardar `LineProfit`?** El costo actual no reconstruye el costo de la venta; la medida histórica de fuente sí.
10. **¿Cómo se agenda en Express?** Con Programador de tareas, `sqlcmd` y una cuenta con privilegios mínimos; SQL Agent no está disponible.

## Limitaciones

- El snapshot diario solo existe para los días en que se ejecuta el ETL; el respaldo no permite reconstruir inventario diario histórico exacto.
- La primera carga asigna una versión inicial desde 1900 porque el tiempo de sistema no prueba vigencia comercial retroactiva.
- La simulación usa la fecha UTC del equipo y debe ejecutarse sobre una copia desechable.
- La marca de agua de dimensiones usa `ValidFrom`, que registra el inicio de la transacción del OLTP: una transacción larga que empiece antes del corte y confirme después quedaría fuera. En producción convendría un margen de solape o Change Tracking.
- La cobertura de inventario usa las existencias del respaldo al 31-05-2016; son muy superiores al stock objetivo en 221 de 227 productos, por lo que la cobertura resulta alta.

