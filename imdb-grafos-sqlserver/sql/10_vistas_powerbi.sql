/* =====================================================================
   10_vistas_powerbi.sql
   Vistas en español para Power BI (esquema rpt). El reporte solo lee rpt:
   si cambia el modelo por dentro, las vistas mantienen el contrato.
   ===================================================================== */
USE ImdbGrafos;
GO

/* ---------- Catálogo ---------- */
CREATE OR ALTER VIEW rpt.pelicula AS
SELECT p.pelicula_id, p.tconst, p.titulo, p.titulo_original, p.anio, p.decada, p.duracion_min,
       c.calificacion, c.votos, s.calificacion_ponderada,
       (SELECT STRING_AGG(g.nombre, ', ') WITHIN GROUP (ORDER BY g.nombre)
        FROM dw.pelicula_genero AS pg JOIN dw.genero AS g ON g.genero_id = pg.genero_id
        WHERE pg.pelicula_id = p.pelicula_id) AS generos,
       CONCAT('https://www.imdb.com/title/', p.tconst, '/') AS enlace_imdb
FROM dw.pelicula AS p
JOIN dw.calificacion AS c ON c.pelicula_id = p.pelicula_id
JOIN mart.pelicula_puntaje AS s ON s.pelicula_id = p.pelicula_id;
GO

CREATE OR ALTER VIEW rpt.pelicula_genero AS
SELECT pg.pelicula_id, g.nombre AS genero
FROM dw.pelicula_genero AS pg JOIN dw.genero AS g ON g.genero_id = pg.genero_id;
GO

CREATE OR ALTER VIEW rpt.peliculas_por_decada AS
SELECT p.decada, COUNT(*) AS peliculas, AVG(CAST(c.calificacion AS DECIMAL(6,3))) AS calificacion_media,
       SUM(CAST(c.votos AS BIGINT)) AS votos
FROM dw.pelicula AS p JOIN dw.calificacion AS c ON c.pelicula_id = p.pelicula_id
WHERE p.decada IS NOT NULL
GROUP BY p.decada;
GO

CREATE OR ALTER VIEW rpt.genero_resumen AS
SELECT g.nombre AS genero, COUNT(*) AS peliculas,
       AVG(CAST(c.calificacion AS DECIMAL(6,3))) AS calificacion_media,
       AVG(CAST(s.calificacion_ponderada AS DECIMAL(7,4))) AS calificacion_ponderada_media,
       SUM(CAST(c.votos AS BIGINT)) AS votos
FROM dw.pelicula_genero AS pg
JOIN dw.genero AS g ON g.genero_id = pg.genero_id
JOIN dw.calificacion AS c ON c.pelicula_id = pg.pelicula_id
JOIN mart.pelicula_puntaje AS s ON s.pelicula_id = pg.pelicula_id
GROUP BY g.nombre;
GO

CREATE OR ALTER VIEW rpt.genero_decada      AS SELECT * FROM mart.genero_decada;
GO
CREATE OR ALTER VIEW rpt.mejor_decada_genero AS SELECT * FROM mart.mejor_decada_genero;
GO
CREATE OR ALTER VIEW rpt.actor_prolifico_decada AS SELECT * FROM mart.actor_prolifico_decada;
GO
CREATE OR ALTER VIEW rpt.percentil_votos    AS SELECT * FROM mart.percentil_votos;
GO
CREATE OR ALTER VIEW rpt.decil_votos        AS SELECT * FROM mart.decil_votos;
GO

/* ---------- Personas y red ---------- */
CREATE OR ALTER VIEW rpt.persona AS
SELECT gp.persona_id, gp.nombre, gp.es_actor, gp.es_director, gp.peliculas,
       nb.grados AS numero_bacon, nt.nucleo_id,
       pe.anio_nacimiento, pe.anio_muerte, pe.profesiones,
       CONCAT('https://www.imdb.com/name/', pe.nconst, '/') AS enlace_imdb
FROM grafo.Persona AS gp
JOIN dw.persona AS pe ON pe.persona_id = gp.persona_id
LEFT JOIN mart.numero_bacon AS nb ON nb.persona_id = gp.persona_id
LEFT JOIN mart.nucleo_talento AS nt ON nt.persona_id = gp.persona_id;
GO

CREATE OR ALTER VIEW rpt.participacion AS
SELECT pa.pelicula_id, pa.persona_id, r.grupo AS rol, r.categoria, pa.orden, pa.personaje
FROM dw.participacion AS pa JOIN dw.rol AS r ON r.rol_id = pa.rol_id;
GO

-- Lazos con 2+ películas juntos (los de 1 película son el 90 % y no aportan al visual de red)
CREATE OR ALTER VIEW rpt.colaboracion_frecuente AS
SELECT c.persona_a, a.nombre AS nombre_a, c.persona_b, b.nombre AS nombre_b, c.peliculas_en_comun
FROM dw.colaboracion AS c
JOIN grafo.Persona AS a ON a.persona_id = c.persona_a
JOIN grafo.Persona AS b ON b.persona_id = c.persona_b
WHERE c.peliculas_en_comun >= 2 AND c.persona_a < c.persona_b;
GO

CREATE OR ALTER VIEW rpt.numero_bacon_distribucion AS
SELECT nb.grados, COUNT(*) AS personas,
       CAST(100.0 * COUNT(*) / (SELECT COUNT(*) FROM grafo.Persona) AS DECIMAL(5,2)) AS pct_red
FROM mart.numero_bacon AS nb
GROUP BY nb.grados;
GO

CREATE OR ALTER VIEW rpt.top_colaboradores  AS SELECT * FROM mart.top_colaboradores;
GO
CREATE OR ALTER VIEW rpt.elenco_fiel        AS SELECT * FROM mart.elenco_fiel;
GO
CREATE OR ALTER VIEW rpt.ejemplo_separacion AS SELECT * FROM mart.ejemplo_separacion;
GO

CREATE OR ALTER VIEW rpt.nucleo_talento_resumen AS
WITH miembros AS (
    SELECT nt.nucleo_id, gp.persona_id, gp.nombre, gp.peliculas,
           ROW_NUMBER() OVER (PARTITION BY nt.nucleo_id ORDER BY gp.peliculas DESC, gp.persona_id) AS rn,
           COUNT(*) OVER (PARTITION BY nt.nucleo_id) AS personas
    FROM mart.nucleo_talento AS nt JOIN grafo.Persona AS gp ON gp.persona_id = nt.persona_id
)
SELECT nucleo_id, MAX(personas) AS personas,
       STRING_AGG(IIF(rn <= 5, nombre, NULL), ', ') WITHIN GROUP (ORDER BY rn) AS figuras
FROM miembros
GROUP BY nucleo_id;
GO

/* ---------- Auditoría y rendimiento ---------- */
CREATE OR ALTER VIEW rpt.auditoria_carga AS
SELECT a.archivo, a.metodo, a.filas_fuente, a.filas_leidas, a.filas_cargadas,
       a.filas_rechazadas, a.filas_filtradas, a.segundos, a.inicio
FROM qa.auditoria_carga AS a
WHERE a.carga_id IN (SELECT MAX(carga_id) FROM qa.auditoria_carga WHERE fin IS NOT NULL GROUP BY archivo);
GO

CREATE OR ALTER VIEW rpt.medicion AS SELECT * FROM qa.v_medicion_resumen;
GO

PRINT N'Vistas rpt creadas.';
GO
