/* =====================================================================
   06_ventana_deslizante.sql
   Ventana deslizante de 12 meses sobre dw.fact_viaje (solo operaciones de metadatos).

   Cuando llega un mes nuevo (p. ej. 2025-01) y se quiere conservar solo 12 meses:

     antes   p1 vacía | ene-24 | feb-24 | ... | dic-24 | p14 vacía (>= 20250101)
     1. SPLIT 20250201 sobre p14 (vacía)          → nace la partición de ene-25 + otra vacía a la derecha
     2. etl.sp_cargar_mes '2025-01'               → SWITCH IN del mes nuevo
     3. SWITCH OUT de ene-24 a dw.fact_viaje_archivo_202401 (tabla aparte, mismo índice)
     4. MERGE 20240101 (p1 y la de ene-24, ambas vacías) → la punta izquierda vuelve a quedar vacía
     después p1 vacía | feb-24 | ... | ene-25 | vacía

   Regla de oro: SPLIT y MERGE solo sobre particiones VACÍAS. Si no, SQL Server mueve
   filas entre particiones (lento, con log completo). Los procedimientos lo verifican y
   abortan antes de mover datos. La tabla de archivo puede exportarse o borrarse;
   etl.sp_restaurar_mes_archivado la devuelve al hecho (también solo metadatos).
   ===================================================================== */
USE TaxisNYC;
GO

IF OBJECT_ID(N'lab.ventana_log') IS NULL
    CREATE TABLE lab.ventana_log (
        id          INT IDENTITY(1,1) CONSTRAINT pk_ventana_log PRIMARY KEY,
        momento     DATETIME2(3)   NOT NULL CONSTRAINT df_ventana_log DEFAULT SYSDATETIME(),
        operacion   VARCHAR(20)    NOT NULL,   -- SPLIT · SWITCH OUT · MERGE · SWITCH IN
        limite      INT            NULL,
        filas       BIGINT         NULL,
        ms          INT            NOT NULL,
        detalle     NVARCHAR(300)  NULL
    );
GO

/* Particiones del hecho con su rango y filas (lo usan los procedimientos, la demo y las pruebas) */
CREATE OR ALTER VIEW lab.v_particiones_hecho
AS
SELECT p.partition_number AS particion,
       CAST(lim_inf.value AS INT) AS desde_key,      -- incluido (RANGE RIGHT)
       CAST(lim_sup.value AS INT) AS hasta_key,      -- excluido
       SUM(p.rows) AS filas
FROM sys.partitions AS p
JOIN sys.indexes AS i ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.partition_schemes AS s ON s.data_space_id = i.data_space_id
LEFT JOIN sys.partition_range_values AS lim_inf
       ON lim_inf.function_id = s.function_id AND lim_inf.boundary_id = p.partition_number - 1
LEFT JOIN sys.partition_range_values AS lim_sup
       ON lim_sup.function_id = s.function_id AND lim_sup.boundary_id = p.partition_number
WHERE p.object_id = OBJECT_ID(N'dw.fact_viaje') AND i.index_id = 1
GROUP BY p.partition_number, lim_inf.value, lim_sup.value;
GO

CREATE OR ALTER PROCEDURE etl.sp_split_mes
    @key INT    -- primer día del mes (AAAAMM01) que debe tener su propio límite
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM sys.partition_range_values AS v JOIN sys.partition_functions AS f
               ON f.function_id = v.function_id WHERE f.name = N'pf_mes' AND CAST(v.value AS INT) = @key)
        RETURN;   -- ya existe
    IF (SELECT filas FROM lab.v_particiones_hecho WHERE particion = $PARTITION.pf_mes(@key)) > 0
        THROW 50020, N'SPLIT sobre una partición con datos: movería filas. Se aborta.', 1;
    DECLARE @t DATETIME2(7) = SYSDATETIME();
    ALTER PARTITION SCHEME ps_mes NEXT USED [PRIMARY];
    ALTER PARTITION FUNCTION pf_mes() SPLIT RANGE (@key);
    INSERT INTO lab.ventana_log (operacion, limite, filas, ms, detalle)
    VALUES ('SPLIT', @key, 0, DATEDIFF(MILLISECOND, @t, SYSDATETIME()), N'Partición vacía: solo metadatos');
END;
GO

