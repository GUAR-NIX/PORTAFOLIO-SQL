/* =====================================================================
   08_analisis_ventanas.sql
   Análisis de catálogo con funciones de ventana.

     mart.pelicula_puntaje        calificación ponderada (bayesiana) de cada película
     mart.mejor_decada_genero     top 3 por década y género (ROW_NUMBER)
     mart.genero_decada           evolución de la calificación por género
                                  (AVG, media móvil de 3 décadas, LAG, RANK)
     mart.actor_prolifico_decada  actores con más películas por década (DENSE_RANK)
     mart.percentil_votos         percentiles de votos por década (PERCENTILE_CONT)
     mart.decil_votos             deciles de popularidad y su calificación (NTILE)

   Calificación ponderada (la fórmula del Top 250 de IMDb):
       WR = v/(v+m)·R + m/(v+m)·C
   R = calificación, v = votos, C = media de todo el catálogo filtrado y
   m = mediana de votos. Una película de 9,5 con 1.200 votos no le gana a una
   de 9,0 con 2 millones.

   Uso:  EXEC etl.sp_calcular_analitica;
   ===================================================================== */
USE ImdbGrafos;
GO

DROP TABLE IF EXISTS mart.pelicula_puntaje, mart.mejor_decada_genero, mart.genero_decada,
                     mart.actor_prolifico_decada, mart.percentil_votos, mart.decil_votos;
CREATE TABLE mart.pelicula_puntaje (
    pelicula_id          INT           NOT NULL CONSTRAINT PK_pelicula_puntaje PRIMARY KEY,
    calificacion_ponderada DECIMAL(5,3) NOT NULL
);
CREATE TABLE mart.mejor_decada_genero (
    decada        SMALLINT       NOT NULL,
    genero        VARCHAR(40)    NOT NULL,
    puesto        TINYINT        NOT NULL,
    pelicula_id   INT            NOT NULL,
    titulo        VARCHAR(1000)  NOT NULL,
    anio          SMALLINT       NOT NULL,
    calificacion  DECIMAL(3,1)   NOT NULL,
    votos         INT            NOT NULL,
    calificacion_ponderada DECIMAL(5,3) NOT NULL,
    CONSTRAINT PK_mejor_decada_genero PRIMARY KEY (decada, genero, puesto)
);
CREATE TABLE mart.genero_decada (
    genero                VARCHAR(40)   NOT NULL,
    decada                SMALLINT      NOT NULL,
    peliculas             INT           NOT NULL,
    calificacion_media    DECIMAL(4,2)  NOT NULL,
    media_movil_3         DECIMAL(4,2)  NOT NULL,   -- esta década y las 2 anteriores
    cambio_vs_anterior    DECIMAL(4,2)  NULL,       -- LAG
    puesto_en_decada      TINYINT       NOT NULL,   -- RANK del género dentro de la década
    votos_totales         BIGINT        NOT NULL,
    CONSTRAINT PK_genero_decada PRIMARY KEY (genero, decada)
);
CREATE TABLE mart.actor_prolifico_decada (
    decada        SMALLINT      NOT NULL,
    puesto        TINYINT       NOT NULL,
    persona_id    INT           NOT NULL,
    nombre        VARCHAR(400)  NOT NULL,
    peliculas     SMALLINT      NOT NULL,
    calificacion_media DECIMAL(4,2) NOT NULL,
    CONSTRAINT PK_actor_prolifico_decada PRIMARY KEY (decada, persona_id)
);
CREATE TABLE mart.percentil_votos (
    decada    SMALLINT  NOT NULL CONSTRAINT PK_percentil_votos PRIMARY KEY,   -- 0 = todo el catálogo
    peliculas INT       NOT NULL,
    p25       INT       NOT NULL,
    p50       INT       NOT NULL,
    p75       INT       NOT NULL,
    p90       INT       NOT NULL,
    p99       INT       NOT NULL,
    maximo    INT       NOT NULL
);
CREATE TABLE mart.decil_votos (
    decil               TINYINT       NOT NULL CONSTRAINT PK_decil_votos PRIMARY KEY,
    peliculas           INT           NOT NULL,
    votos_min           INT           NOT NULL,
    votos_max           INT           NOT NULL,
    calificacion_media  DECIMAL(4,2)  NOT NULL,
    participacion_votos DECIMAL(5,2)  NOT NULL     -- % de todos los votos
);
GO

