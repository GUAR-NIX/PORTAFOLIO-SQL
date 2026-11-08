/* =====================================================================
   02_staging.sql
   Tablas de staging (texto, mismo orden de columnas que los TSV), parámetros
   del filtro y tablas de auditoría.

   Las tablas se crean solo si no existen: volver a ejecutar este script no
   borra una carga ya hecha (etl.sp_cargar_staging @reanudar = 1 la reutiliza).

   Los TSV de IMDb usan \N como nulo: en staging se guarda tal cual ('\N') y
   se convierte a NULL al pasar al modelo (NULLIF(col, '\N')).
   ===================================================================== */
USE ImdbGrafos;
GO

/* ---------- Parámetros del filtro (datos, no código) ---------- */
IF OBJECT_ID(N'etl.parametro', N'U') IS NULL
CREATE TABLE etl.parametro (
    nombre       VARCHAR(40)   NOT NULL CONSTRAINT PK_parametro PRIMARY KEY,
    valor        VARCHAR(100)  NOT NULL,
    descripcion  VARCHAR(400)  NOT NULL
);
GO
MERGE etl.parametro AS d
USING (VALUES
    ('tipo_titulo',  'movie', 'Solo películas (titleType). Se excluyen series, episodios, cortos y videojuegos'),
    ('min_votos',    '1000',  'Mínimo de votos en title.ratings. Mantiene la base pequeña y deja títulos con calificación estable'),
    ('excluir_adultos', '1',  '1 = se excluyen los títulos con isAdult = 1 (no forman parte del catálogo de la plataforma)')
) AS o (nombre, valor, descripcion)
ON d.nombre = o.nombre
WHEN NOT MATCHED THEN INSERT (nombre, valor, descripcion) VALUES (o.nombre, o.valor, o.descripcion);
GO

/* ---------- Staging: cargas completas (BULK INSERT) ---------- */
IF OBJECT_ID(N'stg.title_basics', N'U') IS NULL
CREATE TABLE stg.title_basics (
    tconst          VARCHAR(12)    NOT NULL,
    titleType       VARCHAR(20)    NULL,
    primaryTitle    VARCHAR(1000)  NULL,
    originalTitle   VARCHAR(1000)  NULL,
    isAdult         VARCHAR(4)     NULL,
    startYear       VARCHAR(4)     NULL,
    endYear         VARCHAR(4)     NULL,
    runtimeMinutes  VARCHAR(10)    NULL,
    genres          VARCHAR(100)   NULL
);

IF OBJECT_ID(N'stg.title_ratings', N'U') IS NULL
CREATE TABLE stg.title_ratings (
    tconst          VARCHAR(12)    NOT NULL,
    averageRating   VARCHAR(5)     NULL,
    numVotes        VARCHAR(10)    NULL
);

/* Películas que pasan el filtro: se calcula tras cargar basics + ratings */
IF OBJECT_ID(N'stg.pelicula_filtro', N'U') IS NULL
CREATE TABLE stg.pelicula_filtro (
    tconst VARCHAR(12) NOT NULL CONSTRAINT PK_stg_pelicula_filtro PRIMARY KEY
);

/* ---------- Staging: cargas filtradas (OPENROWSET BULK + WHERE) ---------- */
IF OBJECT_ID(N'stg.title_principals', N'U') IS NULL
CREATE TABLE stg.title_principals (
    tconst      VARCHAR(12)    NOT NULL,
    ordering    VARCHAR(5)     NULL,
    nconst      VARCHAR(12)    NOT NULL,
    category    VARCHAR(40)    NULL,
    job         VARCHAR(1000)  NULL,
    characters  VARCHAR(2000)  NULL
);

IF OBJECT_ID(N'stg.title_crew', N'U') IS NULL
CREATE TABLE stg.title_crew (
    tconst      VARCHAR(12)    NOT NULL,
    directors   VARCHAR(MAX)   NULL,
    writers     VARCHAR(MAX)   NULL
);

/* title.crew no se puede leer con OPENROWSET: hay 4 series de TV con más de 8.000
   bytes de guionistas y el format file no pasa de VARCHAR(8000). Se carga completo
   con BULK INSERT (que sí llena VARCHAR(MAX)) en esta tabla de paso y se filtra. */
