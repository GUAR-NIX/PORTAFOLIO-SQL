/* =====================================================================
   06_consultas_grafo.sql
   Consultas de grafo con MATCH y SHORTEST_PATH.

     grafo.fn_buscar_persona        nombre -> persona_id (la de más películas si hay homónimos)
     grafo.sp_colaboradores         colaboradores directos de una persona (MATCH)
     grafo.sp_grados_separacion     camino más corto entre dos personas (SHORTEST_PATH),
                                    con la película que une cada salto
     etl.sp_calcular_grafo          materializa en mart:
        mart.numero_bacon           grados de separación de TODOS con Kevin Bacon
        mart.top_colaboradores      actores con más colaboradores distintos
        mart.elenco_fiel            director + actor en 3 o más películas
        mart.nucleo_talento         componentes conexas de la red de lazos fuertes
        mart.ejemplo_separacion     ejemplos de grados de separación entre estrellas
   ===================================================================== */
USE ImdbGrafos;
GO

CREATE OR ALTER FUNCTION grafo.fn_buscar_persona (@nombre VARCHAR(400))
RETURNS INT
AS
BEGIN
    RETURN (SELECT TOP (1) persona_id FROM grafo.Persona
            WHERE nombre = @nombre ORDER BY peliculas DESC, persona_id);
END;
GO

/* ---------- Colaboradores directos con MATCH ---------- */
CREATE OR ALTER PROCEDURE grafo.sp_colaboradores
    @persona_id INT,
    @top        INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@top)
           p2.persona_id, p2.nombre, t.peliculas_en_comun, t.primer_anio, t.ultimo_anio,
           IIF(p2.es_director = 1 AND p2.es_actor = 0, 'director', 'actuación') AS tipo
    FROM grafo.Persona AS p1, grafo.TrabajoCon AS t, grafo.Persona AS p2
    WHERE MATCH(p1-(t)->p2)
      AND p1.persona_id = @persona_id
    ORDER BY t.peliculas_en_comun DESC, p2.peliculas DESC;
END;
GO

/* Película que une dos personas (la más votada). La película común puede venir
   de actuación o de dirección: se busca en dw.participacion. */
CREATE OR ALTER FUNCTION grafo.fn_pelicula_comun (@a INT, @b INT)
RETURNS TABLE
AS
RETURN
    SELECT TOP (1) p.titulo, p.anio, c.votos
    FROM dw.participacion AS x
    JOIN dw.participacion AS y ON y.pelicula_id = x.pelicula_id AND y.persona_id = @b
    JOIN dw.rol AS rx ON rx.rol_id = x.rol_id AND rx.grupo IN ('Actuación', 'Dirección')
    JOIN dw.rol AS ry ON ry.rol_id = y.rol_id AND ry.grupo IN ('Actuación', 'Dirección')
    JOIN dw.pelicula AS p ON p.pelicula_id = x.pelicula_id
    JOIN dw.calificacion AS c ON c.pelicula_id = p.pelicula_id
    WHERE x.persona_id = @a
    ORDER BY c.votos DESC;
GO

/* ---------- Grados de separación con SHORTEST_PATH ----------
   SHORTEST_PATH calcula (en anchura) el camino más corto desde @origen hacia
   todos los nodos alcanzables en hasta @max_saltos; luego se filtra el destino.
   El número de saltos va como literal en el patrón {1,n}: por eso SQL dinámico. */
