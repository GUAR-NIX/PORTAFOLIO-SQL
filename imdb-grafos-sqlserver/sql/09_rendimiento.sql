/* =====================================================================
   09_rendimiento.sql
   Banco de pruebas: grafo (MATCH / SHORTEST_PATH) frente a SQL relacional
   (JOIN / CTE recursivo / BFS iterativo) y búsqueda por índice frente a LIKE.

   Para que la comparación sea justa, dw.colaboracion guarda EXACTAMENTE las
   mismas aristas que grafo.TrabajoCon, pero como tabla normal con
   PRIMARY KEY (persona_a, persona_b).

   Cada variante se ejecuta 1 vez de calentamiento + @repeticiones veces con
   la caché caliente; el resultado se asigna a variables (no viaja al cliente).
   Se guarda cada corrida en qa.medicion y la mediana en qa.v_medicion_resumen.

   Uso:  EXEC qa.sp_medir_rendimiento @repeticiones = 5;
   ===================================================================== */
USE ImdbGrafos;
GO

DROP TABLE IF EXISTS dw.colaboracion;
CREATE TABLE dw.colaboracion (
    persona_a           INT       NOT NULL,
    persona_b           INT       NOT NULL,
    peliculas_en_comun  SMALLINT  NOT NULL,
    CONSTRAINT PK_colaboracion PRIMARY KEY (persona_a, persona_b)
);

IF OBJECT_ID(N'qa.medicion', N'U') IS NULL
CREATE TABLE qa.medicion (
    medicion_id  INT IDENTITY(1,1) CONSTRAINT PK_medicion PRIMARY KEY,
    ejecucion    DATETIME2(0)   NOT NULL,
    prueba       VARCHAR(80)    NOT NULL,
    variante     VARCHAR(80)    NOT NULL,
    repeticion   TINYINT        NOT NULL,
    ms           INT            NOT NULL,
    filas        BIGINT         NULL      -- tamaño del resultado (para verificar que coinciden)
);
GO

CREATE OR ALTER VIEW qa.v_medicion_resumen
AS
WITH ultima AS (SELECT MAX(ejecucion) AS ejecucion FROM qa.medicion)
SELECT DISTINCT m.prueba, m.variante,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY m.ms) OVER (PARTITION BY m.prueba, m.variante) AS ms_mediana,
       MIN(m.ms) OVER (PARTITION BY m.prueba, m.variante) AS ms_min,
       MAX(m.ms) OVER (PARTITION BY m.prueba, m.variante) AS ms_max,
       MAX(m.filas) OVER (PARTITION BY m.prueba, m.variante) AS filas,
       COUNT(*) OVER (PARTITION BY m.prueba, m.variante) AS repeticiones
FROM qa.medicion AS m JOIN ultima AS u ON u.ejecucion = m.ejecucion;
GO

