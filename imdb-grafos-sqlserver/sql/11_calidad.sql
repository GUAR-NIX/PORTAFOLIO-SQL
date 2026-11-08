/* =====================================================================
   11_calidad.sql
   Controles de calidad.   EXEC qa.sp_validar_calidad;

   Cada control calcula un valor y lo compara con lo esperado. Si algo no
   cuadra queda en ALERTA y el procedimiento termina con error (THROW) para
   que 00_EJECUTAR_TODO y pytest fallen de forma visible.

   Bloques:
     A. Carga: TSV (conteo de Python) -> leídas -> staging
     B. Modelo relacional
     C. Grafo: nodos, aristas huérfanas, simetría y pesos
     D. Resultados: número de Bacon, búsqueda, analítica
   ===================================================================== */
USE ImdbGrafos;
GO

IF OBJECT_ID(N'qa.resultado_control', N'U') IS NULL
CREATE TABLE qa.resultado_control (
    ejecucion   DATETIME2(0)   NOT NULL,
    orden       TINYINT        NOT NULL,
    bloque      CHAR(1)        NOT NULL,
    control     VARCHAR(200)   NOT NULL,
    valor       DECIMAL(19,3)  NULL,
    esperado    VARCHAR(40)    NOT NULL,
    estado      VARCHAR(6)     NOT NULL,
    CONSTRAINT PK_resultado_control PRIMARY KEY (ejecucion, orden)
);
GO

