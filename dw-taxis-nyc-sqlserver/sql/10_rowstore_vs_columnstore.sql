/* =====================================================================
   10_rowstore_vs_columnstore.sql
   Laboratorio: el mismo hecho (todas las filas) guardado de tres formas, comparado en
   espacio y en tiempo con 6 consultas típicas de BI, en frío y en caliente.

     COLUMNSTORE        dw.fact_viaje (índice columnstore agrupado ordenado, particionado por mes)
     ROWSTORE           lab.fact_viaje_rowstore (índice agrupado B-tree en fecha_key, fila_origen; sin compresión)
     ROWSTORE PAGE      la misma tabla reconstruida con DATA_COMPRESSION = PAGE

   Para no duplicar 4 GB dos veces, la copia rowstore se mide, se reconstruye con PAGE,
   se vuelve a medir y al final se borra (@conservar_copia = 0). Los resultados quedan en
   lab.espacio_almacenamiento y lab.benchmark.

   "Frío" = CHECKPOINT + DBCC DROPCLEANBUFFERS antes de la consulta (todo se lee de disco).
   "Caliente" = mejor de 3 ejecuciones seguidas con los datos ya en memoria.
   Ojo: SQL Server Express limita el buffer pool a ~1,4 GB, así que la copia rowstore
   nunca cabe entera en memoria y el columnstore sí (en gran parte).
   ===================================================================== */
USE TaxisNYC;
GO

IF OBJECT_ID(N'lab.espacio_almacenamiento') IS NULL
    CREATE TABLE lab.espacio_almacenamiento (
        almacenamiento  VARCHAR(20)   NOT NULL CONSTRAINT pk_espacio PRIMARY KEY,
        filas           BIGINT        NOT NULL,
        reservado_mb    DECIMAL(12,1) NOT NULL,
        bytes_por_fila  DECIMAL(9,1)  NOT NULL,
        seg_creacion    DECIMAL(9,1)  NULL,
        medido_en       DATETIME2(0)  NOT NULL CONSTRAINT df_espacio DEFAULT SYSDATETIME()
    );
GO
IF OBJECT_ID(N'lab.benchmark') IS NULL
    CREATE TABLE lab.benchmark (
        id              INT IDENTITY(1,1) CONSTRAINT pk_benchmark PRIMARY KEY,
        consulta        VARCHAR(4)     NOT NULL,
        descripcion     NVARCHAR(80)   NOT NULL,
        almacenamiento  VARCHAR(20)    NOT NULL,
        ejecucion       VARCHAR(10)    NOT NULL,   -- fria · caliente
        intento         TINYINT        NOT NULL,
        ms              INT            NOT NULL,
        cpu_ms          INT            NOT NULL,
        lecturas_fisicas BIGINT        NULL,        -- páginas leídas de disco (sys.dm_exec_requests)
        medido_en       DATETIME2(0)   NOT NULL CONSTRAINT df_benchmark DEFAULT SYSDATETIME()
    );
GO

CREATE OR ALTER PROCEDURE lab.sp_medir_espacio
    @almacenamiento VARCHAR(20), @tabla SYSNAME, @seg_creacion DECIMAL(9,1) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @filas BIGINT, @mb DECIMAL(12,1);
    SELECT @filas = SUM(CASE WHEN index_id IN (0, 1) THEN row_count ELSE 0 END),
           @mb = SUM(reserved_page_count) * 8 / 1024.0
    FROM sys.dm_db_partition_stats WHERE object_id = OBJECT_ID(@tabla);
    DELETE FROM lab.espacio_almacenamiento WHERE almacenamiento = @almacenamiento;
    INSERT INTO lab.espacio_almacenamiento (almacenamiento, filas, reservado_mb, bytes_por_fila, seg_creacion)
    VALUES (@almacenamiento, @filas, @mb, @mb * 1048576 / NULLIF(@filas, 0), @seg_creacion);
END;
GO