CREATE OR ALTER PROCEDURE etl.sp_calcular_analitica
    @min_peliculas_genero_decada INT = 20     -- celdas con menos películas no se reportan
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @t DATETIME2(3) = SYSDATETIME();

    /* 1. Calificación ponderada */
    DECLARE @C FLOAT, @m FLOAT;
    SELECT @C = AVG(CAST(calificacion AS FLOAT)) FROM dw.calificacion;
    SELECT DISTINCT @m = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY votos) OVER () FROM dw.calificacion;

    TRUNCATE TABLE mart.pelicula_puntaje;
    INSERT INTO mart.pelicula_puntaje
    SELECT pelicula_id, CAST(votos / (votos + @m) * calificacion + @m / (votos + @m) * @C AS DECIMAL(5,3))
    FROM dw.calificacion;

    /* 2. Mejores películas por década y género */
    TRUNCATE TABLE mart.mejor_decada_genero;
    INSERT INTO mart.mejor_decada_genero
    SELECT decada, genero, puesto, pelicula_id, titulo, anio, calificacion, votos, calificacion_ponderada
    FROM (
        SELECT p.decada, g.nombre AS genero, p.pelicula_id, p.titulo, p.anio, c.calificacion, c.votos,
               s.calificacion_ponderada,
               ROW_NUMBER() OVER (PARTITION BY p.decada, g.genero_id
                                  ORDER BY s.calificacion_ponderada DESC, c.votos DESC) AS puesto,
               COUNT(*) OVER (PARTITION BY p.decada, g.genero_id) AS en_celda
        FROM dw.pelicula AS p
        JOIN dw.calificacion AS c ON c.pelicula_id = p.pelicula_id
        JOIN mart.pelicula_puntaje AS s ON s.pelicula_id = p.pelicula_id
        JOIN dw.pelicula_genero AS pg ON pg.pelicula_id = p.pelicula_id
        JOIN dw.genero AS g ON g.genero_id = pg.genero_id
        WHERE p.anio IS NOT NULL
    ) AS x
    WHERE puesto <= 3 AND en_celda >= @min_peliculas_genero_decada;

    /* 3. Evolución de la calificación por género */
    TRUNCATE TABLE mart.genero_decada;
    WITH base AS (
        SELECT g.nombre AS genero, p.decada, COUNT(*) AS peliculas,
               AVG(CAST(c.calificacion AS DECIMAL(6,3))) AS media, SUM(CAST(c.votos AS BIGINT)) AS votos
        FROM dw.pelicula AS p
        JOIN dw.calificacion AS c ON c.pelicula_id = p.pelicula_id
        JOIN dw.pelicula_genero AS pg ON pg.pelicula_id = p.pelicula_id
        JOIN dw.genero AS g ON g.genero_id = pg.genero_id
        WHERE p.anio IS NOT NULL
        GROUP BY g.nombre, p.decada
        HAVING COUNT(*) >= @min_peliculas_genero_decada
    )
    INSERT INTO mart.genero_decada
    SELECT genero, decada, peliculas, media,
           AVG(media) OVER (PARTITION BY genero ORDER BY decada ROWS BETWEEN 2 PRECEDING AND CURRENT ROW),
           media - LAG(media) OVER (PARTITION BY genero ORDER BY decada),
           RANK() OVER (PARTITION BY decada ORDER BY media DESC),
           votos
    FROM base;

    /* 4. Actores más prolíficos por década (top 5, con empates) */
    TRUNCATE TABLE mart.actor_prolifico_decada;
    WITH por_decada AS (
        SELECT p.decada, pe.persona_id, pe.nombre, COUNT(DISTINCT pa.pelicula_id) AS peliculas,
               AVG(CAST(c.calificacion AS DECIMAL(6,3))) AS media
        FROM dw.participacion AS pa
        JOIN dw.rol AS r ON r.rol_id = pa.rol_id AND r.grupo = 'Actuación'
        JOIN dw.pelicula AS p ON p.pelicula_id = pa.pelicula_id
        JOIN dw.calificacion AS c ON c.pelicula_id = p.pelicula_id
        JOIN dw.persona AS pe ON pe.persona_id = pa.persona_id
        WHERE p.anio IS NOT NULL
        GROUP BY p.decada, pe.persona_id, pe.nombre
    ), ranking AS (
        SELECT *, DENSE_RANK() OVER (PARTITION BY decada ORDER BY peliculas DESC) AS puesto
        FROM por_decada
    )
    INSERT INTO mart.actor_prolifico_decada
    SELECT decada, puesto, persona_id, nombre, peliculas, media FROM ranking
    WHERE puesto <= 5 AND peliculas >= 3;          -- décadas casi vacías (1900) no tienen ranking útil

    /* 5. Percentiles de votos: todo el catálogo (decada = 0) y por década */
    TRUNCATE TABLE mart.percentil_votos;
    WITH v AS (
        SELECT p.decada, c.votos FROM dw.pelicula AS p JOIN dw.calificacion AS c ON c.pelicula_id = p.pelicula_id
        WHERE p.anio IS NOT NULL
    ), todos AS (
        SELECT 0 AS decada, votos FROM v UNION ALL SELECT decada, votos FROM v
    )
    INSERT INTO mart.percentil_votos
    SELECT DISTINCT decada,
           COUNT(*) OVER (PARTITION BY decada),
           PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY votos) OVER (PARTITION BY decada),
           PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY votos) OVER (PARTITION BY decada),
           PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY votos) OVER (PARTITION BY decada),
           PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY votos) OVER (PARTITION BY decada),
           PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY votos) OVER (PARTITION BY decada),
           MAX(votos) OVER (PARTITION BY decada)
    FROM todos;

    /* 6. Deciles de popularidad: ¿las películas más votadas están mejor calificadas? */
    TRUNCATE TABLE mart.decil_votos;
    DECLARE @votos_totales FLOAT = (SELECT SUM(CAST(votos AS BIGINT)) FROM dw.calificacion);
    INSERT INTO mart.decil_votos
    SELECT decil, COUNT(*), MIN(votos), MAX(votos), AVG(CAST(calificacion AS DECIMAL(6,3))),
           CAST(100.0 * SUM(CAST(votos AS BIGINT)) / @votos_totales AS DECIMAL(5,2))
    FROM (SELECT votos, calificacion, NTILE(10) OVER (ORDER BY votos) AS decil FROM dw.calificacion) AS d
    GROUP BY decil;

    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('mart analítica con ventanas', NULL, @t, SYSDATETIME());
END;
GO

PRINT N'Análisis con ventanas creado.';
GO