CREATE OR ALTER PROCEDURE qa.sp_validar_calidad
    @lanzar_error BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ahora DATETIME2(0) = SYSDATETIME();
    DECLARE @r TABLE (orden TINYINT, bloque CHAR(1), control VARCHAR(200), valor DECIMAL(19,3), esperado VARCHAR(40), ok BIT);
    DECLARE @v DECIMAL(19,3), @w DECIMAL(19,3);

    DECLARE @tipo VARCHAR(20) = (SELECT valor FROM etl.parametro WHERE nombre = 'tipo_titulo'),
            @min_votos INT     = (SELECT CAST(valor AS INT) FROM etl.parametro WHERE nombre = 'min_votos'),
            @sin_adultos BIT   = (SELECT CAST(valor AS BIT) FROM etl.parametro WHERE nombre = 'excluir_adultos');

    /* Última carga terminada de cada archivo */
    DECLARE @aud TABLE (archivo VARCHAR(40) PRIMARY KEY, fuente BIGINT, leidas BIGINT, cargadas BIGINT);
    INSERT INTO @aud
    SELECT a.archivo, a.filas_fuente, a.filas_leidas, a.filas_cargadas
    FROM qa.auditoria_carga AS a
    WHERE a.carga_id IN (SELECT MAX(carga_id) FROM qa.auditoria_carga WHERE fin IS NOT NULL GROUP BY archivo);

    /* ---------- A. Carga ---------- */
    INSERT INTO @r SELECT 1, 'A', 'Archivos de IMDb con carga terminada (de 6)', COUNT(*), '6', IIF(COUNT(*) = 6, 1, 0) FROM @aud;

    INSERT INTO @r SELECT 2, 'A', 'Archivos con filas leídas por el motor ≠ filas del TSV', COUNT(*), '0', IIF(COUNT(*) = 0, 1, 0)
    FROM @aud WHERE leidas <> fuente;

    SELECT @v = SUM(fuente - leidas) FROM @aud;
    INSERT INTO @r SELECT 3, 'A', 'Filas rechazadas por errores de formato (todos los archivos)', @v, '0', IIF(@v = 0, 1, 0);

    -- Si alguna fila rechazada fuera de una película filtrada, su película no tendría fila en crew
    INSERT INTO @r SELECT 4, 'A', 'Películas filtradas sin su fila de title.crew', COUNT(*), '0', IIF(COUNT(*) = 0, 1, 0)
    FROM stg.pelicula_filtro AS f WHERE NOT EXISTS (SELECT 1 FROM stg.title_crew AS c WHERE c.tconst = f.tconst);

    SELECT @v = COUNT_BIG(*) FROM stg.title_basics;
    INSERT INTO @r SELECT 5, 'A', 'stg.title_basics − filas del TSV', @v - fuente, '0', IIF(@v = fuente, 1, 0) FROM @aud WHERE archivo = 'title.basics';
    SELECT @v = COUNT_BIG(*) FROM stg.title_ratings;
    INSERT INTO @r SELECT 6, 'A', 'stg.title_ratings − filas del TSV', @v - fuente, '0', IIF(@v = fuente, 1, 0) FROM @aud WHERE archivo = 'title.ratings';

    INSERT INTO @r SELECT 7, 'A', 'Archivos filtrados cuya auditoría no coincide con su tabla de staging', COUNT(*), '0', IIF(COUNT(*) = 0, 1, 0)
    FROM @aud AS a
    WHERE (a.archivo = 'title.principals' AND a.cargadas <> (SELECT COUNT_BIG(*) FROM stg.title_principals))
       OR (a.archivo = 'title.crew'       AND a.cargadas <> (SELECT COUNT_BIG(*) FROM stg.title_crew))
       OR (a.archivo = 'title.akas'       AND a.cargadas <> (SELECT COUNT_BIG(*) FROM stg.title_akas))
       OR (a.archivo = 'name.basics'      AND a.cargadas <> (SELECT COUNT_BIG(*) FROM stg.name_basics));

    /* ---------- B. Modelo relacional ---------- */
    SELECT @v = COUNT(*) FROM stg.title_basics AS b JOIN stg.title_ratings AS r ON r.tconst = b.tconst
    WHERE b.titleType = @tipo AND TRY_CAST(r.numVotes AS INT) >= @min_votos AND (@sin_adultos = 0 OR b.isAdult = '0');
    SELECT @w = COUNT(*) FROM dw.pelicula;
    INSERT INTO @r SELECT 8, 'B', 'dw.pelicula − películas que cumplen el filtro en los TSV', @w - @v, '0', IIF(@w = @v, 1, 0);

    INSERT INTO @r SELECT 9, 'B', 'Películas sin calificación', COUNT(*), '0', IIF(COUNT(*) = 0, 1, 0)
    FROM dw.pelicula AS p WHERE NOT EXISTS (SELECT 1 FROM dw.calificacion AS c WHERE c.pelicula_id = p.pelicula_id);

    INSERT INTO @r SELECT 10, 'B', 'Películas con menos votos que el mínimo o que no son movie', COUNT(*), '0', IIF(COUNT(*) = 0, 1, 0)
    FROM dw.pelicula AS p JOIN dw.calificacion AS c ON c.pelicula_id = p.pelicula_id
    JOIN stg.title_basics AS b ON b.tconst = p.tconst
    WHERE c.votos < @min_votos OR b.titleType <> @tipo;

    SELECT @v = COUNT(*) FROM stg.title_basics AS b JOIN stg.pelicula_filtro AS f ON f.tconst = b.tconst
    CROSS APPLY STRING_SPLIT(b.genres, ',') AS s WHERE b.genres <> '\N';
    SELECT @w = COUNT(*) FROM dw.pelicula_genero;
    INSERT INTO @r SELECT 11, 'B', 'Géneros en la lista del TSV − filas de dw.pelicula_genero', @v - @w, '0', IIF(@v = @w, 1, 0);

    -- Las participaciones de principals solo se pierden si la persona no está en name.basics
    SELECT @v = COUNT(*) FROM (SELECT DISTINCT t.tconst, t.nconst, t.category FROM stg.title_principals AS t) AS d
    WHERE EXISTS (SELECT 1 FROM stg.name_basics AS n WHERE n.nconst = d.nconst AND n.primaryName <> '\N');
    SELECT @w = COUNT(*) FROM dw.participacion WHERE fuente = 'principals';
    INSERT INTO @r SELECT 12, 'B', 'Participaciones de principals (con persona conocida) − cargadas', @v - @w, '0', IIF(@v = @w, 1, 0);

    INSERT INTO @r SELECT 13, 'B', 'Participaciones con persona o película inexistente', COUNT(*), '0', IIF(COUNT(*) = 0, 1, 0)
    FROM dw.participacion AS pa
    WHERE NOT EXISTS (SELECT 1 FROM dw.persona AS p WHERE p.persona_id = pa.persona_id)
       OR NOT EXISTS (SELECT 1 FROM dw.pelicula AS m WHERE m.pelicula_id = pa.pelicula_id);

    INSERT INTO @r SELECT 14, 'B', 'Películas sin director (ni en principals ni en crew)', COUNT(*), '<= 1 %',
           IIF(COUNT(*) <= 0.01 * (SELECT COUNT(*) FROM dw.pelicula), 1, 0)
    FROM dw.pelicula AS p
    WHERE NOT EXISTS (SELECT 1 FROM dw.participacion AS pa JOIN dw.rol AS r ON r.rol_id = pa.rol_id
                      WHERE pa.pelicula_id = p.pelicula_id AND r.grupo = 'Dirección');

    /* ---------- C. Grafo ---------- */
    SELECT @v = COUNT(*) FROM grafo.Pelicula; SELECT @w = COUNT(*) FROM dw.pelicula;
    INSERT INTO @r SELECT 15, 'C', 'Nodos Pelicula − dw.pelicula', @v - @w, '0', IIF(@v = @w, 1, 0);

    SELECT @v = COUNT(*) FROM grafo.Persona;
    SELECT @w = COUNT(DISTINCT pa.persona_id) FROM dw.participacion AS pa JOIN dw.rol AS r ON r.rol_id = pa.rol_id
    WHERE r.grupo IN ('Actuación', 'Dirección');
    INSERT INTO @r SELECT 16, 'C', 'Nodos Persona − personas con actuación o dirección', @v - @w, '0', IIF(@v = @w, 1, 0);

    INSERT INTO @r SELECT 17, 'C', 'Aristas ActuoEn huérfanas', COUNT(*), '0', IIF(COUNT(*) = 0, 1, 0)
    FROM grafo.ActuoEn AS e
    WHERE NOT EXISTS (SELECT 1 FROM grafo.Persona AS p WHERE p.$node_id = e.$from_id)
       OR NOT EXISTS (SELECT 1 FROM grafo.Pelicula AS m WHERE m.$node_id = e.$to_id);

    INSERT INTO @r SELECT 18, 'C', 'Aristas Dirigio huérfanas', COUNT(*), '0', IIF(COUNT(*) = 0, 1, 0)
    FROM grafo.Dirigio AS e
    WHERE NOT EXISTS (SELECT 1 FROM grafo.Persona AS p WHERE p.$node_id = e.$from_id)
       OR NOT EXISTS (SELECT 1 FROM grafo.Pelicula AS m WHERE m.$node_id = e.$to_id);

    INSERT INTO @r SELECT 19, 'C', 'Aristas TrabajoCon huérfanas', COUNT(*), '0', IIF(COUNT(*) = 0, 1, 0)
    FROM grafo.TrabajoCon AS e
    WHERE NOT EXISTS (SELECT 1 FROM grafo.Persona AS p WHERE p.$node_id = e.$from_id)
       OR NOT EXISTS (SELECT 1 FROM grafo.Persona AS q WHERE q.$node_id = e.$to_id);

    INSERT INTO @r SELECT 20, 'C', 'Aristas TrabajoCon sin su inversa con el mismo peso', COUNT(*), '0', IIF(COUNT(*) = 0, 1, 0)
    FROM grafo.TrabajoCon AS e
    WHERE NOT EXISTS (SELECT 1 FROM grafo.TrabajoCon AS i
                      WHERE i.$from_id = e.$to_id AND i.$to_id = e.$from_id AND i.peliculas_en_comun = e.peliculas_en_comun);

    INSERT INTO @r SELECT 21, 'C', 'Autociclos en TrabajoCon', COUNT(*), '0', IIF(COUNT(*) = 0, 1, 0)
    FROM grafo.TrabajoCon AS e WHERE e.$from_id = e.$to_id;

    /* Suma de pesos = Σ k·(k−1) por película, con k = personas de la red en esa película */
    SELECT @v = SUM(CAST(k AS BIGINT) * (k - 1))
    FROM (SELECT pa.pelicula_id, COUNT(DISTINCT pa.persona_id) AS k
          FROM dw.participacion AS pa JOIN dw.rol AS r ON r.rol_id = pa.rol_id
          WHERE r.grupo IN ('Actuación', 'Dirección') GROUP BY pa.pelicula_id) AS x;
    SELECT @w = SUM(CAST(peliculas_en_comun AS BIGINT)) FROM grafo.TrabajoCon;
    INSERT INTO @r SELECT 22, 'C', 'Σ pesos de TrabajoCon − Σ k(k−1) por película', @w - @v, '0', IIF(@v = @w, 1, 0);

    SELECT @v = COUNT(*) FROM grafo.ActuoEn;
    SELECT @w = COUNT(*) FROM (SELECT DISTINCT pa.pelicula_id, pa.persona_id FROM dw.participacion AS pa
                               JOIN dw.rol AS r ON r.rol_id = pa.rol_id WHERE r.grupo = 'Actuación') AS x;
    INSERT INTO @r SELECT 23, 'C', 'Aristas ActuoEn − pares persona-película de actuación', @v - @w, '0', IIF(@v = @w, 1, 0);

    /* ---------- D. Resultados ---------- */
    SELECT @v = COUNT(*) FROM mart.numero_bacon WHERE grados = 1;
    SELECT @w = COUNT(*) FROM grafo.Persona AS p1, grafo.TrabajoCon AS t, grafo.Persona AS p2
    WHERE MATCH(p1-(t)->p2) AND p1.persona_id = 102;
    INSERT INTO @r SELECT 24, 'D', 'Bacon = 1 − colaboradores directos de Kevin Bacon (MATCH)', @v - @w, '0', IIF(@v = @w, 1, 0);

    -- Propiedad del BFS: quien está a k grados tiene un vecino a k−1 y ningún vecino a menos de k−1
    INSERT INTO @r SELECT 25, 'D', 'Personas cuyo número de Bacon no es coherente con el de sus vecinos', COUNT(*), '0', IIF(COUNT(*) = 0, 1, 0)
    FROM mart.numero_bacon AS nb
    CROSS APPLY (SELECT MIN(v.grados) AS minimo FROM dw.colaboracion AS c
                 JOIN mart.numero_bacon AS v ON v.persona_id = c.persona_b
                 WHERE c.persona_a = nb.persona_id) AS vec
    WHERE nb.grados > 0 AND vec.minimo <> nb.grados - 1;

    INSERT INTO @r SELECT 26, 'D', 'Películas sin texto en el índice de búsqueda', COUNT(*), '0', IIF(COUNT(*) = 0, 1, 0)
    FROM dw.pelicula AS p WHERE NOT EXISTS (SELECT 1 FROM busqueda.titulo AS b WHERE b.pelicula_id = p.pelicula_id);

    INSERT INTO @r SELECT 27, 'D', 'Palabras cuya frecuencia documental no coincide con el índice', COUNT(*), '0', IIF(COUNT(*) = 0, 1, 0)
    FROM busqueda.palabra AS p
    WHERE p.documentos <> (SELECT COUNT(*) FROM busqueda.indice AS i WHERE i.palabra_id = p.palabra_id);

    INSERT INTO @r SELECT 28, 'D', 'Calificaciones ponderadas fuera del rango [1, 10]', COUNT(*), '0', IIF(COUNT(*) = 0, 1, 0)
    FROM mart.pelicula_puntaje WHERE calificacion_ponderada NOT BETWEEN 1 AND 10;

    INSERT INTO @r SELECT 29, 'D', 'Celdas década-género con más de un puesto 1', COUNT(*), '0', IIF(COUNT(*) = 0, 1, 0)
    FROM (SELECT decada, genero FROM mart.mejor_decada_genero WHERE puesto = 1 GROUP BY decada, genero HAVING COUNT(*) > 1) AS x;

    /* ---------- Resultado ---------- */
    INSERT INTO qa.resultado_control (ejecucion, orden, bloque, control, valor, esperado, estado)
    SELECT @ahora, orden, bloque, control, valor, esperado, IIF(ok = 1, 'OK', 'ALERTA') FROM @r;

    SELECT orden, bloque, control, valor, esperado, estado
    FROM qa.resultado_control WHERE ejecucion = @ahora ORDER BY orden;

    DECLARE @alertas INT = (SELECT COUNT(*) FROM @r WHERE ok = 0);
    IF @alertas > 0 AND @lanzar_error = 1
    BEGIN
        DECLARE @msg NVARCHAR(200) = CONCAT(N'Controles de calidad con ALERTA: ', @alertas);
        THROW 50001, @msg, 1;
    END;
    PRINT CONCAT(N'Controles de calidad: ', (29 - @alertas), N' de 29 en OK.');
END;
GO

PRINT N'Controles de calidad creados.';
GO
