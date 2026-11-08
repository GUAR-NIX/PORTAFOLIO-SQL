/* =====================================================================
   02_staging_y_carga.sql — Tabla staging y carga masiva con BULK INSERT
   ===================================================================== */
USE CitiBikeTuning;
GO

CREATE TABLE stg.viaje_crudo
(
    ride_id             VARCHAR(40)   NULL,
    rideable_type       VARCHAR(30)   NULL,
    started_at          VARCHAR(30)   NULL,
    ended_at            VARCHAR(30)   NULL,
    start_station_name  NVARCHAR(200) NULL,
    start_station_id    VARCHAR(40)   NULL,
    end_station_name    NVARCHAR(200) NULL,
    end_station_id      VARCHAR(40)   NULL,
    start_lat           VARCHAR(40)   NULL,
    start_lng           VARCHAR(40)   NULL,
    end_lat             VARCHAR(40)   NULL,
    end_lng             VARCHAR(40)   NULL,
    member_casual       VARCHAR(20)   NULL,
    periodo_archivo     INT           NULL,
    fila_archivo        INT           NULL
);
GO

CREATE TABLE etl.bitacora_carga
(
    id_carga        INT IDENTITY(1,1) PRIMARY KEY,
    etapa           NVARCHAR(80)  NOT NULL,
    filas_afectadas BIGINT        NOT NULL,
    duracion_ms     INT           NOT NULL,
    fecha_registro  DATETIME2(3)  NOT NULL DEFAULT SYSDATETIME()
);
GO

CREATE OR ALTER PROCEDURE etl.sp_cargar_staging
    @carpeta_datos NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 DATETIME2(3) = SYSDATETIME();
    DECLARE @ruta_tsv NVARCHAR(500) = @carpeta_datos + N'\raw\citibike_2024T1.tsv';

    TRUNCATE TABLE stg.viaje_crudo;

    DECLARE @sql NVARCHAR(MAX) = N'
        BULK INSERT stg.viaje_crudo
        FROM ''' + REPLACE(@ruta_tsv, N'''', N'''''') + N'''
        WITH
        (
            FIRSTROW = 2,
            FIELDTERMINATOR = ''\t'',
            ROWTERMINATOR = ''0x0a'',
            CODEPAGE = ''65001'',
            TABLOCK
        );';

    EXEC sys.sp_executesql @sql;

    DECLARE @filas BIGINT = (SELECT COUNT_BIG(*) FROM stg.viaje_crudo);
    INSERT INTO etl.bitacora_carga (etapa, filas_afectadas, duracion_ms)
    VALUES (N'BULK_INSERT_STAGING', @filas, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()));
END;
GO
