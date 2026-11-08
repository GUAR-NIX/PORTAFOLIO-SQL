/* =====================================================================
   08_calidad_y_reconciliacion.sql — Controles automáticos de calidad,
   reconciliación (fuente = modelo + excluidas), equivalencia de
   resultados antes/después y dirección esperada de cada mejora
   ===================================================================== */
USE CitiBikeTuning;
GO

IF OBJECT_ID(N'qa.resultado_control', N'U') IS NOT NULL DROP TABLE qa.resultado_control;
CREATE TABLE qa.resultado_control
(
    orden           INT           NOT NULL PRIMARY KEY,
    categoria       NVARCHAR(40)  NOT NULL,
    control         NVARCHAR(160) NOT NULL,
    valor_observado DECIMAL(18,2) NOT NULL,
    valor_esperado  DECIMAL(18,2) NOT NULL,
    estado          VARCHAR(10)   NOT NULL
);
GO

CREATE OR ALTER PROCEDURE qa.sp_validar_calidad
    @lanzar_error BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE qa.resultado_control;

    -- (categoría, control, observado, esperado, ok)
    DECLARE @c TABLE (n INT IDENTITY(1,1), categoria NVARCHAR(40), control NVARCHAR(160), obs DECIMAL(18,2), esp DECIMAL(18,2), ok BIT);

    -- El staging se vacía tras la limpieza (libera espacio): su conteo queda en la bitácora
    DECLARE @stg_filas BIGINT = (SELECT TOP (1) filas_afectadas FROM etl.bitacora_carga WHERE etapa = N'BULK_INSERT_STAGING' ORDER BY id_carga DESC);
    DECLARE @lim_filas BIGINT = (SELECT COUNT_BIG(*) FROM limpio.viaje);
    DECLARE @lim_validas BIGINT = (SELECT COUNT_BIG(*) FROM limpio.viaje WHERE motivo_exclusion IS NULL);
    DECLARE @lim_excluidas BIGINT = (SELECT COUNT_BIG(*) FROM limpio.viaje WHERE motivo_exclusion IS NOT NULL);
    DECLARE @dw_filas BIGINT = (SELECT COUNT_BIG(*) FROM dw.fact_viaje);
    DECLARE @heap BIGINT = (SELECT COUNT_BIG(*) FROM lab.viaje_heap);
    DECLARE @nocov BIGINT = (SELECT COUNT_BIG(*) FROM lab.viaje_rowstore_nocov);
    DECLARE @cov BIGINT = (SELECT COUNT_BIG(*) FROM lab.viaje_rowstore);
    DECLARE @cci BIGINT = (SELECT COUNT_BIG(*) FROM lab.viaje_columnstore);
    DECLARE @dur_lim BIGINT = (SELECT SUM(CAST(duracion_seg AS BIGINT)) FROM limpio.viaje WHERE motivo_exclusion IS NULL);
    DECLARE @dur_dw BIGINT = (SELECT SUM(CAST(duracion_seg AS BIGINT)) FROM dw.fact_viaje);
    DECLARE @dur_cov BIGINT = (SELECT SUM(CAST(duracion_seg AS BIGINT)) FROM lab.viaje_rowstore);
    DECLARE @dur_cci BIGINT = (SELECT SUM(CAST(duracion_seg AS BIGINT)) FROM lab.viaje_columnstore);

    INSERT INTO @c (categoria, control, obs, esp, ok) VALUES
    (N'Reconciliación', N'Filas cargadas por BULK INSERT = filas en limpio.viaje (ninguna se pierde)', ISNULL(@stg_filas, -1) - @lim_filas, 0, IIF(@stg_filas = @lim_filas, 1, 0)),
    (N'Reconciliación', N'limpio.viaje = válidas + excluidas', @lim_filas - (@lim_validas + @lim_excluidas), 0, IIF(@lim_filas = @lim_validas + @lim_excluidas, 1, 0)),
    (N'Reconciliación', N'dw.fact_viaje tiene exactamente las filas válidas', @lim_validas - @dw_filas, 0, IIF(@lim_validas = @dw_filas, 1, 0)),
    (N'Reconciliación', N'Las 4 tablas del laboratorio tienen exactamente las filas válidas', ABS(@heap - @lim_validas) + ABS(@nocov - @lim_validas) + ABS(@cov - @lim_validas) + ABS(@cci - @lim_validas), 0,
        IIF(@heap = @lim_validas AND @nocov = @lim_validas AND @cov = @lim_validas AND @cci = @lim_validas, 1, 0)),
    (N'Reconciliación', N'Suma de duración idéntica en limpio, dw, rowstore y columnstore', ABS(@dur_lim - @dur_dw) + ABS(@dur_lim - @dur_cov) + ABS(@dur_lim - @dur_cci), 0,
        IIF(@dur_lim = @dur_dw AND @dur_lim = @dur_cov AND @dur_lim = @dur_cci, 1, 0));

    DECLARE @dur_mal INT = (SELECT COUNT(*) FROM dw.fact_viaje WHERE duracion_seg <= 0 OR duracion_seg > 86400);
    DECLARE @falsos INT = (SELECT COUNT(*) FROM dw.fact_viaje WHERE estacion_origen_key = estacion_destino_key AND duracion_seg < 60);
    DECLARE @dias_t1 INT = (SELECT COUNT(*) FROM dw.dim_fecha WHERE fecha >= '2024-01-01' AND fecha < '2024-04-01');
    DECLARE @huerfanas INT = (
        SELECT COUNT(*) FROM dw.fact_viaje v
        LEFT JOIN dw.dim_fecha f ON f.fecha_key = v.fecha_key
        LEFT JOIN dw.dim_estacion eo ON eo.estacion_key = v.estacion_origen_key
        LEFT JOIN dw.dim_estacion ed ON ed.estacion_key = v.estacion_destino_key
        LEFT JOIN dw.dim_tipo_bici tb ON tb.tipo_bici_key = v.tipo_bici_key
        WHERE f.fecha_key IS NULL OR eo.estacion_key IS NULL OR ed.estacion_key IS NULL OR tb.tipo_bici_key IS NULL);
    DECLARE @dup_ride INT = (SELECT COUNT(*) - COUNT(DISTINCT ride_id) FROM lab.viaje_rowstore);
    DECLARE @serie_falt BIGINT = (SELECT COUNT(DISTINCT estacion_origen_id) * 91 - COUNT(*) FROM lab.serie_diaria_estacion);
    DECLARE @ratio_cci DECIMAL(8,2) = (SELECT ratio_compresion_vs_heap FROM perf.tamano_estructura WHERE orden = 4);

    INSERT INTO @c (categoria, control, obs, esp, ok) VALUES
    (N'Calidad', N'Cero viajes con duración <= 0 o > 86.400 s en dw.fact_viaje', @dur_mal, 0, IIF(@dur_mal = 0, 1, 0)),
    (N'Calidad', N'Cero falsos arranques (< 60 s en la misma estación) en dw.fact_viaje', @falsos, 0, IIF(@falsos = 0, 1, 0)),
    (N'Dimensiones', N'Calendario de enero–marzo 2024 completo en dw.dim_fecha (91 días)', @dias_t1, 91, IIF(@dias_t1 = 91, 1, 0)),
    (N'Dimensiones', N'Cero claves foráneas huérfanas en dw.fact_viaje', @huerfanas, 0, IIF(@huerfanas = 0, 1, 0)),
    (N'Dimensiones', N'Cero ride_id duplicados entre los viajes válidos', @dup_ride, 0, IIF(@dup_ride = 0, 1, 0)),
    (N'Laboratorio', N'Serie diaria densa: estaciones × 91 días, sin huecos', @serie_falt, 0, IIF(@serie_falt = 0, 1, 0)),
    (N'Almacenamiento', N'Columnstore comprime al menos 3 veces frente al heap', ISNULL(@ratio_cci, 0), 3.00, IIF(@ratio_cci >= 3.00, 1, 0));

    -- Equivalencia: todas las variantes de un grupo devuelven las mismas filas y el mismo checksum
    INSERT INTO @c (categoria, control, obs, esp, ok)
    SELECT N'Equivalencia SQL',
           LEFT(grupo_experimento, 60) + N': mismas filas y checksum en sus ' + CAST(COUNT(*) AS NVARCHAR(5)) + N' variantes',
           COUNT(DISTINCT CONCAT(filas_devueltas, '|', checksum_resultado)), 1,
           IIF(COUNT(DISTINCT CONCAT(filas_devueltas, '|', checksum_resultado)) = 1 AND MIN(filas_devueltas) > 0, 1, 0)
    FROM perf.experimento_resultado
    GROUP BY grupo_experimento
    ORDER BY MIN(id_experimento);

    DECLARE @inestables INT = (SELECT COUNT(*) FROM perf.experimento_resultado WHERE checksums_distintos <> 1);
    INSERT INTO @c (categoria, control, obs, esp, ok) VALUES
    (N'Equivalencia SQL', N'Cada variante devuelve el mismo resultado en todas sus corridas (frío y caliente)', @inestables, 0, IIF(@inestables = 0, 1, 0));

    -- E6: comparación fila a fila (no solo checksum) entre subconsulta y función de ventana
    DECLARE @dif_e6 INT;
    ;WITH sub AS (
        SELECT r1.estacion_origen_id, r1.fecha_dia,
               (SELECT AVG(CAST(r2.viajes AS DECIMAL(12,4))) FROM lab.serie_diaria_estacion r2
                WHERE r2.estacion_origen_id = r1.estacion_origen_id
                  AND r2.fecha_dia BETWEEN DATEADD(DAY, -6, r1.fecha_dia) AND r1.fecha_dia) AS m
        FROM lab.serie_diaria_estacion r1),
    win AS (
        SELECT estacion_origen_id, fecha_dia,
               AVG(CAST(viajes AS DECIMAL(12,4))) OVER (PARTITION BY estacion_origen_id ORDER BY fecha_dia
                                                       ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS m
        FROM lab.serie_diaria_estacion),
    dif AS (
        SELECT * FROM (SELECT * FROM sub EXCEPT SELECT * FROM win) a
        UNION ALL
        SELECT * FROM (SELECT * FROM win EXCEPT SELECT * FROM sub) b)
    SELECT @dif_e6 = COUNT(*) FROM dif;
    INSERT INTO @c (categoria, control, obs, esp, ok) VALUES
    (N'Equivalencia SQL', N'E6: subconsulta y AVG() OVER coinciden fila a fila (EXCEPT en ambos sentidos)', @dif_e6, 0, IIF(@dif_e6 = 0, 1, 0));

    -- Dirección esperada de cada mejora (comparaciones relativas, no umbrales fijos de tiempo)
    DECLARE @r TABLE (codigo VARCHAR(30) PRIMARY KEY, lec FLOAT, durc FLOAT, durf FLOAT, lookup BIT, modo VARCHAR(20), op NVARCHAR(100));
    INSERT INTO @r SELECT codigo_experimento, lecturas_logicas, duracion_ms_caliente, duracion_ms_frio, tiene_key_lookup, modo_ejecucion, operador_principal
    FROM perf.experimento_resultado;
    DECLARE @x FLOAT, @y FLOAT;

    SELECT @x = lec FROM @r WHERE codigo = 'E1_C_COVERING'; SELECT @y = lec FROM @r WHERE codigo = 'E1_A_HEAP';
    INSERT INTO @c VALUES (N'Rendimiento', N'E1: el índice cubriente lee menos del 5 % de las páginas del heap y no hace Key Lookup', ROUND(@x / @y * 100, 2), 5,
        IIF(@x / @y < 0.05 AND (SELECT lookup FROM @r WHERE codigo = 'E1_C_COVERING') = 0, 1, 0));

    SELECT @x = lec FROM @r WHERE codigo = 'E2_D_INDICE_RANGO'; SELECT @y = lec FROM @r WHERE codigo = 'E2_A_HEAP_FUNCION';
    INSERT INTO @c VALUES (N'Rendimiento', N'E2: solo índice + rango SARGable baja las lecturas a menos del 10 %', ROUND(@x / @y * 100, 2), 10, IIF(@x / @y < 0.10, 1, 0));
    SELECT @x = MIN(lec) FROM @r WHERE codigo IN ('E2_B_HEAP_RANGO', 'E2_C_INDICE_FUNCION');
    INSERT INTO @c VALUES (N'Rendimiento', N'E2: reescritura sola o índice solo no bajan las lecturas (siguen >= 90 % del heap)', ROUND(@x / @y * 100, 2), 90, IIF(@x / @y >= 0.90, 1, 0));

    INSERT INTO @c VALUES (N'Rendimiento', N'E3: el columnstore se ejecuta en modo Batch', IIF((SELECT modo FROM @r WHERE codigo = 'E3_C_AGG_CCI') = 'Batch', 1, 0), 1,
        IIF((SELECT modo FROM @r WHERE codigo = 'E3_C_AGG_CCI') = 'Batch', 1, 0));
    SELECT @x = lec FROM @r WHERE codigo = 'E3_C_AGG_CCI'; SELECT @y = lec FROM @r WHERE codigo = 'E3_B_AGG_ROWSTORE';
    INSERT INTO @c VALUES (N'Rendimiento', N'E3: el columnstore lee menos del 30 % de las páginas del rowstore', ROUND(@x / @y * 100, 2), 30, IIF(@x / @y < 0.30, 1, 0));

    SELECT @x = lec FROM @r WHERE codigo = 'E4_B_CON_FILTRADO'; SELECT @y = lec FROM @r WHERE codigo = 'E4_A_SIN_FILTRADO';
    INSERT INTO @c VALUES (N'Rendimiento', N'E4: el índice filtrado lee menos del 10 % de las páginas', ROUND(@x / @y * 100, 2), 10, IIF(@x / @y < 0.10, 1, 0));

    INSERT INTO @c VALUES (N'Rendimiento', N'E5: el plan reutilizado (sniffing) usa Key Lookup y RECOMPILE no',
        IIF((SELECT lookup FROM @r WHERE codigo = 'E5_A_SNIFF_MALO') = 1 AND (SELECT lookup FROM @r WHERE codigo = 'E5_B_RECOMPILE') = 0, 1, 0), 1,
        IIF((SELECT lookup FROM @r WHERE codigo = 'E5_A_SNIFF_MALO') = 1 AND (SELECT lookup FROM @r WHERE codigo = 'E5_B_RECOMPILE') = 0, 1, 0));
    SELECT @x = lec FROM @r WHERE codigo = 'E5_B_RECOMPILE'; SELECT @y = lec FROM @r WHERE codigo = 'E5_A_SNIFF_MALO';
    INSERT INTO @c VALUES (N'Rendimiento', N'E5: RECOMPILE lee menos páginas que el plan reutilizado', ROUND(@x / @y * 100, 2), 100, IIF(@x < @y, 1, 0));

    SELECT @x = lec FROM @r WHERE codigo = 'E6_B_WINDOW_FUNC'; SELECT @y = lec FROM @r WHERE codigo = 'E6_A_SUBQUERY_CORR';
    INSERT INTO @c VALUES (N'Rendimiento', N'E6: la función de ventana lee menos páginas que la subconsulta', ROUND(@x / @y * 100, 2), 100, IIF(@x < @y, 1, 0));

    SELECT @x = lec FROM @r WHERE codigo = 'E7_D_INDICE_APPLY'; SELECT @y = lec FROM @r WHERE codigo = 'E7_A_HEAP_ROWNUMBER';
    INSERT INTO @c VALUES (N'Rendimiento', N'E7: índice + CROSS APPLY lee menos del 1 % de las páginas', ROUND(@x / @y * 100, 2), 1, IIF(@x / @y < 0.01, 1, 0));

    SELECT @x = durc FROM @r WHERE codigo = 'E8_B_CONJUNTO'; SELECT @y = durc FROM @r WHERE codigo = 'E8_A_CURSOR';
    INSERT INTO @c VALUES (N'Rendimiento', N'E8: la operación en conjunto tarda menos que el cursor (mediana en caliente)', ROUND(@x / @y * 100, 2), 100, IIF(@x < @y, 1, 0));

    -- E9: Query Store
    DECLARE @lk_malo BIT = (SELECT tiene_key_lookup FROM perf.demo_plan_forzado WHERE paso = 2);
    DECLARE @forz BIT = (SELECT es_plan_forzado FROM perf.demo_plan_forzado WHERE paso = 3);
    DECLARE @lk_forz BIT = (SELECT tiene_key_lookup FROM perf.demo_plan_forzado WHERE paso = 3);
    DECLARE @plan_forz BIGINT = (SELECT plan_id FROM perf.demo_plan_forzado WHERE paso = 3);
    DECLARE @plan_bueno BIGINT = (SELECT plan_id FROM perf.demo_plan_forzado WHERE paso = 1);
    INSERT INTO @c VALUES (N'Query Store', N'E9: la regresión provocada genera un plan con Key Lookup', ISNULL(@lk_malo, 0), 1, IIF(@lk_malo = 1, 1, 0));
    INSERT INTO @c VALUES (N'Query Store', N'E9: tras sp_query_store_force_plan se usa el plan original (forzado y sin Key Lookup)',
        IIF(@forz = 1 AND @lk_forz = 0 AND @plan_forz = @plan_bueno, 1, 0), 1, IIF(@forz = 1 AND @lk_forz = 0 AND @plan_forz = @plan_bueno, 1, 0));
    SELECT @x = lec FROM @r WHERE codigo = 'E9_C_PLAN_FORZADO'; SELECT @y = lec FROM @r WHERE codigo = 'E9_B_REGRESION';
    INSERT INTO @c VALUES (N'Query Store', N'E9: el plan forzado lee menos páginas que el plan de la regresión', ROUND(@x / @y * 100, 2), 100, IIF(@x < @y, 1, 0));

    DECLARE @tp_n INT = (SELECT COUNT(*) FROM perf.curva_tipping_point);
    DECLARE @tp_cruce BIT = IIF(
        (SELECT lecturas_forzado_lookup FROM perf.curva_tipping_point WHERE dias_ventana = 1) < (SELECT lecturas_heap_scan FROM perf.curva_tipping_point WHERE dias_ventana = 1)
        AND (SELECT lecturas_forzado_lookup FROM perf.curva_tipping_point WHERE dias_ventana = 91) > (SELECT lecturas_heap_scan FROM perf.curva_tipping_point WHERE dias_ventana = 91), 1, 0);
    INSERT INTO @c VALUES (N'Tipping point', N'Curva completa: 6 ventanas de 1 a 91 días', @tp_n, 6, IIF(@tp_n = 6, 1, 0));
    INSERT INTO @c VALUES (N'Tipping point', N'El Key Lookup forzado gana al heap en 1 día y pierde en 91 días', @tp_cruce, 1, @tp_cruce);

    DECLARE @qs INT = (SELECT COUNT(DISTINCT etiqueta_bench) FROM perf.resumen_query_store);
    DECLARE @tags INT = (SELECT COUNT(DISTINCT CASE WHEN codigo_experimento LIKE 'E9%' THEN 'E9_QS' ELSE codigo_experimento END)
                         FROM perf.experimento_resultado WHERE codigo_experimento NOT LIKE 'E8%');
    INSERT INTO @c VALUES (N'Query Store', N'Query Store registró todas las consultas etiquetadas del laboratorio', @qs, @tags, IIF(@qs >= @tags, 1, 0));

    INSERT INTO qa.resultado_control (orden, categoria, control, valor_observado, valor_esperado, estado)
    SELECT n, categoria, control, ISNULL(obs, -1), esp, CASE WHEN ok = 1 THEN 'OK' ELSE 'ALERTA' END
    FROM @c;

    SELECT * FROM qa.resultado_control ORDER BY orden;

    IF @lanzar_error = 1 AND EXISTS (SELECT 1 FROM qa.resultado_control WHERE estado <> 'OK')
    BEGIN
        DECLARE @msg NVARCHAR(400) = (
            SELECT TOP (1) CONCAT(N'ALERTA en control #', orden, N': ', control, N' (observado=', valor_observado, N', esperado=', valor_esperado, N')')
            FROM qa.resultado_control WHERE estado <> 'OK' ORDER BY orden);
        THROW 50001, @msg, 1;
    END;
END;
GO