/* ---------- Grados de separación con un BFS iterativo (WHILE + visitados) ---------- */
CREATE OR ALTER PROCEDURE grafo.sp_grados_bfs
    @origen INT, @destino INT, @max_saltos TINYINT = 6, @grados INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #visitado (persona_id INT PRIMARY KEY, nivel TINYINT NOT NULL);
    INSERT INTO #visitado VALUES (@origen, 0);
    DECLARE @nivel TINYINT = 0;
    SET @grados = NULL;
    WHILE @nivel < @max_saltos AND @grados IS NULL
    BEGIN
        INSERT INTO #visitado (persona_id, nivel)
        SELECT DISTINCT c.persona_b, @nivel + 1
        FROM #visitado AS v
        JOIN dw.colaboracion AS c ON c.persona_a = v.persona_id
        WHERE v.nivel = @nivel
          AND NOT EXISTS (SELECT 1 FROM #visitado AS x WHERE x.persona_id = c.persona_b);
        IF @@ROWCOUNT = 0 BREAK;
        SET @nivel += 1;
        IF EXISTS (SELECT 1 FROM #visitado WHERE persona_id = @destino) SET @grados = @nivel;
    END;
END;
GO

CREATE OR ALTER PROCEDURE qa.sp_medir_rendimiento
    @repeticiones TINYINT = 5
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ahora DATETIME2(0) = SYSDATETIME(), @t DATETIME2(7), @n BIGINT, @r TINYINT;

    /* Copia relacional de TrabajoCon (mismas aristas, mismos dos sentidos) */
    IF NOT EXISTS (SELECT 1 FROM dw.colaboracion)
        INSERT INTO dw.colaboracion WITH (TABLOCK) (persona_a, persona_b, peliculas_en_comun)
        SELECT a.persona_id, b.persona_id, t.peliculas_en_comun
        FROM grafo.Persona AS a, grafo.TrabajoCon AS t, grafo.Persona AS b
        WHERE MATCH(a-(t)->b);

    DECLARE @bacon INT = 102,
            @destino INT = grafo.fn_buscar_persona('Shah Rukh Khan');

    /* Catálogo de variantes: (prueba, variante, SQL que deja el tamaño del resultado en @n) */
    DECLARE @v TABLE (orden INT IDENTITY, prueba VARCHAR(80), variante VARCHAR(80), consulta NVARCHAR(MAX));
    INSERT INTO @v (prueba, variante, consulta) VALUES
    /* 1. Colaboradores directos de Kevin Bacon */
    ('1. Colaboradores directos', 'MATCH sobre TrabajoCon (arista precalculada)',
     N'SELECT @n = COUNT(*) FROM grafo.Persona AS p1, grafo.TrabajoCon AS t, grafo.Persona AS p2
       WHERE MATCH(p1-(t)->p2) AND p1.persona_id = @o;'),
    ('1. Colaboradores directos', 'JOIN sobre dw.colaboracion (misma arista)',
     N'SELECT @n = COUNT(*) FROM dw.colaboracion WHERE persona_a = @o;'),
    ('1. Colaboradores directos', 'MATCH bipartito Persona->Pelicula<-Persona',
     N'SELECT @n = COUNT(DISTINCT p2.persona_id)
       FROM grafo.Persona AS p1, grafo.ActuoEn AS e1, grafo.Pelicula AS m, grafo.ActuoEn AS e2, grafo.Persona AS p2
       WHERE MATCH(p1-(e1)->m<-(e2)-p2) AND p1.persona_id = @o AND p2.persona_id <> @o;'),
    ('1. Colaboradores directos', 'JOIN relacional sobre dw.participacion',
     N'SELECT @n = COUNT(DISTINCT y.persona_id)
       FROM dw.participacion AS x JOIN dw.rol AS rx ON rx.rol_id = x.rol_id AND rx.grupo = ''Actuación''
       JOIN dw.participacion AS y ON y.pelicula_id = x.pelicula_id
       JOIN dw.rol AS ry ON ry.rol_id = y.rol_id AND ry.grupo = ''Actuación''
       WHERE x.persona_id = @o AND y.persona_id <> @o;'),
    /* 2. Red a dos saltos (colaboradores de colaboradores) */
    ('2. Red a 2 saltos', 'MATCH p1->p2->p3',
     N'SELECT @n = COUNT(DISTINCT p3.persona_id)
       FROM grafo.Persona AS p1, grafo.TrabajoCon AS t1, grafo.Persona AS p2, grafo.TrabajoCon AS t2, grafo.Persona AS p3
       WHERE MATCH(p1-(t1)->p2-(t2)->p3) AND p1.persona_id = @o AND p3.persona_id <> @o;'),
    ('2. Red a 2 saltos', 'JOIN doble sobre dw.colaboracion',
     N'SELECT @n = COUNT(DISTINCT c2.persona_b)
       FROM dw.colaboracion AS c1 JOIN dw.colaboracion AS c2 ON c2.persona_a = c1.persona_b
       WHERE c1.persona_a = @o AND c2.persona_b <> @o;'),
    ('2. Red a 2 saltos', 'CTE recursivo (profundidad 2)',
     N'WITH r AS (SELECT CAST(@o AS INT) AS persona_id, 0 AS nivel
                UNION ALL
                SELECT c.persona_b, r.nivel + 1 FROM r JOIN dw.colaboracion AS c ON c.persona_a = r.persona_id
                WHERE r.nivel < 2)
       SELECT @n = COUNT(DISTINCT persona_id) FROM r WHERE nivel = 2 AND persona_id <> @o OPTION (MAXRECURSION 10);'),
    /* 3. Grados de separación Kevin Bacon -> Shah Rukh Khan (3 grados) */
    ('3. Grados de separación (Bacon -> Shah Rukh Khan)', 'SHORTEST_PATH (hasta 6 saltos)',
     N'SELECT @n = MIN(q.saltos) FROM (
         SELECT LAST_VALUE(p2.persona_id) WITHIN GROUP (GRAPH PATH) AS destino,
                COUNT(p2.persona_id) WITHIN GROUP (GRAPH PATH) AS saltos
         FROM grafo.Persona AS p1, grafo.TrabajoCon FOR PATH AS t, grafo.Persona FOR PATH AS p2
         WHERE MATCH(SHORTEST_PATH(p1(-(t)->p2){1,6})) AND p1.persona_id = @o) AS q
       WHERE q.destino = @d;'),
    ('3. Grados de separación (Bacon -> Shah Rukh Khan)', 'BFS iterativo (WHILE + tabla de visitados)',
     N'DECLARE @g INT; EXEC grafo.sp_grados_bfs @origen = @o, @destino = @d, @grados = @g OUTPUT; SET @n = @g;'),
    ('3. Grados de separación (Bacon -> Shah Rukh Khan)', 'CTE recursivo (sin memoria de visitados, tope 3)',
     N'WITH r AS (SELECT CAST(@o AS INT) AS persona_id, 0 AS nivel
                UNION ALL
                SELECT c.persona_b, r.nivel + 1 FROM r JOIN dw.colaboracion AS c ON c.persona_a = r.persona_id
                WHERE r.nivel < 3 AND r.persona_id <> @d)
       SELECT @n = MIN(nivel) FROM r WHERE persona_id = @d OPTION (MAXRECURSION 10);'),
    /* 4. Búsqueda de texto: índice invertido frente a LIKE */
    ('4. Búsqueda "padrino"', 'Índice invertido (palabra exacta)',
     N'DECLARE @x TABLE (pelicula_id INT, titulo VARCHAR(1000), anio SMALLINT, calificacion DECIMAL(3,1), votos INT,
                        puntaje DECIMAL(9,3), texto VARCHAR(1000), total INT);
       INSERT INTO @x EXEC busqueda.sp_buscar @consulta = ''padrino'', @top = 1000000; SELECT @n = COUNT(*) FROM @x;'),
    ('4. Búsqueda "padrino"', 'LIKE ''%padrino%''',
     N'DECLARE @x TABLE (pelicula_id INT, titulo VARCHAR(1000), anio SMALLINT, calificacion DECIMAL(3,1), votos INT,
                        texto VARCHAR(1000), total INT);
       INSERT INTO @x EXEC busqueda.sp_buscar_like @texto = ''padrino'', @top = 1000000; SELECT @n = COUNT(*) FROM @x;'),
    ('5. Búsqueda "war"', 'Índice invertido (palabra exacta)',
     N'DECLARE @x TABLE (pelicula_id INT, titulo VARCHAR(1000), anio SMALLINT, calificacion DECIMAL(3,1), votos INT,
                        puntaje DECIMAL(9,3), texto VARCHAR(1000), total INT);
       INSERT INTO @x EXEC busqueda.sp_buscar @consulta = ''war'', @top = 1000000; SELECT @n = COUNT(*) FROM @x;'),
    ('5. Búsqueda "war"', 'LIKE ''%war%''',
     N'DECLARE @x TABLE (pelicula_id INT, titulo VARCHAR(1000), anio SMALLINT, calificacion DECIMAL(3,1), votos INT,
                        texto VARCHAR(1000), total INT);
       INSERT INTO @x EXEC busqueda.sp_buscar_like @texto = ''war'', @top = 1000000; SELECT @n = COUNT(*) FROM @x;'),
    ('6. Búsqueda "señor anill*"', 'Índice invertido (AND + prefijo)',
     N'DECLARE @x TABLE (pelicula_id INT, titulo VARCHAR(1000), anio SMALLINT, calificacion DECIMAL(3,1), votos INT,
                        puntaje DECIMAL(9,3), texto VARCHAR(1000), total INT);
       INSERT INTO @x EXEC busqueda.sp_buscar @consulta = ''señor anill*'', @top = 1000000; SELECT @n = COUNT(*) FROM @x;'),
    ('6. Búsqueda "señor anill*"', 'LIKE ''%señor%anill%''',
     N'DECLARE @x TABLE (pelicula_id INT, titulo VARCHAR(1000), anio SMALLINT, calificacion DECIMAL(3,1), votos INT,
                        texto VARCHAR(1000), total INT);
       INSERT INTO @x EXEC busqueda.sp_buscar_like @texto = ''señor%anill'', @top = 1000000; SELECT @n = COUNT(*) FROM @x;');

    DECLARE @orden INT = 0, @prueba VARCHAR(80), @variante VARCHAR(80), @consulta NVARCHAR(MAX);
    WHILE 1 = 1
    BEGIN
        SELECT TOP (1) @orden = orden, @prueba = prueba, @variante = variante, @consulta = consulta
        FROM @v WHERE orden > @orden ORDER BY orden;
        IF @@ROWCOUNT = 0 BREAK;

        SET @r = 0;
        WHILE @r <= @repeticiones           -- la corrida 0 es de calentamiento y no se guarda
        BEGIN
            SET @t = SYSDATETIME();
            EXEC sys.sp_executesql @consulta, N'@o INT, @d INT, @n BIGINT OUTPUT', @o = @bacon, @d = @destino, @n = @n OUTPUT;
            IF @r > 0
                INSERT INTO qa.medicion (ejecucion, prueba, variante, repeticion, ms, filas)
                VALUES (@ahora, @prueba, @variante, @r, DATEDIFF(MILLISECOND, @t, SYSDATETIME()), @n);
            SET @r += 1;
        END;
        PRINT CONCAT(@prueba, N' | ', @variante, N' | resultado ', @n);
    END;

    SELECT * FROM qa.v_medicion_resumen ORDER BY prueba, ms_mediana;
END;
GO

PRINT N'Banco de rendimiento creado.';
GO
