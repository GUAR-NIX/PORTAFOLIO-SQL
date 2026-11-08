/* =====================================================================
   02_staging.sql
   Staging de un mes, zonas, cifras de control de la fuente y auditoría de cargas.

   stg.viaje tiene los tipos de la fuente (el CSV sale de un Parquet tipado), sin
   restricciones: cualquier valor absurdo debe llegar hasta las reglas de calidad,
   no romper el BULK INSERT. Se vacía al inicio de cada carga mensual.
   ===================================================================== */
USE TaxisNYC;
GO

IF OBJECT_ID(N'stg.viaje') IS NULL
    CREATE TABLE stg.viaje (
        fila_origen            INT           NOT NULL,   -- fila dentro del Parquet (linaje)
        vendor_id              INT           NULL,
        recogida               DATETIME2(0)  NULL,       -- tpep_pickup_datetime
        llegada                DATETIME2(0)  NULL,       -- tpep_dropoff_datetime
        pasajeros              INT           NULL,
        distancia_millas       DECIMAL(12,2) NULL,
        ratecode_id            INT           NULL,
        envio_diferido         CHAR(1)       NULL,       -- store_and_fwd_flag (Y/N)
        zona_origen_id         INT           NULL,
        zona_destino_id        INT           NULL,
        tipo_pago_id           INT           NULL,
        tarifa_base            DECIMAL(12,2) NULL,       -- fare_amount
        extra                  DECIMAL(12,2) NULL,
        impuesto_mta           DECIMAL(12,2) NULL,
        propina                DECIMAL(12,2) NULL,
        peajes                 DECIMAL(12,2) NULL,
        recargo_mejora         DECIMAL(12,2) NULL,
        total                  DECIMAL(12,2) NULL,
        recargo_congestion     DECIMAL(12,2) NULL,
        cargo_aeropuerto       DECIMAL(12,2) NULL
    );
GO

IF OBJECT_ID(N'stg.zona') IS NULL
    CREATE TABLE stg.zona (
        location_id   NVARCHAR(10)  NULL,
        borough       NVARCHAR(50)  NULL,
        zone          NVARCHAR(100) NULL,
        service_zone  NVARCHAR(50)  NULL
    );
GO

/* Cifras de control: las calcula Python sobre cada Parquet (scripts/descargar_datos.py)
   y SQL Server las lee del JSON. Son el "contrato" contra el que se cuadra cada mes. */
IF OBJECT_ID(N'qa.cifras_control') IS NULL
    CREATE TABLE qa.cifras_control (
        periodo                 CHAR(7)       NOT NULL CONSTRAINT pk_cifras_control PRIMARY KEY,  -- '2024-01'
        archivo                 NVARCHAR(100) NOT NULL,
        csv                     NVARCHAR(100) NOT NULL,
        sha256                  CHAR(64)      NOT NULL,
        bytes_parquet           BIGINT        NOT NULL,
        bytes_csv               BIGINT        NOT NULL,
        filas                   INT           NOT NULL,
        filas_fuera_del_mes     INT           NOT NULL,
        suma_total              DECIMAL(16,2) NOT NULL,
        suma_tarifa_base        DECIMAL(16,2) NOT NULL,
        suma_propina            DECIMAL(16,2) NOT NULL,
        suma_distancia          DECIMAL(16,2) NOT NULL,
        pasajeros_nulos         INT           NOT NULL,
        recogida_min            DATETIME2(0)  NOT NULL,
        recogida_max            DATETIME2(0)  NOT NULL,
        leido_en                DATETIME2(0)  NOT NULL CONSTRAINT df_cifras_leido DEFAULT SYSDATETIME()
    );
GO

/* Bitácora: una fila por intento de carga mensual (también los omitidos y los fallidos) */
IF OBJECT_ID(N'qa.auditoria_carga') IS NULL
    CREATE TABLE qa.auditoria_carga (
        carga_id            INT IDENTITY(1,1) CONSTRAINT pk_auditoria_carga PRIMARY KEY,
        periodo             CHAR(7)        NOT NULL,
        archivo             NVARCHAR(100)  NOT NULL,
        sha256              CHAR(64)       NULL,
        inicio              DATETIME2(3)   NOT NULL CONSTRAINT df_auditoria_inicio DEFAULT SYSDATETIME(),
        fin                 DATETIME2(3)   NULL,
        estado              VARCHAR(10)    NOT NULL,   -- EN CURSO · OK · OMITIDO · ERROR
        filas_archivo       INT            NULL,       -- según las cifras de control
        filas_staging       INT            NULL,
        filas_hecho         INT            NULL,
        filas_cuarentena    INT            NULL,
        seg_bulk_insert     DECIMAL(9,1)   NULL,
        seg_clasificacion   DECIMAL(9,1)   NULL,
        seg_columnstore     DECIMAL(9,1)   NULL,
        ms_switch           INT            NULL,       -- TRUNCATE de la partición + SWITCH (solo metadatos)
        seg_total           DECIMAL(9,1)   NULL,
        usuario             NVARCHAR(128)  NOT NULL CONSTRAINT df_auditoria_usuario DEFAULT SUSER_SNAME(),
        mensaje             NVARCHAR(2000) NULL
    );
