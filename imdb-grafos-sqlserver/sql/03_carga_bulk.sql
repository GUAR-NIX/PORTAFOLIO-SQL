/* =====================================================================
   03_carga_bulk.sql
   etl.sp_cargar_staging -> carga los 6 TSV de IMDb al staging con auditoría.

     1. Cifras de control de la fuente (JSON de descargar_datos.py) con
        OPENROWSET(BULK ... SINGLE_CLOB) + OPENJSON.
     2. title.basics y title.ratings completos con BULK INSERT
        (12,9 M + 1,7 M filas): con ellos se decide qué películas entran.
     3. stg.pelicula_filtro = películas (titleType = movie), no adultas y con
        >= 1.000 votos (parámetros en etl.parametro).
     4. title.principals (102 M filas), title.akas y name.basics se leen con
        OPENROWSET(BULK) + format file y se filtran AL VUELO: en staging solo
        queda lo que pertenece a las películas filtradas. Así la base ocupa
        ~2 GB en vez de ~12 GB.
     5. title.crew (12,9 M filas, 0,4 GB) va con BULK INSERT completo a una
        tabla de paso y luego se filtra: 4 series de TV tienen listas de
        guionistas de más de 8.000 bytes y OPENROWSET no lee más que eso.

   Auditoría (qa.auditoria_carga): filas en el TSV (Python) frente a filas
   leídas por el motor frente a filas cargadas en staging.

   Reanudable: con @reanudar = 1 se saltan los archivos cuya última carga
   terminó, con el mismo filtro, y cuya tabla de staging conserva esas filas.

   Nota de codificación: los TSV están en UTF-8. BULK INSERT con
   CODEPAGE = '65001' escribe bien en columnas VARCHAR UTF-8. OPENROWSET(BULK)
   en cambio devuelve VARCHAR con la intercalación del servidor
   (Modern_Spanish, página 1252) y estropea los caracteres que no existen en
   ella. Por eso se lee con CODEPAGE = 'RAW' (bytes tal cual) y las columnas de
   texto libre se reinterpretan con CAST(CAST(col AS VARBINARY) AS VARCHAR).

   Uso:
     EXEC etl.sp_cargar_staging @carpeta_proyecto = N'C:\...\imdb-grafos-sqlserver';
   La cuenta del servicio (NT Service\MSSQL$SQLEXPRESS) necesita leer data\ y
   sql\formatos\ y escribir en data\errores\ (ver docs/GUIA_PASO_A_PASO.md).
   ===================================================================== */
USE ImdbGrafos;
GO

