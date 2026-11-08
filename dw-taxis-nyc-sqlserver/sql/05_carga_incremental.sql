/* =====================================================================
   05_carga_incremental.sql
   Carga incremental mes a mes, idempotente.

   etl.sp_cargar_mes '2024-03' hace, para un solo mes:
     1. Si ese mes ya está cargado con el mismo archivo (sha256) → OMITIDO (salvo @forzar = 1).
     2. TRUNCATE stg.viaje + BULK INSERT del CSV del mes.
     3. Cuadra filas del staging contra las cifras de control del Parquet.
     4. Clasifica con etl.fn_viajes_clasificados: los que rompen una regla → qa.cuarentena_viaje
        (se borra antes lo del mismo periodo), el resto → etl.viaje_carga (tabla de trabajo).
     5. Crea el columnstore en la tabla de trabajo y la cambia por la partición del mes:
        TRUNCATE ... WITH (PARTITIONS (n)) + ALTER TABLE ... SWITCH TO ... PARTITION n.
        Ambos son operaciones de metadatos: el hecho nunca queda a medio cargar.
     6. Verifica archivo = hecho + cuarentena y deja todo en qa.auditoria_carga.
   Recargar un mes N veces deja exactamente el mismo resultado.

   etl.sp_cargar_pendientes recorre los meses de qa.cifras_control en orden.
   ===================================================================== */
USE TaxisNYC;
GO

