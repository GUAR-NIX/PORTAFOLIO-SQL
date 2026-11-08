/* =====================================================================
   09_calidad.sql
   qa.sp_validar_calidad: controles de punta a punta. Devuelve una fila por control y,
   si alguno queda en ALERTA, termina con THROW (el pipeline y las pruebas fallan a la vista).

     EXEC qa.sp_validar_calidad;                    -- falla si hay alertas
     EXEC qa.sp_validar_calidad @lanzar_error = 0;  -- solo informa
   ===================================================================== */
USE TaxisNYC;
GO

IF OBJECT_ID(N'qa.resultado_control') IS NULL
    CREATE TABLE qa.resultado_control (
        ejecucion   DATETIME2(0)   NOT NULL,
        orden       TINYINT        NOT NULL,
        control     NVARCHAR(150)  NOT NULL,
        valor       DECIMAL(18,2)  NULL,
        esperado    NVARCHAR(40)   NOT NULL,
        estado      VARCHAR(6)     NOT NULL,
        CONSTRAINT pk_resultado_control PRIMARY KEY (ejecucion, orden)
    );
GO

CREATE OR ALTER PROCEDURE qa.sp_validar_calidad
    @lanzar_error BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r TABLE (orden TINYINT, control NVARCHAR(150), valor DECIMAL(18,2), esperado NVARCHAR(40), ok BIT);
    DECLARE @meses INT = (SELECT COUNT(*) FROM qa.cifras_control);

    -- Cuadre contra la fuente (vista rpt.cuadre_fuente: Parquet = hecho + cuarentena)
    SELECT * INTO #cuadre FROM rpt.cuadre_fuente;
    INSERT INTO @r SELECT 1, N'Meses con cifras de control (Parquet procesados)', @meses, N'12', IIF(@meses = 12, 1, 0);
    INSERT INTO @r SELECT 2, N'Meses donde filas Parquet ≠ hecho + cuarentena', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
        FROM #cuadre WHERE dif_filas <> 0;
    INSERT INTO @r SELECT 3, N'Meses donde la suma de total_amount no cuadra al centavo', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
        FROM #cuadre WHERE dif_total <> 0;
    INSERT INTO @r SELECT 4, N'Meses donde la suma de fare_amount no cuadra', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
        FROM #cuadre WHERE dif_tarifa_base <> 0;
    INSERT INTO @r SELECT 5, N'Meses donde la suma de tip_amount no cuadra', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
        FROM #cuadre WHERE dif_propina <> 0;
    INSERT INTO @r SELECT 6, N'Meses donde la suma de trip_distance no cuadra', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
        FROM #cuadre WHERE dif_distancia <> 0;
    INSERT INTO @r SELECT 7, N'Meses donde pasajeros nulos no cuadran', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
        FROM #cuadre WHERE dif_pasajeros_nulos <> 0;
    INSERT INTO @r SELECT 8, N'Meses donde regla R01 (SQL) ≠ filas fuera del mes (Python)', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
        FROM #cuadre WHERE dif_fuera_del_mes <> 0;

    -- Auditoría de cargas
    INSERT INTO @r SELECT 9, N'Meses cuya última carga terminó en OK', COUNT(*), N'= meses', IIF(COUNT(*) = @meses, 1, 0)
        FROM (SELECT periodo, estado, ROW_NUMBER() OVER (PARTITION BY periodo ORDER BY carga_id DESC) AS n
              FROM qa.auditoria_carga WHERE estado IN ('OK', 'ERROR')) AS a
        WHERE n = 1 AND estado = 'OK';
    INSERT INTO @r SELECT 10, N'Cargas que quedaron EN CURSO (interrumpidas)', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
        FROM qa.auditoria_carga WHERE estado = 'EN CURSO';
    INSERT INTO @r SELECT 11, N'Particiones cuyo conteo ≠ filas_hecho de su última carga OK', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
        FROM lab.v_particiones_hecho AS p
        JOIN (SELECT periodo, filas_hecho, ROW_NUMBER() OVER (PARTITION BY periodo ORDER BY carga_id DESC) AS n
              FROM qa.auditoria_carga WHERE estado = 'OK') AS a
          ON a.n = 1 AND CONVERT(INT, REPLACE(a.periodo, '-', '') + '01') = p.desde_key
        WHERE p.filas <> a.filas_hecho;

    -- Estructura física: particiones y columnstore
    INSERT INTO @r SELECT 12, N'Particiones extremas (izquierda y derecha) con filas', ISNULL(SUM(filas), 0), N'0',
           IIF(ISNULL(SUM(filas), 0) = 0, 1, 0)
        FROM lab.v_particiones_hecho
        WHERE particion IN (1, (SELECT MAX(particion) FROM lab.v_particiones_hecho));
    INSERT INTO @r SELECT 13, N'Viajes cuyo fecha_key u hora no corresponden a la recogida', COUNT_BIG(*), N'0',
           IIF(COUNT_BIG(*) = 0, 1, 0)
        FROM dw.fact_viaje
        WHERE fecha_key <> CONVERT(INT, CONVERT(CHAR(8), recogida, 112)) OR hora <> DATEPART(HOUR, recogida);
    INSERT INTO @r SELECT 14, N'Grupos de filas del columnstore sin comprimir (delta store con filas)', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
        FROM sys.dm_db_column_store_row_group_physical_stats
        WHERE object_id = OBJECT_ID(N'dw.fact_viaje') AND state_desc <> 'COMPRESSED'
          AND total_rows > 0;   -- un UPDATE revertido deja un delta store OPEN vacío: no es un problema

    -- Reglas: ningún viaje del hecho debe romper una regla de cuarentena
    INSERT INTO @r SELECT 15, N'Viajes en el hecho con duración ≤ 0 o > 6 h', COUNT_BIG(*), N'0', IIF(COUNT_BIG(*) = 0, 1, 0)
        FROM dw.fact_viaje WHERE duracion_seg <= 0 OR duracion_seg > 6 * 3600;
    INSERT INTO @r SELECT 16, N'Viajes en el hecho con importe negativo, > 200 mi o > 80 mph', COUNT_BIG(*), N'0',
           IIF(COUNT_BIG(*) = 0, 1, 0)
        FROM dw.fact_viaje
        WHERE tarifa_base < 0 OR total < 0 OR distancia_millas > 200 OR distancia_millas * 3600.0 / duracion_seg > 80;

    -- Integridad referencial (no hay FK declaradas: se verifica aquí)
    INSERT INTO @r SELECT 17, N'Huérfanos de dim_fecha', COUNT_BIG(*), N'0', IIF(COUNT_BIG(*) = 0, 1, 0)
        FROM dw.fact_viaje AS v WHERE NOT EXISTS (SELECT 1 FROM dw.dim_fecha AS d WHERE d.fecha_key = v.fecha_key);
    INSERT INTO @r SELECT 18, N'Huérfanos de dim_zona (origen o destino)', COUNT_BIG(*), N'0', IIF(COUNT_BIG(*) = 0, 1, 0)
        FROM dw.fact_viaje AS v
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_zona AS d WHERE d.zona_id = v.zona_origen_id)
           OR NOT EXISTS (SELECT 1 FROM dw.dim_zona AS d WHERE d.zona_id = v.zona_destino_id);
    INSERT INTO @r SELECT 19, N'Huérfanos de dim_proveedor, dim_tipo_pago o dim_tarifa', COUNT_BIG(*), N'0', IIF(COUNT_BIG(*) = 0, 1, 0)
        FROM dw.fact_viaje AS v
        WHERE NOT EXISTS (SELECT 1 FROM dw.dim_proveedor AS d WHERE d.proveedor_id = v.proveedor_id)
           OR NOT EXISTS (SELECT 1 FROM dw.dim_tipo_pago AS d WHERE d.tipo_pago_id = v.tipo_pago_id)
           OR NOT EXISTS (SELECT 1 FROM dw.dim_tarifa AS d WHERE d.tarifa_id = v.tarifa_id);
    INSERT INTO @r SELECT 20, N'Zonas del catálogo oficial cargadas', COUNT(*), N'265', IIF(COUNT(*) = 265, 1, 0)
        FROM dw.dim_zona WHERE es_inferida = 0;

    -- Marts cuadran con el hecho
    DECLARE @viajes BIGINT = (SELECT COUNT_BIG(*) FROM dw.fact_viaje);
    INSERT INTO @r SELECT 21, N'mart.kpi_mensual − hecho (viajes)', ISNULL(SUM(viajes), 0) - @viajes, N'0',
           IIF(ISNULL(SUM(viajes), 0) = @viajes, 1, 0) FROM mart.kpi_mensual;
    INSERT INTO @r SELECT 22, N'mart.demanda_diaria − hecho (viajes)', ISNULL(SUM(viajes), 0) - @viajes, N'0',
           IIF(ISNULL(SUM(viajes), 0) = @viajes, 1, 0) FROM mart.demanda_diaria;
    INSERT INTO @r SELECT 23, N'mart.demanda_dia_hora − hecho (viajes)', ISNULL(SUM(viajes), 0) - @viajes, N'0',
           IIF(ISNULL(SUM(viajes), 0) = @viajes, 1, 0) FROM mart.demanda_dia_hora;
    INSERT INTO @r SELECT 24, N'mart.ruta − hecho (viajes)', ISNULL(SUM(viajes), 0) - @viajes, N'0',
           IIF(ISNULL(SUM(viajes), 0) = @viajes, 1, 0) FROM mart.ruta;
    INSERT INTO @r SELECT 25, N'mart.propina_pago − hecho (viajes)', ISNULL(SUM(viajes), 0) - @viajes, N'0',
           IIF(ISNULL(SUM(viajes), 0) = @viajes, 1, 0) FROM mart.propina_pago;
    INSERT INTO @r SELECT 26, N'Días de 2024 en mart.demanda_diaria', COUNT(*), N'366', IIF(COUNT(*) = 366, 1, 0)
        FROM mart.demanda_diaria;
    INSERT INTO @r SELECT 27, N'Staging vacío al terminar las cargas', COUNT_BIG(*), N'0', IIF(COUNT_BIG(*) = 0, 1, 0)
        FROM stg.viaje;

    DECLARE @ejecucion DATETIME2(0) = SYSDATETIME();
    INSERT INTO qa.resultado_control (ejecucion, orden, control, valor, esperado, estado)
    SELECT @ejecucion, orden, control, valor, esperado, IIF(ok = 1, 'OK', 'ALERTA') FROM @r;

    SELECT orden, control, valor, esperado, IIF(ok = 1, 'OK', 'ALERTA') AS estado FROM @r ORDER BY orden;

    DECLARE @alertas INT = (SELECT COUNT(*) FROM @r WHERE ok = 0);
    IF @alertas > 0 AND @lanzar_error = 1
    BEGIN
        DECLARE @msg NVARCHAR(200) = CONCAT(N'Controles de calidad: ', @alertas, N' en ALERTA. Revisa qa.resultado_control.');
        THROW 50100, @msg, 1;
    END;
    DECLARE @total INT = (SELECT COUNT(*) FROM @r);
    PRINT CONCAT(N'Controles de calidad: ', @total - @alertas, N'/', @total, N' OK');
END;
GO
