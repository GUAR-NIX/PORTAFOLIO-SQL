/* =====================================================================
   04_modelo_relacional.sql
   Modelo relacional limpio (esquema dw) y su carga desde staging.

     dw.pelicula            1 fila por película filtrada (clave = número del tconst)
     dw.calificacion        calificación promedio y votos de IMDb
     dw.genero              catálogo de géneros
     dw.pelicula_genero     puente: la lista "Drama,Romance" se normaliza en filas
     dw.persona             actores, directores, guionistas... de esas películas
     dw.rol                 categorías de IMDb agrupadas en español
     dw.participacion       persona – película – rol (principals + crew)
     dw.titulo_alternativo  títulos por país/idioma (title.akas)

   Claves: 'tt0111161' -> 111161 y 'nm0000102' -> 102. Un INT ocupa 4 bytes
   frente a ~10 del texto y acelera los joins del grafo.

   Uso:  EXEC etl.sp_cargar_modelo;
   ===================================================================== */
USE ImdbGrafos;
GO

/* Las tablas se recrean en orden inverso de dependencias */
DROP TABLE IF EXISTS dw.titulo_alternativo, dw.participacion, dw.pelicula_genero,
                     dw.calificacion, dw.rol, dw.genero, dw.persona, dw.pelicula;
GO

CREATE TABLE dw.pelicula (
    pelicula_id      INT            NOT NULL CONSTRAINT PK_pelicula PRIMARY KEY,
    tconst           VARCHAR(12)    NOT NULL CONSTRAINT UQ_pelicula_tconst UNIQUE,
    titulo           VARCHAR(1000)  NOT NULL,
    titulo_original  VARCHAR(1000)  NULL,
    anio             SMALLINT       NULL,
    decada           AS CAST(anio / 10 * 10 AS SMALLINT) PERSISTED,
    duracion_min     SMALLINT       NULL
);

CREATE TABLE dw.calificacion (
    pelicula_id   INT           NOT NULL CONSTRAINT PK_calificacion PRIMARY KEY
                                CONSTRAINT FK_calificacion_pelicula REFERENCES dw.pelicula (pelicula_id),
    calificacion  DECIMAL(3,1)  NOT NULL CONSTRAINT CK_calificacion_rango CHECK (calificacion BETWEEN 1 AND 10),
    votos         INT           NOT NULL
);

CREATE TABLE dw.genero (
    genero_id  TINYINT IDENTITY(1,1) CONSTRAINT PK_genero PRIMARY KEY,
    nombre     VARCHAR(40)  NOT NULL CONSTRAINT UQ_genero UNIQUE
);

CREATE TABLE dw.pelicula_genero (
    pelicula_id  INT      NOT NULL CONSTRAINT FK_pg_pelicula REFERENCES dw.pelicula (pelicula_id),
    genero_id    TINYINT  NOT NULL CONSTRAINT FK_pg_genero REFERENCES dw.genero (genero_id),
    CONSTRAINT PK_pelicula_genero PRIMARY KEY (pelicula_id, genero_id)
);

CREATE TABLE dw.persona (
    persona_id       INT           NOT NULL CONSTRAINT PK_persona PRIMARY KEY,
    nconst           VARCHAR(12)   NOT NULL CONSTRAINT UQ_persona_nconst UNIQUE,
    nombre           VARCHAR(400)  NOT NULL,
    anio_nacimiento  SMALLINT      NULL,
    anio_muerte      SMALLINT      NULL,
    profesiones      VARCHAR(200)  NULL
);

CREATE TABLE dw.rol (
    rol_id     TINYINT IDENTITY(1,1) CONSTRAINT PK_rol PRIMARY KEY,
    categoria  VARCHAR(40)  NOT NULL CONSTRAINT UQ_rol UNIQUE,   -- valor original de IMDb
    grupo      VARCHAR(30)  NOT NULL                             -- agrupación en español
);

CREATE TABLE dw.participacion (
    pelicula_id  INT           NOT NULL CONSTRAINT FK_part_pelicula REFERENCES dw.pelicula (pelicula_id),
    persona_id   INT           NOT NULL CONSTRAINT FK_part_persona REFERENCES dw.persona (persona_id),
    rol_id       TINYINT       NOT NULL CONSTRAINT FK_part_rol REFERENCES dw.rol (rol_id),
    orden        TINYINT       NULL,      -- posición en los créditos (NULL si viene solo de title.crew)
    personaje    VARCHAR(400)  NULL,
    fuente       VARCHAR(10)   NOT NULL,  -- principals | crew
    CONSTRAINT PK_participacion PRIMARY KEY (pelicula_id, persona_id, rol_id)
);
CREATE INDEX IX_participacion_persona ON dw.participacion (persona_id, rol_id) INCLUDE (pelicula_id);

