/* Ejecutar con sqlcmd -v BackupPath="...\\WideWorldImporters-Full.bak".
   No sobrescribe una fuente existente. Las rutas físicas se leen del servidor. */
USE master;
GO
IF DB_ID(N'WideWorldImporters') IS NULL
BEGIN
    DECLARE @datos nvarchar(4000)=CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultDataPath'));
    DECLARE @log nvarchar(4000)=CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultLogPath'));
    DECLARE @sql nvarchar(max)=N'RESTORE DATABASE WideWorldImporters FROM DISK=N''$(BackupPath)'' WITH '
      +N'MOVE N''WWI_Primary'' TO N'''+@datos+N'WideWorldImporters.mdf'', '
      +N'MOVE N''WWI_UserData'' TO N'''+@datos+N'WideWorldImporters_UserData.ndf'', '
      +N'MOVE N''WWI_Log'' TO N'''+@log+N'WideWorldImporters.ldf'', '
      +N'MOVE N''WWI_InMemory_Data_1'' TO N'''+@datos+N'WideWorldImporters_InMemory_Data_1'', RECOVERY, STATS=10;';
    EXEC sys.sp_executesql @sql;
END;
GO

