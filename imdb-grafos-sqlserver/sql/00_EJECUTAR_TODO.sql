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

   Antes: .venv\Scripts\python scripts\descargar_datos.py  (deja los TSV y las
   cifras de control en data\) y los permisos del paso 2 de la guía.
   Tarda ~15 min (la mitad es leer
   los 102 M de filas de title.principals) + ~8 min del banco de rendimiento.

   Reanudable: si se corta en la carga, vuelve a ejecutar solo el paso 2
   (EXEC etl.sp_cargar_staging ... @reanudar = 1) y luego desde el paso 3.
   ===================================================================== */
:on error exit
SET QUOTED_IDENTIFIER ON;
GO

PRINT N'=== 1/7 Estructura (base, staging, modelo, grafo, búsqueda, analítica, vistas, calidad) ===';
:r $(Proyecto)\sql\01_crear_base.sql
:r $(Proyecto)\sql\02_staging.sql
:r $(Proyecto)\sql\03_carga_bulk.sql
:r $(Proyecto)\sql\04_modelo_relacional.sql
:r $(Proyecto)\sql\05_modelo_grafo.sql
:r $(Proyecto)\sql\06_consultas_grafo.sql
:r $(Proyecto)\sql\07_busqueda_texto.sql
:r $(Proyecto)\sql\08_analisis_ventanas.sql
:r $(Proyecto)\sql\09_rendimiento.sql
:r $(Proyecto)\sql\10_vistas_powerbi.sql
:r $(Proyecto)\sql\11_calidad.sql
GO

PRINT N'=== 2/7 Carga de los TSV al staging (BULK INSERT + OPENROWSET con filtro) ===';
USE ImdbGrafos;
EXEC etl.sp_cargar_staging @carpeta_proyecto = N'$(Proyecto)', @reanudar = 1;
GO

PRINT N'=== 3/7 Modelo relacional ===';
USE ImdbGrafos;
EXEC etl.sp_cargar_modelo;
GO

PRINT N'=== 4/7 Modelo de grafo (NODE / EDGE) ===';
USE ImdbGrafos;
EXEC etl.sp_cargar_grafo;
GO

PRINT N'=== 5/7 Búsqueda de texto, analítica con ventanas y resultados de grafo ===';
USE ImdbGrafos;
EXEC etl.sp_cargar_busqueda;
EXEC etl.sp_calcular_analitica;
INSERT INTO dw.colaboracion WITH (TABLOCK) (persona_a, persona_b, peliculas_en_comun)
SELECT a.persona_id, b.persona_id, t.peliculas_en_comun
FROM grafo.Persona AS a, grafo.TrabajoCon AS t, grafo.Persona AS b
WHERE MATCH(a-(t)->b);
EXEC etl.sp_calcular_grafo;
GO

PRINT N'=== 6/7 Controles de calidad ===';
USE ImdbGrafos;
EXEC qa.sp_validar_calidad;
GO

PRINT N'=== 7/7 Banco de rendimiento (grafo vs relacional, índice vs LIKE) ===';
USE ImdbGrafos;
EXEC qa.sp_medir_rendimiento @repeticiones = 5;
GO
