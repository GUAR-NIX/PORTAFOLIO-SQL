/* =====================================================================
   01_crear_base.sql
   Base TaxisNYC y esquemas por capa.

     stg    viajes de un mes tal como vienen del CSV (se vacía en cada carga)
     dw     modelo estrella: dimensiones + hecho particionado por mes con columnstore
     etl    procedimientos de carga y tablas de trabajo del SWITCH
     qa     auditoría de cargas, cifras de control de la fuente, cuarentena y controles
     mart   tablas analíticas materializadas (horas pico, rutas, propinas...)
     rpt    vistas listas para Power BI (única capa que lee el reporte)
     lab    laboratorio: comparación rowstore vs columnstore y ventana deslizante
   ===================================================================== */
USE master;
GO

IF DB_ID(N'TaxisNYC') IS NULL
BEGIN
    CREATE DATABASE TaxisNYC;
    ALTER DATABASE TaxisNYC SET RECOVERY SIMPLE;   -- base analítica: sin backups de log
    -- Crecer de a 512 MB evita miles de crecimientos pequeños al cargar ~40 M filas
    DECLARE @sql NVARCHAR(400) = N'ALTER DATABASE TaxisNYC MODIFY FILE (NAME = N''TaxisNYC'', FILEGROWTH = 512MB);';
    EXEC (@sql);
    SET @sql = N'ALTER DATABASE TaxisNYC MODIFY FILE (NAME = N''TaxisNYC_log'', SIZE = 1024MB, FILEGROWTH = 512MB);';
    EXEC (@sql);
END;
GO

USE TaxisNYC;
GO

DECLARE @esquema SYSNAME, @sql NVARCHAR(200);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT v FROM (VALUES (N'stg'), (N'dw'), (N'etl'), (N'qa'), (N'mart'), (N'rpt'), (N'lab')) AS e(v);
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

PRINT CONCAT(N'Base lista: ', DB_NAME(), N' (', CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(20)), N', ',
             CAST(SERVERPROPERTY('Edition') AS NVARCHAR(60)), N')');
GO
