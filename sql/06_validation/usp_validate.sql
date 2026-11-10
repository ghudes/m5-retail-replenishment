USE M5;
GO

/*
dbo.usp_validate
Returns every check with actual vs. expected and raises an error if any fail.
Extend this as facts, forecast, and replenishment tables are added.
*/
CREATE OR ALTER PROCEDURE dbo.usp_validate
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @checks TABLE (check_name varchar(100), actual bigint, expected bigint);

    INSERT INTO @checks (check_name, actual, expected)
    SELECT 'stg.item_store series',            COUNT_BIG(*), 30490    FROM stg.item_store
    UNION ALL
    SELECT 'stg.sales_long rows',              COUNT_BIG(*), 59181090 FROM stg.sales_long
    UNION ALL
    SELECT 'stg.sales_long distinct days',     COUNT_BIG(DISTINCT day_num), 1941 FROM stg.sales_long
    UNION ALL
    SELECT 'stg.sales_long days not in calendar',
           COUNT_BIG(*), 0
    FROM (SELECT DISTINCT day_num FROM stg.sales_long) AS s
    WHERE NOT EXISTS (SELECT 1 FROM stg.calendar AS c WHERE c.day_num = s.day_num)
    UNION ALL
    SELECT 'dim_date rows',                    COUNT_BIG(*), 1969     FROM dbo.dim_date
    UNION ALL
    SELECT 'dim_item rows',                    COUNT_BIG(*), 3049     FROM dbo.dim_item
    UNION ALL
    SELECT 'dim_store rows',                   COUNT_BIG(*), 10       FROM dbo.dim_store
    UNION ALL
    SELECT 'dim_date weeks missing from dim_week',
           COUNT_BIG(*), 0
    FROM dbo.dim_date AS d
    WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_week AS w WHERE w.week_key = d.week_key);

    SELECT
        check_name,
        actual,
        expected,
        CASE WHEN actual = expected THEN 'OK' ELSE 'FAIL' END AS status
    FROM @checks
    ORDER BY CASE WHEN actual = expected THEN 1 ELSE 0 END, check_name;

    -- Total units, recorded in the README for the week 2 fact reconciliation
    SELECT SUM(CAST(units_sold AS bigint)) AS total_units_staging FROM stg.sales_long;

    IF EXISTS (SELECT 1 FROM @checks WHERE actual <> expected)
        THROW 50001, 'Validation failed. See the check results above.', 1;
END;
GO
