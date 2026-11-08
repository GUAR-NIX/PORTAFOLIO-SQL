/* =====================================================================
   09_canasta.sql
   Análisis de canasta: pares de productos que se compran juntos.

   Para cada par (A, B) dentro de la misma factura de venta:
     soporte(A,B)    = facturas con A y B / total de facturas
     confianza(A→B)  = facturas con A y B / facturas con A
     lift(A,B)       = soporte(A,B) / (soporte(A) × soporte(B))
                       > 1: se compran juntos más de lo que dicta el azar

   Control de tamaño: el auto-join factura × factura crece con el cuadrado de
   los productos por factura. Se limita a productos presentes en al menos
   @min_facturas_producto facturas y se guardan pares con al menos
   @min_facturas_par facturas en común. Todo en tablas temporales indexadas.
   ===================================================================== */
USE RetailAnalitica;
GO

DROP TABLE IF EXISTS mart.canasta_par;
CREATE TABLE mart.canasta_par (
    clave_producto_a  INT           NOT NULL,
    clave_producto_b  INT           NOT NULL,
    facturas_a        INT           NOT NULL,
    facturas_b        INT           NOT NULL,
    facturas_ab       INT           NOT NULL,
    total_facturas    INT           NOT NULL,
    soporte           DECIMAL(9,6)  NOT NULL,
    confianza_a_b     DECIMAL(9,6)  NOT NULL,
    confianza_b_a     DECIMAL(9,6)  NOT NULL,
    lift              DECIMAL(9,3)  NOT NULL,
    CONSTRAINT PK_canasta_par PRIMARY KEY (clave_producto_a, clave_producto_b),
    CONSTRAINT CK_canasta_orden CHECK (clave_producto_a < clave_producto_b)
);
GO

CREATE OR ALTER PROCEDURE etl.sp_calcular_canasta
    @min_facturas_producto INT = 200,
    @min_facturas_par      INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @inicio DATETIME2(0) = SYSDATETIME(), @total INT;

    TRUNCATE TABLE mart.canasta_par;

    /* Factura × producto distinto (solo ventas) */
    DROP TABLE IF EXISTS #fp;
    SELECT DISTINCT factura, clave_producto
    INTO #fp
    FROM dw.fact_linea
    WHERE es_devolucion = 0;

    SELECT @total = COUNT(DISTINCT factura) FROM #fp;

    DROP TABLE IF EXISTS #prod;
    SELECT clave_producto, COUNT(*) AS facturas
    INTO #prod
    FROM #fp
    GROUP BY clave_producto
    HAVING COUNT(*) >= @min_facturas_producto;

    DELETE fp FROM #fp AS fp WHERE NOT EXISTS (SELECT 1 FROM #prod AS p WHERE p.clave_producto = fp.clave_producto);
    CREATE CLUSTERED INDEX IX_fp ON #fp (factura, clave_producto);

    INSERT INTO mart.canasta_par
    SELECT x.a, x.b, pa.facturas, pb.facturas, x.ab, @total,
           CAST(x.ab * 1.0 / @total AS DECIMAL(9,6)),
           CAST(x.ab * 1.0 / pa.facturas AS DECIMAL(9,6)),
           CAST(x.ab * 1.0 / pb.facturas AS DECIMAL(9,6)),
           CAST((x.ab * 1.0 / @total) / ((pa.facturas * 1.0 / @total) * (pb.facturas * 1.0 / @total)) AS DECIMAL(9,3))
    FROM (
        SELECT a.clave_producto AS a, b.clave_producto AS b, COUNT(*) AS ab
        FROM #fp AS a
        JOIN #fp AS b ON b.factura = a.factura AND b.clave_producto > a.clave_producto
        GROUP BY a.clave_producto, b.clave_producto
        HAVING COUNT(*) >= @min_facturas_par
    ) AS x
    JOIN #prod AS pa ON pa.clave_producto = x.a
    JOIN #prod AS pb ON pb.clave_producto = x.b;

    DECLARE @filas INT = @@ROWCOUNT;
    INSERT INTO qa.bitacora_carga (paso, filas, inicio, fin, detalle)
    VALUES (N'Canasta', @filas, @inicio, SYSDATETIME(),
            CONCAT(N'productos ≥ ', @min_facturas_producto, N' facturas; pares ≥ ', @min_facturas_par));
    PRINT CONCAT(N'Canasta: ', FORMAT(@filas, 'N0'), N' pares frecuentes sobre ', FORMAT(@total, 'N0'), N' facturas.');
END;
GO

PRINT N'Canasta creada.';
GO
