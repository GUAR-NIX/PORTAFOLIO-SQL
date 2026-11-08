/* =====================================================================
   05_modelo_estrella.sql
   Modelo estrella pequeño:

       dim_fecha ─┐
     dim_cliente ─┼── fact_linea (grano: línea de factura limpia,
    dim_producto ─┤               ventas en positivo y devoluciones en negativo)
        dim_pais ─┘

   etl.sp_cargar_modelo reconstruye todo desde limpio.factura_linea
   (idempotente: TRUNCATE + INSERT, una sola transacción).
   ===================================================================== */
USE RetailAnalitica;
GO

DROP TABLE IF EXISTS dw.fact_linea;
DROP TABLE IF EXISTS dw.dim_fecha;
DROP TABLE IF EXISTS dw.dim_cliente;
DROP TABLE IF EXISTS dw.dim_producto;
DROP TABLE IF EXISTS dw.dim_pais;
GO

CREATE TABLE dw.dim_fecha (
    clave_fecha     INT          NOT NULL CONSTRAINT PK_dim_fecha PRIMARY KEY,   -- yyyymmdd
    fecha           DATE         NOT NULL,
    anio            SMALLINT     NOT NULL,
    trimestre       TINYINT      NOT NULL,
    mes             TINYINT      NOT NULL,
    nombre_mes      NVARCHAR(12) NOT NULL,
    anio_mes        CHAR(7)      NOT NULL,      -- 2011-03
    inicio_mes      DATE         NOT NULL,
    dia_semana      TINYINT      NOT NULL,      -- 1 = lunes
    nombre_dia      NVARCHAR(12) NOT NULL,
    es_fin_semana   BIT          NOT NULL
);

CREATE TABLE dw.dim_pais (
    clave_pais      INT IDENTITY(1,1) CONSTRAINT PK_dim_pais PRIMARY KEY,
    pais            NVARCHAR(60)  NOT NULL CONSTRAINT UQ_dim_pais UNIQUE,
    pais_es         NVARCHAR(60)  NOT NULL,
    region          NVARCHAR(40)  NOT NULL,
    es_mercado_local BIT          NOT NULL     -- Reino Unido
);

CREATE TABLE dw.dim_producto (
    clave_producto  INT IDENTITY(1,1) CONSTRAINT PK_dim_producto PRIMARY KEY,
    codigo_producto NVARCHAR(20)  NOT NULL CONSTRAINT UQ_dim_producto UNIQUE,
    descripcion     NVARCHAR(200) NOT NULL,     -- la descripción más frecuente del código
    descripciones_distintas INT   NOT NULL,     -- cuántas variantes de texto tenía en la fuente
    precio_mediano  DECIMAL(10,2) NULL
);

CREATE TABLE dw.dim_cliente (
    clave_cliente   INT           NOT NULL CONSTRAINT PK_dim_cliente PRIMARY KEY,  -- = Customer ID; -1 = sin identificar
    cliente_id      INT           NULL,
    pais_principal  NVARCHAR(60)  NOT NULL,
    primera_compra  DATETIME2(0)  NULL,
    ultima_compra   DATETIME2(0)  NULL,
    cohorte_mes     DATE          NULL          -- mes de la primera compra
);

CREATE TABLE dw.fact_linea (
    linea_id        INT           NOT NULL,     -- = limpio.factura_linea.linea_id (linaje)
    clave_fecha     INT           NOT NULL CONSTRAINT FK_fact_fecha    REFERENCES dw.dim_fecha (clave_fecha),
    clave_cliente   INT           NOT NULL CONSTRAINT FK_fact_cliente  REFERENCES dw.dim_cliente (clave_cliente),
    clave_producto  INT           NOT NULL CONSTRAINT FK_fact_producto REFERENCES dw.dim_producto (clave_producto),
    clave_pais      INT           NOT NULL CONSTRAINT FK_fact_pais     REFERENCES dw.dim_pais (clave_pais),
    factura         NVARCHAR(20)  NOT NULL,
    fecha_hora      DATETIME2(0)  NOT NULL,
    es_devolucion   BIT           NOT NULL,
    cantidad        INT           NOT NULL,     -- negativa en devoluciones
    precio_unitario DECIMAL(10,3) NOT NULL,
    importe         DECIMAL(19,3) NOT NULL,     -- cantidad × precio (negativo en devoluciones)
    CONSTRAINT PK_fact_linea PRIMARY KEY NONCLUSTERED (linea_id)
);
CREATE CLUSTERED COLUMNSTORE INDEX CCI_fact_linea ON dw.fact_linea;
GO