CREATE OR ALTER PROCEDURE grafo.sp_grados_separacion
    @origen      INT,
    @destino     INT,
    @max_saltos  TINYINT = 6
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @camino VARCHAR(4000), @saltos INT;
    DECLARE @sql NVARCHAR(MAX) = N'
        SELECT TOP (1) @camino = q.ids, @saltos = q.saltos
        FROM (
            SELECT STRING_AGG(CAST(p2.persona_id AS VARCHAR(12)), ''>'') WITHIN GROUP (GRAPH PATH) AS ids,
                   LAST_VALUE(p2.persona_id) WITHIN GROUP (GRAPH PATH) AS destino,
                   COUNT(p2.persona_id) WITHIN GROUP (GRAPH PATH) AS saltos
            FROM grafo.Persona AS p1, grafo.TrabajoCon FOR PATH AS t, grafo.Persona FOR PATH AS p2
            WHERE MATCH(SHORTEST_PATH(p1(-(t)->p2){1,' + CAST(@max_saltos AS NVARCHAR(3)) + N'}))
              AND p1.persona_id = @origen
        ) AS q
        WHERE q.destino = @destino;';
    EXEC sys.sp_executesql @sql, N'@origen INT, @destino INT, @camino VARCHAR(4000) OUTPUT, @saltos INT OUTPUT',
         @origen = @origen, @destino = @destino, @camino = @camino OUTPUT, @saltos = @saltos OUTPUT;

    /* Desarmar el camino en saltos y buscar la película (la más votada) que une cada par */
    WITH nodos AS (
        SELECT 0 AS pos, @origen AS persona_id
        UNION ALL
        SELECT CAST(s.ordinal AS INT), CAST(s.value AS INT)
        FROM STRING_SPLIT(@camino, '>', 1) AS s
    ), saltos AS (
        SELECT a.pos + 1 AS salto, a.persona_id AS desde, b.persona_id AS hacia
        FROM nodos AS a JOIN nodos AS b ON b.pos = a.pos + 1
    )
    SELECT s.salto, @saltos AS grados, s.desde AS desde_id, pa.nombre AS desde,
           s.hacia AS hacia_id, pb.nombre AS hacia, pel.titulo AS pelicula, pel.anio
    FROM saltos AS s
    JOIN grafo.Persona AS pa ON pa.persona_id = s.desde
    JOIN grafo.Persona AS pb ON pb.persona_id = s.hacia
    CROSS APPLY grafo.fn_pelicula_comun(s.desde, s.hacia) AS pel
    ORDER BY s.salto;
END;
GO

/* ---------- Materialización de los resultados de grafo ---------- */
DROP TABLE IF EXISTS mart.numero_bacon, mart.top_colaboradores, mart.elenco_fiel,
                     mart.nucleo_talento, mart.ejemplo_separacion;
CREATE TABLE mart.numero_bacon (
    persona_id  INT            NOT NULL CONSTRAINT PK_numero_bacon PRIMARY KEY,
    grados      TINYINT        NOT NULL,
    camino      VARCHAR(4000)  NOT NULL      -- nombres separados por " > "
);
CREATE TABLE mart.top_colaboradores (
    posicion                   SMALLINT      NOT NULL CONSTRAINT PK_top_colaboradores PRIMARY KEY,
    persona_id                 INT           NOT NULL,
    nombre                     VARCHAR(400)  NOT NULL,
    peliculas                  SMALLINT      NOT NULL,
    colaboradores_distintos    INT           NOT NULL,
    colaboraciones_repetidas   INT           NOT NULL   -- colaboradores con 2+ películas juntos
);
CREATE TABLE mart.elenco_fiel (
    director_id      INT            NOT NULL,
    director         VARCHAR(400)   NOT NULL,
    actor_id         INT            NOT NULL,
    actor            VARCHAR(400)   NOT NULL,
    peliculas        SMALLINT       NOT NULL,
    primera          SMALLINT       NULL,
    ultima           SMALLINT       NULL,
    titulos          VARCHAR(4000)  NOT NULL,
    CONSTRAINT PK_elenco_fiel PRIMARY KEY (director_id, actor_id)
);
CREATE TABLE mart.nucleo_talento (
    persona_id  INT  NOT NULL CONSTRAINT PK_nucleo_talento PRIMARY KEY,
    nucleo_id   INT  NOT NULL      -- menor persona_id del componente
);
CREATE TABLE mart.ejemplo_separacion (
    ejemplo     TINYINT        NOT NULL,
    salto       TINYINT        NOT NULL,
    grados      TINYINT        NOT NULL,
    desde_id    INT            NOT NULL,
    desde       VARCHAR(400)   NOT NULL,
    hacia_id    INT            NOT NULL,
    hacia       VARCHAR(400)   NOT NULL,
    pelicula    VARCHAR(1000)  NULL,
    anio        SMALLINT       NULL,
    CONSTRAINT PK_ejemplo_separacion PRIMARY KEY (ejemplo, salto)
);
GO

