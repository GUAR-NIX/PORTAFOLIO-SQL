/* =====================================================================
   05_estructuras_laboratorio.sql — 4 diseños físicos sobre las mismas
   6.653.987 filas válidas + serie diaria densa por estación + tiempos
   de carga con y sin índices
   ---------------------------------------------------------------------
   1. lab.viaje_heap           : Tabla HEAP (sin índice agrupado ni secundarios)
   2. lab.viaje_rowstore_nocov : Rowstore B-Tree + índices NO cubrientes (provocan Key Lookup)
   3. lab.viaje_rowstore       : Rowstore B-Tree + índice CUBRIENTE (INCLUDE) + índice FILTRADO
   4. lab.viaje_columnstore    : Clustered Columnstore Index (CCI en Batch Mode)
   ===================================================================== */
USE CitiBikeTuning;
GO

-- 1. HEAP PURO (sin clave primaria ni índices)
CREATE TABLE lab.viaje_heap
(
    id_viaje                INT           NOT NULL,
    ride_id                 VARCHAR(24)   NOT NULL,
    tipo_bici_cod           VARCHAR(20)   NOT NULL,
    es_electrica            BIT           NOT NULL,
    fecha_inicio            DATETIME2(0)  NOT NULL,
    fecha_dia               DATE          NOT NULL,
    anio                    SMALLINT      NOT NULL,
    mes                     TINYINT       NOT NULL,
    hora                    TINYINT       NOT NULL,
    es_fin_de_semana        BIT           NOT NULL,
    estacion_origen_id      VARCHAR(32)   NOT NULL,
    estacion_destino_id     VARCHAR(32)   NOT NULL,
    es_miembro              BIT           NOT NULL,
    cruza_hudson        BIT           NOT NULL,
    duracion_seg            INT           NOT NULL,
    distancia_m             INT           NOT NULL,
    velocidad_kmh           DECIMAL(8,2)  NOT NULL
);
GO

-- 2. ROWSTORE CON ÍNDICE NO CUBRIENTE (para medir Key Lookup, Tipping Point y Parameter Sniffing)
CREATE TABLE lab.viaje_rowstore_nocov
(
    id_viaje                INT           NOT NULL,
    ride_id                 VARCHAR(24)   NOT NULL,
    tipo_bici_cod           VARCHAR(20)   NOT NULL,
    es_electrica            BIT           NOT NULL,
    fecha_inicio            DATETIME2(0)  NOT NULL,
    fecha_dia               DATE          NOT NULL,
    anio                    SMALLINT      NOT NULL,
    mes                     TINYINT       NOT NULL,
    hora                    TINYINT       NOT NULL,
    es_fin_de_semana        BIT           NOT NULL,
    estacion_origen_id      VARCHAR(32)   NOT NULL,
    estacion_destino_id     VARCHAR(32)   NOT NULL,
    es_miembro              BIT           NOT NULL,
    cruza_hudson        BIT           NOT NULL,
    duracion_seg            INT           NOT NULL,
    distancia_m             INT           NOT NULL,
    velocidad_kmh           DECIMAL(8,2)  NOT NULL,
    CONSTRAINT PK_lab_viaje_rowstore_nocov PRIMARY KEY CLUSTERED (fecha_inicio, id_viaje)
);
GO

-- 3. ROWSTORE AFINADO (con índice cubriente INCLUDE e índice filtrado WHERE)
CREATE TABLE lab.viaje_rowstore
(
    id_viaje                INT           NOT NULL,
    ride_id                 VARCHAR(24)   NOT NULL,
    tipo_bici_cod           VARCHAR(20)   NOT NULL,
    es_electrica            BIT           NOT NULL,
    fecha_inicio            DATETIME2(0)  NOT NULL,
    fecha_dia               DATE          NOT NULL,
    anio                    SMALLINT      NOT NULL,
    mes                     TINYINT       NOT NULL,
    hora                    TINYINT       NOT NULL,
    es_fin_de_semana        BIT           NOT NULL,
    estacion_origen_id      VARCHAR(32)   NOT NULL,
    estacion_destino_id     VARCHAR(32)   NOT NULL,
    es_miembro              BIT           NOT NULL,
    cruza_hudson        BIT           NOT NULL,
    duracion_seg            INT           NOT NULL,
    distancia_m             INT           NOT NULL,
    velocidad_kmh           DECIMAL(8,2)  NOT NULL,
    CONSTRAINT PK_lab_viaje_rowstore PRIMARY KEY CLUSTERED (fecha_inicio, id_viaje)
);
GO

