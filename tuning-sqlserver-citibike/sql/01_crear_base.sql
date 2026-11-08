/* =====================================================================
   01_crear_base.sql — Creación de CitiBikeTuning y activación de Query Store
   ===================================================================== */
USE master;
GO

IF DB_ID(N'CitiBikeTuning') IS NOT NULL
BEGIN
    ALTER DATABASE CitiBikeTuning SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE CitiBikeTuning;
END;
GO

-- Tamaño inicial holgado para que el crecimiento automático no contamine los tiempos de carga.
-- SQL Server Express limita cada base a 10 GB de datos: el pipeline completo usa unos 6 GB.
CREATE DATABASE CitiBikeTuning;
GO
ALTER DATABASE CitiBikeTuning MODIFY FILE (NAME = N'CitiBikeTuning', SIZE = 4096MB, FILEGROWTH = 512MB);
ALTER DATABASE CitiBikeTuning MODIFY FILE (NAME = N'CitiBikeTuning_log', SIZE = 1024MB, FILEGROWTH = 512MB);
GO

ALTER DATABASE CitiBikeTuning SET RECOVERY SIMPLE;
ALTER DATABASE CitiBikeTuning SET PAGE_VERIFY CHECKSUM;
ALTER DATABASE CitiBikeTuning SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE CitiBikeTuning SET AUTO_UPDATE_STATISTICS ON;
GO

-- Guarda el último plan real (con filas reales por operador) de cada consulta en caché:
-- se exporta a reports/planes/*.sqlplan desde sys.dm_exec_query_plan_stats.
USE CitiBikeTuning;
ALTER DATABASE SCOPED CONFIGURATION SET LAST_QUERY_PLAN_STATS = ON;
USE master;
GO

-- Activar Query Store con captura integral para el laboratorio de rendimiento
ALTER DATABASE CitiBikeTuning
SET QUERY_STORE = ON
(
    OPERATION_MODE = READ_WRITE,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 30),
    DATA_FLUSH_INTERVAL_SECONDS = 60,
    INTERVAL_LENGTH_MINUTES = 1,
    MAX_STORAGE_SIZE_MB = 256,
    QUERY_CAPTURE_MODE = ALL,
    SIZE_BASED_CLEANUP_MODE = AUTO,
    MAX_PLANS_PER_QUERY = 200
);
GO

USE CitiBikeTuning;
GO

CREATE SCHEMA etl AUTHORIZATION dbo;
GO
CREATE SCHEMA stg AUTHORIZATION dbo;
GO
CREATE SCHEMA limpio AUTHORIZATION dbo;
GO
CREATE SCHEMA dw AUTHORIZATION dbo;
GO
CREATE SCHEMA lab AUTHORIZATION dbo;
GO
CREATE SCHEMA perf AUTHORIZATION dbo;
GO
CREATE SCHEMA rpt AUTHORIZATION dbo;
GO
CREATE SCHEMA qa AUTHORIZATION dbo;
GO