CREATE OR ALTER PROCEDURE etl.sp_cargar_modelo
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @inicio DATETIME2(0) = SYSDATETIME(), @filas BIGINT;

    BEGIN TRANSACTION;

    -- Las FK impiden TRUNCATE en dimensiones: primero el hecho, luego DELETE en dimensiones
    TRUNCATE TABLE dw.fact_linea;
    DELETE FROM dw.dim_cliente;
    DELETE FROM dw.dim_producto;
    DELETE FROM dw.dim_pais;
    DELETE FROM dw.dim_fecha;
    DBCC CHECKIDENT ('dw.dim_producto', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('dw.dim_pais', RESEED, 0) WITH NO_INFOMSGS;

    /* dim_fecha: calendario continuo entre la primera y la última fecha */
    DECLARE @desde DATE, @hasta DATE;
    SELECT @desde = MIN(CAST(fecha_hora AS DATE)), @hasta = MAX(CAST(fecha_hora AS DATE))
    FROM limpio.factura_linea;

    WITH n AS (
        SELECT TOP (DATEDIFF(DAY, @desde, @hasta) + 1)
               ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
        FROM sys.all_objects a CROSS JOIN sys.all_objects b
    ), d AS (SELECT DATEADD(DAY, i, @desde) AS fecha FROM n)
    INSERT INTO dw.dim_fecha
    SELECT YEAR(fecha) * 10000 + MONTH(fecha) * 100 + DAY(fecha),
           fecha, YEAR(fecha), DATEPART(QUARTER, fecha), MONTH(fecha),
           CHOOSE(MONTH(fecha), N'enero', N'febrero', N'marzo', N'abril', N'mayo', N'junio', N'julio',
                  N'agosto', N'septiembre', N'octubre', N'noviembre', N'diciembre'),
           CONVERT(CHAR(7), fecha, 120),
           DATEFROMPARTS(YEAR(fecha), MONTH(fecha), 1),
           (DATEDIFF(DAY, '19000101', fecha) % 7) + 1,           -- independiente de SET DATEFIRST
           CHOOSE((DATEDIFF(DAY, '19000101', fecha) % 7) + 1,
                  N'lunes', N'martes', N'miércoles', N'jueves', N'viernes', N'sábado', N'domingo'),
           CASE WHEN DATEDIFF(DAY, '19000101', fecha) % 7 >= 5 THEN 1 ELSE 0 END
    FROM d;

    /* dim_pais: nombre en español y región (referencia en limpio.pais_referencia) */
    INSERT INTO dw.dim_pais (pais, pais_es, region, es_mercado_local)
    SELECT p.pais,
           ISNULL(r.pais_es, p.pais),
           ISNULL(r.region, N'Sin región'),
           CASE WHEN p.pais = N'United Kingdom' THEN 1 ELSE 0 END
    FROM (SELECT DISTINCT pais FROM limpio.factura_linea WHERE motivo_exclusion IS NULL) AS p
    LEFT JOIN limpio.pais_referencia AS r ON r.pais = p.pais
    ORDER BY p.pais;

    /* dim_producto: un código puede tener varias descripciones -> la más frecuente */
    WITH descr AS (
        SELECT codigo_producto, descripcion, COUNT(*) AS veces,
               ROW_NUMBER() OVER (PARTITION BY codigo_producto
                                  ORDER BY COUNT(*) DESC, descripcion) AS rn
        FROM limpio.factura_linea
        WHERE motivo_exclusion IS NULL AND descripcion IS NOT NULL
        GROUP BY codigo_producto, descripcion
    ), precio AS (
        SELECT DISTINCT codigo_producto,
               PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY precio) OVER (PARTITION BY codigo_producto) AS mediana
        FROM limpio.factura_linea
        WHERE motivo_exclusion IS NULL AND es_devolucion = 0
    ), codigos AS (
        SELECT codigo_producto FROM limpio.factura_linea WHERE motivo_exclusion IS NULL GROUP BY codigo_producto
    )
    INSERT INTO dw.dim_producto (codigo_producto, descripcion, descripciones_distintas, precio_mediano)
    SELECT c.codigo_producto,
           ISNULL(d.descripcion, N'(sin descripción)'),
           (SELECT COUNT(*) FROM descr AS x WHERE x.codigo_producto = c.codigo_producto),
           p.mediana
    FROM codigos AS c
    LEFT JOIN descr AS d ON d.codigo_producto = c.codigo_producto AND d.rn = 1
    LEFT JOIN precio AS p ON p.codigo_producto = c.codigo_producto
    ORDER BY c.codigo_producto;

    /* dim_cliente: país principal = el de más líneas; cohorte = mes de la primera compra */
    INSERT INTO dw.dim_cliente (clave_cliente, cliente_id, pais_principal, primera_compra, ultima_compra, cohorte_mes)
    VALUES (-1, NULL, N'(sin identificar)', NULL, NULL, NULL);

    WITH pais AS (
        SELECT cliente_id, pais,
               ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY COUNT(*) DESC, pais) AS rn
        FROM limpio.factura_linea
        WHERE motivo_exclusion IS NULL AND cliente_id IS NOT NULL
        GROUP BY cliente_id, pais
    ), compras AS (
        SELECT cliente_id,
               MIN(CASE WHEN es_devolucion = 0 THEN fecha_hora END) AS primera,
               MAX(CASE WHEN es_devolucion = 0 THEN fecha_hora END) AS ultima
        FROM limpio.factura_linea
        WHERE motivo_exclusion IS NULL AND cliente_id IS NOT NULL
        GROUP BY cliente_id
    )
    INSERT INTO dw.dim_cliente (clave_cliente, cliente_id, pais_principal, primera_compra, ultima_compra, cohorte_mes)
    SELECT c.cliente_id, c.cliente_id, p.pais, c.primera, c.ultima,
           DATEFROMPARTS(YEAR(c.primera), MONTH(c.primera), 1)
    FROM compras AS c
    JOIN pais AS p ON p.cliente_id = c.cliente_id AND p.rn = 1;

    /* Hechos: solo líneas que pasaron la limpieza */
    INSERT INTO dw.fact_linea WITH (TABLOCK)
           (linea_id, clave_fecha, clave_cliente, clave_producto, clave_pais, factura, fecha_hora,
            es_devolucion, cantidad, precio_unitario, importe)
    SELECT l.linea_id,
           YEAR(l.fecha_hora) * 10000 + MONTH(l.fecha_hora) * 100 + DAY(l.fecha_hora),
           ISNULL(l.cliente_id, -1),
           pr.clave_producto,
           pa.clave_pais,
           l.factura, l.fecha_hora, l.es_devolucion, l.cantidad, l.precio, l.importe
    FROM limpio.factura_linea AS l
    JOIN dw.dim_producto AS pr ON pr.codigo_producto = l.codigo_producto
    JOIN dw.dim_pais     AS pa ON pa.pais = l.pais
    WHERE l.motivo_exclusion IS NULL;
    SET @filas = @@ROWCOUNT;

    COMMIT;

    DECLARE @clientes INT = (SELECT COUNT(*) - 1 FROM dw.dim_cliente),
            @productos INT = (SELECT COUNT(*) FROM dw.dim_producto),
            @paises INT = (SELECT COUNT(*) FROM dw.dim_pais);
    INSERT INTO qa.bitacora_carga (paso, filas, inicio, fin, detalle)
    VALUES (N'Modelo estrella', @filas, @inicio, SYSDATETIME(),
            CONCAT(@clientes, N' clientes, ', @productos, N' productos, ', @paises, N' países'));

    PRINT CONCAT(N'Modelo estrella cargado: ', FORMAT(@filas, 'N0'), N' líneas de hecho, ',
                 FORMAT(@clientes, 'N0'), N' clientes, ', FORMAT(@productos, 'N0'), N' productos.');
END;
GO

PRINT N'Modelo estrella creado.';
GO
