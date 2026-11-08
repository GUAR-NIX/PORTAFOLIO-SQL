/* =====================================================================
   11_demo_ventana_deslizante.sql
   Demostración real (y reversible) de la ventana deslizante sobre el hecho de ~40 M filas.

     1. Simula la llegada de 2025-01 con 12 meses de retención:
        SPLIT 20250201 · SWITCH OUT de 2024-01 a dw.fact_viaje_archivo_202401 · MERGE 20240101
     2. Deshace todo: SPLIT 20240101 · SWITCH IN del archivo · MERGE 20250201
   Cada paso queda en lab.ventana_log con sus milisegundos; el estado de las particiones
   en cada etapa queda en lab.ventana_estado. Al final el hecho es idéntico al de antes.
   ===================================================================== */
USE TaxisNYC;
GO

IF OBJECT_ID(N'lab.ventana_estado') IS NULL
    CREATE TABLE lab.ventana_estado (
        etapa      VARCHAR(20) NOT NULL,
        particion  INT         NOT NULL,
        desde_key  INT         NULL,
        hasta_key  INT         NULL,
        filas      BIGINT      NOT NULL,
        CONSTRAINT pk_ventana_estado PRIMARY KEY (etapa, particion)
    );
GO

CREATE OR ALTER PROCEDURE lab.sp_demo_ventana_deslizante
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @filas_antes BIGINT = (SELECT COUNT_BIG(*) FROM dw.fact_viaje), @filas_despues BIGINT;
    TRUNCATE TABLE lab.ventana_log;
    TRUNCATE TABLE lab.ventana_estado;

    INSERT INTO lab.ventana_estado SELECT '1 antes', particion, desde_key, hasta_key, filas FROM lab.v_particiones_hecho;

    -- Llega enero 2025 y se conservan 12 meses: sale enero 2024
    EXEC etl.sp_ventana_deslizante @mes_nuevo = '2025-01', @meses_conservar = 12;
    INSERT INTO lab.ventana_estado SELECT '2 ventana movida', particion, desde_key, hasta_key, filas FROM lab.v_particiones_hecho;
    DECLARE @en_hecho BIGINT = (SELECT COUNT_BIG(*) FROM dw.fact_viaje), @archivadas BIGINT;
    EXEC sys.sp_executesql N'SELECT @n = COUNT_BIG(*) FROM dw.fact_viaje_archivo_202401;',
                           N'@n BIGINT OUTPUT', @n = @archivadas OUTPUT;
    PRINT CONCAT(N'Ventana movida: hecho con ', FORMAT(@en_hecho, N'N0', 'es-EC'),
                 N' filas; archivo 2024-01 con ', FORMAT(@archivadas, N'N0', 'es-EC'));

    -- Deshacer: enero 2024 vuelve al hecho y se quita el límite de prueba de febrero 2025
    EXEC etl.sp_restaurar_mes_archivado @periodo = '2024-01';
    EXEC etl.sp_merge_limite_vacio @key = 20250201;
    INSERT INTO lab.ventana_estado SELECT '3 restaurado', particion, desde_key, hasta_key, filas FROM lab.v_particiones_hecho;

    SET @filas_despues = (SELECT COUNT_BIG(*) FROM dw.fact_viaje);
    IF @filas_despues <> @filas_antes
        THROW 50030, N'La demo de ventana deslizante no dejó el hecho igual que antes.', 1;
    DECLARE @ops INT, @ms INT;
    SELECT @ops = COUNT(*), @ms = SUM(ms) FROM lab.ventana_log;
    PRINT CONCAT(N'Ventana deslizante: ', @ops, N' operaciones, ', @ms, N' ms en total; hecho restaurado con ',
                 FORMAT(@filas_despues, N'N0', 'es-EC'), N' filas');
END;
GO