CREATE TABLE dw.titulo_alternativo (
    pelicula_id  INT            NOT NULL CONSTRAINT FK_ta_pelicula REFERENCES dw.pelicula (pelicula_id),
    orden        SMALLINT       NOT NULL,
    titulo       VARCHAR(1000)  NOT NULL,
    region       VARCHAR(10)    NULL,
    idioma       VARCHAR(10)    NULL,
    tipos        VARCHAR(100)   NULL,
    CONSTRAINT PK_titulo_alternativo PRIMARY KEY (pelicula_id, orden)
);
GO

CREATE OR ALTER PROCEDURE etl.sp_cargar_modelo
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @t DATETIME2(3);

    DELETE FROM dw.titulo_alternativo; DELETE FROM dw.participacion; DELETE FROM dw.pelicula_genero;
    DELETE FROM dw.calificacion; DELETE FROM dw.persona; DELETE FROM dw.pelicula;
    DELETE FROM dw.genero; DELETE FROM dw.rol;

    /* ---------- Películas y calificación ---------- */
    SET @t = SYSDATETIME();
    INSERT INTO dw.pelicula (pelicula_id, tconst, titulo, titulo_original, anio, duracion_min)
    SELECT CAST(SUBSTRING(b.tconst, 3, 12) AS INT), b.tconst, b.primaryTitle,
           NULLIF(NULLIF(b.originalTitle, '\N'), b.primaryTitle),       -- solo si difiere del título
           TRY_CAST(NULLIF(b.startYear, '\N') AS SMALLINT),
           TRY_CAST(NULLIF(b.runtimeMinutes, '\N') AS SMALLINT)
    FROM stg.title_basics AS b
    JOIN stg.pelicula_filtro AS f ON f.tconst = b.tconst;
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('dw.pelicula', @@ROWCOUNT, @t, SYSDATETIME());

    SET @t = SYSDATETIME();
    INSERT INTO dw.calificacion (pelicula_id, calificacion, votos)
    SELECT p.pelicula_id, CAST(r.averageRating AS DECIMAL(3,1)), CAST(r.numVotes AS INT)
    FROM stg.title_ratings AS r
    JOIN dw.pelicula AS p ON p.tconst = r.tconst;
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('dw.calificacion', @@ROWCOUNT, @t, SYSDATETIME());

    /* ---------- Géneros: "Action,Crime,Drama" -> 3 filas ---------- */
    SET @t = SYSDATETIME();
    SELECT p.pelicula_id, CAST(TRIM(s.value) AS VARCHAR(40)) AS genero
    INTO #pg
    FROM stg.title_basics AS b
    JOIN dw.pelicula AS p ON p.tconst = b.tconst
    CROSS APPLY STRING_SPLIT(b.genres, ',') AS s
    WHERE b.genres <> '\N';

    INSERT INTO dw.genero (nombre) SELECT DISTINCT genero FROM #pg ORDER BY genero;
    INSERT INTO dw.pelicula_genero (pelicula_id, genero_id)
    SELECT DISTINCT x.pelicula_id, g.genero_id
    FROM #pg AS x JOIN dw.genero AS g ON g.nombre = x.genero COLLATE DATABASE_DEFAULT;
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('dw.pelicula_genero', @@ROWCOUNT, @t, SYSDATETIME());

    /* ---------- Personas ---------- */
    SET @t = SYSDATETIME();
    INSERT INTO dw.persona (persona_id, nconst, nombre, anio_nacimiento, anio_muerte, profesiones)
    SELECT CAST(SUBSTRING(n.nconst, 3, 12) AS INT), n.nconst, n.primaryName,
           TRY_CAST(NULLIF(n.birthYear, '\N') AS SMALLINT),
           TRY_CAST(NULLIF(n.deathYear, '\N') AS SMALLINT),
           NULLIF(n.primaryProfession, '\N')
    FROM stg.name_basics AS n
    WHERE n.primaryName <> '\N';
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('dw.persona', @@ROWCOUNT, @t, SYSDATETIME());

    /* ---------- Roles: categorías de IMDb agrupadas ---------- */
    INSERT INTO dw.rol (categoria, grupo)
    SELECT c.categoria,
           CASE c.categoria
                WHEN 'actor' THEN 'Actuación' WHEN 'actress' THEN 'Actuación'
                WHEN 'director' THEN 'Dirección' WHEN 'writer' THEN 'Guion'
                WHEN 'producer' THEN 'Producción' WHEN 'composer' THEN 'Música'
                WHEN 'cinematographer' THEN 'Fotografía' WHEN 'editor' THEN 'Montaje'
                WHEN 'self' THEN 'Aparece como sí mismo'
                WHEN 'archive_footage' THEN 'Material de archivo' WHEN 'archive_sound' THEN 'Material de archivo'
                ELSE 'Otros equipos técnicos' END
    FROM (SELECT DISTINCT category AS categoria FROM stg.title_principals
          UNION SELECT 'director' UNION SELECT 'writer') AS c;

    /* ---------- Participación: principals + directores y guionistas de crew ---------- */
    SET @t = SYSDATETIME();
    WITH principals AS (
        SELECT CAST(SUBSTRING(t.tconst, 3, 12) AS INT) AS pelicula_id,
               CAST(SUBSTRING(t.nconst, 3, 12) AS INT) AS persona_id,
               r.rol_id,
               TRY_CAST(t.ordering AS TINYINT) AS orden,
               -- characters viene como arreglo JSON: ["Andy Dufresne"] -> Andy Dufresne
               CAST(IIF(ISJSON(t.characters) = 1, JSON_VALUE(t.characters, '$[0]'), NULL) AS VARCHAR(400)) AS personaje,
               ROW_NUMBER() OVER (PARTITION BY t.tconst, t.nconst, r.rol_id
                                  ORDER BY TRY_CAST(t.ordering AS INT)) AS rn
        FROM stg.title_principals AS t
        JOIN dw.rol AS r ON r.categoria = t.category
    )
    INSERT INTO dw.participacion (pelicula_id, persona_id, rol_id, orden, personaje, fuente)
    SELECT pr.pelicula_id, pr.persona_id, pr.rol_id, pr.orden, pr.personaje, 'principals'
    FROM principals AS pr
    WHERE pr.rn = 1
      AND EXISTS (SELECT 1 FROM dw.persona AS p WHERE p.persona_id = pr.persona_id);
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('dw.participacion (principals)', @@ROWCOUNT, @t, SYSDATETIME());

    SET @t = SYSDATETIME();
    INSERT INTO dw.participacion (pelicula_id, persona_id, rol_id, orden, personaje, fuente)
    SELECT DISTINCT CAST(SUBSTRING(c.tconst, 3, 12) AS INT), CAST(SUBSTRING(s.value, 3, 12) AS INT),
           r.rol_id, NULL, NULL, 'crew'
    FROM stg.title_crew AS c
    CROSS APPLY (SELECT 'director' AS categoria, d.value FROM STRING_SPLIT(c.directors, ',') AS d
                 UNION ALL
                 SELECT 'writer', w.value FROM STRING_SPLIT(c.writers, ',') AS w) AS s
    JOIN dw.rol AS r ON r.categoria = s.categoria
    WHERE s.value <> '\N'
      AND EXISTS (SELECT 1 FROM dw.persona AS p WHERE p.persona_id = CAST(SUBSTRING(s.value, 3, 12) AS INT))
      AND NOT EXISTS (SELECT 1 FROM dw.participacion AS x
                      WHERE x.pelicula_id = CAST(SUBSTRING(c.tconst, 3, 12) AS INT)
                        AND x.persona_id = CAST(SUBSTRING(s.value, 3, 12) AS INT)
                        AND x.rol_id = r.rol_id);
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('dw.participacion (crew)', @@ROWCOUNT, @t, SYSDATETIME());

    /* ---------- Títulos alternativos ---------- */
    SET @t = SYSDATETIME();
    INSERT INTO dw.titulo_alternativo (pelicula_id, orden, titulo, region, idioma, tipos)
    SELECT CAST(SUBSTRING(a.titleId, 3, 12) AS INT), CAST(a.ordering AS SMALLINT), a.title,
           NULLIF(a.region, '\N'), NULLIF(a.language, '\N'), NULLIF(a.types, '\N')
    FROM stg.title_akas AS a
    WHERE a.title <> '\N';
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('dw.titulo_alternativo', @@ROWCOUNT, @t, SYSDATETIME());

    DECLARE @np INT = (SELECT COUNT(*) FROM dw.pelicula), @npe INT = (SELECT COUNT(*) FROM dw.persona),
            @npa INT = (SELECT COUNT(*) FROM dw.participacion);
    PRINT CONCAT(N'Modelo relacional: ', FORMAT(@np, 'N0'), N' películas, ', FORMAT(@npe, 'N0'),
                 N' personas, ', FORMAT(@npa, 'N0'), N' participaciones.');
END;
GO

PRINT N'Modelo relacional creado.';
GO