CREATE OR ALTER PROCEDURE etl.sp_cargar_mes
    @periodo        CHAR(7),            -- '2024-01'
    @carpeta_datos  NVARCHAR(400),      -- ...\data (el CSV está en data\raw)
    @forzar         BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @t0 DATETIME2(3) = SYSDATETIME(), @t DATETIME2(3), @carga_id INT, @sql NVARCHAR(MAX),
            @archivo NVARCHAR(100), @csv NVARCHAR(100), @sha CHAR(64), @filas_control INT,
            @inicio DATETIME2(0) = CAST(@periodo + '-01' AS DATETIME2(0)), @fin DATETIME2(0),
            @key_inicio INT, @key_fin INT, @particion INT,
            @filas_stg INT, @filas_hecho INT, @filas_cuarentena INT;
    SET @fin = DATEADD(MONTH, 1, @inicio);
    SET @key_inicio = CONVERT(INT, CONVERT(CHAR(8), @inicio, 112));
    SET @key_fin = CONVERT(INT, CONVERT(CHAR(8), @fin, 112));
    SET @particion = $PARTITION.pf_mes(@key_inicio);

    SELECT @archivo = archivo, @csv = csv, @sha = sha256, @filas_control = filas
    FROM qa.cifras_control WHERE periodo = @periodo;
    IF @archivo IS NULL
        THROW 50010, N'No hay cifras de control para ese periodo: ejecuta descargar_datos.py y etl.sp_leer_cifras_control.', 1;

    -- La partición debe existir y corresponder exactamente al mes (límites del SPLIT)
    IF NOT EXISTS (SELECT 1 FROM sys.partition_range_values AS v
                   JOIN sys.partition_functions AS f ON f.function_id = v.function_id
                   WHERE f.name = N'pf_mes' AND CAST(v.value AS INT) = @key_inicio)
       OR $PARTITION.pf_mes(@key_fin) <> @particion + 1
        THROW 50011, N'El mes no tiene su propia partición: prepárala con etl.sp_ventana_deslizante.', 1;

    -- 1. Idempotencia: el mismo archivo ya cargado sin errores no se vuelve a cargar
    IF @forzar = 0 AND EXISTS (SELECT 1 FROM qa.auditoria_carga
                               WHERE periodo = @periodo AND sha256 = @sha AND estado = 'OK'
                                 AND carga_id = (SELECT MAX(carga_id) FROM qa.auditoria_carga
                                                 WHERE periodo = @periodo AND estado IN ('OK', 'ERROR')))
    BEGIN
        INSERT INTO qa.auditoria_carga (periodo, archivo, sha256, estado, filas_archivo, fin, seg_total, mensaje)
        VALUES (@periodo, @archivo, @sha, 'OMITIDO', @filas_control, SYSDATETIME(), 0,
                N'Ya cargado con el mismo sha256; usa @forzar = 1 para recargar');
        PRINT CONCAT(@periodo, N': OMITIDO (ya cargado)');
        RETURN;
    END;

    -- Una carga anterior que quedó EN CURSO murió a medias (apagón, reinicio): se marca como ERROR.
    -- El hecho no quedó a medias porque el SWITCH es lo último y es atómico.
    UPDATE qa.auditoria_carga
    SET estado = 'ERROR', fin = SYSDATETIME(), mensaje = N'Interrumpida: el proceso terminó sin cerrar la carga'
    WHERE periodo = @periodo AND estado = 'EN CURSO';

    INSERT INTO qa.auditoria_carga (periodo, archivo, sha256, estado, filas_archivo)
    VALUES (@periodo, @archivo, @sha, 'EN CURSO', @filas_control);
    SET @carga_id = SCOPE_IDENTITY();

    BEGIN TRY
        -- 2. Staging
        SET @t = SYSDATETIME();
        TRUNCATE TABLE stg.viaje;
        SET @sql = N'BULK INSERT stg.viaje FROM ''' + REPLACE(@carpeta_datos, N'''', N'''''') + N'\raw\' + @csv
                 + N''' WITH (FORMAT = ''CSV'', FIRSTROW = 2, ROWTERMINATOR = ''0x0a'', CODEPAGE = ''65001'','
                 + N' KEEPNULLS, TABLOCK, MAXERRORS = 0);';
        EXEC (@sql);
        SET @filas_stg = (SELECT COUNT(*) FROM stg.viaje);
        UPDATE qa.auditoria_carga
        SET filas_staging = @filas_stg, seg_bulk_insert = DATEDIFF(MILLISECOND, @t, SYSDATETIME()) / 1000.0
        WHERE carga_id = @carga_id;

        -- 3. Cuadre de filas contra el Parquet antes de tocar el modelo
        IF @filas_stg <> @filas_control
            THROW 50012, N'Las filas del staging no cuadran con las cifras de control del Parquet.', 1;

        EXEC etl.sp_agregar_miembros_inferidos;

        -- 4. Clasificación: cuarentena y tabla de trabajo
        SET @t = SYSDATETIME();
        DELETE FROM qa.cuarentena_viaje WHERE periodo = @periodo;
        INSERT INTO qa.cuarentena_viaje WITH (TABLOCK)
            (periodo, fila_origen, regla, carga_id, vendor_id, recogida, llegada, pasajeros, distancia_millas,
             ratecode_id, zona_origen_id, zona_destino_id, tipo_pago_id, tarifa_base, propina, total)
        SELECT @periodo, fila_origen, regla, @carga_id, vendor_id, recogida, llegada, pasajeros, distancia_millas,
               ratecode_id, zona_origen_id, zona_destino_id, tipo_pago_id, tarifa_base, propina, total
        FROM etl.fn_viajes_clasificados(@inicio, @fin)
        WHERE regla IS NOT NULL;
        SET @filas_cuarentena = @@ROWCOUNT;

        -- Tabla de trabajo con la misma estructura que el hecho (SELECT TOP 0 INTO: una sola definición)
        DROP TABLE IF EXISTS etl.viaje_carga;
        SELECT TOP (0) * INTO etl.viaje_carga FROM dw.fact_viaje;

        INSERT INTO etl.viaje_carga WITH (TABLOCK)
        SELECT CONVERT(INT, CONVERT(CHAR(8), recogida, 112)), DATEPART(HOUR, recogida), recogida, llegada,
               CAST(duracion_seg AS INT), vendor_id, ISNULL(ratecode_id, 0), tipo_pago_id,
               zona_origen_id, zona_destino_id, pasajeros, distancia_millas, tarifa_base,
               extra, impuesto_mta, propina, peajes, recargo_mejora,
               ISNULL(recargo_congestion, 0), ISNULL(cargo_aeropuerto, 0),   -- nulos en registros de tarifa flexible
               total, CASE envio_diferido WHEN 'Y' THEN 1 WHEN 'N' THEN 0 END, fila_origen, @carga_id
        FROM etl.fn_viajes_clasificados(@inicio, @fin)
        WHERE regla IS NULL;
        SET @filas_hecho = @@ROWCOUNT;
        UPDATE qa.auditoria_carga
        SET filas_cuarentena = @filas_cuarentena, filas_hecho = @filas_hecho,
            seg_clasificacion = DATEDIFF(MILLISECOND, @t, SYSDATETIME()) / 1000.0
        WHERE carga_id = @carga_id;

        -- 5. Columnstore ordenado + CHECK del rango (requisito del SWITCH hacia una partición)
        SET @t = SYSDATETIME();
        SET @sql = N'ALTER TABLE etl.viaje_carga WITH CHECK ADD CONSTRAINT ck_viaje_carga_mes CHECK (fecha_key >= '
                 + CAST(@key_inicio AS NVARCHAR(8)) + N' AND fecha_key < ' + CAST(@key_fin AS NVARCHAR(8)) + N');';
        EXEC (@sql);
        CREATE CLUSTERED COLUMNSTORE INDEX cci_viaje_carga ON etl.viaje_carga ORDER (recogida) WITH (MAXDOP = 1);
        UPDATE qa.auditoria_carga SET seg_columnstore = DATEDIFF(MILLISECOND, @t, SYSDATETIME()) / 1000.0
        WHERE carga_id = @carga_id;

        IF @filas_hecho + @filas_cuarentena <> @filas_control
            THROW 50013, N'Hecho + cuarentena no cuadra con las filas del Parquet.', 1;

        -- Reemplazo atómico de la partición: vaciarla y enchufar la tabla de trabajo
        SET @t = SYSDATETIME();
        BEGIN TRANSACTION;
            SET @sql = N'TRUNCATE TABLE dw.fact_viaje WITH (PARTITIONS (' + CAST(@particion AS NVARCHAR(5)) + N'));';
            EXEC (@sql);
            SET @sql = N'ALTER TABLE etl.viaje_carga SWITCH TO dw.fact_viaje PARTITION '
                     + CAST(@particion AS NVARCHAR(5)) + N';';
            EXEC (@sql);
        COMMIT;
        DROP TABLE etl.viaje_carga;

        UPDATE qa.auditoria_carga
        SET estado = 'OK', fin = SYSDATETIME(), ms_switch = DATEDIFF(MILLISECOND, @t, SYSDATETIME()),
            seg_total = DATEDIFF(MILLISECOND, @t0, SYSDATETIME()) / 1000.0,
            mensaje = CONCAT(N'Partición ', @particion)
        WHERE carga_id = @carga_id;
        TRUNCATE TABLE stg.viaje;   -- libera ~0,4 GB: el staging solo vive durante la carga

        PRINT CONCAT(@periodo, N': OK · ', FORMAT(@filas_hecho, N'N0', 'es-EC'), N' al hecho · ',
                     FORMAT(@filas_cuarentena, N'N0', 'es-EC'), N' a cuarentena · ',
                     DATEDIFF(SECOND, @t0, SYSDATETIME()), N' s');
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        UPDATE qa.auditoria_carga
        SET estado = 'ERROR', fin = SYSDATETIME(), seg_total = DATEDIFF(MILLISECOND, @t0, SYSDATETIME()) / 1000.0,
            mensaje = LEFT(CONCAT(N'Error ', ERROR_NUMBER(), N': ', ERROR_MESSAGE()), 2000)
        WHERE carga_id = @carga_id;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE etl.sp_cargar_pendientes
    @carpeta_datos  NVARCHAR(400),
    @forzar         BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @periodo CHAR(7);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT periodo FROM qa.cifras_control ORDER BY periodo;
    OPEN c;
    FETCH NEXT FROM c INTO @periodo;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC etl.sp_cargar_mes @periodo = @periodo, @carpeta_datos = @carpeta_datos, @forzar = @forzar;
        FETCH NEXT FROM c INTO @periodo;
    END;
    CLOSE c;
    DEALLOCATE c;
END;
GO
