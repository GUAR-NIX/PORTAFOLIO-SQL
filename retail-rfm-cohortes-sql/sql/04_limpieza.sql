/* =====================================================================
   04_limpieza.sql
   etl.sp_limpiar: staging (texto) -> limpio.factura_linea (tipado y clasificado).

   Ninguna fila se borra: cada línea del archivo queda en limpio.factura_linea
   con un motivo_exclusion (NULL = entra al modelo). Así la reconciliación
   fuente = modelo + excluidas cuadra fila por fila y peso por peso.

   Reglas, en orden de prioridad (la primera que aplica gana):
     1 DUPLICADO            línea idéntica en las 8 columnas de la fuente; se
                            conserva la primera (hoja más antigua, fila menor).
                            Incluye el solapamiento entre hojas (1–9 dic 2010).
     2 AJUSTE_DEUDA         facturas que empiezan con 'A' ("Adjust bad debt").
     3 CODIGO_NO_PRODUCTO   envío, comisiones, ajustes manuales, muestras...
                            (limpio.codigo_especial). No son ventas de producto.
     4 MOVIMIENTO_INVENTARIO cantidad negativa SIN factura 'C' y precio 0: son
                            mermas/ajustes de bodega ("damaged", "lost"...).
     5 PRECIO_CERO          precio 0 en una factura normal (regalos, errores).
     6 CANTIDAD_INVALIDA    cantidad <= 0 en factura normal o > 0 en factura 'C'.
   Las facturas que empiezan con 'C' son DEVOLUCIONES/cancelaciones: entran al
   modelo con cantidad e importe negativos (es_devolucion = 1).
   Clientes nulos: NO se excluyen (son ingreso real), pero quedan fuera de los
   análisis por cliente (RFM, cohortes) con clave_cliente = -1.
   ===================================================================== */
USE RetailAnalitica;
GO

/* Códigos de stock que no son productos (identificados en el perfilado) */
DROP TABLE IF EXISTS limpio.codigo_especial;
CREATE TABLE limpio.codigo_especial (
    codigo_producto NVARCHAR(20)  NOT NULL CONSTRAINT PK_codigo_especial PRIMARY KEY,
    significado     NVARCHAR(100) NOT NULL
);
INSERT INTO limpio.codigo_especial (codigo_producto, significado) VALUES
 (N'POST',         N'Gastos de envío'),
 (N'DOT',          N'Gastos de envío (dotcom)'),
 (N'C2',           N'Transporte'),
 (N'M',            N'Ajuste manual (también "m": la intercalación no distingue mayúsculas)'),
 (N'D',            N'Descuento'),
 (N'S',            N'Muestras'),
 (N'B',            N'Ajuste de deuda'),
 (N'BANK CHARGES', N'Comisión bancaria'),
 (N'AMAZONFEE',    N'Comisión de Amazon'),
 (N'CRUK',         N'Comisión CRUK'),
 (N'PADS',         N'Relleno de embalaje'),
 (N'ADJUST',       N'Ajuste'),
 (N'ADJUST2',      N'Ajuste'),
 (N'TEST001',      N'Prueba'),
 (N'TEST002',      N'Prueba');
-- Tarjetas de regalo (gift_0001_10, gift_0001_20, ...) se agregan por patrón en el procedimiento
GO

