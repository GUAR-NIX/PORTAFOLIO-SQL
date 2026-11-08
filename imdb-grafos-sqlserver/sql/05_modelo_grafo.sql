/* =====================================================================
   05_modelo_grafo.sql
   Modelo de grafo con SQL Graph (tablas NODE y EDGE).

     NODE  grafo.Persona     actores, actrices y directores de las películas filtradas
     NODE  grafo.Pelicula    películas filtradas, con calificación y votos
     EDGE  grafo.ActuoEn     Persona -> Pelicula (orden en los créditos, personaje)
     EDGE  grafo.Dirigio     Persona -> Pelicula
     EDGE  grafo.TrabajoCon  Persona -> Persona, peso = películas en común

   TrabajoCon se construye con los pares de personas (actuación o dirección)
   que coinciden en una misma película. La relación es simétrica, pero en SQL
   Graph las aristas tienen dirección: se guarda en los DOS sentidos para que
   MATCH y SHORTEST_PATH recorran la red sin importar quién es "from" o "to".

   Las restricciones CONNECTION impiden aristas entre tipos de nodo
   equivocados y que se borre un nodo que todavía tiene aristas.

   Uso:  EXEC etl.sp_cargar_grafo;
   ===================================================================== */
USE ImdbGrafos;
GO

DROP TABLE IF EXISTS grafo.TrabajoCon, grafo.ActuoEn, grafo.Dirigio, grafo.Persona, grafo.Pelicula;
GO

CREATE TABLE grafo.Persona (
    persona_id   INT           NOT NULL CONSTRAINT PK_g_persona PRIMARY KEY,
    nombre       VARCHAR(400)  NOT NULL,
    es_actor     BIT           NOT NULL,
    es_director  BIT           NOT NULL,
    peliculas    SMALLINT      NOT NULL     -- películas filtradas en las que actuó o dirigió
) AS NODE;

CREATE TABLE grafo.Pelicula (
    pelicula_id   INT            NOT NULL CONSTRAINT PK_g_pelicula PRIMARY KEY,
    titulo        VARCHAR(1000)  NOT NULL,
    anio          SMALLINT       NULL,
    calificacion  DECIMAL(3,1)   NOT NULL,
    votos         INT            NOT NULL
) AS NODE;

CREATE TABLE grafo.ActuoEn (
    orden      TINYINT       NULL,
    personaje  VARCHAR(400)  NULL,
    CONSTRAINT EC_ActuoEn CONNECTION (grafo.Persona TO grafo.Pelicula)
) AS EDGE;

CREATE TABLE grafo.Dirigio (
    CONSTRAINT EC_Dirigio CONNECTION (grafo.Persona TO grafo.Pelicula)
) AS EDGE;

CREATE TABLE grafo.TrabajoCon (
    peliculas_en_comun  SMALLINT  NOT NULL,
    primer_anio         SMALLINT  NULL,
    ultimo_anio         SMALLINT  NULL,
    CONSTRAINT EC_TrabajoCon CONNECTION (grafo.Persona TO grafo.Persona)
) AS EDGE;
GO

/* Índices recomendados para aristas: (from, to) y (to, from) */
CREATE CLUSTERED INDEX CX_TrabajoCon ON grafo.TrabajoCon ($from_id, $to_id);
CREATE INDEX IX_ActuoEn_from ON grafo.ActuoEn ($from_id, $to_id);
CREATE INDEX IX_ActuoEn_to   ON grafo.ActuoEn ($to_id, $from_id);
CREATE INDEX IX_Dirigio_from ON grafo.Dirigio ($from_id, $to_id);
CREATE INDEX IX_Dirigio_to   ON grafo.Dirigio ($to_id, $from_id);
CREATE INDEX IX_Persona_nombre ON grafo.Persona (nombre) INCLUDE (es_actor, peliculas);
GO

