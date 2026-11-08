/* =====================================================================
   06_laboratorio_tuning.sql — Experimentos antes/después (E1–E9),
   curva del punto de inflexión y auditoría de Query Store
   ---------------------------------------------------------------------
   Método de medición (perf.sp_correr_y_medir):
     1. Una ejecución de calentamiento (compila el plan y carga páginas).
     2. @corridas ejecuciones EN CALIENTE (páginas ya en memoria).
     3. @corridas ejecuciones EN FRÍO: antes de cada una, CHECKPOINT +
        DBCC DROPCLEANBUFFERS, de modo que las páginas se leen del disco.
   Cada corrida queda en perf.medicion; el informe usa la MEDIANA.

   Aviso: DBCC DROPCLEANBUFFERS vacía la caché de datos de TODA la
   instancia. Solo debe ejecutarse en una instancia de laboratorio
   (aquí, SQL Server Express local); nunca en producción.

   Lecturas lógicas, CPU, lecturas físicas y memoria concedida salen de
   sys.dm_exec_query_stats (columnas last_*) o, para procedimientos, de
   sys.dm_exec_procedure_stats, incluida la duración (last_elapsed_time,
   en microsegundos: el reloj SYSDATETIME() de Windows solo resuelve
   ~1 ms y no sirve para consultas que tardan menos que eso).
   Las consultas con OPTION (RECOMPILE) no dejan fila en esas vistas:
   para ellas se usa la diferencia de los contadores de
   sys.dm_exec_requests y el reloj de pared alrededor de la ejecución
   (ambos incluyen la compilación, que es parte del costo de RECOMPILE).
   El plan real se guarda desde
   sys.dm_exec_query_plan_stats (LAST_QUERY_PLAN_STATS = ON).
   ===================================================================== */
USE CitiBikeTuning;
GO

IF OBJECT_ID(N'perf.medicion', N'U') IS NOT NULL DROP TABLE perf.medicion;
CREATE TABLE perf.medicion
(
    codigo_experimento  VARCHAR(30)   NOT NULL,
    modo                VARCHAR(10)   NOT NULL, -- 'CALIENTE' o 'FRIO'
    corrida             INT           NOT NULL,
    duracion_us         BIGINT        NOT NULL,
    cpu_us              BIGINT        NOT NULL,
    lecturas_logicas    BIGINT        NOT NULL,
    lecturas_fisicas    BIGINT        NOT NULL,
    memoria_kb          BIGINT        NULL,     -- NULL si la consulta no deja estadísticas en caché (RECOMPILE)
    fuente_metricas     VARCHAR(20)   NOT NULL, -- query_stats, procedure_stats o requests
    filas_devueltas     BIGINT        NOT NULL,
    checksum_resultado  BIGINT        NOT NULL,
    CONSTRAINT PK_perf_medicion PRIMARY KEY (codigo_experimento, modo, corrida)
);
GO

IF OBJECT_ID(N'perf.experimento_resultado', N'U') IS NOT NULL DROP TABLE perf.experimento_resultado;
CREATE TABLE perf.experimento_resultado
(
    id_experimento          INT           NOT NULL PRIMARY KEY,
    codigo_experimento      VARCHAR(30)   NOT NULL UNIQUE,
    grupo_experimento       NVARCHAR(90)  NOT NULL,
    variante                NVARCHAR(120) NOT NULL,
    rol_comparacion         VARCHAR(20)   NOT NULL, -- ANTES, INTERMEDIO, SOLO_REESCRITURA, SOLO_INDICE, ALTERNATIVA, REFERENCIA, DESPUES
    tabla_objetivo          VARCHAR(60)   NOT NULL,
    corridas_por_modo       INT           NOT NULL,
    lecturas_logicas        BIGINT        NULL,
    cpu_ms_caliente         DECIMAL(12,3) NULL,
    duracion_ms_caliente    DECIMAL(12,3) NULL,
    duracion_ms_frio        DECIMAL(12,3) NULL,
    lecturas_fisicas_frio   BIGINT        NULL,
    memoria_kb              BIGINT        NULL,
    filas_devueltas         BIGINT        NULL,
    checksum_resultado      BIGINT        NULL,
    checksums_distintos     INT           NULL, -- entre todas las corridas: debe ser 1
    filas_estimadas_acceso  DECIMAL(16,2) NULL,
    filas_reales_acceso     BIGINT        NULL,
    operador_principal      NVARCHAR(100) NULL,
    operadores_plan         NVARCHAR(400) NULL,
    modo_ejecucion          VARCHAR(20)   NULL,
    tiene_key_lookup        BIT           NULL,
    plan_xml                XML           NULL,
    reduccion_lecturas_pct  DECIMAL(9,2)  NULL,
    speedup_caliente_x      DECIMAL(10,2) NULL,
    speedup_frio_x          DECIMAL(10,2) NULL
);
GO

IF OBJECT_ID(N'perf.curva_tipping_point', N'U') IS NOT NULL DROP TABLE perf.curva_tipping_point;
CREATE TABLE perf.curva_tipping_point
(
    id_punto                INT           NOT NULL PRIMARY KEY,
    dias_ventana            INT           NOT NULL,
    etiqueta_ventana        NVARCHAR(40)  NOT NULL,
    filas_calificadas       BIGINT        NOT NULL,
    pct_tabla               DECIMAL(8,3)  NOT NULL,
    lecturas_heap_scan      BIGINT        NOT NULL,
    lecturas_nocov_natural  BIGINT        NOT NULL,
    operador_nocov_natural  NVARCHAR(80)  NOT NULL,
    lecturas_forzado_lookup BIGINT        NOT NULL,
    lecturas_covering_seek  BIGINT        NOT NULL,
    lecturas_columnstore    BIGINT        NOT NULL
);
GO

IF OBJECT_ID(N'perf.resumen_query_store', N'U') IS NOT NULL DROP TABLE perf.resumen_query_store;
CREATE TABLE perf.resumen_query_store
(
    query_id                BIGINT        NOT NULL,
    plan_id                 BIGINT        NOT NULL,
    etiqueta_bench          VARCHAR(40)   NOT NULL,
    ejecuciones             BIGINT        NOT NULL,
    lecturas_logicas_prom   DECIMAL(16,2) NOT NULL,
    cpu_ms_prom             DECIMAL(14,3) NOT NULL,
    duracion_ms_prom        DECIMAL(14,3) NOT NULL,
    memoria_kb_prom         DECIMAL(16,2) NOT NULL,
    es_plan_forzado         BIT           NOT NULL,
    texto_consulta          NVARCHAR(400) NOT NULL
);
GO

