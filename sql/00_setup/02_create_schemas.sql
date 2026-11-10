-- stg = staging (raw loads and typed staging tables); dbo = star schema.

USE M5;
GO

IF SCHEMA_ID(N'stg') IS NULL
    EXEC (N'CREATE SCHEMA stg AUTHORIZATION dbo;');
GO
