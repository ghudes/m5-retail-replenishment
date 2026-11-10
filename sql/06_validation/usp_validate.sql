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

    ------------------------------------------------------------------
    -- Sales facts: row counts and reconciliation back to staging
    ------------------------------------------------------------------
    DECLARE @units_staging bigint = (SELECT SUM(CAST(units_sold AS bigint)) FROM stg.sales_long);
    DECLARE @units_daily   bigint = (SELECT SUM(CAST(units_sold AS bigint)) FROM dbo.fact_sales_daily);
    DECLARE @units_weekly  bigint = (SELECT SUM(CAST(units_sold AS bigint)) FROM dbo.fact_sales_weekly);
    DECLARE @rev_daily_c   bigint = (SELECT CAST(SUM(revenue) * 100 AS bigint) FROM dbo.fact_sales_daily);
    DECLARE @rev_weekly_c  bigint = (SELECT CAST(SUM(revenue) * 100 AS bigint) FROM dbo.fact_sales_weekly);

    INSERT INTO @checks (check_name, actual, expected)
    SELECT 'fact_sales_daily rows',            COUNT_BIG(*), 59181090 FROM dbo.fact_sales_daily
    UNION ALL
    SELECT 'fact_sales_daily duplicate grain',
           COUNT_BIG(*), 0
    FROM (SELECT date_key, item_key, store_key FROM dbo.fact_sales_daily
          GROUP BY date_key, item_key, store_key HAVING COUNT(*) > 1) AS dup
    UNION ALL
    -- One row per series per sales week: 30,490 series x 278 weeks.
    -- dim_date has day_num for all 1,969 days, so count weeks over sales days only.
    SELECT 'fact_sales_weekly rows',           COUNT_BIG(*),
           30490 * (SELECT COUNT_BIG(DISTINCT d.week_key)
                    FROM dbo.dim_date AS d
                    WHERE d.day_num IN (SELECT day_num FROM stg.sales_long))
    FROM dbo.fact_sales_weekly
    UNION ALL
    SELECT 'fact_sales_weekly duplicate grain',
           COUNT_BIG(*), 0
    FROM (SELECT week_key, item_key, store_key FROM dbo.fact_sales_weekly
          GROUP BY week_key, item_key, store_key HAVING COUNT(*) > 1) AS dup
    UNION ALL
    SELECT 'units: daily fact vs. staging',    @units_daily,  @units_staging
    UNION ALL
    SELECT 'units: weekly fact vs. daily fact', @units_weekly, @units_daily
    UNION ALL
    SELECT 'revenue cents: weekly vs. daily',  @rev_weekly_c, @rev_daily_c
    UNION ALL
    SELECT 'units sold with no price',         COUNT_BIG(*), 0
    FROM dbo.fact_sales_daily WHERE units_sold > 0 AND sell_price IS NULL
    UNION ALL
    SELECT 'weekly rows over 7 selling days',  COUNT_BIG(*), 0
    FROM dbo.fact_sales_weekly WHERE selling_days > 7;

    SELECT
        check_name,
        actual,
        expected,
        CASE WHEN actual = expected THEN 'OK' ELSE 'FAIL' END AS status
    FROM @checks
    ORDER BY CASE WHEN actual = expected THEN 1 ELSE 0 END, check_name;

    -- Headline totals for the README Validation table
    SELECT
        @units_staging                                AS total_units,
        CAST(@rev_daily_c / 100.0 AS decimal(16, 2))  AS total_revenue,
        (SELECT COUNT_BIG(*) FROM dbo.fact_sales_weekly) AS weekly_fact_rows;

    IF EXISTS (SELECT 1 FROM @checks WHERE actual <> expected)
        THROW 50001, 'Validation failed. See the check results above.', 1;
END;
GO