/* Países: nombre en español y región */
DROP TABLE IF EXISTS limpio.pais_referencia;
CREATE TABLE limpio.pais_referencia (
    pais     NVARCHAR(60) NOT NULL CONSTRAINT PK_pais_referencia PRIMARY KEY,
    pais_es  NVARCHAR(60) NOT NULL,
    region   NVARCHAR(40) NOT NULL
);
INSERT INTO limpio.pais_referencia (pais, pais_es, region) VALUES
 (N'United Kingdom', N'Reino Unido', N'Reino Unido'),
 (N'EIRE', N'Irlanda', N'Europa'), (N'Channel Islands', N'Islas del Canal', N'Europa'),
 (N'France', N'Francia', N'Europa'), (N'Germany', N'Alemania', N'Europa'),
 (N'Netherlands', N'Países Bajos', N'Europa'), (N'Belgium', N'Bélgica', N'Europa'),
 (N'Spain', N'España', N'Europa'), (N'Portugal', N'Portugal', N'Europa'),
 (N'Italy', N'Italia', N'Europa'), (N'Switzerland', N'Suiza', N'Europa'),
 (N'Austria', N'Austria', N'Europa'), (N'Denmark', N'Dinamarca', N'Europa'),
 (N'Sweden', N'Suecia', N'Europa'), (N'Norway', N'Noruega', N'Europa'),
 (N'Finland', N'Finlandia', N'Europa'), (N'Iceland', N'Islandia', N'Europa'),
 (N'Poland', N'Polonia', N'Europa'), (N'Lithuania', N'Lituania', N'Europa'),
 (N'Czech Republic', N'República Checa', N'Europa'), (N'Greece', N'Grecia', N'Europa'),
 (N'Cyprus', N'Chipre', N'Europa'), (N'Malta', N'Malta', N'Europa'),
 (N'European Community', N'Comunidad Europea', N'Europa'),
 (N'USA', N'Estados Unidos', N'América'), (N'Canada', N'Canadá', N'América'),
 (N'Brazil', N'Brasil', N'América'), (N'West Indies', N'Antillas', N'América'),
 (N'Bermuda', N'Bermudas', N'América'),
 (N'Israel', N'Israel', N'Medio Oriente'), (N'Lebanon', N'Líbano', N'Medio Oriente'),
 (N'United Arab Emirates', N'Emiratos Árabes Unidos', N'Medio Oriente'),
 (N'Saudi Arabia', N'Arabia Saudita', N'Medio Oriente'), (N'Bahrain', N'Baréin', N'Medio Oriente'),
 (N'Japan', N'Japón', N'Asia-Pacífico'), (N'Singapore', N'Singapur', N'Asia-Pacífico'),
 (N'Hong Kong', N'Hong Kong', N'Asia-Pacífico'), (N'Korea', N'Corea del Sur', N'Asia-Pacífico'),
 (N'Thailand', N'Tailandia', N'Asia-Pacífico'), (N'Australia', N'Australia', N'Asia-Pacífico'),
 (N'RSA', N'Sudáfrica', N'África'), (N'Nigeria', N'Nigeria', N'África'),
 (N'Unspecified', N'Sin especificar', N'Sin región');
GO

DROP TABLE IF EXISTS limpio.factura_linea;
CREATE TABLE limpio.factura_linea (
    linea_id          INT IDENTITY(1,1) CONSTRAINT PK_limpio_linea PRIMARY KEY,
    hoja              NVARCHAR(20)   NOT NULL,
    fila_origen       INT            NOT NULL,
    factura           NVARCHAR(20)   NOT NULL,
    codigo_producto   NVARCHAR(20)   NOT NULL,
    descripcion       NVARCHAR(200)  NULL,
    cantidad          INT            NOT NULL,
    fecha_hora        DATETIME2(0)   NOT NULL,
    precio            DECIMAL(10,3)  NOT NULL,
    cliente_id        INT            NULL,
    pais              NVARCHAR(60)   NOT NULL,
    importe           AS CAST(cantidad * precio AS DECIMAL(19,3)) PERSISTED,
    es_devolucion     AS CAST(CASE WHEN factura LIKE N'C%' THEN 1 ELSE 0 END AS BIT) PERSISTED,
    es_duplicado_entre_hojas BIT     NOT NULL DEFAULT 0,
    motivo_exclusion  VARCHAR(30)    NULL,
    CONSTRAINT UQ_limpio_origen UNIQUE (hoja, fila_origen)
) WITH (DATA_COMPRESSION = ROW);
GO