-- 4. COLUMNSTORE (Clustered Columnstore Index para analítica masiva en Batch Mode)
CREATE TABLE lab.viaje_columnstore
(
    id_viaje                INT           NOT NULL,
    ride_id                 VARCHAR(24)   NOT NULL,
    tipo_bici_cod           VARCHAR(20)   NOT NULL,
    es_electrica            BIT           NOT NULL,
    fecha_inicio            DATETIME2(0)  NOT NULL,
    fecha_dia               DATE          NOT NULL,
    anio                    SMALLINT      NOT NULL,
    mes                     TINYINT       NOT NULL,
    hora                    TINYINT       NOT NULL,
    es_fin_de_semana        BIT           NOT NULL,
    estacion_origen_id      VARCHAR(32)   NOT NULL,
    estacion_destino_id     VARCHAR(32)   NOT NULL,
    es_miembro              BIT           NOT NULL,
    cruza_hudson        BIT           NOT NULL,
    duracion_seg            INT           NOT NULL,
    distancia_m             INT           NOT NULL,
    velocidad_kmh           DECIMAL(8,2)  NOT NULL,
    INDEX CCI_lab_viaje_columnstore CLUSTERED COLUMNSTORE
);
GO

-- 5. Serie diaria DENSA por estación (calendario completo, 0 viajes si no hubo salidas ese día).
--    Al no faltar días, "7 filas anteriores" y "7 días de calendario" son lo mismo: la subconsulta
--    correlacionada y la función de ventana de E6 devuelven exactamente el mismo resultado.
CREATE TABLE lab.serie_diaria_estacion
(
    estacion_origen_id      VARCHAR(32)   NOT NULL,
    fecha_dia               DATE          NOT NULL,
    viajes                  INT           NOT NULL,
    CONSTRAINT PK_lab_serie_diaria PRIMARY KEY CLUSTERED (estacion_origen_id, fecha_dia)
);
GO

-- Tiempos de carga con y sin índices (varias corridas sobre una tabla de prueba que se borra al final)
CREATE TABLE perf.tiempo_carga
(
    estrategia          VARCHAR(40)   NOT NULL,
    descripcion         NVARCHAR(160) NOT NULL,
    corrida             INT           NOT NULL,
    filas               BIGINT        NOT NULL,
    ms_insercion        INT           NOT NULL,
    ms_indices          INT           NOT NULL,
    ms_total            INT           NOT NULL,
    CONSTRAINT PK_perf_tiempo_carga PRIMARY KEY (estrategia, corrida)
);
GO

-- Tabla donde se persiste la huella física en disco y compresión de cada estructura
CREATE TABLE perf.tamano_estructura
(
    orden               INT           NOT NULL PRIMARY KEY,
    objeto_sql          VARCHAR(80)   NOT NULL,
    arquitectura        NVARCHAR(80)  NOT NULL,
    filas               BIGINT        NOT NULL,
    datos_mb            DECIMAL(10,2) NOT NULL,
    indices_secund_mb   DECIMAL(10,2) NOT NULL,
    total_reservado_mb  DECIMAL(10,2) NOT NULL,
    paginas_datos_8kb   BIGINT        NOT NULL,
    bytes_por_fila      DECIMAL(10,2) NOT NULL,
    ratio_compresion_vs_heap DECIMAL(8,2) NOT NULL
);
GO