IF OBJECT_ID(N'stg.title_crew_completo', N'U') IS NULL
CREATE TABLE stg.title_crew_completo (
    tconst      VARCHAR(12)    NOT NULL,
    directors   VARCHAR(MAX)   NULL,
    writers     VARCHAR(MAX)   NULL
);

IF OBJECT_ID(N'stg.title_akas', N'U') IS NULL
CREATE TABLE stg.title_akas (
    titleId          VARCHAR(12)    NOT NULL,
    ordering         VARCHAR(5)     NULL,
    title            VARCHAR(1000)  NULL,
    region           VARCHAR(10)    NULL,
    language         VARCHAR(10)    NULL,
    types            VARCHAR(100)   NULL,
    attributes       VARCHAR(400)   NULL,
    isOriginalTitle  VARCHAR(4)     NULL
);

/* Personas que aparecen en alguna película filtrada (principals o crew) */
IF OBJECT_ID(N'stg.persona_filtro', N'U') IS NULL
CREATE TABLE stg.persona_filtro (
    nconst VARCHAR(12) NOT NULL CONSTRAINT PK_stg_persona_filtro PRIMARY KEY
);

IF OBJECT_ID(N'stg.name_basics', N'U') IS NULL
CREATE TABLE stg.name_basics (
    nconst             VARCHAR(12)    NOT NULL,
    primaryName        VARCHAR(400)   NULL,
    birthYear          VARCHAR(4)     NULL,
    deathYear          VARCHAR(4)     NULL,
    primaryProfession  VARCHAR(200)   NULL,
    knownForTitles     VARCHAR(200)   NULL
);
GO

/* ---------- Auditoría ---------- */
-- Cifras de control de la FUENTE (filas de cada TSV contadas por descargar_datos.py)
IF OBJECT_ID(N'qa.cifra_control', N'U') IS NULL
CREATE TABLE qa.cifra_control (
    archivo        VARCHAR(40)   NOT NULL CONSTRAINT PK_cifra_control PRIMARY KEY,
    filas_fuente   BIGINT        NOT NULL,
    bytes_tsv      BIGINT        NOT NULL,
    publicado      VARCHAR(40)   NULL      -- Last-Modified del servidor de IMDb
);

-- Una fila por archivo cargado: leídas por el motor frente a cargadas en staging
IF OBJECT_ID(N'qa.auditoria_carga', N'U') IS NULL
CREATE TABLE qa.auditoria_carga (
    carga_id          INT IDENTITY(1,1) CONSTRAINT PK_auditoria_carga PRIMARY KEY,
    archivo           VARCHAR(40)    NOT NULL,
    metodo            VARCHAR(40)    NOT NULL,   -- BULK INSERT | OPENROWSET(BULK) + filtro
    filas_fuente      BIGINT         NULL,       -- contadas fuera de SQL (Python)
    filas_leidas      BIGINT         NULL,       -- filas que el motor pudo leer del TSV
    filas_cargadas    BIGINT         NULL,       -- filas que quedaron en staging
    filas_rechazadas  AS (filas_fuente - filas_leidas),      -- errores de formato
    filas_filtradas   AS (filas_leidas - filas_cargadas),    -- descartadas por el filtro
    inicio            DATETIME2(0)   NOT NULL,
    fin               DATETIME2(0)   NULL,
    segundos          AS DATEDIFF(SECOND, inicio, fin),
    detalle           VARCHAR(400)   NULL
);

-- Bitácora de los pasos posteriores (modelo, grafo, índices...)
IF OBJECT_ID(N'qa.bitacora', N'U') IS NULL
CREATE TABLE qa.bitacora (
    paso_id    INT IDENTITY(1,1) CONSTRAINT PK_bitacora PRIMARY KEY,
    paso       VARCHAR(80)    NOT NULL,
    filas      BIGINT         NULL,
    inicio     DATETIME2(3)   NOT NULL,
    fin        DATETIME2(3)   NOT NULL,
    ms         AS DATEDIFF(MILLISECOND, inicio, fin)
);
GO

PRINT N'Staging y auditoría listos.';
GO