CREATE OR ALTER PROCEDURE etl.sp_limpiar
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @inicio DATETIME2(0) = SYSDATETIME(), @filas BIGINT;

    BEGIN TRANSACTION;
    TRUNCATE TABLE limpio.factura_linea;

    /* 1. Tipado. TRY_CONVERT no aborta: si algo no convierte, el NOT NULL de la
          tabla lo hace fallar y lo vemos (mejor ruidoso que silencioso). */
    INSERT INTO limpio.factura_linea WITH (TABLOCK)
           (hoja, fila_origen, factura, codigo_producto, descripcion, cantidad,
            fecha_hora, precio, cliente_id, pais)
    SELECT hoja, fila_origen,
           invoice,
           stock_code,
           NULLIF(LTRIM(RTRIM(description)), N''),
           TRY_CONVERT(INT, quantity),
           TRY_CONVERT(DATETIME2(0), invoice_date, 120),
           TRY_CONVERT(DECIMAL(10,3), price),
           TRY_CONVERT(INT, NULLIF(customer_id, N'')),
           country
    FROM stg.factura_linea
    ORDER BY hoja, fila_origen;
    SET @filas = @@ROWCOUNT;

    /* 2. Duplicados exactos (8 columnas de la fuente) */
    WITH d AS (
        SELECT motivo_exclusion, es_duplicado_entre_hojas, hoja,
               ROW_NUMBER() OVER (PARTITION BY factura, codigo_producto, descripcion, cantidad,
                                               fecha_hora, precio, cliente_id, pais
                                  ORDER BY hoja, fila_origen) AS rn,
               MIN(hoja) OVER (PARTITION BY factura, codigo_producto, descripcion, cantidad,
                                            fecha_hora, precio, cliente_id, pais) AS primera_hoja
        FROM limpio.factura_linea
    )
    UPDATE d
    SET motivo_exclusion = 'DUPLICADO',
        es_duplicado_entre_hojas = CASE WHEN hoja <> primera_hoja THEN 1 ELSE 0 END
    WHERE rn > 1;

    /* 3–6. Resto de reglas, en orden de prioridad */
    UPDATE l
    SET motivo_exclusion =
        CASE
            WHEN l.factura LIKE N'A%'                                        THEN 'AJUSTE_DEUDA'
            WHEN e.codigo_producto IS NOT NULL
              OR l.codigo_producto LIKE N'gift[_]%'                           THEN 'CODIGO_NO_PRODUCTO'
            WHEN l.factura NOT LIKE N'C%' AND l.cantidad < 0 AND l.precio = 0 THEN 'MOVIMIENTO_INVENTARIO'
            WHEN l.precio = 0                                                 THEN 'PRECIO_CERO'
            WHEN l.factura NOT LIKE N'C%' AND l.cantidad <= 0                 THEN 'CANTIDAD_INVALIDA'
            WHEN l.factura LIKE N'C%'     AND l.cantidad >= 0                 THEN 'CANTIDAD_INVALIDA'
            WHEN l.precio < 0                                                 THEN 'CANTIDAD_INVALIDA'
        END
    FROM limpio.factura_linea AS l
    LEFT JOIN limpio.codigo_especial AS e
           ON e.codigo_producto = l.codigo_producto
    WHERE l.motivo_exclusion IS NULL;

    COMMIT;

    DECLARE @validas BIGINT = (SELECT COUNT_BIG(*) FROM limpio.factura_linea WHERE motivo_exclusion IS NULL);
    INSERT INTO qa.bitacora_carga (paso, filas, inicio, fin, detalle)
    VALUES (N'Limpieza', @filas, @inicio, SYSDATETIME(), CONCAT(@validas, N' líneas válidas'));

    PRINT CONCAT(N'Limpieza: ', FORMAT(@filas, 'N0'), N' líneas tipadas.');
    SELECT ISNULL(motivo_exclusion, '(válida)')   AS motivo,
           COUNT_BIG(*)                           AS lineas,
           SUM(importe)                           AS importe,
           SUM(CAST(es_duplicado_entre_hojas AS INT)) AS duplicados_entre_hojas
    FROM limpio.factura_linea
    GROUP BY motivo_exclusion
    ORDER BY lineas DESC;
END;
GO

PRINT N'Limpieza creada.';
GO