CREATE OR ALTER PROCEDURE etl.sp_cargar_laboratorio
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 DATETIME2(3) = SYSDATETIME();

    -- Limpiar índices secundarios previos si existen
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_nocov_origen_fecha' AND object_id = OBJECT_ID(N'lab.viaje_rowstore_nocov'))
        DROP INDEX IX_nocov_origen_fecha ON lab.viaje_rowstore_nocov;

    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_nocov_duracion' AND object_id = OBJECT_ID(N'lab.viaje_rowstore_nocov'))
        DROP INDEX IX_nocov_duracion ON lab.viaje_rowstore_nocov;

    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_cov_origen_fecha_inc' AND object_id = OBJECT_ID(N'lab.viaje_rowstore'))
        DROP INDEX IX_cov_origen_fecha_inc ON lab.viaje_rowstore;

    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_filt_casual_largo' AND object_id = OBJECT_ID(N'lab.viaje_rowstore'))
        DROP INDEX IX_filt_casual_largo ON lab.viaje_rowstore;

    TRUNCATE TABLE lab.viaje_heap;
    TRUNCATE TABLE lab.viaje_rowstore_nocov;
    TRUNCATE TABLE lab.viaje_rowstore;
    TRUNCATE TABLE lab.viaje_columnstore;
    TRUNCATE TABLE lab.serie_diaria_estacion;

    -- 1. Poblar HEAP
    INSERT INTO lab.viaje_heap WITH (TABLOCK)
    SELECT
        id_viaje, ride_id, tipo_bici_cod, es_electrica, fecha_inicio, fecha_dia,
        anio, mes, hora, es_fin_de_semana, estacion_origen_id, estacion_destino_id,
        es_miembro, cruza_hudson, duracion_seg, distancia_m, velocidad_kmh
    FROM limpio.viaje
    WHERE motivo_exclusion IS NULL
    OPTION (MAXDOP 1); -- orden físico de inserción = orden del archivo (id_viaje), como un heap real

    -- 2. Poblar ROWSTORE NO CUBRIENTE (ordenado por clave agrupada)
    INSERT INTO lab.viaje_rowstore_nocov WITH (TABLOCK)
    SELECT
        id_viaje, ride_id, tipo_bici_cod, es_electrica, fecha_inicio, fecha_dia,
        anio, mes, hora, es_fin_de_semana, estacion_origen_id, estacion_destino_id,
        es_miembro, cruza_hudson, duracion_seg, distancia_m, velocidad_kmh
    FROM limpio.viaje
    WHERE motivo_exclusion IS NULL
    ORDER BY fecha_inicio, id_viaje;

    -- Índices secundarios NO cubrientes (solo claves de búsqueda, sin INCLUDE)
    CREATE NONCLUSTERED INDEX IX_nocov_origen_fecha
        ON lab.viaje_rowstore_nocov (estacion_origen_id, fecha_inicio);

    -- Índice por duración para el experimento de parameter sniffing (E5) y Query Store (E9)
    CREATE NONCLUSTERED INDEX IX_nocov_duracion
        ON lab.viaje_rowstore_nocov (duracion_seg);

    -- 3. Poblar ROWSTORE AFINADO
    INSERT INTO lab.viaje_rowstore WITH (TABLOCK)
    SELECT
        id_viaje, ride_id, tipo_bici_cod, es_electrica, fecha_inicio, fecha_dia,
        anio, mes, hora, es_fin_de_semana, estacion_origen_id, estacion_destino_id,
        es_miembro, cruza_hudson, duracion_seg, distancia_m, velocidad_kmh
    FROM limpio.viaje
    WHERE motivo_exclusion IS NULL
    ORDER BY fecha_inicio, id_viaje;

    -- Crear índice CUBRIENTE (INCLUDE evita el Key Lookup por completo)
    CREATE NONCLUSTERED INDEX IX_cov_origen_fecha_inc
        ON lab.viaje_rowstore (estacion_origen_id, fecha_inicio)
        INCLUDE (duracion_seg, distancia_m, es_miembro, es_electrica, estacion_destino_id);

    -- Crear índice FILTRADO (solo usuarios ocasionales con viajes >= 30 min: una fracción pequeña de la tabla)
    CREATE NONCLUSTERED INDEX IX_filt_casual_largo
        ON lab.viaje_rowstore (fecha_inicio, estacion_origen_id)
        INCLUDE (duracion_seg, distancia_m, es_electrica, estacion_destino_id)
        WHERE es_miembro = 0 AND duracion_seg >= 1800;

    -- 4. Poblar COLUMNSTORE (ordenando primero por fecha_inicio para optimizar eliminación de segmentos)
    INSERT INTO lab.viaje_columnstore WITH (TABLOCK)
    SELECT
        id_viaje, ride_id, tipo_bici_cod, es_electrica, fecha_inicio, fecha_dia,
        anio, mes, hora, es_fin_de_semana, estacion_origen_id, estacion_destino_id,
        es_miembro, cruza_hudson, duracion_seg, distancia_m, velocidad_kmh
    FROM limpio.viaje
    WHERE motivo_exclusion IS NULL
    ORDER BY fecha_inicio, id_viaje;

    ALTER INDEX CCI_lab_viaje_columnstore ON lab.viaje_columnstore REBUILD;

    -- 5. Poblar la serie diaria densa: cada estación × cada día del trimestre (2024-01-01 a 2024-03-31)
    ;WITH calendario AS
    (
        SELECT DATEADD(DAY, n.n, CAST('2024-01-01' AS DATE)) AS fecha_dia
        FROM (SELECT TOP (DATEDIFF(DAY, '2024-01-01', '2024-04-01'))
                     CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS INT) AS n
              FROM sys.all_objects) AS n
    ),
    estaciones AS
    (
        SELECT DISTINCT estacion_origen_id FROM lab.viaje_rowstore
    ),
    conteo AS
    (
        SELECT estacion_origen_id, fecha_dia, COUNT(*) AS viajes
        FROM lab.viaje_rowstore
        GROUP BY estacion_origen_id, fecha_dia
    )
    INSERT INTO lab.serie_diaria_estacion WITH (TABLOCK) (estacion_origen_id, fecha_dia, viajes)
    SELECT e.estacion_origen_id, c.fecha_dia, ISNULL(x.viajes, 0)
    FROM estaciones AS e
    CROSS JOIN calendario AS c
    LEFT JOIN conteo AS x
           ON x.estacion_origen_id = e.estacion_origen_id
          AND x.fecha_dia = c.fecha_dia;

    -- Actualizar estadísticas con FULLSCAN en las tablas del laboratorio para estimaciones exactas
    UPDATE STATISTICS lab.viaje_heap WITH FULLSCAN;
    UPDATE STATISTICS lab.viaje_rowstore_nocov WITH FULLSCAN;
    UPDATE STATISTICS lab.viaje_rowstore WITH FULLSCAN;
    UPDATE STATISTICS lab.serie_diaria_estacion WITH FULLSCAN;

    -- Calcular y registrar huella física de almacenamiento
    TRUNCATE TABLE perf.tamano_estructura;

    ;WITH stats_part AS
    (
        SELECT
            OBJECT_SCHEMA_NAME(p.object_id) + '.' + OBJECT_NAME(p.object_id) AS objeto_sql,
            MAX(CASE WHEN p.index_id IN (0, 1) THEN p.row_count ELSE 0 END) AS filas,
            SUM(CASE WHEN p.index_id IN (0, 1) THEN p.used_page_count ELSE 0 END) AS paginas_base,
            SUM(CASE WHEN p.index_id > 1 THEN p.used_page_count ELSE 0 END) AS paginas_secund,
            SUM(p.reserved_page_count) AS paginas_reservadas
        FROM sys.dm_db_partition_stats AS p
        WHERE p.object_id IN (
            OBJECT_ID(N'lab.viaje_heap'),
            OBJECT_ID(N'lab.viaje_rowstore_nocov'),
            OBJECT_ID(N'lab.viaje_rowstore'),
            OBJECT_ID(N'lab.viaje_columnstore')
        )
        GROUP BY p.object_id
    )
    INSERT INTO perf.tamano_estructura
    (
        orden, objeto_sql, arquitectura, filas,
        datos_mb, indices_secund_mb, total_reservado_mb,
        paginas_datos_8kb, bytes_por_fila, ratio_compresion_vs_heap
    )
    SELECT
        CASE objeto_sql
            WHEN 'lab.viaje_heap'           THEN 1
            WHEN 'lab.viaje_rowstore_nocov' THEN 2
            WHEN 'lab.viaje_rowstore'       THEN 3
            WHEN 'lab.viaje_columnstore'    THEN 4
        END AS orden,
        objeto_sql,
        CASE objeto_sql
            WHEN 'lab.viaje_heap'           THEN N'Heap sin índices (línea base)'
            WHEN 'lab.viaje_rowstore_nocov' THEN N'Rowstore B-Tree + índices no cubrientes'
            WHEN 'lab.viaje_rowstore'       THEN N'Rowstore B-Tree + índice cubriente INCLUDE + filtrado'
            WHEN 'lab.viaje_columnstore'    THEN N'Clustered Columnstore Index (CCI)'
        END AS arquitectura,
        filas,
        CAST(paginas_base * 8.0 / 1024.0 AS DECIMAL(10,2)) AS datos_mb,
        CAST(paginas_secund * 8.0 / 1024.0 AS DECIMAL(10,2)) AS indices_secund_mb,
        CAST(paginas_reservadas * 8.0 / 1024.0 AS DECIMAL(10,2)) AS total_reservado_mb,
        paginas_base AS paginas_datos_8kb,
        CAST((paginas_base * 8192.0) / NULLIF(filas, 0) AS DECIMAL(10,2)) AS bytes_por_fila,
        CAST(1.00 AS DECIMAL(8,2)) AS ratio_compresion_vs_heap
    FROM stats_part;

    DECLARE @datos_heap DECIMAL(10,2) = (SELECT datos_mb FROM perf.tamano_estructura WHERE orden = 1);
    UPDATE perf.tamano_estructura
    SET ratio_compresion_vs_heap = CAST(ROUND(@datos_heap / NULLIF(datos_mb, 0), 2) AS DECIMAL(8,2));

    INSERT INTO etl.bitacora_carga (etapa, filas_afectadas, duracion_ms)
    VALUES (N'ESTRUCTURAS_E_INDICES_LABORATORIO', (SELECT COUNT_BIG(*) FROM lab.viaje_rowstore), DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
END;
GO

/* ---------------------------------------------------------------------
   Tiempo de carga con y sin índices.
   Se copian las mismas filas válidas (desde lab.viaje_heap) a lab.carga_prueba con tres estrategias:
     HEAP              : sin índices.
     INDICES_DESPUES   : índice agrupado + INSERT y luego CREATE de los 2 índices secundarios.
     INDICES_ANTES     : la tabla ya tiene el agrupado y los 2 secundarios cuando llega el INSERT.
   Cada estrategia se repite @corridas veces (en orden rotado); el README reporta la mediana.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.sp_medir_tiempos_carga
    @corridas INT = 3
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE perf.tiempo_carga;

    DECLARE @c INT = 1, @k INT, @e INT, @estrategia VARCHAR(40),
            @t0 DATETIME2(7), @t1 DATETIME2(7), @t2 DATETIME2(7), @filas BIGINT;

    WHILE @c <= @corridas
    BEGIN
        SET @k = 0;
        WHILE @k < 3
        BEGIN
            SET @e = ((@k + @c - 1) % 3) + 1; -- rota el orden para no favorecer a ninguna estrategia
            SET @estrategia = CASE @e WHEN 1 THEN 'HEAP' WHEN 2 THEN 'INDICES_DESPUES' ELSE 'INDICES_ANTES' END;
            IF OBJECT_ID(N'lab.carga_prueba', N'U') IS NOT NULL DROP TABLE lab.carga_prueba;

            CREATE TABLE lab.carga_prueba
            (
                id_viaje INT NOT NULL, ride_id VARCHAR(24) NOT NULL, tipo_bici_cod VARCHAR(20) NOT NULL,
                es_electrica BIT NOT NULL, fecha_inicio DATETIME2(0) NOT NULL, fecha_dia DATE NOT NULL,
                anio SMALLINT NOT NULL, mes TINYINT NOT NULL, hora TINYINT NOT NULL, es_fin_de_semana BIT NOT NULL,
                estacion_origen_id VARCHAR(32) NOT NULL, estacion_destino_id VARCHAR(32) NOT NULL,
                es_miembro BIT NOT NULL, cruza_hudson BIT NOT NULL, duracion_seg INT NOT NULL,
                distancia_m INT NOT NULL, velocidad_kmh DECIMAL(8,2) NOT NULL
            );
            IF @e IN (2, 3)
                ALTER TABLE lab.carga_prueba ADD CONSTRAINT PK_carga_prueba PRIMARY KEY CLUSTERED (fecha_inicio, id_viaje);
            IF @e = 3
            BEGIN
                CREATE NONCLUSTERED INDEX IX_cp_cov ON lab.carga_prueba (estacion_origen_id, fecha_inicio)
                    INCLUDE (duracion_seg, distancia_m, es_miembro, es_electrica, estacion_destino_id);
                CREATE NONCLUSTERED INDEX IX_cp_filt ON lab.carga_prueba (fecha_inicio, estacion_origen_id)
                    INCLUDE (duracion_seg, distancia_m, es_electrica, estacion_destino_id)
                    WHERE es_miembro = 0 AND duracion_seg >= 1800;
            END;

            CHECKPOINT;
            SET @t0 = SYSDATETIME();
            INSERT INTO lab.carga_prueba WITH (TABLOCK)
            SELECT id_viaje, ride_id, tipo_bici_cod, es_electrica, fecha_inicio, fecha_dia,
                   anio, mes, hora, es_fin_de_semana, estacion_origen_id, estacion_destino_id,
                   es_miembro, cruza_hudson, duracion_seg, distancia_m, velocidad_kmh
            FROM lab.viaje_heap;
            SET @filas = @@ROWCOUNT;
            SET @t1 = SYSDATETIME();

            IF @e = 2
            BEGIN
                CREATE NONCLUSTERED INDEX IX_cp_cov ON lab.carga_prueba (estacion_origen_id, fecha_inicio)
                    INCLUDE (duracion_seg, distancia_m, es_miembro, es_electrica, estacion_destino_id);
                CREATE NONCLUSTERED INDEX IX_cp_filt ON lab.carga_prueba (fecha_inicio, estacion_origen_id)
                    INCLUDE (duracion_seg, distancia_m, es_electrica, estacion_destino_id)
                    WHERE es_miembro = 0 AND duracion_seg >= 1800;
            END;
            SET @t2 = SYSDATETIME();

            INSERT INTO perf.tiempo_carga (estrategia, descripcion, corrida, filas, ms_insercion, ms_indices, ms_total)
            VALUES
            (
                @estrategia,
                CASE @e
                    WHEN 1 THEN N'Heap sin índices'
                    WHEN 2 THEN N'Agrupado + INSERT, luego CREATE de 2 índices secundarios'
                    ELSE N'Agrupado + 2 índices secundarios ya creados antes del INSERT'
                END,
                @c, @filas,
                DATEDIFF(MILLISECOND, @t0, @t1),
                DATEDIFF(MILLISECOND, @t1, @t2),
                DATEDIFF(MILLISECOND, @t0, @t2)
            );
            SET @k += 1;
        END;
        SET @c += 1;
    END;

    DROP TABLE lab.carga_prueba;
END;
GO