CREATE OR ALTER PROCEDURE etl.sp_cargar_grafo
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @t DATETIME2(3);

    -- Orden: primero aristas (las CONNECTION impiden borrar nodos con aristas)
    TRUNCATE TABLE grafo.TrabajoCon; TRUNCATE TABLE grafo.ActuoEn; TRUNCATE TABLE grafo.Dirigio;
    DELETE FROM grafo.Persona; DELETE FROM grafo.Pelicula;

    /* Participaciones que forman la red: actuación y dirección (1 fila por persona y película) */
    SELECT pa.pelicula_id, pa.persona_id,
           MAX(IIF(r.grupo = 'Actuación', 1, 0)) AS actuo,
           MAX(IIF(r.grupo = 'Dirección', 1, 0)) AS dirigio
    INTO #red
    FROM dw.participacion AS pa
    JOIN dw.rol AS r ON r.rol_id = pa.rol_id
    WHERE r.grupo IN ('Actuación', 'Dirección')
    GROUP BY pa.pelicula_id, pa.persona_id;
    CREATE UNIQUE CLUSTERED INDEX CX_red ON #red (pelicula_id, persona_id);

    /* ---------- Nodos ---------- */
    SET @t = SYSDATETIME();
    INSERT INTO grafo.Pelicula (pelicula_id, titulo, anio, calificacion, votos)
    SELECT p.pelicula_id, p.titulo, p.anio, c.calificacion, c.votos
    FROM dw.pelicula AS p JOIN dw.calificacion AS c ON c.pelicula_id = p.pelicula_id;
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('grafo.Pelicula (NODE)', @@ROWCOUNT, @t, SYSDATETIME());

    SET @t = SYSDATETIME();
    INSERT INTO grafo.Persona (persona_id, nombre, es_actor, es_director, peliculas)
    SELECT pe.persona_id, pe.nombre, MAX(r.actuo), MAX(r.dirigio), COUNT(*)
    FROM #red AS r JOIN dw.persona AS pe ON pe.persona_id = r.persona_id
    GROUP BY pe.persona_id, pe.nombre;
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('grafo.Persona (NODE)', @@ROWCOUNT, @t, SYSDATETIME());

    /* ---------- Aristas Persona -> Película ---------- */
    SET @t = SYSDATETIME();
    INSERT INTO grafo.ActuoEn ($from_id, $to_id, orden, personaje)
    SELECT gp.$node_id, gm.$node_id, x.orden, x.personaje
    FROM (SELECT pa.pelicula_id, pa.persona_id, MIN(pa.orden) AS orden, MIN(pa.personaje) AS personaje
          FROM dw.participacion AS pa JOIN dw.rol AS r ON r.rol_id = pa.rol_id
          WHERE r.grupo = 'Actuación'
          GROUP BY pa.pelicula_id, pa.persona_id) AS x       -- actor + actress de la misma persona = 1 arista
    JOIN grafo.Persona AS gp ON gp.persona_id = x.persona_id
    JOIN grafo.Pelicula AS gm ON gm.pelicula_id = x.pelicula_id;
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('grafo.ActuoEn (EDGE)', @@ROWCOUNT, @t, SYSDATETIME());

    SET @t = SYSDATETIME();
    INSERT INTO grafo.Dirigio ($from_id, $to_id)
    SELECT gp.$node_id, gm.$node_id
    FROM #red AS r
    JOIN grafo.Persona AS gp ON gp.persona_id = r.persona_id
    JOIN grafo.Pelicula AS gm ON gm.pelicula_id = r.pelicula_id
    WHERE r.dirigio = 1;
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('grafo.Dirigio (EDGE)', @@ROWCOUNT, @t, SYSDATETIME());

    /* ---------- TrabajoCon: pares que coinciden en una película ---------- */
    SET @t = SYSDATETIME();
    SELECT a.persona_id AS persona_a, b.persona_id AS persona_b,
           COUNT(*) AS peliculas_en_comun, MIN(p.anio) AS primer_anio, MAX(p.anio) AS ultimo_anio
    INTO #pares
    FROM #red AS a
    JOIN #red AS b ON b.pelicula_id = a.pelicula_id AND b.persona_id > a.persona_id   -- cada par una sola vez
    JOIN dw.pelicula AS p ON p.pelicula_id = a.pelicula_id
    GROUP BY a.persona_id, b.persona_id;
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('pares distintos de colaboradores', @@ROWCOUNT, @t, SYSDATETIME());

    SET @t = SYSDATETIME();
    INSERT INTO grafo.TrabajoCon WITH (TABLOCK) ($from_id, $to_id, peliculas_en_comun, primer_anio, ultimo_anio)
    SELECT ga.$node_id, gb.$node_id, x.peliculas_en_comun, x.primer_anio, x.ultimo_anio
    FROM (SELECT persona_a AS desde, persona_b AS hacia, peliculas_en_comun, primer_anio, ultimo_anio FROM #pares
          UNION ALL
          SELECT persona_b, persona_a, peliculas_en_comun, primer_anio, ultimo_anio FROM #pares) AS x
    JOIN grafo.Persona AS ga ON ga.persona_id = x.desde
    JOIN grafo.Persona AS gb ON gb.persona_id = x.hacia;
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('grafo.TrabajoCon (EDGE, 2 sentidos)', @@ROWCOUNT, @t, SYSDATETIME());

    DECLARE @n1 INT = (SELECT COUNT(*) FROM grafo.Persona), @n2 INT = (SELECT COUNT(*) FROM grafo.Pelicula),
            @e1 INT = (SELECT COUNT(*) FROM grafo.ActuoEn), @e2 INT = (SELECT COUNT(*) FROM grafo.Dirigio),
            @e3 INT = (SELECT COUNT(*) FROM grafo.TrabajoCon);
    PRINT CONCAT(N'Grafo: ', FORMAT(@n1, 'N0'), N' personas, ', FORMAT(@n2, 'N0'), N' películas; aristas ActuoEn ',
                 FORMAT(@e1, 'N0'), N', Dirigio ', FORMAT(@e2, 'N0'), N', TrabajoCon ', FORMAT(@e3, 'N0'));
END;
GO

PRINT N'Modelo de grafo creado.';
GO
