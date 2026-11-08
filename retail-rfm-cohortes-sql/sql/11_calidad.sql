/* =====================================================================
   11_calidad.sql
   Pruebas y controles de calidad en SQL.   EXEC qa.sp_validar_calidad;

   Cada control devuelve un valor y lo compara con lo esperado. Si algo no
   cuadra queda en ALERTA y el procedimiento termina con error (THROW) para
   que el pipeline (00_EJECUTAR_TODO / pytest) falle de forma visible.

   Bloques:
     A. Reconciliación fuente -> staging -> limpio -> modelo (cifras de control)
     B. Reglas de limpieza
     C. Integridad del modelo estrella
     D. Coherencia de RFM, cohortes, devoluciones y canasta
   ===================================================================== */
USE RetailAnalitica;
GO

IF OBJECT_ID(N'qa.resultado_control', N'U') IS NULL
CREATE TABLE qa.resultado_control (
    ejecucion   DATETIME2(0)   NOT NULL,
    orden       TINYINT        NOT NULL,
    bloque      CHAR(1)        NOT NULL,
    control     NVARCHAR(200)  NOT NULL,
    valor       DECIMAL(19,3)  NULL,
    esperado    NVARCHAR(40)   NOT NULL,
    estado      VARCHAR(6)     NOT NULL,
    CONSTRAINT PK_resultado_control PRIMARY KEY (ejecucion, orden)
);
GO

