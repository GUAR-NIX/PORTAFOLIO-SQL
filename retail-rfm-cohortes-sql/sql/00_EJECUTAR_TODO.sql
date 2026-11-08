/* =====================================================================
   00_EJECUTAR_TODO.sql — Pipeline completo de punta a punta
   ---------------------------------------------------------------------
   Requiere MODO SQLCMD. La ruta de la carpeta llega desde fuera, en la variable
   "Proyecto" (ruta absoluta, sin espacios); el script no fija ninguna.

   Lo más simple, el lanzador (calcula la ruta solo):

     .\ejecutar.ps1

   A mano, desde cmd (las comillas del valor son obligatorias):

     sqlcmd -S "localhost\SQLEXPRESS" -E -C -I -b -f 65001 -v Proyecto="%CD%" -i sql\00_EJECUTAR_TODO.sql

   En SSMS (Query > SQLCMD Mode) agrega antes de ejecutar:
     :setvar Proyecto "<ruta de esta carpeta>"

   Antes: python scripts\descargar_datos.py  (deja el CSV y las cifras de control en data\)
   Tarda ~2–3 minutos.
   ===================================================================== */
:on error exit
SET QUOTED_IDENTIFIER ON;
GO

PRINT N'=== 1/5 Estructura (base, staging, limpieza, modelo, analítica, vistas, calidad) ===';
:r $(Proyecto)\sql\01_crear_base.sql
:r $(Proyecto)\sql\02_staging.sql
:r $(Proyecto)\sql\03_carga_bulk.sql
:r $(Proyecto)\sql\04_limpieza.sql
:r $(Proyecto)\sql\05_modelo_estrella.sql
:r $(Proyecto)\sql\06_rfm.sql
:r $(Proyecto)\sql\07_cohortes.sql
:r $(Proyecto)\sql\08_devoluciones.sql
:r $(Proyecto)\sql\09_canasta.sql
:r $(Proyecto)\sql\10_vistas_powerbi.sql
:r $(Proyecto)\sql\11_calidad.sql
GO

PRINT N'=== 2/5 Carga del CSV al staging (BULK INSERT) ===';
USE RetailAnalitica;
EXEC etl.sp_cargar_staging @carpeta_datos = N'$(Proyecto)\data';
GO

PRINT N'=== 3/5 Limpieza y modelo estrella ===';
USE RetailAnalitica;
EXEC etl.sp_limpiar;
EXEC etl.sp_cargar_modelo;
GO

PRINT N'=== 4/5 RFM, cohortes, devoluciones y canasta ===';
USE RetailAnalitica;
EXEC etl.sp_calcular_rfm;
EXEC etl.sp_calcular_cohortes;
EXEC etl.sp_calcular_devoluciones;
EXEC etl.sp_calcular_canasta;
GO

PRINT N'=== 5/5 Controles de calidad ===';
USE RetailAnalitica;
EXEC qa.sp_validar_calidad;
GO
