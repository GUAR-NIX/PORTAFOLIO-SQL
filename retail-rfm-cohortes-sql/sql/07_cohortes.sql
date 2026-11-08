/* =====================================================================
   07_cohortes.sql
   Cohortes mensuales: cada cliente pertenece a la cohorte del mes de su
   primera compra (dw.dim_cliente.cohorte_mes).

   mart.cohorte_mes (formato largo, una fila por cohorte × mes transcurrido):
     clientes_activos   clientes de la cohorte con al menos una COMPRA ese mes
     tasa_retencion     clientes_activos / tamaño de la cohorte (mes 0 = 100 %)
     ingreso_neto       ventas − devoluciones de la cohorte en ese mes
     ingreso_acum_por_cliente  ingreso acumulado / tamaño (curva de valor)

   Advertencias que también van al README:
     · La cohorte dic-2009 está censurada a la izquierda: el archivo empieza
       ese mes, así que mezcla clientes nuevos con clientes antiguos.
     · dic-2011 solo tiene 9 días: su retención está subestimada.

   etl.sp_matriz_retencion devuelve la matriz cohorte × mes con PIVOT dinámico.
   ===================================================================== */
USE RetailAnalitica;
GO

DROP TABLE IF EXISTS mart.cohorte_mes;
CREATE TABLE mart.cohorte_mes (
    cohorte_mes          DATE          NOT NULL,
    mes_desde            TINYINT       NOT NULL,     -- 0 = mes de la primera compra
    mes_calendario       DATE          NOT NULL,
    tamano_cohorte       INT           NOT NULL,
    clientes_activos     INT           NOT NULL,
    tasa_retencion       DECIMAL(7,4)  NOT NULL,
    ingreso_neto         DECIMAL(19,2) NOT NULL,
    ingreso_acumulado    DECIMAL(19,2) NOT NULL,
    ingreso_acum_por_cliente DECIMAL(19,2) NOT NULL,
    CONSTRAINT PK_cohorte_mes PRIMARY KEY (cohorte_mes, mes_desde)
);
GO

CREATE OR ALTER PROCEDURE etl.sp_calcular_cohortes
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @inicio DATETIME2(0) = SYSDATETIME();
    DECLARE @ultimo_mes DATE = (SELECT MAX(inicio_mes) FROM dw.dim_fecha);

    TRUNCATE TABLE mart.cohorte_mes;

    WITH clientes AS (
        SELECT clave_cliente, cohorte_mes
        FROM dw.dim_cliente
        WHERE clave_cliente <> -1 AND cohorte_mes IS NOT NULL
    ), tamano AS (
        SELECT cohorte_mes, COUNT(*) AS tamano FROM clientes GROUP BY cohorte_mes
    ), meses AS (                       -- rejilla completa: cohortes × meses posibles (incluye ceros)
        SELECT t.cohorte_mes, t.tamano, d.inicio_mes AS mes_calendario,
               DATEDIFF(MONTH, t.cohorte_mes, d.inicio_mes) AS mes_desde
        FROM tamano AS t
        JOIN (SELECT DISTINCT inicio_mes FROM dw.dim_fecha) AS d
          ON d.inicio_mes >= t.cohorte_mes AND d.inicio_mes <= @ultimo_mes
    ), actividad AS (
        SELECT c.cohorte_mes, df.inicio_mes AS mes_calendario,
               COUNT(DISTINCT CASE WHEN f.es_devolucion = 0 THEN f.clave_cliente END) AS activos,
               SUM(f.importe) AS ingreso
        FROM dw.fact_linea AS f
        JOIN clientes   AS c  ON c.clave_cliente = f.clave_cliente
        JOIN dw.dim_fecha AS df ON df.clave_fecha = f.clave_fecha
        GROUP BY c.cohorte_mes, df.inicio_mes
    )
    INSERT INTO mart.cohorte_mes
    SELECT m.cohorte_mes, m.mes_desde, m.mes_calendario, m.tamano,
           ISNULL(a.activos, 0),
           CAST(ISNULL(a.activos, 0) * 1.0 / m.tamano AS DECIMAL(7,4)),
           ISNULL(a.ingreso, 0),
           SUM(ISNULL(a.ingreso, 0)) OVER (PARTITION BY m.cohorte_mes ORDER BY m.mes_desde
                                           ROWS UNBOUNDED PRECEDING),
           SUM(ISNULL(a.ingreso, 0)) OVER (PARTITION BY m.cohorte_mes ORDER BY m.mes_desde
                                           ROWS UNBOUNDED PRECEDING) / m.tamano
    FROM meses AS m
    LEFT JOIN actividad AS a
           ON a.cohorte_mes = m.cohorte_mes AND a.mes_calendario = m.mes_calendario;

    DECLARE @filas INT = @@ROWCOUNT;
    INSERT INTO qa.bitacora_carga (paso, filas, inicio, fin, detalle)
    VALUES (N'Cohortes', @filas, @inicio, SYSDATETIME(), N'cohorte × mes');
    PRINT CONCAT(N'Cohortes calculadas: ', @filas, N' celdas cohorte × mes.');
END;
GO

/* Matriz de retención (o de ingreso acumulado por cliente) con PIVOT dinámico.
   EXEC etl.sp_matriz_retencion;                         -- % retención
   EXEC etl.sp_matriz_retencion @metrica = 'ingreso';    -- GBP acumulados por cliente */
CREATE OR ALTER PROCEDURE etl.sp_matriz_retencion
    @metrica   VARCHAR(10) = 'retencion',
    @max_meses TINYINT     = 12
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @columnas NVARCHAR(MAX), @sql NVARCHAR(MAX);

    SELECT @columnas = STRING_AGG(QUOTENAME(CONCAT('M', mes_desde)), ',') WITHIN GROUP (ORDER BY mes_desde)
    FROM (SELECT DISTINCT mes_desde FROM mart.cohorte_mes WHERE mes_desde <= @max_meses) AS x;

    SET @sql = N'
    SELECT cohorte, tamano_cohorte, ' + @columnas + N'
    FROM (
        SELECT CONVERT(CHAR(7), cohorte_mes, 120) AS cohorte, tamano_cohorte,
               CONCAT(''M'', mes_desde) AS mes,
               ' + CASE WHEN @metrica = 'ingreso' THEN N'ingreso_acum_por_cliente'
                        ELSE N'CAST(tasa_retencion * 100 AS DECIMAL(5,1))' END + N' AS valor
        FROM mart.cohorte_mes
        WHERE mes_desde <= @max
    ) AS src
    PIVOT (MAX(valor) FOR mes IN (' + @columnas + N')) AS p
    ORDER BY cohorte;';
    EXEC sys.sp_executesql @sql, N'@max TINYINT', @max = @max_meses;
END;
GO

PRINT N'Cohortes creadas.';
GO
