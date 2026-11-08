/* =====================================================================
   07_busqueda_texto.sql
   Búsqueda de títulos: Full-Text Search si está instalado y, si no, un
   índice invertido propio en T-SQL que imita CONTAINS y FREETEXT.

   En esta PC FULLTEXTSERVICEPROPERTY('IsFullTextInstalled') = 0: SQL Server
   2025 Express se instaló sin el componente "Full-Text and Semantic
   Extractions for Search". El bloque de Full-Text queda escrito (y se ejecuta
   solo si el componente existe) y la alternativa es la que se mide.

     busqueda.titulo        1 fila por texto distinto de una película
                            (título, título original y títulos alternativos de akas)
     busqueda.palabra       vocabulario: cada palabra con su frecuencia documental
     busqueda.indice        índice invertido palabra -> título (clave agrupada)
     busqueda.sp_buscar     @modo = 'todas'  ~ CONTAINS(texto, '"pal1*" AND "pal2"')
                            @modo = 'libre'  ~ FREETEXT(texto, 'pal1 pal2'), ordenado por TF-IDF
     busqueda.sp_buscar_like  la línea base: LIKE '%texto%' (sin índice posible)

   La intercalación de la base (CI_AI) hace que "amelie" encuentre "Amélie".
   ===================================================================== */
USE ImdbGrafos;
GO

DROP TABLE IF EXISTS busqueda.indice, busqueda.palabra, busqueda.titulo;
GO

CREATE TABLE busqueda.titulo (
    titulo_id    INT IDENTITY(1,1) CONSTRAINT PK_busqueda_titulo PRIMARY KEY,
    pelicula_id  INT            NOT NULL,
    texto        VARCHAR(1000)  NOT NULL,
    tipo         VARCHAR(12)    NOT NULL      -- principal | original | alternativo
);
CREATE INDEX IX_busqueda_titulo_pelicula ON busqueda.titulo (pelicula_id);

CREATE TABLE busqueda.palabra (
    palabra_id  INT IDENTITY(1,1) CONSTRAINT PK_busqueda_palabra PRIMARY KEY NONCLUSTERED,
    palabra     VARCHAR(200)  NOT NULL,
    documentos  INT           NOT NULL,       -- en cuántos títulos aparece (para el IDF)
    CONSTRAINT UQ_busqueda_palabra UNIQUE CLUSTERED (palabra)
);

CREATE TABLE busqueda.indice (
    palabra_id  INT  NOT NULL,
    titulo_id   INT  NOT NULL,
    CONSTRAINT PK_busqueda_indice PRIMARY KEY (palabra_id, titulo_id)
);
GO

/* Normaliza un texto a palabras separadas por un espacio: signos de puntuación
   -> espacio. Mayúsculas y tildes no importan por la intercalación CI_AI. */
CREATE OR ALTER FUNCTION busqueda.fn_normalizar (@texto VARCHAR(1000))
RETURNS VARCHAR(1000)
WITH SCHEMABINDING
AS
BEGIN
    RETURN LOWER(TRANSLATE(@texto, '.,:;!?¡¿()[]{}"''`´’‘“”«»/\|-–—_&+*#@%=<>~^…·',
                                   '                                            '));
END;
GO