CREATE OR ALTER PROCEDURE lab.sp_medir_consultas
    @almacenamiento VARCHAR(20), @tabla NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @consultas TABLE (consulta VARCHAR(4), descripcion NVARCHAR(80), plantilla NVARCHAR(MAX));
    INSERT INTO @consultas VALUES
        ('C1', N'Viajes e ingreso por mes (agregación total)',
         N'SELECT fecha_key / 100 AS mes, COUNT_BIG(*) AS n, SUM(total) AS t FROM {T} GROUP BY fecha_key / 100'),
        ('C2', N'Propina % por tipo de pago',
         N'SELECT tipo_pago_id, COUNT_BIG(*) AS n, SUM(propina) / SUM(tarifa_base) AS p FROM {T} GROUP BY tipo_pago_id'),
        ('C3', N'Top 10 rutas origen-destino',
         N'SELECT TOP (10) zona_origen_id, zona_destino_id, COUNT_BIG(*) AS n FROM {T}
           GROUP BY zona_origen_id, zona_destino_id ORDER BY n DESC'),
        ('C4', N'Horas pico: join con dim_fecha, día × hora',
         N'SELECT f.dia_semana, v.hora, COUNT_BIG(*) AS n, AVG(v.tarifa_base) AS t FROM {T} AS v
           JOIN dw.dim_fecha AS f ON f.fecha_key = v.fecha_key GROUP BY f.dia_semana, v.hora'),
        ('C5', N'Un mes (julio): filtro por la clave de partición',
         N'SELECT COUNT_BIG(*) AS n, SUM(total) AS t, AVG(distancia_millas) AS d FROM {T}
           WHERE fecha_key >= 20240701 AND fecha_key < 20240801'),
        ('C6', N'Dos horas del 4 de julio: filtro por recogida',
         N'SELECT COUNT_BIG(*) AS n, SUM(total) AS t FROM {T}
           WHERE recogida >= ''2024-07-04T20:00:00'' AND recogida < ''2024-07-04T22:00:00''');

    DECLARE @c VARCHAR(4), @d NVARCHAR(80), @p NVARCHAR(MAX), @sql NVARCHAR(MAX), @i TINYINT,
            @t0 DATETIME2(7), @cpu0 INT, @r0 BIGINT, @cpu1 INT, @r1 BIGINT, @ms INT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT consulta, descripcion, plantilla FROM @consultas ORDER BY consulta;
    OPEN c;
    FETCH NEXT FROM c INTO @c, @d, @p;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- El resultado va a una tabla temporal: se mide la consulta, no el envío al cliente
        SET @sql = N'DROP TABLE IF EXISTS #r; SELECT * INTO #r FROM (' + REPLACE(@p, N'{T}', @tabla) + N') AS q;';
        SET @i = 0;
        WHILE @i < 4   -- intento 0 = frío; 1–3 = caliente
        BEGIN
            IF @i = 0
            BEGIN
                CHECKPOINT;
                DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;
            END;
            SELECT @cpu0 = cpu_time, @r0 = reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
            SET @t0 = SYSDATETIME();
            EXEC sys.sp_executesql @sql;
            SET @ms = DATEDIFF(MILLISECOND, @t0, SYSDATETIME());
            SELECT @cpu1 = cpu_time, @r1 = reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
            INSERT INTO lab.benchmark (consulta, descripcion, almacenamiento, ejecucion, intento, ms, cpu_ms, lecturas_fisicas)
            VALUES (@c, @d, @almacenamiento, IIF(@i = 0, 'fria', 'caliente'), @i, @ms, @cpu1 - @cpu0, @r1 - @r0);
            SET @i += 1;
        END;
        FETCH NEXT FROM c INTO @c, @d, @p;
    END;
    CLOSE c;
    DEALLOCATE c;
END;
GO

CREATE OR ALTER PROCEDURE lab.sp_comparar_almacenamiento
    @conservar_copia BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t DATETIME2(3);
    DELETE FROM lab.benchmark;

    -- 1. Columnstore (el hecho real)
    EXEC lab.sp_medir_espacio 'COLUMNSTORE', N'dw.fact_viaje';
    EXEC lab.sp_medir_consultas 'COLUMNSTORE', N'dw.fact_viaje';

    -- 2. Rowstore sin compresión: B-tree agrupado por (fecha_key, fila_origen), lo típico en un DW sin columnstore
    DROP TABLE IF EXISTS lab.fact_viaje_rowstore;
    SET @t = SYSDATETIME();
    SELECT * INTO lab.fact_viaje_rowstore FROM dw.fact_viaje WHERE 1 = 0;
    CREATE CLUSTERED INDEX cix_fact_viaje_rowstore ON lab.fact_viaje_rowstore (fecha_key, fila_origen);
    INSERT INTO lab.fact_viaje_rowstore WITH (TABLOCK) SELECT * FROM dw.fact_viaje;
    DECLARE @seg DECIMAL(9,1) = DATEDIFF(MILLISECOND, @t, SYSDATETIME()) / 1000.0;
    EXEC lab.sp_medir_espacio 'ROWSTORE', N'lab.fact_viaje_rowstore', @seg;
    EXEC lab.sp_medir_consultas 'ROWSTORE', N'lab.fact_viaje_rowstore';

    -- 3. La misma tabla con compresión de página
    SET @t = SYSDATETIME();
    ALTER INDEX cix_fact_viaje_rowstore ON lab.fact_viaje_rowstore REBUILD WITH (DATA_COMPRESSION = PAGE);
    SET @seg = DATEDIFF(MILLISECOND, @t, SYSDATETIME()) / 1000.0;
    EXEC lab.sp_medir_espacio 'ROWSTORE PAGE', N'lab.fact_viaje_rowstore', @seg;
    EXEC lab.sp_medir_consultas 'ROWSTORE PAGE', N'lab.fact_viaje_rowstore';

    IF @conservar_copia = 0
        DROP TABLE lab.fact_viaje_rowstore;
END;
GO

/* Resumen: espacio y tiempos (frío y mejor caliente) por consulta y almacenamiento */
CREATE OR ALTER VIEW rpt.benchmark_almacenamiento AS
WITH b AS (
    SELECT consulta, descripcion, almacenamiento,
           MAX(CASE WHEN ejecucion = 'fria' THEN ms END)          AS ms_frio,
           MIN(CASE WHEN ejecucion = 'caliente' THEN ms END)      AS ms_caliente,
           MIN(CASE WHEN ejecucion = 'caliente' THEN cpu_ms END)  AS cpu_ms_caliente,
           MAX(CASE WHEN ejecucion = 'fria' THEN lecturas_fisicas END) AS lecturas_fisicas_frio
    FROM lab.benchmark GROUP BY consulta, descripcion, almacenamiento
)
SELECT b.consulta, b.descripcion, b.almacenamiento, b.ms_frio, b.ms_caliente, b.cpu_ms_caliente, b.lecturas_fisicas_frio,
       CAST(b.ms_caliente * 1.0 / NULLIF(c.ms_caliente, 0) AS DECIMAL(9,1)) AS veces_mas_lento_que_columnstore,
       e.reservado_mb, e.bytes_por_fila
FROM b
LEFT JOIN b AS c ON c.consulta = b.consulta AND c.almacenamiento = 'COLUMNSTORE'
JOIN lab.espacio_almacenamiento AS e ON e.almacenamiento = b.almacenamiento;
GO
