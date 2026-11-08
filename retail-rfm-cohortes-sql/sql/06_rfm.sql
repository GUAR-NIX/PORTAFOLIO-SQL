/* =====================================================================
   06_rfm.sql
   Segmentación RFM (Recencia, Frecuencia, Monto) con NTILE(5).

   Definiciones (solo clientes identificados con al menos una compra):
     fecha de corte = día siguiente a la última factura del archivo (2011-12-10)
     Recencia   = días desde la última compra hasta la fecha de corte
     Frecuencia = facturas de venta distintas
     Monto      = importe NETO de producto (ventas − devoluciones), en GBP

   Puntajes 1–5 (5 = mejor) con NTILE(5):
     R ordena por recencia descendente (más reciente = 5)
     F ordena por frecuencia y DESEMPATA por monto: más del 30 % de los
       clientes compró una sola vez, y NTILE reparte los empates entre
       quintiles de forma arbitraria. Desempatar por monto hace que esa
       división tenga sentido de negocio y sea determinista.
     M ordena por monto.
     Todas llevan cliente_id al final del ORDER BY: mismo resultado en cada corrida.

   Segmentos: mapa clásico R × F (10 segmentos) guardado como DATOS en
   mart.regla_segmento, no como un CASE escondido en el código.
   ===================================================================== */
USE RetailAnalitica;
GO

DROP TABLE IF EXISTS mart.regla_segmento;
CREATE TABLE mart.regla_segmento (
    segmento        NVARCHAR(30)  NOT NULL CONSTRAINT PK_regla_segmento PRIMARY KEY,
    r_min TINYINT NOT NULL, r_max TINYINT NOT NULL,
    f_min TINYINT NOT NULL, f_max TINYINT NOT NULL,
    orden           TINYINT       NOT NULL,
    accion_sugerida NVARCHAR(200) NOT NULL
);
INSERT INTO mart.regla_segmento VALUES
 (N'Campeones',           5, 5, 4, 5,  1, N'Recompensar, pedir reseñas, acceso anticipado a novedades'),
 (N'Leales',              3, 4, 4, 5,  2, N'Venta cruzada y programa de fidelidad'),
 (N'Leales potenciales',  4, 5, 2, 3,  3, N'Ofrecer membresía y recomendaciones personalizadas'),
 (N'Nuevos',              5, 5, 1, 1,  4, N'Onboarding y segunda compra con incentivo'),
 (N'Prometedores',        4, 4, 1, 1,  5, N'Crear marca: contenido y ofertas de bajo costo'),
 (N'Requieren atención',  3, 3, 3, 3,  6, N'Ofertas por tiempo limitado según historial'),
 (N'Por dormirse',        3, 3, 1, 2,  7, N'Reactivar con productos populares y descuentos'),
 (N'En riesgo',           1, 2, 3, 4,  8, N'Campaña de recuperación personalizada'),
 (N'No se pueden perder', 1, 2, 5, 5,  9, N'Contacto directo: eran de los mejores clientes'),
 (N'Hibernando',          1, 2, 1, 2, 10, N'Reactivación barata o dejar ir');
GO

DROP TABLE IF EXISTS mart.cliente_rfm;
CREATE TABLE mart.cliente_rfm (
    cliente_id      INT           NOT NULL CONSTRAINT PK_cliente_rfm PRIMARY KEY,
    fecha_corte     DATE          NOT NULL,
    ultima_compra   DATE          NOT NULL,
    recencia_dias   INT           NOT NULL,
    frecuencia      INT           NOT NULL,
    monto           DECIMAL(19,2) NOT NULL,
    r               TINYINT       NOT NULL,
    f               TINYINT       NOT NULL,
    m               TINYINT       NOT NULL,
    rfm_codigo      AS CAST(CONCAT(r, f, m) AS CHAR(3)) PERSISTED,
    segmento        NVARCHAR(30)  NOT NULL
);
GO

CREATE OR ALTER PROCEDURE etl.sp_calcular_rfm
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @inicio DATETIME2(0) = SYSDATETIME();
    DECLARE @corte DATE = DATEADD(DAY, 1, (SELECT CAST(MAX(fecha_hora) AS DATE) FROM dw.fact_linea));

    TRUNCATE TABLE mart.cliente_rfm;

    WITH base AS (
        SELECT f.clave_cliente AS cliente_id,
               MAX(CASE WHEN f.es_devolucion = 0 THEN f.fecha_hora END)               AS ultima_compra,
               COUNT(DISTINCT CASE WHEN f.es_devolucion = 0 THEN f.factura END)       AS frecuencia,
               SUM(f.importe)                                                         AS monto
        FROM dw.fact_linea AS f
        WHERE f.clave_cliente <> -1
        GROUP BY f.clave_cliente
        HAVING MAX(CASE WHEN f.es_devolucion = 0 THEN 1 ELSE 0 END) = 1   -- al menos una compra
    ), puntajes AS (
        SELECT cliente_id, ultima_compra, frecuencia, monto,
               DATEDIFF(DAY, CAST(ultima_compra AS DATE), @corte) AS recencia_dias,
               NTILE(5) OVER (ORDER BY DATEDIFF(DAY, CAST(ultima_compra AS DATE), @corte) DESC, cliente_id) AS r,
               NTILE(5) OVER (ORDER BY frecuencia, monto, cliente_id)                                       AS f,
               NTILE(5) OVER (ORDER BY monto, cliente_id)                                                   AS m
        FROM base
    )
    INSERT INTO mart.cliente_rfm (cliente_id, fecha_corte, ultima_compra, recencia_dias, frecuencia, monto, r, f, m, segmento)
    SELECT p.cliente_id, @corte, CAST(p.ultima_compra AS DATE), p.recencia_dias, p.frecuencia, p.monto,
           p.r, p.f, p.m, s.segmento
    FROM puntajes AS p
    JOIN mart.regla_segmento AS s
      ON p.r BETWEEN s.r_min AND s.r_max
     AND p.f BETWEEN s.f_min AND s.f_max;

    DECLARE @filas INT = @@ROWCOUNT;
    INSERT INTO qa.bitacora_carga (paso, filas, inicio, fin, detalle)
    VALUES (N'RFM', @filas, @inicio, SYSDATETIME(), CONCAT(N'Fecha de corte ', @corte));
    PRINT CONCAT(N'RFM calculado: ', FORMAT(@filas, 'N0'), N' clientes (corte ', @corte, N').');
END;
GO

PRINT N'RFM creado.';
GO