CREATE OR ALTER PROCEDURE qa.sp_validar_calidad
    @lanzar_error BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ahora DATETIME2(0) = SYSDATETIME();
    DECLARE @r TABLE (orden TINYINT, bloque CHAR(1), control NVARCHAR(200),
                      valor DECIMAL(19,3), esperado NVARCHAR(40), ok BIT);

    DECLARE @fuente_filas BIGINT, @fuente_cant BIGINT, @fuente_imp DECIMAL(19,3);
    SELECT @fuente_filas = SUM(filas), @fuente_cant = SUM(cantidad_total), @fuente_imp = SUM(importe_total)
    FROM qa.cifra_control;

    /* ---------- A. Reconciliación ---------- */
    INSERT INTO @r
    SELECT 1, 'A', N'Hojas cuyo número de filas en staging difiere de la fuente', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
    FROM qa.cifra_control AS c
    LEFT JOIN (SELECT hoja, COUNT_BIG(*) AS n FROM stg.factura_linea GROUP BY hoja) AS s ON s.hoja = c.hoja
    WHERE ISNULL(s.n, -1) <> c.filas;

    INSERT INTO @r
    SELECT 2, 'A', N'Hojas cuya cantidad total (unidades) en staging difiere de la fuente', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
    FROM qa.cifra_control AS c
    LEFT JOIN (SELECT hoja, SUM(CAST(quantity AS BIGINT)) AS u FROM stg.factura_linea GROUP BY hoja) AS s ON s.hoja = c.hoja
    WHERE ISNULL(s.u, -1) <> c.cantidad_total;

    INSERT INTO @r
    SELECT 3, 'A', N'Hojas cuyo importe en staging difiere de la fuente en más de 0,01 GBP', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
    FROM qa.cifra_control AS c
    LEFT JOIN (SELECT hoja, SUM(CAST(quantity AS INT) * CAST(price AS DECIMAL(10,3))) AS i
               FROM stg.factura_linea GROUP BY hoja) AS s ON s.hoja = c.hoja
    WHERE ABS(ISNULL(s.i, 0) - c.importe_total) > 0.01;

    INSERT INTO @r
    SELECT 4, 'A', N'Filas perdidas al tipar (fuente − limpio)', @fuente_filas - COUNT_BIG(*), N'0',
           IIF(@fuente_filas = COUNT_BIG(*), 1, 0)
    FROM limpio.factura_linea;

    INSERT INTO @r
    SELECT 5, 'A', N'Diferencia de importe fuente − (modelo + excluidas), GBP', @fuente_imp - SUM(importe), N'0',
           IIF(ABS(@fuente_imp - SUM(importe)) <= 0.01, 1, 0)
    FROM limpio.factura_linea;

    INSERT INTO @r
    SELECT 6, 'A', N'Diferencia de unidades fuente − limpio', @fuente_cant - SUM(CAST(cantidad AS BIGINT)), N'0',
           IIF(@fuente_cant = SUM(CAST(cantidad AS BIGINT)), 1, 0)
    FROM limpio.factura_linea;

    INSERT INTO @r
    SELECT 7, 'A', N'Líneas válidas que no llegaron al hecho (o sobran)',
           ABS((SELECT COUNT_BIG(*) FROM limpio.factura_linea WHERE motivo_exclusion IS NULL)
               - (SELECT COUNT_BIG(*) FROM dw.fact_linea)), N'0',
           IIF((SELECT COUNT_BIG(*) FROM limpio.factura_linea WHERE motivo_exclusion IS NULL)
               = (SELECT COUNT_BIG(*) FROM dw.fact_linea), 1, 0);

    INSERT INTO @r
    SELECT 8, 'A', N'Diferencia de importe limpio válido − hecho, GBP',
           (SELECT SUM(importe) FROM limpio.factura_linea WHERE motivo_exclusion IS NULL)
           - (SELECT SUM(importe) FROM dw.fact_linea), N'0',
           IIF((SELECT SUM(importe) FROM limpio.factura_linea WHERE motivo_exclusion IS NULL)
               = (SELECT SUM(importe) FROM dw.fact_linea), 1, 0);

    /* ---------- B. Reglas de limpieza ---------- */
    INSERT INTO @r
    SELECT 9, 'B', N'Líneas del solapamiento entre hojas (1–9 dic 2010) sin marcar como duplicado', COUNT(*), N'0',
           IIF(COUNT(*) = 0, 1, 0)
    FROM limpio.factura_linea
    WHERE hoja = N'Year 2010-2011' AND fecha_hora < '2010-12-10' AND ISNULL(motivo_exclusion, '') <> 'DUPLICADO';

    INSERT INTO @r
    SELECT 10, 'B', N'Grupos duplicados que conservan más de una línea válida', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
    FROM (SELECT 1 AS x FROM limpio.factura_linea WHERE motivo_exclusion IS NULL
          GROUP BY factura, codigo_producto, descripcion, cantidad, fecha_hora, precio, cliente_id, pais
          HAVING COUNT(*) > 1) AS d;

    INSERT INTO @r
    SELECT 11, 'B', N'Hechos con signo incoherente (venta ≤ 0 o devolución ≥ 0)', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
    FROM dw.fact_linea
    WHERE (es_devolucion = 0 AND (cantidad <= 0 OR importe <= 0))
       OR (es_devolucion = 1 AND (cantidad >= 0 OR importe >= 0));

    INSERT INTO @r
    SELECT 12, 'B', N'Hechos con códigos que no son producto (envío, comisiones, ajustes)', COUNT(*), N'0',
           IIF(COUNT(*) = 0, 1, 0)
    FROM dw.fact_linea AS f
    JOIN dw.dim_producto AS p ON p.clave_producto = f.clave_producto
    WHERE p.codigo_producto IN (SELECT codigo_producto FROM limpio.codigo_especial)
       OR p.codigo_producto LIKE N'gift[_]%';

    INSERT INTO @r
    SELECT 13, 'B', N'Hechos fuera del rango de fechas de la fuente', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
    FROM dw.fact_linea
    WHERE fecha_hora < '2009-12-01' OR fecha_hora >= '2011-12-10';

    INSERT INTO @r
    SELECT 14, 'B', N'Líneas sin cliente en limpio = líneas con cliente -1 en el hecho (diferencia)',
           ABS((SELECT COUNT_BIG(*) FROM limpio.factura_linea WHERE motivo_exclusion IS NULL AND cliente_id IS NULL)
               - (SELECT COUNT_BIG(*) FROM dw.fact_linea WHERE clave_cliente = -1)), N'0',
           IIF((SELECT COUNT_BIG(*) FROM limpio.factura_linea WHERE motivo_exclusion IS NULL AND cliente_id IS NULL)
               = (SELECT COUNT_BIG(*) FROM dw.fact_linea WHERE clave_cliente = -1), 1, 0);

    /* ---------- C. Integridad del modelo ---------- */
    INSERT INTO @r
    SELECT 15, 'C', N'Claves foráneas deshabilitadas o no confiables en dw', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
    FROM sys.foreign_keys
    WHERE SCHEMA_NAME(schema_id) = N'dw' AND (is_disabled = 1 OR is_not_trusted = 1);

    INSERT INTO @r
    SELECT 16, 'C', N'Clientes en dim_cliente sin ninguna línea de hecho', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
    FROM dw.dim_cliente AS c
    WHERE NOT EXISTS (SELECT 1 FROM dw.fact_linea AS f WHERE f.clave_cliente = c.clave_cliente);

    INSERT INTO @r
    SELECT 17, 'C', N'Huecos en el calendario dim_fecha (días faltantes)',
           DATEDIFF(DAY, MIN(fecha), MAX(fecha)) + 1 - COUNT(*), N'0',
           IIF(DATEDIFF(DAY, MIN(fecha), MAX(fecha)) + 1 = COUNT(*), 1, 0)
    FROM dw.dim_fecha;

    /* ---------- D. Analítica ---------- */
    INSERT INTO @r
    SELECT 18, 'D', N'Clientes con compra que no están en RFM (o sobran)',
           ABS((SELECT COUNT(*) FROM dw.dim_cliente WHERE clave_cliente <> -1 AND primera_compra IS NOT NULL)
               - (SELECT COUNT(*) FROM mart.cliente_rfm)), N'0',
           IIF((SELECT COUNT(*) FROM dw.dim_cliente WHERE clave_cliente <> -1 AND primera_compra IS NOT NULL)
               = (SELECT COUNT(*) FROM mart.cliente_rfm), 1, 0);

    -- NTILE(5) reparte en 5 grupos cuyo tamaño difiere como máximo en 1
    INSERT INTO @r
    SELECT 19, 'D', N'Puntajes R, F o M con quintiles desbalanceados (> 1 cliente de diferencia)', COUNT(*), N'0',
           IIF(COUNT(*) = 0, 1, 0)
    FROM (
        SELECT x.p
        FROM (SELECT 'r' AS p, COUNT(*) AS n FROM mart.cliente_rfm GROUP BY r
              UNION ALL SELECT 'f', COUNT(*) FROM mart.cliente_rfm GROUP BY f
              UNION ALL SELECT 'm', COUNT(*) FROM mart.cliente_rfm GROUP BY m) AS x
        GROUP BY x.p
        HAVING MAX(x.n) - MIN(x.n) > 1 OR COUNT(*) <> 5
    ) AS d;

    INSERT INTO @r
    SELECT 20, 'D', N'Combinaciones R×F sin segmento o con más de uno', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
    FROM (VALUES (1),(2),(3),(4),(5)) AS r(v)
    CROSS JOIN (VALUES (1),(2),(3),(4),(5)) AS f(v)
    OUTER APPLY (SELECT COUNT(*) AS n FROM mart.regla_segmento AS s
                 WHERE r.v BETWEEN s.r_min AND s.r_max AND f.v BETWEEN s.f_min AND s.f_max) AS s
    WHERE s.n <> 1;

    INSERT INTO @r
    SELECT 21, 'D', N'Cohortes cuya retención en el mes 0 no es 100 %', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
    FROM mart.cohorte_mes WHERE mes_desde = 0 AND tasa_retencion <> 1;

    INSERT INTO @r
    SELECT 22, 'D', N'Suma de tamaños de cohorte − clientes con compra',
           (SELECT SUM(tamano_cohorte) FROM mart.cohorte_mes WHERE mes_desde = 0) - (SELECT COUNT(*) FROM mart.cliente_rfm),
           N'0',
           IIF((SELECT SUM(tamano_cohorte) FROM mart.cohorte_mes WHERE mes_desde = 0) = (SELECT COUNT(*) FROM mart.cliente_rfm), 1, 0);

    -- Ingreso de cohortes = ingreso neto de clientes identificados desde su mes de cohorte
    DECLARE @ing_cohortes DECIMAL(19,2) = (SELECT SUM(ingreso_neto) FROM mart.cohorte_mes);
    DECLARE @ing_hecho DECIMAL(19,2) = (
        SELECT SUM(f.importe) FROM dw.fact_linea AS f
        JOIN dw.dim_cliente AS c ON c.clave_cliente = f.clave_cliente
        WHERE c.cohorte_mes IS NOT NULL AND f.fecha_hora >= c.cohorte_mes);
    INSERT INTO @r
    SELECT 23, 'D', N'Diferencia ingreso de cohortes − hecho (clientes identificados), GBP',
           @ing_cohortes - @ing_hecho, N'0', IIF(ABS(@ing_cohortes - @ing_hecho) <= 0.05, 1, 0);

    INSERT INTO @r
    SELECT 24, 'D', N'Retención fuera de [0, 1] o activos > tamaño de cohorte', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
    FROM mart.cohorte_mes WHERE tasa_retencion < 0 OR tasa_retencion > 1 OR clientes_activos > tamano_cohorte;

    INSERT INTO @r
    SELECT 25, 'D', N'Devoluciones en mart ≠ devoluciones en el hecho (diferencia de líneas)',
           ABS((SELECT COUNT(*) FROM mart.devolucion_linea) - (SELECT COUNT(*) FROM dw.fact_linea WHERE es_devolucion = 1)),
           N'0',
           IIF((SELECT COUNT(*) FROM mart.devolucion_linea) = (SELECT COUNT(*) FROM dw.fact_linea WHERE es_devolucion = 1), 1, 0);

    INSERT INTO @r
    SELECT 26, 'D', N'Devoluciones con compra previa POSTERIOR a la devolución', COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
    FROM mart.devolucion_linea WHERE dias_desde_compra < 0;

    INSERT INTO @r
    SELECT 27, 'D', N'Pares de canasta con métricas imposibles (confianza > 1, soporte_ab > soporte individual)',
           COUNT(*), N'0', IIF(COUNT(*) = 0, 1, 0)
    FROM mart.canasta_par
    WHERE confianza_a_b > 1 OR confianza_b_a > 1 OR lift <= 0
       OR facturas_ab > facturas_a OR facturas_ab > facturas_b;

    /* ---------- Resultado ---------- */
    INSERT INTO qa.resultado_control (ejecucion, orden, bloque, control, valor, esperado, estado)
    SELECT @ahora, orden, bloque, control, valor, esperado, IIF(ok = 1, 'OK', 'ALERTA') FROM @r;

    SELECT orden, bloque, control, valor, esperado, IIF(ok = 1, 'OK', 'ALERTA') AS estado
    FROM @r ORDER BY orden;

    DECLARE @alertas INT = (SELECT COUNT(*) FROM @r WHERE ok = 0), @total INT = (SELECT COUNT(*) FROM @r);
    PRINT CONCAT(N'Controles de calidad: ', @total - @alertas, N' OK, ', @alertas, N' en ALERTA.');
    IF @alertas > 0 AND @lanzar_error = 1
        THROW 50001, N'Hay controles de calidad en ALERTA: revisa qa.resultado_control.', 1;
END;
GO

PRINT N'Controles de calidad creados.';
GO