CREATE OR ALTER PROCEDURE etl.sp_cargar_staging
    @carpeta_proyecto NVARCHAR(400),
    @reanudar         BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @raiz NVARCHAR(400) =
        CASE WHEN RIGHT(@carpeta_proyecto, 1) = N'\' THEN LEFT(@carpeta_proyecto, LEN(@carpeta_proyecto) - 1)
             ELSE @carpeta_proyecto END;
    DECLARE @raw NVARCHAR(500) = @raiz + N'\data\raw\',
            @fmt NVARCHAR(500) = @raiz + N'\sql\formatos\',
            @err NVARCHAR(500) = @raiz + N'\data\errores\',
            @sello NVARCHAR(20) = FORMAT(SYSDATETIME(), 'yyyyMMdd_HHmmss'),
            @sql NVARCHAR(MAX), @inicio DATETIME2(0), @leidas BIGINT, @cargadas BIGINT, @id INT;

    /* Firma del filtro: si cambian los parámetros, no se reutiliza nada */
    DECLARE @tipo VARCHAR(20) = (SELECT valor FROM etl.parametro WHERE nombre = 'tipo_titulo'),
            @min_votos INT     = (SELECT CAST(valor AS INT) FROM etl.parametro WHERE nombre = 'min_votos'),
            @sin_adultos BIT   = (SELECT CAST(valor AS BIT) FROM etl.parametro WHERE nombre = 'excluir_adultos');
    DECLARE @firma VARCHAR(200) = CONCAT('tipo=', @tipo, ';min_votos=', @min_votos, ';sin_adultos=', @sin_adultos);

    /* ---------- 1. Cifras de control de la fuente ---------- */
    DECLARE @contenido NVARCHAR(MAX);
    SET @sql = N'SELECT @c = BulkColumn FROM OPENROWSET(BULK '
             + QUOTENAME(@raiz + N'\data\cifras_control.json', '''') + N', SINGLE_CLOB) AS j;';
    EXEC sys.sp_executesql @sql, N'@c NVARCHAR(MAX) OUTPUT', @c = @contenido OUTPUT;

    DELETE FROM qa.cifra_control;
    INSERT INTO qa.cifra_control (archivo, filas_fuente, bytes_tsv, publicado)
    SELECT a.[key] COLLATE DATABASE_DEFAULT,
           CAST(JSON_VALUE(a.value, '$.filas_datos') AS BIGINT),
           CAST(JSON_VALUE(a.value, '$.bytes_tsv') AS BIGINT),
           JSON_VALUE(a.value, '$.last_modified')
    FROM OPENJSON(@contenido, '$.archivos') AS a;

    /* Tabla de trabajo: qué archivo va a qué tabla y cómo */
    DECLARE @plan TABLE (orden INT, archivo VARCHAR(40), tabla SYSNAME, metodo VARCHAR(40),
                         columnas NVARCHAR(MAX), filtro NVARCHAR(MAX));
    INSERT INTO @plan VALUES
     (1, 'title.basics',  N'stg.title_basics',  'BULK INSERT', NULL, NULL),
     (2, 'title.ratings', N'stg.title_ratings', 'BULK INSERT', NULL, NULL),
     (3, 'title.principals', N'stg.title_principals', 'OPENROWSET(BULK) + filtro',
         N'f.tconst, f.ordering, f.nconst, f.category,
           CAST(CAST(f.job AS VARBINARY(1000)) AS VARCHAR(1000)),
           CAST(CAST(f.characters AS VARBINARY(2000)) AS VARCHAR(2000))',
         N'EXISTS (SELECT 1 FROM stg.pelicula_filtro AS p WHERE p.tconst = f.tconst COLLATE DATABASE_DEFAULT)'),
     (4, 'title.crew', N'stg.title_crew', 'BULK INSERT + filtro',
         N'f.tconst, f.directors, f.writers',
         N'EXISTS (SELECT 1 FROM stg.pelicula_filtro AS p WHERE p.tconst = f.tconst)'),
     (5, 'title.akas', N'stg.title_akas', 'OPENROWSET(BULK) + filtro',
         N'f.titleId, f.ordering, CAST(CAST(f.title AS VARBINARY(1000)) AS VARCHAR(1000)),
           f.region, f.language, f.types, CAST(CAST(f.attributes AS VARBINARY(400)) AS VARCHAR(400)),
           f.isOriginalTitle',
         N'EXISTS (SELECT 1 FROM stg.pelicula_filtro AS p WHERE p.tconst = f.titleId COLLATE DATABASE_DEFAULT)'),
     (6, 'name.basics', N'stg.name_basics', 'OPENROWSET(BULK) + filtro',
         N'f.nconst, CAST(CAST(f.primaryName AS VARBINARY(400)) AS VARCHAR(400)),
           f.birthYear, f.deathYear, f.primaryProfession, f.knownForTitles',
         N'EXISTS (SELECT 1 FROM stg.persona_filtro AS p WHERE p.nconst = f.nconst COLLATE DATABASE_DEFAULT)');

    DECLARE @orden INT = 0, @archivo VARCHAR(40), @tabla SYSNAME, @metodo VARCHAR(40),
            @columnas NVARCHAR(MAX), @filtro NVARCHAR(MAX), @tsv NVARCHAR(600), @fuente BIGINT;

    WHILE 1 = 1
    BEGIN
        SELECT TOP (1) @orden = orden, @archivo = archivo, @tabla = tabla, @metodo = metodo,
                       @columnas = columnas, @filtro = filtro
        FROM @plan WHERE orden > @orden ORDER BY orden;
        IF @@ROWCOUNT = 0 BREAK;

        /* Antes de los archivos filtrados: calcular los conjuntos del filtro */
        IF @orden = 3
        BEGIN
            TRUNCATE TABLE stg.pelicula_filtro;
            INSERT INTO stg.pelicula_filtro (tconst)
            SELECT b.tconst
            FROM stg.title_basics AS b
            JOIN stg.title_ratings AS r ON r.tconst = b.tconst
            WHERE b.titleType = @tipo
              AND TRY_CAST(r.numVotes AS INT) >= @min_votos
              AND (@sin_adultos = 0 OR b.isAdult = '0');
            PRINT CONCAT(N'  Películas que pasan el filtro (', @firma, N'): ', FORMAT(@@ROWCOUNT, 'N0'));
        END;
        IF @orden = 6
        BEGIN
            TRUNCATE TABLE stg.persona_filtro;
            INSERT INTO stg.persona_filtro (nconst)
            SELECT nconst FROM stg.title_principals
            UNION
            SELECT s.value FROM stg.title_crew AS c CROSS APPLY STRING_SPLIT(c.directors, ',') AS s WHERE s.value <> '\N'
            UNION
            SELECT s.value FROM stg.title_crew AS c CROSS APPLY STRING_SPLIT(c.writers, ',') AS s WHERE s.value <> '\N';
            PRINT CONCAT(N'  Personas en las películas filtradas: ', FORMAT(@@ROWCOUNT, 'N0'));
        END;

        /* ¿Se puede reutilizar la carga anterior? */
        SET @sql = N'SELECT @n = COUNT_BIG(*) FROM ' + @tabla + N';';
        EXEC sys.sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @cargadas OUTPUT;
        IF @reanudar = 1 AND @cargadas > 0 AND EXISTS (
               SELECT 1 FROM qa.auditoria_carga AS a
               WHERE a.carga_id = (SELECT MAX(carga_id) FROM qa.auditoria_carga WHERE archivo = @archivo)
                 AND a.fin IS NOT NULL AND a.filas_cargadas = @cargadas
                 AND (a.metodo = 'BULK INSERT' OR a.detalle LIKE '%' + @firma))
        BEGIN
            PRINT CONCAT(N'[OMITIDO] ', @archivo, N': ya cargado (', FORMAT(@cargadas, 'N0'), N' filas)');
            CONTINUE;
        END;

        SET @tsv = @raw + @archivo + N'.tsv';
        SET @fuente = (SELECT filas_fuente FROM qa.cifra_control WHERE archivo = @archivo);
        SET @inicio = SYSDATETIME();
        INSERT INTO qa.auditoria_carga (archivo, metodo, filas_fuente, inicio, detalle)
        VALUES (@archivo, @metodo, @fuente, @inicio, IIF(@metodo = 'BULK INSERT', @tsv, @firma));
        SET @id = SCOPE_IDENTITY();

        SET @sql = N'TRUNCATE TABLE ' + @tabla + N';';
        EXEC (@sql);

        IF @metodo = 'BULK INSERT'
        BEGIN
            SET @sql = N'BULK INSERT ' + @tabla + N' FROM ' + QUOTENAME(@tsv, '''') + N'
                WITH (FIRSTROW = 2, FIELDTERMINATOR = ''\t'', ROWTERMINATOR = ''0x0a'',
                      CODEPAGE = ''65001'', TABLOCK, MAXERRORS = 1000,
                      ERRORFILE = ' + QUOTENAME(@err + @archivo + N'_' + @sello + N'.err', '''') + N');';
            EXEC (@sql);
            SET @sql = N'SELECT @n = COUNT_BIG(*) FROM ' + @tabla + N';';
            EXEC sys.sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @cargadas OUTPUT;
            SET @leidas = @cargadas;   -- BULK INSERT no filtra: lo leído es lo cargado
        END
        ELSE IF @metodo = 'BULK INSERT + filtro'
        BEGIN
            -- Carga completa a la tabla de paso (VARCHAR(MAX)) y filtro con INSERT ... SELECT
            TRUNCATE TABLE stg.title_crew_completo;
            SET @sql = N'BULK INSERT stg.title_crew_completo FROM ' + QUOTENAME(@tsv, '''') + N'
                WITH (FIRSTROW = 2, FIELDTERMINATOR = ''\t'', ROWTERMINATOR = ''0x0a'',
                      CODEPAGE = ''65001'', TABLOCK, MAXERRORS = 1000,
                      ERRORFILE = ' + QUOTENAME(@err + @archivo + N'_' + @sello + N'.err', '''') + N');';
            EXEC (@sql);
            SET @leidas = (SELECT COUNT_BIG(*) FROM stg.title_crew_completo);
            SET @sql = N'INSERT INTO ' + @tabla + N' WITH (TABLOCK) SELECT ' + @columnas
                     + N' FROM stg.title_crew_completo AS f WHERE ' + @filtro + N';';
            EXEC (@sql);
            SET @cargadas = @@ROWCOUNT;
            TRUNCATE TABLE stg.title_crew_completo;   -- libera los 0,4 GB de la tabla de paso
        END
        ELSE
        BEGIN
            DECLARE @origen NVARCHAR(MAX) = N'OPENROWSET(BULK ' + QUOTENAME(@tsv, '''')
                + N', FORMATFILE = ' + QUOTENAME(@fmt + REPLACE(@archivo, '.', '_') + N'.fmt', '''')
                + N', CODEPAGE = ''RAW'', FIRSTROW = 2, MAXERRORS = 1000) AS f';
            -- Pasada 1: cuántas filas puede leer el motor (auditoría de formato)
            SET @sql = N'SELECT @n = COUNT_BIG(*) FROM ' + @origen + N';';
            EXEC sys.sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @leidas OUTPUT;
            -- Pasada 2: solo las filas de las películas / personas filtradas
            SET @sql = N'INSERT INTO ' + @tabla + N' WITH (TABLOCK) SELECT ' + @columnas
                     + N' FROM ' + @origen + N' WHERE ' + @filtro + N';';
            EXEC (@sql);
            SET @cargadas = @@ROWCOUNT;
        END;

        UPDATE qa.auditoria_carga
        SET filas_leidas = @leidas, filas_cargadas = @cargadas, fin = SYSDATETIME()
        WHERE carga_id = @id;

        PRINT CONCAT(N'  ', @archivo, N': fuente ', FORMAT(@fuente, 'N0'), N' · leídas ', FORMAT(@leidas, 'N0'),
                     N' · cargadas ', FORMAT(@cargadas, 'N0'), N' · ', DATEDIFF(SECOND, @inicio, SYSDATETIME()), N' s');
    END;
END;
GO

PRINT N'Procedimiento de carga creado.';
GO