-- Bitácora del forzado de plan con Query Store (E9)
IF OBJECT_ID(N'perf.demo_plan_forzado', N'U') IS NOT NULL DROP TABLE perf.demo_plan_forzado;
CREATE TABLE perf.demo_plan_forzado
(
    paso                    INT           NOT NULL PRIMARY KEY,
    descripcion             NVARCHAR(200) NOT NULL,
    query_id                BIGINT        NULL,
    plan_id                 BIGINT        NULL,
    tiene_key_lookup        BIT           NULL,
    es_plan_forzado         BIT           NULL,
    fallos_forzado          BIGINT        NULL
);
GO

/* ---------------------------------------------------------------------
   Procedimientos de E8: suma acumulada por estación con CURSOR vs. en conjunto
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE lab.sp_acumulado_cursor
    @cnt BIGINT OUTPUT,
    @chk BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @resultado TABLE (estacion_origen_id VARCHAR(32), fecha_dia DATE, acumulado BIGINT);
    DECLARE @est VARCHAR(32), @fecha DATE, @viajes INT, @est_prev VARCHAR(32) = NULL, @acum BIGINT = 0;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT estacion_origen_id, fecha_dia, viajes
        FROM lab.serie_diaria_estacion
        ORDER BY estacion_origen_id, fecha_dia;
    OPEN c;
    FETCH NEXT FROM c INTO @est, @fecha, @viajes;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @est_prev IS NULL OR @est <> @est_prev SET @acum = 0;
        SET @acum += @viajes;
        INSERT INTO @resultado VALUES (@est, @fecha, @acum);
        SET @est_prev = @est;
        FETCH NEXT FROM c INTO @est, @fecha, @viajes;
    END;
    CLOSE c;
    DEALLOCATE c;

    SELECT @cnt = COUNT_BIG(*), @chk = SUM(acumulado) FROM @resultado;
END;
GO

CREATE OR ALTER PROCEDURE lab.sp_acumulado_conjunto
    @cnt BIGINT OUTPUT,
    @chk BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @cnt = COUNT_BIG(*), @chk = SUM(acumulado)
    FROM (
        SELECT SUM(CAST(viajes AS BIGINT)) OVER (
                   PARTITION BY estacion_origen_id ORDER BY fecha_dia
                   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS acumulado
        FROM lab.serie_diaria_estacion
    ) AS x;
END;
GO

/* ---------------------------------------------------------------------
   Arnés de medición
   @sql_cuerpo   : consulta que empieza por SELECT y asigna @cnt y @chk (puede usar @p INT).
   @procedimiento: si se indica, @sql_cuerpo es un EXEC de ese procedimiento.
   @p_preparar   : valor con el que se compila el plan antes de medir (parameter sniffing).
   @limpiar_plan : 1 = saca de la caché el plan previo de la misma etiqueta antes de empezar.
   @etiqueta     : comentario que identifica la consulta (por defecto, el código).
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE perf.sp_correr_y_medir
    @id_experimento     INT,
    @codigo_experimento VARCHAR(30),
    @grupo_experimento  NVARCHAR(90),
    @variante           NVARCHAR(120),
    @rol_comparacion    VARCHAR(20),
    @tabla_objetivo     VARCHAR(60),
    @sql_cuerpo         NVARCHAR(MAX),
    @p                  INT = NULL,
    @p_preparar         INT = NULL,
    @limpiar_plan       BIT = 0,
    @etiqueta           VARCHAR(30) = NULL,
    @procedimiento      SYSNAME = NULL,
    @corridas           INT = 5
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tag NVARCHAR(60) = N'/*BENCH:' + CAST(ISNULL(@etiqueta, @codigo_experimento) AS NVARCHAR(30)) + N'*/';
    DECLARE @patron NVARCHAR(80) = N'%' + REPLACE(@tag, N'_', N'[_]') + N'%';
    DECLARE @sql NVARCHAR(MAX) =
        CASE WHEN @procedimiento IS NULL
             THEN STUFF(LTRIM(@sql_cuerpo), 1, 6, N'SELECT ' + @tag)
             ELSE @tag + N' ' + @sql_cuerpo
        END;
    DECLARE @def NVARCHAR(200) = N'@p INT, @cnt BIGINT OUTPUT, @chk BIGINT OUTPUT';
    DECLARE @cnt BIGINT, @chk BIGINT, @r INT, @m INT, @modo VARCHAR(10);
    DECLARE @t0 DATETIME2(7), @t1 DATETIME2(7), @desde DATETIME;
    DECLARE @lec BIGINT, @fis BIGINT, @cpu BIGINT, @mem BIGINT, @dur BIGINT, @fuente VARCHAR(20);
    DECLARE @rq_cpu BIGINT, @rq_lec BIGINT, @rq_fis BIGINT;
    DECLARE @ph VARBINARY(64);

    DELETE FROM perf.medicion WHERE codigo_experimento = @codigo_experimento;
    DELETE FROM perf.experimento_resultado WHERE codigo_experimento = @codigo_experimento;

    IF @limpiar_plan = 1
    BEGIN
        DECLARE planes CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT qs.plan_handle
            FROM sys.dm_exec_query_stats AS qs
            CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
            WHERE st.text LIKE @patron AND st.text NOT LIKE N'%dm_exec_query_stats%';
        OPEN planes;
        FETCH NEXT FROM planes INTO @ph;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DBCC FREEPROCCACHE (@ph) WITH NO_INFOMSGS;
            FETCH NEXT FROM planes INTO @ph;
        END;
        CLOSE planes;
        DEALLOCATE planes;
    END;

    -- Compilación con un valor atípico (solo en los experimentos de sniffing)
    IF @p_preparar IS NOT NULL
        EXEC sys.sp_executesql @sql, @def, @p = @p_preparar, @cnt = @cnt OUTPUT, @chk = @chk OUTPUT;

    -- Calentamiento
    EXEC sys.sp_executesql @sql, @def, @p = @p, @cnt = @cnt OUTPUT, @chk = @chk OUTPUT;

    SET @m = 1;
    WHILE @m <= 2
    BEGIN
        SET @modo = CASE @m WHEN 1 THEN 'CALIENTE' ELSE 'FRIO' END;
        SET @r = 1;
        WHILE @r <= @corridas
        BEGIN
            IF @modo = 'FRIO'
            BEGIN
                CHECKPOINT;
                DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;
            END;

            SELECT @lec = NULL, @fis = NULL, @cpu = NULL, @mem = NULL, @dur = NULL;
            -- Contadores de la propia petición: respaldo para consultas que no quedan en caché
            SELECT @rq_cpu = cpu_time, @rq_lec = logical_reads, @rq_fis = reads
            FROM sys.dm_exec_requests WHERE session_id = @@SPID;
            SET @t0 = SYSDATETIME();
            SET @desde = DATEADD(MILLISECOND, -20, CAST(@t0 AS DATETIME));
            EXEC sys.sp_executesql @sql, @def, @p = @p, @cnt = @cnt OUTPUT, @chk = @chk OUTPUT;
            SET @t1 = SYSDATETIME();

            IF @procedimiento IS NULL
                SELECT
                    @lec = SUM(qs.last_logical_reads),
                    @fis = SUM(qs.last_physical_reads),
                    @cpu = SUM(qs.last_worker_time),
                    @dur = SUM(qs.last_elapsed_time),
                    @mem = MAX(qs.last_grant_kb)
                FROM sys.dm_exec_query_stats AS qs
                CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
                WHERE st.text LIKE @patron
                  AND st.text NOT LIKE N'%dm_exec_query_stats%'
                  AND qs.last_execution_time >= @desde;
            ELSE
                SELECT
                    @lec = ps.last_logical_reads,
                    @fis = ps.last_physical_reads,
                    @cpu = ps.last_worker_time,
                    @dur = ps.last_elapsed_time,
                    @mem = 0
                FROM sys.dm_exec_procedure_stats AS ps
                WHERE ps.database_id = DB_ID()
                  AND ps.object_id = OBJECT_ID(@procedimiento);

            SET @fuente = CASE WHEN @procedimiento IS NOT NULL THEN 'procedure_stats' ELSE 'query_stats' END;
            IF @lec IS NULL
                SELECT @fuente = 'requests',
                       @cpu = (cpu_time - @rq_cpu) * 1000,
                       @lec = logical_reads - @rq_lec,
                       @fis = reads - @rq_fis
                FROM sys.dm_exec_requests WHERE session_id = @@SPID;

            INSERT INTO perf.medicion
            VALUES (@codigo_experimento, @modo, @r, ISNULL(@dur, DATEDIFF_BIG(MICROSECOND, @t0, @t1)),
                    @cpu, @lec, @fis, @mem, @fuente,
                    ISNULL(@cnt, 0), ISNULL(@chk, 0));
            SET @r += 1;
        END;
        SET @m += 1;
    END;

    -- Plan real de la última ejecución (o, si no está en caché, el plan registrado en Query Store)
    DECLARE @plan XML = NULL;
    IF @procedimiento IS NULL
        SELECT TOP (1) @plan = ps.query_plan
        FROM sys.dm_exec_query_stats AS qs
        CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
        CROSS APPLY sys.dm_exec_query_plan_stats(qs.plan_handle) AS ps
        WHERE st.text LIKE @patron AND st.text NOT LIKE N'%dm_exec_query_stats%'
        ORDER BY qs.last_execution_time DESC;
    ELSE
        SELECT TOP (1) @plan = ps.query_plan
        FROM sys.dm_exec_procedure_stats AS pr
        CROSS APPLY sys.dm_exec_query_plan_stats(pr.plan_handle) AS ps
        WHERE pr.database_id = DB_ID() AND pr.object_id = OBJECT_ID(@procedimiento);

    IF @plan IS NULL
        SELECT TOP (1) @plan = TRY_CAST(p.query_plan AS XML)
        FROM sys.query_store_query AS q
        JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
        JOIN sys.query_store_plan AS p ON p.query_id = q.query_id
        WHERE qt.query_sql_text LIKE @patron
        ORDER BY p.last_execution_time DESC;

    ;WITH med AS
    (
        SELECT DISTINCT
            PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CASE WHEN modo = 'CALIENTE' THEN lecturas_logicas END) OVER () AS lec,
            PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CASE WHEN modo = 'CALIENTE' THEN cpu_us END) OVER () AS cpu_c,
            PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CASE WHEN modo = 'CALIENTE' THEN duracion_us END) OVER () AS dur_c,
            PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CASE WHEN modo = 'FRIO' THEN duracion_us END) OVER () AS dur_f,
            PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CASE WHEN modo = 'FRIO' THEN lecturas_fisicas END) OVER () AS fis_f,
            MAX(memoria_kb) OVER () AS mem,
            MAX(filas_devueltas) OVER () AS filas,
            MAX(checksum_resultado) OVER () AS chk
        FROM perf.medicion
        WHERE codigo_experimento = @codigo_experimento
    )
    INSERT INTO perf.experimento_resultado
    (
        id_experimento, codigo_experimento, grupo_experimento, variante, rol_comparacion, tabla_objetivo,
        corridas_por_modo, lecturas_logicas, cpu_ms_caliente, duracion_ms_caliente, duracion_ms_frio,
        lecturas_fisicas_frio, memoria_kb, filas_devueltas, checksum_resultado, checksums_distintos, plan_xml
    )
    SELECT
        @id_experimento, @codigo_experimento, @grupo_experimento, @variante, @rol_comparacion, @tabla_objetivo,
        @corridas,
        CAST(ROUND(lec, 0) AS BIGINT),
        CAST(cpu_c / 1000.0 AS DECIMAL(12,3)),
        CAST(dur_c / 1000.0 AS DECIMAL(12,3)),
        CAST(dur_f / 1000.0 AS DECIMAL(12,3)),
        CAST(ROUND(fis_f, 0) AS BIGINT),
        mem, filas, chk,
        (SELECT COUNT(DISTINCT CONCAT(filas_devueltas, '|', checksum_resultado))
         FROM perf.medicion WHERE codigo_experimento = @codigo_experimento),
        @plan
    FROM med;

    -- Lectura del plan: operador de acceso principal, operadores presentes y modo de ejecución
    DECLARE @ops TABLE (op NVARCHAR(60), nodo INT);
    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    INSERT INTO @ops (op, nodo)
    SELECT n.value('@PhysicalOp', 'NVARCHAR(60)'), n.value('@NodeId', 'INT')
    FROM @plan.nodes('//RelOp') AS t(n);

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    UPDATE r
    SET
        operador_principal = CASE
            WHEN @procedimiento = N'lab.sp_acumulado_cursor' THEN N'Cursor FAST_FORWARD (fila a fila)'
            WHEN @plan IS NULL THEN N'(sin plan)'
            ELSE
                CASE
                    WHEN @plan.exist('//RelOp[@PhysicalOp="Columnstore Index Scan"]') = 1
                      OR @plan.exist('//IndexScan[@Storage="ColumnStore"]') = 1 THEN N'Columnstore Index Scan'
                    WHEN @plan.exist('//RelOp[@PhysicalOp="Table Scan"]') = 1
                     AND @plan.exist('//RelOp[@PhysicalOp="Nested Loops"]') = 1 THEN N'Table Scan (heap) por cada estación'
                    WHEN @plan.exist('//RelOp[@PhysicalOp="Table Scan"]') = 1 THEN N'Table Scan (heap)'
                    WHEN @plan.exist('//IndexScan[@Lookup="1"]') = 1 THEN N'Index Seek + Key Lookup'
                    WHEN @plan.exist('//RelOp[@PhysicalOp="Hash Match" and @LogicalOp="Inner Join"]') = 1
                     AND @plan.exist('//RelOp[@PhysicalOp="Clustered Index Scan" or @PhysicalOp="Clustered Index Seek"]') = 0 THEN N'Intersección de 2 índices (Hash Match)'
                    WHEN @plan.exist('//RelOp[@PhysicalOp="Nested Loops"]') = 1
                     AND @plan.exist('//RelOp[@PhysicalOp="Clustered Index Scan"]') = 1
                     AND @plan.exist('//RelOp[@PhysicalOp="Clustered Index Seek"]') = 1 THEN N'Clustered Index Scan + Seek por fila (Nested Loops)'
                    WHEN @plan.exist('//RelOp[@PhysicalOp="Index Seek"]') = 1
                     AND @plan.exist('//RelOp[@PhysicalOp="Top"]') = 1 THEN N'Index Seek + Top (10) por estación'
                    WHEN @plan.exist('//RelOp[@PhysicalOp="Clustered Index Scan"]') = 1 THEN N'Clustered Index Scan'
                    WHEN @plan.exist('//RelOp[@PhysicalOp="Index Scan"]') = 1 THEN N'Index Scan'
                    WHEN @plan.exist('//RelOp[@PhysicalOp="Clustered Index Seek"]') = 1 THEN N'Clustered Index Seek'
                    WHEN @plan.exist('//RelOp[@PhysicalOp="Index Seek"]') = 1 THEN N'Index Seek'
                    ELSE ISNULL(@plan.value('(//RelOp/@PhysicalOp)[1]', 'NVARCHAR(100)'), N'(sin plan)')
                END
                + CASE WHEN @plan.exist('//IndexScan/Object[contains(@Index, "IX_filt")]') = 1 THEN N' del índice filtrado' ELSE N'' END
                + CASE WHEN @plan.exist('//RelOp[@PhysicalOp="Sort"]') = 1 THEN N' + Sort' ELSE N'' END
                + CASE WHEN @plan.exist('//RelOp[@PhysicalOp="Window Spool"]') = 1 THEN N' + Window Spool' ELSE N'' END
        END,
        operadores_plan = (
            SELECT STRING_AGG(op, N', ') WITHIN GROUP (ORDER BY primera_aparicion)
            FROM (
                SELECT op, MIN(nodo) AS primera_aparicion
                FROM @ops
                GROUP BY op
            ) AS ops
        ),
        modo_ejecucion = CASE
            WHEN @plan.exist('//RunTimeCountersPerThread[@ActualExecutionMode="Batch"]') = 1
              OR @plan.exist('//RelOp[@EstimatedExecutionMode="Batch"]') = 1 THEN 'Batch'
            WHEN @plan IS NULL THEN NULL
            ELSE 'Row'
        END,
        tiene_key_lookup = CASE WHEN @plan.exist('//IndexScan[@Lookup="1"]') = 1 THEN 1 ELSE 0 END,
        filas_estimadas_acceso = @plan.value('(//RelOp[not(descendant::RelOp)]/@EstimateRows)[1]', 'FLOAT'),
        filas_reales_acceso = @plan.value('sum((//RelOp[not(descendant::RelOp)])[1]/RunTimeInformation/RunTimeCountersPerThread/@ActualRows)', 'FLOAT')
    FROM perf.experimento_resultado AS r
    WHERE r.codigo_experimento = @codigo_experimento;
