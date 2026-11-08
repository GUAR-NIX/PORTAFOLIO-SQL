/* =====================================================================
   00_EJECUTAR_TODO.sql — Pipeline completo de extremo a extremo
   ---------------------------------------------------------------------
   Forma recomendada (pasa la ruta del proyecto en $(Proyecto)):
     python scripts\ejecutar_sql.py

   Equivalente con sqlcmd desde cmd.exe (en PowerShell, anteponer --%):
     sqlcmd -S "localhost\SQLEXPRESS" -E -C -I -b -f 65001 -v Proyecto="C:\ruta\tuning-sqlserver-citibike" -i sql\00_EJECUTAR_TODO.sql

   Requisito previo:
     python descargar_datos.py   (genera data\raw\citibike_2024T1.tsv)

   Duración en el equipo de referencia: unos 40 minutos (~20 de limpieza,
   ~8 de benchmark: cada variante corre 5 veces en caliente y 5 en frío).
   ===================================================================== */
:on error exit
SET QUOTED_IDENTIFIER ON;
GO

PRINT N'=== 1/7 Creando la base CitiBikeTuning (Query Store activo) y sus objetos ===';
:r $(Proyecto)\sql\01_crear_base.sql
:r $(Proyecto)\sql\02_staging_y_carga.sql
:r $(Proyecto)\sql\03_limpieza.sql
:r $(Proyecto)\sql\04_modelo_estrella.sql
:r $(Proyecto)\sql\05_estructuras_laboratorio.sql
:r $(Proyecto)\sql\06_laboratorio_tuning.sql
:r $(Proyecto)\sql\07_vistas_analiticas.sql
:r $(Proyecto)\sql\08_calidad_y_reconciliacion.sql
GO

PRINT N'=== 2/7 BULK INSERT de los viajes de enero–marzo 2024 al staging ===';
USE CitiBikeTuning;
EXEC etl.sp_cargar_staging @carpeta_datos = N'$(Proyecto)\data';
GO

PRINT N'=== 3/7 Limpieza y modelo estrella; se vacía el staging para no acercarse al límite de 10 GB ===';
USE CitiBikeTuning;
EXEC etl.sp_limpiar;
EXEC etl.sp_cargar_modelo;
TRUNCATE TABLE stg.viaje_crudo;
GO

PRINT N'=== 4/7 Construyendo las 4 estructuras físicas del laboratorio ===';
USE CitiBikeTuning;
EXEC etl.sp_cargar_laboratorio;
GO

PRINT N'=== 5/7 Midiendo el tiempo de carga con y sin índices (3 corridas) ===';
USE CitiBikeTuning;
EXEC etl.sp_medir_tiempos_carga @corridas = 3;
GO

PRINT N'=== 6/7 Ejecutando E1–E9 (5 corridas en caliente + 5 en frío) y la curva del punto de inflexión ===';
USE CitiBikeTuning;
EXEC perf.sp_ejecutar_laboratorio @corridas = 5;
GO

PRINT N'=== 7/7 Controles de calidad, equivalencia y rendimiento ===';
USE CitiBikeTuning;
EXEC qa.sp_validar_calidad;
GO
