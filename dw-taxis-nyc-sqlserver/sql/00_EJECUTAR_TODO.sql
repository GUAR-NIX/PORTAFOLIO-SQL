/* =====================================================================
   00_EJECUTAR_TODO.sql — Data warehouse de taxis NYC 2024 de punta a punta
   ---------------------------------------------------------------------
   Requiere MODO SQLCMD. Recibe dos variables desde fuera (el script no fija ninguna ruta):
     Proyecto            ruta absoluta de esta carpeta, sin espacios
     BenchmarkCompleto   1 = con laboratorio rowstore/columnstore, 0 = sin él

   Lo más simple, el lanzador (calcula la ruta solo):

     .\ejecutar.ps1                    # con laboratorio
     .\ejecutar.ps1 -SinBenchmark      # sin laboratorio

   A mano, desde cmd (las comillas del valor son obligatorias):

     sqlcmd -S "localhost\SQLEXPRESS" -E -C -I -b -f 65001 -v Proyecto="%CD%" BenchmarkCompleto=1 -i sql\00_EJECUTAR_TODO.sql

   En SSMS (Query > SQLCMD Mode) agrega antes de ejecutar:
     :setvar Proyecto "<ruta de esta carpeta>"
     :setvar BenchmarkCompleto 1

   Antes: python scripts\descargar_datos.py  (12 CSV + cifras de control en data\)
   Tiempos medidos en un Ryzen 5 4600G con SQL Server 2025 Express:
     carga de 12 meses ~45 min · análisis ~3 min · laboratorio rowstore/columnstore ~20 min
   Es idempotente: si se vuelve a ejecutar, los meses ya cargados se OMITEN (mismo sha256).
   ===================================================================== */
:on error exit
SET QUOTED_IDENTIFIER ON;
GO

PRINT N'=== 1/7 Estructura (base, staging, dimensiones, hecho particionado, procedimientos) ===';
:r $(Proyecto)\sql\01_crear_base.sql
:r $(Proyecto)\sql\02_staging.sql
:r $(Proyecto)\sql\03_dimensiones.sql
:r $(Proyecto)\sql\04_hecho_particionado.sql
:r $(Proyecto)\sql\05_carga_incremental.sql
:r $(Proyecto)\sql\06_ventana_deslizante.sql
:r $(Proyecto)\sql\07_analisis.sql
:r $(Proyecto)\sql\09_calidad.sql
:r $(Proyecto)\sql\10_rowstore_vs_columnstore.sql
:r $(Proyecto)\sql\11_demo_ventana_deslizante.sql
GO

PRINT N'=== 2/7 Cifras de control (JSON de Python) y zonas ===';
USE TaxisNYC;
EXEC etl.sp_leer_cifras_control @carpeta_datos = N'$(Proyecto)\data';
EXEC etl.sp_cargar_zonas @carpeta_datos = N'$(Proyecto)\data';
GO

PRINT N'=== 3/7 Carga incremental mes a mes (BULK INSERT → cuarentena → SWITCH) ===';
USE TaxisNYC;
EXEC etl.sp_cargar_pendientes @carpeta_datos = N'$(Proyecto)\data';
GO

PRINT N'=== 4/7 Análisis con funciones de ventana (mart.*) ===';
USE TaxisNYC;
EXEC etl.sp_calcular_analisis;
GO
-- Las vistas rpt se crean después de los marts: una vista exige que sus tablas ya existan
:r $(Proyecto)\sql\08_vistas_powerbi.sql
GO

PRINT N'=== 5/7 Controles de calidad y cuadre contra los Parquet ===';
USE TaxisNYC;
EXEC qa.sp_validar_calidad;
GO

PRINT N'=== 6/7 Ventana deslizante (demostración reversible) ===';
USE TaxisNYC;
EXEC lab.sp_demo_ventana_deslizante;
EXEC qa.sp_validar_calidad;   -- el hecho debe quedar exactamente igual
GO

PRINT N'=== 7/7 Rowstore vs columnstore ===';
USE TaxisNYC;
IF $(BenchmarkCompleto) = 1
    EXEC lab.sp_comparar_almacenamiento @conservar_copia = 0;
ELSE
    EXEC lab.sp_medir_espacio 'COLUMNSTORE', N'dw.fact_viaje';
SELECT almacenamiento, filas, reservado_mb, bytes_por_fila FROM lab.espacio_almacenamiento ORDER BY reservado_mb;
GO
