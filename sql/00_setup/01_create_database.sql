-- SQL Server 2022 (Developer or Express). Creates the M5 database.
-- Compatibility level 160 is required for STRING_SPLIT's ordinal argument.

USE master;
GO

IF DB_ID(N'M5') IS NULL
    CREATE DATABASE M5;
GO

ALTER DATABASE M5 SET COMPATIBILITY_LEVEL = 160;
ALTER DATABASE M5 SET RECOVERY SIMPLE;   -- rebuildable from source; keeps the log small
GO
