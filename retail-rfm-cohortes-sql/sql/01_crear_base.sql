/* =====================================================================
   01_crear_base.sql
   Base RetailAnalitica y esquemas por capa.

     stg    datos crudos tal como vienen del CSV (todo texto)
     limpio líneas tipadas y clasificadas (venta, devolución, ajuste...)
     dw     modelo estrella pequeño (dimensiones + hechos)
     mart   tablas analíticas materializadas (RFM, cohortes, canasta)
     rpt    vistas listas para Power BI (única capa que lee el reporte)
     etl    procedimientos de carga
     qa     controles de calidad y cifras de control
   ===================================================================== */
USE master;
GO

IF DB_ID(N'RetailAnalitica') IS NULL
BEGIN
    CREATE DATABASE RetailAnalitica;
    ALTER DATABASE RetailAnalitica SET RECOVERY SIMPLE;   -- base analítica: sin backups de log
END;
GO

USE RetailAnalitica;
GO

DECLARE @esquema SYSNAME, @sql NVARCHAR(200);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT v FROM (VALUES (N'stg'), (N'limpio'), (N'dw'), (N'mart'), (N'rpt'), (N'etl'), (N'qa')) AS e(v);
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