GO

/* Lee data/cifras_control.json con OPENROWSET + OPENJSON (sin pasar por Python) */
CREATE OR ALTER PROCEDURE etl.sp_leer_cifras_control
    @carpeta_datos NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @json NVARCHAR(MAX), @sql NVARCHAR(MAX) =
        N'SELECT @j = CAST(BulkColumn AS NVARCHAR(MAX)) FROM OPENROWSET(BULK '''
        + REPLACE(@carpeta_datos, N'''', N'''''') + N'\cifras_control.json'', SINGLE_CLOB) AS f;';
    EXEC sys.sp_executesql @sql, N'@j NVARCHAR(MAX) OUTPUT', @j = @json OUTPUT;

    IF ISJSON(@json) = 0
        THROW 50001, N'cifras_control.json no es un JSON válido. Ejecuta scripts\descargar_datos.py.', 1;

    MERGE qa.cifras_control AS d
    USING (
        SELECT CAST(m.[key] AS CHAR(7)) COLLATE DATABASE_DEFAULT AS periodo, v.*
        FROM OPENJSON(@json, N'$.meses') AS m
        CROSS APPLY OPENJSON(m.[value]) WITH (
            archivo             NVARCHAR(100) N'$.archivo',
            csv                 NVARCHAR(100) N'$.csv',
            sha256              CHAR(64)      N'$.sha256',
            bytes_parquet       BIGINT        N'$.bytes',
            bytes_csv           BIGINT        N'$.csv_bytes',
            filas               INT           N'$.filas',
            filas_fuera_del_mes INT           N'$.filas_fuera_del_mes',
            suma_total          DECIMAL(16,2) N'$.suma_total_amount',
            suma_tarifa_base    DECIMAL(16,2) N'$.suma_fare_amount',
            suma_propina        DECIMAL(16,2) N'$.suma_tip_amount',
            suma_distancia      DECIMAL(16,2) N'$.suma_trip_distance',
            pasajeros_nulos     INT           N'$.pasajeros_nulos',
            recogida_min        DATETIME2(0)  N'$.recogida_min',
            recogida_max        DATETIME2(0)  N'$.recogida_max'
        ) AS v
    ) AS o
    ON d.periodo = o.periodo
    WHEN MATCHED THEN UPDATE SET
        archivo = o.archivo, csv = o.csv, sha256 = o.sha256, bytes_parquet = o.bytes_parquet,
        bytes_csv = o.bytes_csv, filas = o.filas, filas_fuera_del_mes = o.filas_fuera_del_mes,
        suma_total = o.suma_total, suma_tarifa_base = o.suma_tarifa_base, suma_propina = o.suma_propina,
        suma_distancia = o.suma_distancia, pasajeros_nulos = o.pasajeros_nulos,
        recogida_min = o.recogida_min, recogida_max = o.recogida_max, leido_en = SYSDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (periodo, archivo, csv, sha256, bytes_parquet, bytes_csv, filas, filas_fuera_del_mes, suma_total,
         suma_tarifa_base, suma_propina, suma_distancia, pasajeros_nulos, recogida_min, recogida_max)
        VALUES (o.periodo, o.archivo, o.csv, o.sha256, o.bytes_parquet, o.bytes_csv, o.filas,
                o.filas_fuera_del_mes, o.suma_total, o.suma_tarifa_base, o.suma_propina, o.suma_distancia,
                o.pasajeros_nulos, o.recogida_min, o.recogida_max);

    DECLARE @meses INT, @viajes BIGINT;
    SELECT @meses = COUNT(*), @viajes = SUM(CAST(filas AS BIGINT)) FROM qa.cifras_control;
    PRINT CONCAT(N'Cifras de control: ', @meses, N' meses, ', FORMAT(@viajes, N'N0', 'es-EC'), N' viajes');
END;
GO
