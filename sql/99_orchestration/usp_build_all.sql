USE M5;
GO

/*
dbo.usp_build_all
Rebuilds the whole model from the raw CSVs:
    EXEC dbo.usp_build_all @raw_dir = N'C:\m5\raw';
Each new build step (forecast, stockouts, replenishment) gets an EXEC here,
in dependency order, before validation runs.
*/
CREATE OR ALTER PROCEDURE dbo.usp_build_all
    @raw_dir nvarchar(260)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @t datetime2 = SYSDATETIME(), @msg nvarchar(200);

    EXEC stg.usp_load_staging @raw_dir = @raw_dir;
    SET @msg = CONCAT(N'Staging loaded (', DATEDIFF(second, @t, SYSDATETIME()), N's)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    SET @t = SYSDATETIME();
    EXEC dbo.usp_build_dimensions;
    SET @msg = CONCAT(N'Dimensions built (', DATEDIFF(second, @t, SYSDATETIME()), N's)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    SET @t = SYSDATETIME();
    EXEC dbo.usp_build_sales_facts;
    SET @msg = CONCAT(N'Sales facts built (', DATEDIFF(second, @t, SYSDATETIME()), N's)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    EXEC dbo.usp_validate;
END;
GO