CREATE OR ALTER PROCEDURE etl.sp_ventana_deslizante
    @mes_nuevo        CHAR(7),     -- mes que entra (prepara su partición)
    @meses_conservar  INT = 12
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @inicio_nuevo DATE = CAST(@mes_nuevo + '-01' AS DATE);
    DECLARE @key_nuevo INT = CONVERT(INT, CONVERT(CHAR(8), @inicio_nuevo, 112)),
            @key_siguiente INT = CONVERT(INT, CONVERT(CHAR(8), DATEADD(MONTH, 1, @inicio_nuevo), 112)),
            @key_corte INT = CONVERT(INT, CONVERT(CHAR(8), DATEADD(MONTH, 1 - @meses_conservar, @inicio_nuevo), 112));

    -- 1. Preparar: el mes nuevo y el siguiente deben ser límites (la punta derecha queda vacía)
    EXEC etl.sp_split_mes @key_nuevo;
    EXEC etl.sp_split_mes @key_siguiente;

    -- 2. Retirar los meses que salen de la ventana: SWITCH OUT + MERGE, del más antiguo al más nuevo
    DECLARE @limite INT, @particion INT, @filas BIGINT, @tabla SYSNAME, @sql NVARCHAR(MAX), @t DATETIME2(7);
    -- Se relee la vista en cada vuelta: tras un MERGE los números de partición cambian
    WHILE 1 = 1
    BEGIN
        SET @limite = NULL;
        SELECT TOP (1) @limite = desde_key, @particion = particion, @filas = filas
        FROM lab.v_particiones_hecho
        WHERE desde_key IS NOT NULL AND desde_key < @key_corte ORDER BY desde_key;
        IF @limite IS NULL BREAK;
        IF @filas > 0
        BEGIN
            SET @tabla = CONCAT(N'fact_viaje_archivo_', @limite / 100);
            IF OBJECT_ID(N'dw.' + @tabla) IS NOT NULL
                THROW 50021, N'Ya existe una tabla de archivo para ese mes: expórtala o bórrala antes.', 1;
            SET @sql = N'SELECT TOP (0) * INTO dw.' + QUOTENAME(@tabla) + N' FROM dw.fact_viaje;'
                     + N' CREATE CLUSTERED COLUMNSTORE INDEX cci_' + @tabla + N' ON dw.' + QUOTENAME(@tabla)
                     + N' ORDER (recogida);';
            EXEC (@sql);
            SET @t = SYSDATETIME();
            SET @sql = N'ALTER TABLE dw.fact_viaje SWITCH PARTITION ' + CAST(@particion AS NVARCHAR(5))
                     + N' TO dw.' + QUOTENAME(@tabla) + N';';
            EXEC (@sql);
            INSERT INTO lab.ventana_log (operacion, limite, filas, ms, detalle)
            VALUES ('SWITCH OUT', @limite, @filas, DATEDIFF(MILLISECOND, @t, SYSDATETIME()), N'dw.' + @tabla);
        END;
        -- La partición de la izquierda (< @limite) también está vacía: el MERGE no mueve datos
        IF (SELECT SUM(filas) FROM lab.v_particiones_hecho WHERE particion IN (@particion - 1, @particion)) > 0
            THROW 50022, N'MERGE sobre particiones con datos: se aborta.', 1;
        SET @t = SYSDATETIME();
        ALTER PARTITION FUNCTION pf_mes() MERGE RANGE (@limite);
        INSERT INTO lab.ventana_log (operacion, limite, filas, ms, detalle)
        VALUES ('MERGE', @limite, 0, DATEDIFF(MILLISECOND, @t, SYSDATETIME()), N'Particiones vacías: solo metadatos');
    END;
END;
GO

/* Devuelve un mes archivado al hecho (SPLIT del límite + CHECK + SWITCH IN) */
CREATE OR ALTER PROCEDURE etl.sp_restaurar_mes_archivado
    @periodo CHAR(7)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @inicio DATE = CAST(@periodo + '-01' AS DATE);
    DECLARE @key INT = CONVERT(INT, CONVERT(CHAR(8), @inicio, 112)),
            @key_fin INT = CONVERT(INT, CONVERT(CHAR(8), DATEADD(MONTH, 1, @inicio), 112)),
            @tabla SYSNAME = CONCAT(N'fact_viaje_archivo_', REPLACE(@periodo, '-', '')),
            @sql NVARCHAR(MAX), @t DATETIME2(7), @filas BIGINT, @particion INT;
    IF OBJECT_ID(N'dw.' + @tabla) IS NULL
        THROW 50023, N'No existe la tabla de archivo de ese mes.', 1;

    EXEC etl.sp_split_mes @key;
    EXEC etl.sp_split_mes @key_fin;
    SET @particion = $PARTITION.pf_mes(@key);

    SET @sql = N'ALTER TABLE dw.' + QUOTENAME(@tabla) + N' WITH CHECK ADD CONSTRAINT ck_' + @tabla
             + N' CHECK (fecha_key >= ' + CAST(@key AS NVARCHAR(8)) + N' AND fecha_key < '
             + CAST(@key_fin AS NVARCHAR(8)) + N');'
             + N' SELECT @f = COUNT_BIG(*) FROM dw.' + QUOTENAME(@tabla) + N';';
    EXEC sys.sp_executesql @sql, N'@f BIGINT OUTPUT', @f = @filas OUTPUT;

    SET @t = SYSDATETIME();
    SET @sql = N'ALTER TABLE dw.' + QUOTENAME(@tabla) + N' SWITCH TO dw.fact_viaje PARTITION '
             + CAST(@particion AS NVARCHAR(5)) + N'; DROP TABLE dw.' + QUOTENAME(@tabla) + N';';
    EXEC (@sql);
    INSERT INTO lab.ventana_log (operacion, limite, filas, ms, detalle)
    VALUES ('SWITCH IN', @key, @filas, DATEDIFF(MILLISECOND, @t, SYSDATETIME()), N'Restaurado desde dw.' + @tabla);
END;
GO

/* Quita un límite cuyas dos particiones vecinas están vacías (deshacer un SPLIT de prueba) */
CREATE OR ALTER PROCEDURE etl.sp_merge_limite_vacio
    @key INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @particion INT = $PARTITION.pf_mes(@key), @t DATETIME2(7) = SYSDATETIME();
    IF (SELECT SUM(filas) FROM lab.v_particiones_hecho WHERE particion IN (@particion - 1, @particion)) > 0
        THROW 50024, N'MERGE sobre particiones con datos: se aborta.', 1;
    ALTER PARTITION FUNCTION pf_mes() MERGE RANGE (@key);
    INSERT INTO lab.ventana_log (operacion, limite, filas, ms, detalle)
    VALUES ('MERGE', @key, 0, DATEDIFF(MILLISECOND, @t, SYSDATETIME()), N'Particiones vacías: solo metadatos');
END;
GO
