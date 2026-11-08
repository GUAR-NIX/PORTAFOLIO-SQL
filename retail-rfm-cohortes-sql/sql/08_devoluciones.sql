/* =====================================================================
   08_devoluciones.sql
   Análisis de devoluciones (facturas 'C').

   mart.devolucion_linea: cada línea devuelta con la ÚLTIMA compra previa del
   mismo cliente y producto, para medir días hasta la devolución. Se resuelve
   con una sola pasada de ventana (MAX ... ROWS UNBOUNDED PRECEDING) en vez de
   un OUTER APPLY fila por fila: 1 lectura del hecho en lugar de 19 mil.

   Si no hay compra previa en el archivo (la compra fue antes de dic-2009)
   la devolución queda "sin compra previa": es otra forma de censura.
   ===================================================================== */
USE RetailAnalitica;
GO

DROP TABLE IF EXISTS mart.devolucion_linea;
CREATE TABLE mart.devolucion_linea (
    linea_id             INT           NOT NULL CONSTRAINT PK_devolucion_linea PRIMARY KEY,
    clave_cliente        INT           NOT NULL,
    clave_producto       INT           NOT NULL,
    clave_pais           INT           NOT NULL,
    fecha_devolucion     DATETIME2(0)  NOT NULL,
    unidades             INT           NOT NULL,     -- en positivo
    importe              DECIMAL(19,3) NOT NULL,     -- en positivo
    fecha_compra_previa  DATETIME2(0)  NULL,
    dias_desde_compra    INT           NULL
);
GO

CREATE OR ALTER PROCEDURE etl.sp_calcular_devoluciones
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @inicio DATETIME2(0) = SYSDATETIME();

    TRUNCATE TABLE mart.devolucion_linea;

    WITH eventos AS (
        SELECT linea_id, clave_cliente, clave_producto, clave_pais, fecha_hora, es_devolucion,
               cantidad, importe,
               -- última compra (no devolución) del mismo cliente y producto hasta esta línea
               MAX(CASE WHEN es_devolucion = 0 THEN fecha_hora END)
                   OVER (PARTITION BY clave_cliente, clave_producto
                         ORDER BY fecha_hora, es_devolucion, linea_id
                         ROWS UNBOUNDED PRECEDING) AS compra_previa
        FROM dw.fact_linea
        WHERE clave_cliente <> -1
    )
    INSERT INTO mart.devolucion_linea
    SELECT linea_id, clave_cliente, clave_producto, clave_pais, fecha_hora,
           -cantidad, -importe, compra_previa, DATEDIFF(DAY, compra_previa, fecha_hora)
    FROM eventos
    WHERE es_devolucion = 1;

    -- Devoluciones de clientes no identificados (sin cliente no hay compra previa que buscar)
    INSERT INTO mart.devolucion_linea
    SELECT linea_id, clave_cliente, clave_producto, clave_pais, fecha_hora, -cantidad, -importe, NULL, NULL
    FROM dw.fact_linea
    WHERE clave_cliente = -1 AND es_devolucion = 1;

    DECLARE @filas INT = (SELECT COUNT(*) FROM mart.devolucion_linea);
    INSERT INTO qa.bitacora_carga (paso, filas, inicio, fin, detalle)
    VALUES (N'Devoluciones', @filas, @inicio, SYSDATETIME(), N'líneas devueltas');
    PRINT CONCAT(N'Devoluciones: ', FORMAT(@filas, 'N0'), N' líneas.');
END;
GO

PRINT N'Devoluciones creadas.';
GO