CREATE OR ALTER PROCEDURE etl.sp_calcular_grafo
    @min_peliculas_lazo_fuerte TINYINT = 3
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @t DATETIME2(3), @bacon INT = 102;   -- nm0000102 = Kevin Bacon

    /* 1. Número de Bacon de toda la red (un solo SHORTEST_PATH desde Kevin Bacon) */
    SET @t = SYSDATETIME();
    TRUNCATE TABLE mart.numero_bacon;
    INSERT INTO mart.numero_bacon (persona_id, grados, camino)
    SELECT q.destino, q.grados, q.camino
    FROM (
        SELECT LAST_VALUE(p2.persona_id) WITHIN GROUP (GRAPH PATH) AS destino,
               COUNT(p2.persona_id) WITHIN GROUP (GRAPH PATH) AS grados,
               CAST(p1.nombre + ' > ' + STRING_AGG(p2.nombre, ' > ') WITHIN GROUP (GRAPH PATH) AS VARCHAR(4000)) AS camino
        FROM grafo.Persona AS p1, grafo.TrabajoCon FOR PATH AS t, grafo.Persona FOR PATH AS p2
        WHERE MATCH(SHORTEST_PATH(p1(-(t)->p2)+))
          AND p1.persona_id = @bacon
    ) AS q
    WHERE q.destino <> @bacon;          -- SHORTEST_PATH también devuelve el ciclo de vuelta al origen
    DECLARE @alcanzados INT = @@ROWCOUNT;
    INSERT INTO mart.numero_bacon (persona_id, grados, camino)
    SELECT persona_id, 0, nombre FROM grafo.Persona WHERE persona_id = @bacon;
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('mart.numero_bacon (SHORTEST_PATH)', @alcanzados, @t, SYSDATETIME());

    /* 2. Actores con más colaboradores distintos (grado del nodo con MATCH) */
    SET @t = SYSDATETIME();
    TRUNCATE TABLE mart.top_colaboradores;
    INSERT INTO mart.top_colaboradores
    SELECT TOP (100)
           ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, p1.persona_id),
           p1.persona_id, p1.nombre, p1.peliculas, COUNT(*), SUM(IIF(t.peliculas_en_comun >= 2, 1, 0))
    FROM grafo.Persona AS p1, grafo.TrabajoCon AS t, grafo.Persona AS p2
    WHERE MATCH(p1-(t)->p2) AND p1.es_actor = 1
    GROUP BY p1.persona_id, p1.nombre, p1.peliculas
    ORDER BY COUNT(*) DESC, p1.persona_id;
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('mart.top_colaboradores (MATCH)', @@ROWCOUNT, @t, SYSDATETIME());

    /* 3. Directores con elenco fiel: director -> película <- actor, 3+ veces */
    SET @t = SYSDATETIME();
    TRUNCATE TABLE mart.elenco_fiel;
    INSERT INTO mart.elenco_fiel
    SELECT d.persona_id, d.nombre, a.persona_id, a.nombre, COUNT(*), MIN(m.anio), MAX(m.anio),
           LEFT(STRING_AGG(CAST(CONCAT(m.titulo, ' (', m.anio, ')') AS VARCHAR(MAX)), '; ')
                WITHIN GROUP (ORDER BY m.anio), 4000)
    FROM grafo.Persona AS d, grafo.Dirigio AS dg, grafo.Pelicula AS m, grafo.ActuoEn AS ae, grafo.Persona AS a
    WHERE MATCH(d-(dg)->m<-(ae)-a)
      AND a.persona_id <> d.persona_id
    GROUP BY d.persona_id, d.nombre, a.persona_id, a.nombre
    HAVING COUNT(*) >= 3;
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('mart.elenco_fiel (MATCH)', @@ROWCOUNT, @t, SYSDATETIME());

    /* 4. Núcleos de talento: componentes conexas de la red de lazos fuertes
          (pares con @min_peliculas_lazo_fuerte o más películas juntos).
          Propagación de etiquetas: cada nodo adopta la menor etiqueta de sus
          vecinos hasta que nada cambia. */
    SET @t = SYSDATETIME();
    SELECT a.persona_id AS desde, b.persona_id AS hacia
    INTO #lazo
    FROM grafo.Persona AS a, grafo.TrabajoCon AS t, grafo.Persona AS b
    WHERE MATCH(a-(t)->b) AND t.peliculas_en_comun >= @min_peliculas_lazo_fuerte;
    CREATE CLUSTERED INDEX CX_lazo ON #lazo (desde);

    SELECT DISTINCT desde AS persona_id, desde AS etiqueta INTO #et FROM #lazo;
    CREATE UNIQUE CLUSTERED INDEX CX_et ON #et (persona_id);

    DECLARE @cambios INT = 1, @vueltas INT = 0;
    WHILE @cambios > 0
    BEGIN
        UPDATE e SET etiqueta = v.minima
        FROM #et AS e
        JOIN (SELECT l.desde, MIN(n.etiqueta) AS minima
              FROM #lazo AS l JOIN #et AS n ON n.persona_id = l.hacia
              GROUP BY l.desde) AS v ON v.desde = e.persona_id
        WHERE v.minima < e.etiqueta;
        SET @cambios = @@ROWCOUNT;
        SET @vueltas += 1;
    END;
    TRUNCATE TABLE mart.nucleo_talento;
    INSERT INTO mart.nucleo_talento (persona_id, nucleo_id) SELECT persona_id, etiqueta FROM #et;
    INSERT INTO qa.bitacora (paso, filas, inicio, fin)
    VALUES (CONCAT('mart.nucleo_talento (', @vueltas, ' vueltas)'), @@ROWCOUNT, @t, SYSDATETIME());

    /* 5. Ejemplos de grados de separación entre estrellas (nombres fijos) */
    SET @t = SYSDATETIME();
    TRUNCATE TABLE mart.ejemplo_separacion;
    DECLARE @pares TABLE (ejemplo TINYINT, origen VARCHAR(400), destino VARCHAR(400));
    INSERT INTO @pares VALUES
        (1, 'Kevin Bacon', 'Tom Hanks'),
        (2, 'Kevin Bacon', 'Shah Rukh Khan'),
        (3, 'Ricardo Darín', 'Toshirô Mifune'),
        (4, 'Penélope Cruz', 'Bruce Lee'),
        (5, 'Charles Chaplin', 'Zendaya'),
        (6, 'Cantinflas', 'Keanu Reeves');
    DECLARE @e TINYINT = 0, @o INT, @d INT;
    DECLARE @r TABLE (salto INT, grados INT, desde_id INT, desde VARCHAR(400), hacia_id INT,
                      hacia VARCHAR(400), pelicula VARCHAR(1000), anio SMALLINT);
    WHILE 1 = 1
    BEGIN
        SELECT TOP (1) @e = ejemplo, @o = grafo.fn_buscar_persona(origen), @d = grafo.fn_buscar_persona(destino)
        FROM @pares WHERE ejemplo > @e ORDER BY ejemplo;
        IF @@ROWCOUNT = 0 BREAK;
        IF @o IS NULL OR @d IS NULL CONTINUE;
        DELETE FROM @r;
        INSERT INTO @r EXEC grafo.sp_grados_separacion @origen = @o, @destino = @d;
        INSERT INTO mart.ejemplo_separacion
        SELECT @e, salto, grados, desde_id, desde, hacia_id, hacia, pelicula, anio FROM @r;
    END;
    INSERT INTO qa.bitacora (paso, filas, inicio, fin) VALUES ('mart.ejemplo_separacion', NULL, @t, SYSDATETIME());
END;
GO

PRINT N'Consultas de grafo creadas.';
GO