CREATE OR ALTER PROCEDURE etl.sp_cargar_busqueda
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @t DATETIME2(3) = SYSDATETIME();

    TRUNCATE TABLE busqueda.indice; DELETE FROM busqueda.palabra; DELETE FROM busqueda.titulo;
    DBCC CHECKIDENT ('busqueda.palabra', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('busqueda.titulo', RESEED, 0) WITH NO_INFOMSGS;

    /* 1. Textos distintos por película (la intercalación CI_AI deduplica variantes de mayúsculas/tildes) */
    INSERT INTO busqueda.titulo (pelicula_id, texto, tipo)
    SELECT pelicula_id, texto, MIN(tipo)
    FROM (SELECT pelicula_id, titulo AS texto, 'principal' AS tipo FROM dw.pelicula
          UNION ALL
          SELECT pelicula_id, titulo_original, 'original' FROM dw.pelicula WHERE titulo_original IS NOT NULL
          UNION ALL
          SELECT pelicula_id, titulo, 'alternativo' FROM dw.titulo_alternativo) AS x
    GROUP BY pelicula_id, texto;
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('busqueda.titulo', @@ROWCOUNT, @t, SYSDATETIME());

    /* 2. Tokenizar: una fila por (palabra, título) */
    SET @t = SYSDATETIME();
    SELECT DISTINCT CAST(s.value AS VARCHAR(200)) COLLATE DATABASE_DEFAULT AS palabra, t.titulo_id
    INTO #tokens
    FROM busqueda.titulo AS t
    CROSS APPLY STRING_SPLIT(busqueda.fn_normalizar(t.texto), ' ') AS s
    WHERE s.value <> '';

    INSERT INTO busqueda.palabra (palabra, documentos)
    SELECT palabra, COUNT(*) FROM #tokens GROUP BY palabra;

    INSERT INTO busqueda.indice WITH (TABLOCK) (palabra_id, titulo_id)
    SELECT DISTINCT p.palabra_id, k.titulo_id
    FROM #tokens AS k JOIN busqueda.palabra AS p ON p.palabra = k.palabra;
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('busqueda.indice (índice invertido)', @@ROWCOUNT, @t, SYSDATETIME());

    /* 3. Full-Text Search real, solo si el componente está instalado */
    IF FULLTEXTSERVICEPROPERTY('IsFullTextInstalled') = 1
    BEGIN
        SET @t = SYSDATETIME();
        IF NOT EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = 'cat_titulos')
            EXEC (N'CREATE FULLTEXT CATALOG cat_titulos AS DEFAULT;');
        IF NOT EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID('busqueda.titulo'))
            EXEC (N'CREATE FULLTEXT INDEX ON busqueda.titulo (texto LANGUAGE 0)
                    KEY INDEX PK_busqueda_titulo ON cat_titulos WITH CHANGE_TRACKING AUTO;');
        INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('full-text index', NULL, @t, SYSDATETIME());
    END
    ELSE
        PRINT N'Full-Text Search no está instalado: se usa el índice invertido busqueda.indice.';
END;
GO

/* ---------- Búsqueda con el índice invertido ----------
   'todas': todas las palabras deben estar; una palabra que termina en * busca por prefijo.
   'libre': basta una palabra; el puntaje es la suma del IDF de las palabras que coinciden. */
CREATE OR ALTER PROCEDURE busqueda.sp_buscar
    @consulta  VARCHAR(400),
    @modo      VARCHAR(10) = 'todas',
    @top       INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    -- Total de títulos desde los metadatos (contar 680 mil filas en cada búsqueda costaría más que la búsqueda)
    DECLARE @n_titulos FLOAT = (SELECT SUM(row_count) FROM sys.dm_db_partition_stats
                                WHERE object_id = OBJECT_ID(N'busqueda.titulo') AND index_id = 1);

    DECLARE @terminos TABLE (termino VARCHAR(200) PRIMARY KEY, prefijo BIT);
    INSERT INTO @terminos
    SELECT DISTINCT REPLACE(s.value, '*', ''), IIF(s.value LIKE '%*', 1, 0)
    FROM STRING_SPLIT(busqueda.fn_normalizar(REPLACE(@consulta, '*', ' * ')), ' ') AS s
    WHERE s.value NOT IN ('', '*');
    -- fn_normalizar convierte * en espacio: se recupera el prefijo desde la consulta original
    UPDATE t SET prefijo = 1
    FROM @terminos AS t
    WHERE ' ' + LOWER(@consulta) + ' ' LIKE '% ' + t.termino + '*%';

    DECLARE @n_terminos INT = (SELECT COUNT(*) FROM @terminos);

    /* Palabras del vocabulario que cumplen cada término. Dos ramas separadas para que
       ambas sean búsquedas (seek) en el índice agrupado de palabra; un OR las volvería un recorrido. */
    DECLARE @pal TABLE (termino VARCHAR(200), palabra_id INT, idf FLOAT, PRIMARY KEY (termino, palabra_id));
    INSERT INTO @pal
    SELECT t.termino, p.palabra_id, LOG(@n_titulos / p.documentos)
    FROM @terminos AS t JOIN busqueda.palabra AS p ON p.palabra = t.termino
    WHERE t.prefijo = 0
    UNION ALL
    SELECT t.termino, p.palabra_id, LOG(@n_titulos / p.documentos)
    FROM @terminos AS t JOIN busqueda.palabra AS p ON p.palabra LIKE t.termino + '%'
    WHERE t.prefijo = 1;

    WITH coincidencias AS (
        SELECT i.titulo_id, w.termino, MAX(w.idf) AS idf
        FROM @pal AS w
        JOIN busqueda.indice AS i ON i.palabra_id = w.palabra_id
        GROUP BY i.titulo_id, w.termino
    ), por_titulo AS (
        SELECT titulo_id, COUNT(*) AS terminos, SUM(idf) AS puntaje
        FROM coincidencias GROUP BY titulo_id
        HAVING @modo = 'libre' OR COUNT(*) = @n_terminos
    ), por_pelicula AS (
        SELECT b.pelicula_id, MAX(pt.puntaje) AS puntaje,
               MIN(b.texto) AS texto_encontrado
        FROM por_titulo AS pt JOIN busqueda.titulo AS b ON b.titulo_id = pt.titulo_id
        GROUP BY b.pelicula_id
    )
    SELECT TOP (@top) p.pelicula_id, p.titulo, p.anio, c.calificacion, c.votos,
           CAST(pp.puntaje AS DECIMAL(9,3)) AS puntaje, pp.texto_encontrado,
           COUNT(*) OVER () AS total_peliculas
    FROM por_pelicula AS pp
    JOIN dw.pelicula AS p ON p.pelicula_id = pp.pelicula_id
    JOIN dw.calificacion AS c ON c.pelicula_id = p.pelicula_id
    ORDER BY pp.puntaje DESC, c.votos DESC;
END;
GO

/* ---------- Línea base: LIKE '%...%' ----------
   El comodín inicial impide usar un índice: se recorre toda busqueda.titulo. */
CREATE OR ALTER PROCEDURE busqueda.sp_buscar_like
    @texto  VARCHAR(400),
    @top    INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    WITH por_pelicula AS (
        SELECT b.pelicula_id, MIN(b.texto) AS texto_encontrado
        FROM busqueda.titulo AS b
        WHERE b.texto LIKE '%' + @texto + '%'
        GROUP BY b.pelicula_id
    )
    SELECT TOP (@top) p.pelicula_id, p.titulo, p.anio, c.calificacion, c.votos,
           pp.texto_encontrado, COUNT(*) OVER () AS total_peliculas
    FROM por_pelicula AS pp
    JOIN dw.pelicula AS p ON p.pelicula_id = pp.pelicula_id
    JOIN dw.calificacion AS c ON c.pelicula_id = p.pelicula_id
    ORDER BY c.votos DESC;
END;
GO

PRINT N'Búsqueda de texto creada.';
GO