END;
GO

CREATE OR ALTER PROCEDURE perf.sp_ejecutar_laboratorio
    @corridas INT = 5
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 DATETIME2(3) = SYSDATETIME();

    TRUNCATE TABLE perf.medicion;
    TRUNCATE TABLE perf.experimento_resultado;
    TRUNCATE TABLE perf.curva_tipping_point;
    TRUNCATE TABLE perf.resumen_query_store;
    TRUNCATE TABLE perf.demo_plan_forzado;

    ALTER DATABASE CitiBikeTuning SET QUERY_STORE CLEAR;
    DBCC FREEPROCCACHE WITH NO_INFOMSGS;

    -- Estación con más salidas y las 10 / 8 más activas (se eligen desde los datos, no a mano)
    DECLARE @est_top VARCHAR(32);
    DECLARE @top10 NVARCHAR(MAX), @top8 NVARCHAR(MAX), @top10_values NVARCHAR(MAX);

    ;WITH ranking AS
    (
        SELECT estacion_origen_id, ROW_NUMBER() OVER (ORDER BY COUNT_BIG(*) DESC, estacion_origen_id) AS rk
        FROM lab.viaje_rowstore
        GROUP BY estacion_origen_id
    )
    SELECT
        @est_top      = MAX(CASE WHEN rk = 1 THEN estacion_origen_id END),
        @top10        = STRING_AGG(CASE WHEN rk <= 10 THEN '''' + estacion_origen_id + '''' END, ',') WITHIN GROUP (ORDER BY rk),
        @top8         = STRING_AGG(CASE WHEN rk <= 8  THEN '''' + estacion_origen_id + '''' END, ',') WITHIN GROUP (ORDER BY rk),
        @top10_values = STRING_AGG(CASE WHEN rk <= 10 THEN '(''' + estacion_origen_id + ''')' END, ',') WITHIN GROUP (ORDER BY rk)
    FROM ranking
    WHERE rk <= 10;

    DECLARE @q NVARCHAR(MAX);
    DECLARE @chk_e1 NVARCHAR(200) = N'@cnt = COUNT_BIG(*), @chk = ISNULL(SUM(CAST(duracion_seg AS BIGINT)) + SUM(CAST(distancia_m AS BIGINT)), 0)';

    /* =================================================================
       E1 · Estación más activa en marzo: Heap vs. índice no cubriente vs. cubriente
       ================================================================= */
    SET @q = N'SELECT ' + @chk_e1 + N' FROM lab.viaje_heap
               WHERE estacion_origen_id = ''' + @est_top + N''' AND fecha_inicio >= ''2024-03-01'' AND fecha_inicio < ''2024-04-01'';';
    EXEC perf.sp_correr_y_medir 1, 'E1_A_HEAP', N'E1 · Estación más activa en marzo',
        N'Heap sin índices', 'ANTES', 'lab.viaje_heap', @q, @corridas = @corridas;

    SET @q = N'SELECT ' + @chk_e1 + N' FROM lab.viaje_rowstore_nocov WITH (INDEX(IX_nocov_origen_fecha))
               WHERE estacion_origen_id = ''' + @est_top + N''' AND fecha_inicio >= ''2024-03-01'' AND fecha_inicio < ''2024-04-01'';';
    EXEC perf.sp_correr_y_medir 2, 'E1_B_KEYLOOKUP', N'E1 · Estación más activa en marzo',
        N'Índice no cubriente (forzado con INDEX())', 'INTERMEDIO', 'lab.viaje_rowstore_nocov', @q, @corridas = @corridas;

    SET @q = N'SELECT ' + @chk_e1 + N' FROM lab.viaje_rowstore
               WHERE estacion_origen_id = ''' + @est_top + N''' AND fecha_inicio >= ''2024-03-01'' AND fecha_inicio < ''2024-04-01'';';
    EXEC perf.sp_correr_y_medir 3, 'E1_C_COVERING', N'E1 · Estación más activa en marzo',
        N'Índice cubriente con INCLUDE', 'DESPUES', 'lab.viaje_rowstore', @q, @corridas = @corridas;

    /* =================================================================
       E2 · SARGability (1 semana): diseño 2×2 para aislar índice y reescritura
       ================================================================= */
    DECLARE @pred_fn NVARCHAR(200) = N'YEAR(fecha_inicio) = 2024 AND MONTH(fecha_inicio) = 3 AND DAY(fecha_inicio) BETWEEN 4 AND 10';
    DECLARE @pred_rg NVARCHAR(200) = N'fecha_inicio >= ''2024-03-04'' AND fecha_inicio < ''2024-03-11''';
    -- distancia_m no está en ningún índice secundario: todas las variantes necesitan la tabla completa
    DECLARE @sel_e2 NVARCHAR(400) = N'SELECT ' + @chk_e1 + N' FROM ';

    SET @q = @sel_e2 + N'lab.viaje_heap WHERE ' + @pred_fn + N';';
    EXEC perf.sp_correr_y_medir 4, 'E2_A_HEAP_FUNCION', N'E2 · Filtro de una semana (SARGability)',
        N'Heap + YEAR()/MONTH()/DAY()', 'ANTES', 'lab.viaje_heap', @q, @corridas = @corridas;

    SET @q = @sel_e2 + N'lab.viaje_heap WHERE ' + @pred_rg + N';';
    EXEC perf.sp_correr_y_medir 5, 'E2_B_HEAP_RANGO', N'E2 · Filtro de una semana (SARGability)',
        N'Solo reescritura: Heap + rango >= / <', 'SOLO_REESCRITURA', 'lab.viaje_heap', @q, @corridas = @corridas;

    SET @q = @sel_e2 + N'lab.viaje_rowstore_nocov WHERE ' + @pred_fn + N';';
    EXEC perf.sp_correr_y_medir 6, 'E2_C_INDICE_FUNCION', N'E2 · Filtro de una semana (SARGability)',
        N'Solo índice: agrupado por fecha + YEAR()/MONTH()/DAY()', 'SOLO_INDICE', 'lab.viaje_rowstore_nocov', @q, @corridas = @corridas;

    SET @q = @sel_e2 + N'lab.viaje_rowstore_nocov WHERE ' + @pred_rg + N';';
    EXEC perf.sp_correr_y_medir 7, 'E2_D_INDICE_RANGO', N'E2 · Filtro de una semana (SARGability)',
        N'Ambos: agrupado por fecha + rango >= / <', 'DESPUES', 'lab.viaje_rowstore_nocov', @q, @corridas = @corridas;

    /* =================================================================
       E3 · Agregación del trimestre completo: Heap vs. Rowstore vs. Columnstore
       ================================================================= */
    DECLARE @agg NVARCHAR(400) = N'SELECT @cnt = COUNT_BIG(*), @chk = ISNULL(SUM(viajes_grupo) + SUM(suma_dur), 0)
               FROM (SELECT mes, hora, es_electrica, es_miembro, COUNT_BIG(*) AS viajes_grupo, SUM(CAST(duracion_seg AS BIGINT)) AS suma_dur
                     FROM {T} GROUP BY mes, hora, es_electrica, es_miembro) AS g;';
    SET @q = REPLACE(@agg, N'{T}', N'lab.viaje_heap');
    EXEC perf.sp_correr_y_medir 8, 'E3_A_AGG_HEAP', N'E3 · Agregación del trimestre completo',
        N'Heap (modo fila)', 'ANTES', 'lab.viaje_heap', @q, @corridas = @corridas;
    SET @q = REPLACE(@agg, N'{T}', N'lab.viaje_rowstore_nocov');
    EXEC perf.sp_correr_y_medir 9, 'E3_B_AGG_ROWSTORE', N'E3 · Agregación del trimestre completo',
        N'Rowstore con índice agrupado', 'INTERMEDIO', 'lab.viaje_rowstore_nocov', @q, @corridas = @corridas;
    SET @q = REPLACE(@agg, N'{T}', N'lab.viaje_columnstore');
    EXEC perf.sp_correr_y_medir 10, 'E3_C_AGG_CCI', N'E3 · Agregación del trimestre completo',
        N'Clustered Columnstore (CCI)', 'DESPUES', 'lab.viaje_columnstore', @q, @corridas = @corridas;

    /* =================================================================
       E4 · Índice filtrado: viajes de ocasionales de 30 min o más
       ================================================================= */
    DECLARE @e4 NVARCHAR(400) = N'SELECT ' + @chk_e1 + N' FROM {T}
               WHERE es_miembro = 0 AND duracion_seg >= 1800;';
    SET @q = REPLACE(@e4, N'{T}', N'lab.viaje_rowstore_nocov');
    EXEC perf.sp_correr_y_medir 11, 'E4_A_SIN_FILTRADO', N'E4 · Índice filtrado (ocasionales >= 30 min)',
        N'Sin índice filtrado', 'ANTES', 'lab.viaje_rowstore_nocov', @q, @corridas = @corridas;
    SET @q = REPLACE(@e4, N'{T}', N'lab.viaje_rowstore WITH (INDEX(IX_filt_casual_largo))');
    EXEC perf.sp_correr_y_medir 12, 'E4_B_CON_FILTRADO', N'E4 · Índice filtrado (ocasionales >= 30 min)',
        N'Índice filtrado WHERE es_miembro = 0 AND duracion_seg >= 1800', 'DESPUES', 'lab.viaje_rowstore', @q, @corridas = @corridas;

    /* =================================================================
       E5 · Parameter sniffing: "viajes de al menos @p segundos"
       El plan se compila con @p = 80.000 s (casi ninguna fila) y luego se
       ejecuta con @p = 1.200 s (20 min), que devuelve cientos de miles de filas.
       ================================================================= */
    DECLARE @e5 NVARCHAR(400) = N'SELECT ' + @chk_e1 + N' FROM lab.viaje_rowstore_nocov WHERE duracion_seg >= @p';
    SET @q = @e5 + N';';
    EXEC perf.sp_correr_y_medir 13, 'E5_A_SNIFF_MALO', N'E5 · Parameter sniffing (duración mínima)',
        N'Plan compilado para @p = 80.000 y reutilizado con @p = 1.200', 'ANTES', 'lab.viaje_rowstore_nocov', @q,
        @p = 1200, @p_preparar = 80000, @corridas = @corridas;
    SET @q = @e5 + N' OPTION (RECOMPILE);';
    EXEC perf.sp_correr_y_medir 14, 'E5_B_RECOMPILE', N'E5 · Parameter sniffing (duración mínima)',
        N'OPTION (RECOMPILE): plan nuevo en cada ejecución', 'DESPUES', 'lab.viaje_rowstore_nocov', @q,
        @p = 1200, @p_preparar = 80000, @corridas = @corridas;
    SET @q = @e5 + N' OPTION (OPTIMIZE FOR UNKNOWN);';
    EXEC perf.sp_correr_y_medir 15, 'E5_C_OPTIMIZE_UNKNOWN', N'E5 · Parameter sniffing (duración mínima)',
        N'OPTION (OPTIMIZE FOR UNKNOWN): plan para un valor promedio', 'ALTERNATIVA', 'lab.viaje_rowstore_nocov', @q,
        @p = 1200, @p_preparar = 80000, @corridas = @corridas;

    /* =================================================================
       E6 · Media móvil de 7 días por estación (serie diaria densa)
       ================================================================= */
    SET @q = N'SELECT @cnt = COUNT_BIG(*), @chk = SUM(CAST(ROUND(media_movil_7d * 1000, 0) AS BIGINT))
               FROM (
                   SELECT r1.estacion_origen_id, r1.fecha_dia,
                       (SELECT AVG(CAST(r2.viajes AS DECIMAL(12,4)))
                        FROM lab.serie_diaria_estacion AS r2
                        WHERE r2.estacion_origen_id = r1.estacion_origen_id
                          AND r2.fecha_dia BETWEEN DATEADD(DAY, -6, r1.fecha_dia) AND r1.fecha_dia) AS media_movil_7d
                   FROM lab.serie_diaria_estacion AS r1
               ) AS sub;';
    EXEC perf.sp_correr_y_medir 16, 'E6_A_SUBQUERY_CORR', N'E6 · Media móvil de 7 días por estación',
        N'Subconsulta correlacionada', 'ANTES', 'lab.serie_diaria_estacion', @q, @corridas = @corridas;

    SET @q = N'SELECT @cnt = COUNT_BIG(*), @chk = SUM(CAST(ROUND(media_movil_7d * 1000, 0) AS BIGINT))
               FROM (
                   SELECT r1.estacion_origen_id, r1.fecha_dia,
                       AVG(CAST(r1.viajes AS DECIMAL(12,4))) OVER (
                           PARTITION BY r1.estacion_origen_id ORDER BY r1.fecha_dia
                           ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS media_movil_7d
                   FROM lab.serie_diaria_estacion AS r1
               ) AS win;';
    EXEC perf.sp_correr_y_medir 17, 'E6_B_WINDOW_FUNC', N'E6 · Media móvil de 7 días por estación',
        N'Función de ventana AVG() OVER (ROWS 6 PRECEDING)', 'DESPUES', 'lab.serie_diaria_estacion', @q, @corridas = @corridas;

    /* =================================================================
       E7 · Últimos 10 viajes de las 10 estaciones más activas: diseño 2×2
       ================================================================= */
    DECLARE @rn NVARCHAR(MAX) = N'SELECT @cnt = COUNT_BIG(*), @chk = ISNULL(SUM(CAST(duracion_seg AS BIGINT) * 7 + id_viaje % 1000), 0)
               FROM (
                   SELECT id_viaje, duracion_seg,
                       ROW_NUMBER() OVER (PARTITION BY estacion_origen_id ORDER BY fecha_inicio DESC, id_viaje DESC) AS rn
                   FROM {T}
                   WHERE estacion_origen_id IN (' + @top10 + N')
               ) AS x WHERE x.rn <= 10;';
    DECLARE @ap NVARCHAR(MAX) = N'SELECT @cnt = COUNT_BIG(*), @chk = ISNULL(SUM(CAST(ult.duracion_seg AS BIGINT) * 7 + ult.id_viaje % 1000), 0)
               FROM (VALUES ' + @top10_values + N') AS est(id)
               CROSS APPLY (
                   SELECT TOP (10) v.id_viaje, v.duracion_seg
                   FROM {T} AS v
                   WHERE v.estacion_origen_id = est.id
                   ORDER BY v.fecha_inicio DESC, v.id_viaje DESC
               ) AS ult;';
    SET @q = REPLACE(@rn, N'{T}', N'lab.viaje_heap');
    EXEC perf.sp_correr_y_medir 18, 'E7_A_HEAP_ROWNUMBER', N'E7 · Últimos 10 viajes de 10 estaciones',
        N'Heap + ROW_NUMBER()', 'ANTES', 'lab.viaje_heap', @q, @corridas = @corridas;
    SET @q = REPLACE(@ap, N'{T}', N'lab.viaje_heap');
    EXEC perf.sp_correr_y_medir 19, 'E7_B_HEAP_APPLY', N'E7 · Últimos 10 viajes de 10 estaciones',
        N'Solo reescritura: Heap + CROSS APPLY TOP (10)', 'SOLO_REESCRITURA', 'lab.viaje_heap', @q, @corridas = @corridas;
    SET @q = REPLACE(@rn, N'{T}', N'lab.viaje_rowstore');
    EXEC perf.sp_correr_y_medir 20, 'E7_C_INDICE_ROWNUMBER', N'E7 · Últimos 10 viajes de 10 estaciones',
        N'Solo índice: (estación, fecha) + ROW_NUMBER()', 'SOLO_INDICE', 'lab.viaje_rowstore', @q, @corridas = @corridas;
    SET @q = REPLACE(@ap, N'{T}', N'lab.viaje_rowstore');
    EXEC perf.sp_correr_y_medir 21, 'E7_D_INDICE_APPLY', N'E7 · Últimos 10 viajes de 10 estaciones',
        N'Ambos: (estación, fecha) + CROSS APPLY TOP (10)', 'DESPUES', 'lab.viaje_rowstore', @q, @corridas = @corridas;

    /* =================================================================
       E8 · Suma acumulada por estación: cursor fila a fila vs. operación en conjunto
       ================================================================= */
    EXEC perf.sp_correr_y_medir 22, 'E8_A_CURSOR', N'E8 · Suma acumulada por estación y día',
        N'Cursor FAST_FORWARD fila a fila', 'ANTES', 'lab.serie_diaria_estacion',
        N'EXEC lab.sp_acumulado_cursor @cnt = @cnt OUTPUT, @chk = @chk OUTPUT;',
        @procedimiento = N'lab.sp_acumulado_cursor', @corridas = @corridas;
    EXEC perf.sp_correr_y_medir 23, 'E8_B_CONJUNTO', N'E8 · Suma acumulada por estación y día',
        N'SUM() OVER (ROWS UNBOUNDED PRECEDING) en una sola consulta', 'DESPUES', 'lab.serie_diaria_estacion',
        N'EXEC lab.sp_acumulado_conjunto @cnt = @cnt OUTPUT, @chk = @chk OUTPUT;',
        @procedimiento = N'lab.sp_acumulado_conjunto', @corridas = @corridas;

    /* =================================================================
       E9 · Regresión provocada y plan forzado con Query Store
       Las tres variantes usan EXACTAMENTE el mismo texto (etiqueta E9_QS),
       así Query Store las agrupa en un único query_id.
       ================================================================= */
    SET @q = @e5 + N';';
    -- A. Plan compilado con el valor típico (@p = 1.200): es el plan "bueno"
    EXEC perf.sp_correr_y_medir 24, 'E9_A_PLAN_ORIGINAL', N'E9 · Regresión y plan forzado (Query Store)',
        N'Plan original compilado con @p = 1.200', 'REFERENCIA', 'lab.viaje_rowstore_nocov', @q,
        @p = 1200, @limpiar_plan = 1, @etiqueta = 'E9_QS', @corridas = @corridas;
    -- B. Regresión: el plan sale de caché y se recompila con @p = 80.000
    EXEC perf.sp_correr_y_medir 25, 'E9_B_REGRESION', N'E9 · Regresión y plan forzado (Query Store)',
        N'Regresión: plan recompilado con @p = 80.000', 'ANTES', 'lab.viaje_rowstore_nocov', @q,
        @p = 1200, @p_preparar = 80000, @limpiar_plan = 1, @etiqueta = 'E9_QS', @corridas = @corridas;

    EXEC sys.sp_query_store_flush_db;
    DECLARE @qid BIGINT, @plan_bueno BIGINT, @plan_malo BIGINT;
    SELECT TOP (1) @qid = q.query_id
    FROM sys.query_store_query AS q
    JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
    WHERE qt.query_sql_text LIKE N'%/*BENCH:E9[_]QS*/%'
    ORDER BY q.query_id;

    SELECT TOP (1) @plan_bueno = plan_id FROM sys.query_store_plan
    WHERE query_id = @qid AND CAST(query_plan AS NVARCHAR(MAX)) NOT LIKE N'%Lookup="1"%' ORDER BY plan_id;
    SELECT TOP (1) @plan_malo = plan_id FROM sys.query_store_plan
    WHERE query_id = @qid AND CAST(query_plan AS NVARCHAR(MAX)) LIKE N'%Lookup="1"%' ORDER BY plan_id;

    INSERT INTO perf.demo_plan_forzado (paso, descripcion, query_id, plan_id, tiene_key_lookup, es_plan_forzado, fallos_forzado)
    SELECT 1, N'Plan original (compilado con @p = 1.200)', @qid, @plan_bueno, 0, 0, NULL
    UNION ALL
    SELECT 2, N'Plan de la regresión (compilado con @p = 80.000)', @qid, @plan_malo, 1, 0, NULL;

    -- C. Se fuerza el plan original y se repite la misma secuencia que causó la regresión
    IF @qid IS NOT NULL AND @plan_bueno IS NOT NULL
        EXEC sys.sp_query_store_force_plan @query_id = @qid, @plan_id = @plan_bueno;

    EXEC perf.sp_correr_y_medir 26, 'E9_C_PLAN_FORZADO', N'E9 · Regresión y plan forzado (Query Store)',
        N'sp_query_store_force_plan: plan original forzado', 'DESPUES', 'lab.viaje_rowstore_nocov', @q,
        @p = 1200, @p_preparar = 80000, @limpiar_plan = 1, @etiqueta = 'E9_QS', @corridas = @corridas;

    EXEC sys.sp_query_store_flush_db;
    INSERT INTO perf.demo_plan_forzado (paso, descripcion, query_id, plan_id, tiene_key_lookup, es_plan_forzado, fallos_forzado)
    SELECT TOP (1) 3, N'Plan usado tras forzar (recompilado otra vez con @p = 80.000)', p.query_id, p.plan_id,
           CASE WHEN CAST(p.query_plan AS NVARCHAR(MAX)) LIKE N'%Lookup="1"%' THEN 1 ELSE 0 END,
           p.is_forced_plan, p.force_failure_count
    FROM sys.query_store_plan AS p
    WHERE p.query_id = @qid
    ORDER BY p.last_execution_time DESC;

    -- Speedups y reducción de lecturas respecto a la variante ANTES de cada grupo
    ;WITH base AS
    (
        SELECT grupo_experimento,
               NULLIF(lecturas_logicas, 0) AS lec_antes,
               NULLIF(duracion_ms_caliente, 0) AS dur_c_antes,
               NULLIF(duracion_ms_frio, 0) AS dur_f_antes
        FROM perf.experimento_resultado
        WHERE rol_comparacion = 'ANTES'
    )
    UPDATE r
    SET r.reduccion_lecturas_pct = CAST(ROUND((1.0 - CAST(r.lecturas_logicas AS FLOAT) / b.lec_antes) * 100.0, 2) AS DECIMAL(9,2)),
        r.speedup_caliente_x = CAST(ROUND(b.dur_c_antes / NULLIF(r.duracion_ms_caliente, 0), 2) AS DECIMAL(10,2)),
        r.speedup_frio_x = CAST(ROUND(b.dur_f_antes / NULLIF(r.duracion_ms_frio, 0), 2) AS DECIMAL(10,2))
    FROM perf.experimento_resultado AS r
    JOIN base AS b ON b.grupo_experimento = r.grupo_experimento;

    /* =================================================================
       Curva del punto de inflexión (tipping point): 8 estaciones más
       activas y ventanas de 1 a 91 días desde el 1 de enero.
       Se mide solo lecturas lógicas (son deterministas): 1 ejecución.
       ================================================================= */
    DECLARE @total_filas FLOAT = (SELECT CAST(COUNT_BIG(*) AS FLOAT) FROM lab.viaje_rowstore);
    DECLARE @ventanas TABLE (id INT, dias INT, etiqueta NVARCHAR(40));
    INSERT INTO @ventanas VALUES
        (1, 1, N'1 día'), (2, 7, N'7 días'), (3, 14, N'14 días'),
        (4, 30, N'30 días'), (5, 60, N'60 días'), (6, 91, N'91 días (trimestre)');

    DECLARE @vid INT = 1, @vdias INT, @vetiq NVARCHAR(40), @vfin NVARCHAR(20), @f BIGINT, @s BIGINT;
    DECLARE @v INT, @tag NVARCHAR(40), @tabla NVARCHAR(120);
    DECLARE @lect TABLE (v INT, lecturas BIGINT, op NVARCHAR(80));
    WHILE @vid <= 6
    BEGIN
        SELECT @vdias = dias, @vetiq = etiqueta FROM @ventanas WHERE id = @vid;
        SET @vfin = CONVERT(NVARCHAR(10), DATEADD(DAY, @vdias, CAST('2024-01-01' AS DATE)), 23);
        DELETE FROM @lect;
        SET @v = 1;
        WHILE @v <= 5
        BEGIN
            SET @tag = N'/*TP_' + CAST(@vid AS NVARCHAR(2)) + N'_' + CAST(@v AS NVARCHAR(2)) + N'*/';
            SET @tabla = CASE @v
                WHEN 1 THEN N'lab.viaje_heap'
                WHEN 2 THEN N'lab.viaje_rowstore_nocov'
                WHEN 3 THEN N'lab.viaje_rowstore_nocov WITH (INDEX(IX_nocov_origen_fecha))'
                WHEN 4 THEN N'lab.viaje_rowstore'
                ELSE N'lab.viaje_columnstore' END;
            SET @q = @tag + N' SELECT @f = COUNT_BIG(*), @s = SUM(CAST(duracion_seg AS BIGINT)) FROM ' + @tabla
                   + N' WHERE estacion_origen_id IN (' + @top8 + N') AND fecha_inicio >= ''2024-01-01'' AND fecha_inicio < ''' + @vfin + N''';';
            EXEC sys.sp_executesql @q, N'@f BIGINT OUTPUT, @s BIGINT OUTPUT', @f = @f OUTPUT, @s = @s OUTPUT;

            ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
            INSERT INTO @lect (v, lecturas, op)
            SELECT TOP (1) @v, qs.last_logical_reads,
                   CASE WHEN qp.query_plan.exist('//IndexScan[@Lookup="1"]') = 1 THEN N'Index Seek + Key Lookup'
                        WHEN qp.query_plan.exist('//RelOp[@PhysicalOp="Hash Match" and @LogicalOp="Inner Join"]') = 1
                         AND qp.query_plan.exist('//RelOp[@PhysicalOp="Clustered Index Scan" or @PhysicalOp="Clustered Index Seek"]') = 0 THEN N'Intersección de 2 índices'
                        WHEN qp.query_plan.exist('//RelOp[@PhysicalOp="Clustered Index Seek"]') = 1 THEN N'Clustered Index Seek (rango de fechas)'
                        WHEN qp.query_plan.exist('//RelOp[@PhysicalOp="Clustered Index Scan"]') = 1 THEN N'Clustered Index Scan'
                        ELSE ISNULL(qp.query_plan.value('(//RelOp/@PhysicalOp)[1]', 'NVARCHAR(80)'), N'') END
            FROM sys.dm_exec_query_stats AS qs
            CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
            CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
            WHERE st.text LIKE N'%' + REPLACE(@tag, N'_', N'[_]') + N'%' AND st.text NOT LIKE N'%dm_exec%'
            ORDER BY qs.last_execution_time DESC;
            SET @v += 1;
        END;

        INSERT INTO perf.curva_tipping_point
        SELECT @vid, @vdias, @vetiq, @f, CAST(ROUND(@f / @total_filas * 100.0, 3) AS DECIMAL(8,3)),
               (SELECT lecturas FROM @lect WHERE v = 1),
               (SELECT lecturas FROM @lect WHERE v = 2),
               (SELECT op FROM @lect WHERE v = 2),
               (SELECT lecturas FROM @lect WHERE v = 3),
               (SELECT lecturas FROM @lect WHERE v = 4),
               (SELECT lecturas FROM @lect WHERE v = 5);
        SET @vid += 1;
    END;

    -- Resumen de Query Store (antes de quitar el forzado, para que quede registrado)
    EXEC sys.sp_query_store_flush_db;
    INSERT INTO perf.resumen_query_store
    SELECT
        q.query_id,
        p.plan_id,
        SUBSTRING(qt.query_sql_text,
                  CHARINDEX('/*BENCH:', qt.query_sql_text) + 8,
                  CHARINDEX('*/', qt.query_sql_text, CHARINDEX('/*BENCH:', qt.query_sql_text)) - (CHARINDEX('/*BENCH:', qt.query_sql_text) + 8)),
        SUM(rs.count_executions),
        CAST(SUM(rs.avg_logical_io_reads * rs.count_executions) / SUM(rs.count_executions) AS DECIMAL(16,2)),
        CAST(SUM(rs.avg_cpu_time * rs.count_executions) / SUM(rs.count_executions) / 1000.0 AS DECIMAL(14,3)),
        CAST(SUM(rs.avg_duration * rs.count_executions) / SUM(rs.count_executions) / 1000.0 AS DECIMAL(14,3)),
        CAST(SUM(rs.avg_query_max_used_memory * rs.count_executions) / SUM(rs.count_executions) * 8.0 AS DECIMAL(16,2)),
        p.is_forced_plan,
        LEFT(LTRIM(qt.query_sql_text), 400)
    FROM sys.query_store_query AS q
    JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
    JOIN sys.query_store_plan AS p ON p.query_id = q.query_id
    JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
    WHERE qt.query_sql_text LIKE N'%/*BENCH:%*/%'
      AND qt.query_sql_text NOT LIKE N'%sys.query_store%'
      AND qt.query_sql_text NOT LIKE N'%CREATE OR ALTER%'
    GROUP BY q.query_id, p.plan_id, p.is_forced_plan, qt.query_sql_text;

    -- Se deja la base sin planes forzados para que una nueva corrida empiece igual
    IF @qid IS NOT NULL AND @plan_bueno IS NOT NULL
        EXEC sys.sp_query_store_unforce_plan @query_id = @qid, @plan_id = @plan_bueno;

    INSERT INTO etl.bitacora_carga (etapa, filas_afectadas, duracion_ms)
    VALUES (N'BENCHMARK_LABORATORIO_TUNING', (SELECT COUNT(*) FROM perf.experimento_resultado), DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
END;
GO
