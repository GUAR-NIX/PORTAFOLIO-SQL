/* =====================================================================
   02_staging.sql
   Tabla de staging (texto, mismo orden que el CSV) y tablas de auditoría.
   ===================================================================== */
USE RetailAnalitica;
GO

DROP TABLE IF EXISTS stg.factura_linea;
CREATE TABLE stg.factura_linea (
    hoja          NVARCHAR(20)   NOT NULL,   -- hoja del Excel de origen (linaje)
    fila_origen   INT            NOT NULL,   -- fila dentro de la hoja (linaje)
    invoice       NVARCHAR(20)   NULL,
    stock_code    NVARCHAR(20)   NULL,
    description   NVARCHAR(200)  NULL,
    quantity      NVARCHAR(20)   NULL,
    invoice_date  NVARCHAR(30)   NULL,
    price         NVARCHAR(30)   NULL,
    customer_id   NVARCHAR(20)   NULL,
    country       NVARCHAR(60)   NULL
) WITH (DATA_COMPRESSION = ROW);
GO

-- Bitácora de cargas
IF OBJECT_ID(N'qa.bitacora_carga', N'U') IS NULL
CREATE TABLE qa.bitacora_carga (
    carga_id     INT IDENTITY(1,1) CONSTRAINT PK_bitacora_carga PRIMARY KEY,
    paso         NVARCHAR(60)   NOT NULL,
    filas        BIGINT         NULL,
    inicio       DATETIME2(0)   NOT NULL,
    fin          DATETIME2(0)   NULL,
    segundos     AS DATEDIFF(SECOND, inicio, fin),
    detalle      NVARCHAR(400)  NULL
);
GO

-- Cifras de control de la FUENTE (calculadas fuera de SQL Server por descargar_datos.py).
-- Es el "contrato" contra el que se reconcilia todo lo que se carga.
IF OBJECT_ID(N'qa.cifra_control', N'U') IS NULL
CREATE TABLE qa.cifra_control (
    hoja             NVARCHAR(20)   NOT NULL CONSTRAINT PK_cifra_control PRIMARY KEY,
    filas            BIGINT         NOT NULL,
    cantidad_total   BIGINT         NOT NULL,
    importe_total    DECIMAL(19,3)  NOT NULL
);
GO

PRINT N'Staging y auditoría listos.';
GO
