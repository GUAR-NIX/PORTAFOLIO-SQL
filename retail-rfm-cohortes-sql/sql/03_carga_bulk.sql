/* =====================================================================
   03_carga_bulk.sql
   etl.sp_cargar_staging  -> BULK INSERT del CSV al staging y lectura de las
                             cifras de control (JSON) con OPENROWSET + OPENJSON.

   Uso:
     EXEC etl.sp_cargar_staging @carpeta_datos = N'C:\...\retail-rfm-cohortes-sql\data';

   La cuenta del servicio (NT Service\MSSQL$SQLEXPRESS) necesita permiso de
   lectura sobre la carpeta data/ (ver docs/GUIA_PASO_A_PASO.md, paso 2).
   ===================================================================== */
USE RetailAnalitica;
GO

CREATE OR ALTER PROCEDURE etl.sp_cargar_staging
    @carpeta_datos NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @carpeta NVARCHAR(400) =
        CASE WHEN RIGHT(@carpeta_datos, 1) = N'\' THEN LEFT(@carpeta_datos, LEN(@carpeta_datos) - 1)
             ELSE @carpeta_datos END;
    DECLARE @csv  NVARCHAR(600) = @carpeta + N'\raw\online_retail_ii.csv';
    DECLARE @json NVARCHAR(600) = @carpeta + N'\cifras_control.json';
    DECLARE @sql NVARCHAR(MAX), @inicio DATETIME2(0) = SYSDATETIME(), @filas BIGINT;

    /* 1. CSV -> staging (idempotente: siempre se vacía antes) */
    TRUNCATE TABLE stg.factura_linea;

    SET @sql = N'
        BULK INSERT stg.factura_linea
        FROM ' + QUOTENAME(@csv, '''') + N'
        WITH (FORMAT = ''CSV'', FIRSTROW = 2, FIELDQUOTE = ''"'',
              FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'',
              CODEPAGE = ''65001'', TABLOCK, MAXERRORS = 0);';
    EXEC sys.sp_executesql @sql;

    SELECT @filas = COUNT_BIG(*) FROM stg.factura_linea;
    INSERT INTO qa.bitacora_carga (paso, filas, inicio, fin, detalle)
    VALUES (N'BULK INSERT staging', @filas, @inicio, SYSDATETIME(), @csv);

    /* 2. Cifras de control de la fuente (JSON generado por descargar_datos.py) */
    DECLARE @contenido NVARCHAR(MAX);
    SET @sql = N'SELECT @c = BulkColumn FROM OPENROWSET(BULK ' + QUOTENAME(@json, '''')
             + N', SINGLE_CLOB) AS j;';
    EXEC sys.sp_executesql @sql, N'@c NVARCHAR(MAX) OUTPUT', @c = @contenido OUTPUT;

    DELETE FROM qa.cifra_control;
    INSERT INTO qa.cifra_control (hoja, filas, cantidad_total, importe_total)
    SELECT h.[key],
           CAST(JSON_VALUE(h.value, '$.filas') AS BIGINT),
           CAST(JSON_VALUE(h.value, '$.cantidad_total') AS BIGINT),
           CAST(JSON_VALUE(h.value, '$.importe_total') AS DECIMAL(19,3))
    FROM OPENJSON(@contenido, '$.hojas') AS h;

    DECLARE @hojas INT = (SELECT COUNT(*) FROM qa.cifra_control);
    PRINT CONCAT(N'Staging cargado: ', FORMAT(@filas, 'N0'), N' filas en ',
                 DATEDIFF(SECOND, @inicio, SYSDATETIME()), N' s. Cifras de control: ', @hojas, N' hojas.');
END;
GO

PRINT N'Procedimiento de carga creado.';
GO
