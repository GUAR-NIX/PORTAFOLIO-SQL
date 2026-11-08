/* =====================================================================
   01_crear_base.sql
   Base ImdbGrafos y esquemas por capa.

     stg      datos crudos tal como vienen de los TSV (todo texto)
     dw       modelo relacional limpio (pelicula, persona, genero, participacion...)
     grafo    tablas NODE y EDGE de SQL Graph (Persona, Pelicula, ActuoEn, Dirigio, TrabajoCon)
     busqueda índice invertido de palabras (alternativa a Full-Text Search)
     mart     tablas analíticas materializadas (ventanas, Bacon, elenco fiel)
     rpt      vistas listas para Power BI (única capa que lee el reporte)
     etl      procedimientos de carga
     qa       auditoría de cargas, cifras de control, mediciones y controles

   Intercalación de la base: Latin1_General_100_CI_AI_SC_UTF8
     * UTF8 -> VARCHAR guarda Unicode (títulos en japonés, ruso...) con la mitad
       de espacio que NVARCHAR para texto latino;
     * CI_AI -> las búsquedas ignoran mayúsculas y tildes ("amelie" = "Amélie").
   ===================================================================== */
USE master;
GO

IF DB_ID(N'ImdbGrafos') IS NULL
BEGIN
    CREATE DATABASE ImdbGrafos COLLATE Latin1_General_100_CI_AI_SC_UTF8;
    ALTER DATABASE ImdbGrafos SET RECOVERY SIMPLE;   -- base analítica: sin backups de log
END;
GO

USE ImdbGrafos;
GO

DECLARE @esquema SYSNAME, @sql NVARCHAR(200);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT v FROM (VALUES (N'stg'), (N'dw'), (N'grafo'), (N'busqueda'), (N'mart'),
                          (N'rpt'), (N'etl'), (N'qa')) AS e(v);
OPEN c;
FETCH NEXT FROM c INTO @esquema;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF SCHEMA_ID(@esquema) IS NULL
    BEGIN
        SET @sql = N'CREATE SCHEMA ' + QUOTENAME(@esquema) + N' AUTHORIZATION dbo;';
        EXEC (@sql);
    END;
    FETCH NEXT FROM c INTO @esquema;
END;
CLOSE c;
DEALLOCATE c;

PRINT CONCAT(N'Base lista: ', DB_NAME(), N' (', CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(20)), N')');
GO
