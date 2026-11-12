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

    ------------------------------------------------------------------
    -- Forecast: rebuild the eligible rows independently from
    -- fact_sales_weekly, then check the forecast fact against them.
    -- Eligible = listed, 7 selling days, and at least 52 listed weeks before.
    ------------------------------------------------------------------
    DECLARE @eligible_rows bigint, @eligible_units bigint;

    WITH listed AS (
        SELECT units_sold,
               ROW_NUMBER() OVER (PARTITION BY item_key, store_key ORDER BY week_key) AS t
        FROM dbo.fact_sales_weekly
        WHERE is_listed = 1 AND selling_days = 7
    )
    SELECT @eligible_rows  = COUNT_BIG(*),
           @eligible_units = SUM(CAST(units_sold AS bigint))
    FROM listed
    WHERE t > 52;

    DECLARE @fc_abs_error_m bigint =
        (SELECT CAST(SUM(abs_error) * 1000 AS bigint) FROM dbo.fact_forecast_weekly);
    DECLARE @fc_abs_error_52_m bigint =
        (SELECT CAST(SUM(f.abs_error) * 1000 AS bigint)
         FROM dbo.fact_forecast_weekly AS f
         WHERE f.week_key IN (SELECT TOP (52) week_key
                              FROM (SELECT DISTINCT week_key FROM dbo.fact_forecast_weekly) AS w
                              ORDER BY week_key DESC));

    INSERT INTO @checks (check_name, actual, expected)
    -- The forecast numbers each series' listed weeks with ROW_NUMBER, which
    -- is only a week count if there are no gaps once an item is listed.
    SELECT 'series with gaps after first listed week', COUNT_BIG(*), 0
    FROM (
        SELECT f.item_key, f.store_key
        FROM dbo.fact_sales_weekly AS f
        JOIN (SELECT week_key, ROW_NUMBER() OVER (ORDER BY week_key) AS week_seq
              FROM (SELECT DISTINCT week_key FROM dbo.fact_sales_weekly) AS w) AS s
          ON s.week_key = f.week_key
        WHERE f.is_listed = 1
        GROUP BY f.item_key, f.store_key
        HAVING COUNT(*) <> MAX(s.week_seq) - MIN(s.week_seq) + 1
    ) AS gaps
    UNION ALL
    SELECT 'fact_forecast_weekly methods',      COUNT_BIG(DISTINCT forecast_method), 3
    FROM dbo.fact_forecast_weekly
    UNION ALL
    SELECT 'fact_forecast_weekly rows',         COUNT_BIG(*), 3 * @eligible_rows
    FROM dbo.fact_forecast_weekly
    UNION ALL
    SELECT 'fact_forecast_weekly duplicate grain',
           COUNT_BIG(*), 0
    FROM (SELECT week_key, item_key, store_key, forecast_method FROM dbo.fact_forecast_weekly
          GROUP BY week_key, item_key, store_key, forecast_method HAVING COUNT(*) > 1) AS dup
    UNION ALL
    SELECT CONCAT('forecast actual units vs. weekly fact: ', forecast_method),
           SUM(CAST(actual_units AS bigint)), @eligible_units
    FROM dbo.fact_forecast_weekly
    GROUP BY forecast_method
    UNION ALL
    SELECT 'forecast rows negative',            COUNT_BIG(*), 0
    FROM dbo.fact_forecast_weekly WHERE forecast_units < 0
    UNION ALL
    SELECT 'forecast_accuracy rows',            COUNT_BIG(*), 9   -- 3 methods x 3 windows
    FROM dbo.forecast_accuracy
    UNION ALL
    SELECT 'forecast_accuracy WAPE missing or negative', COUNT_BIG(*), 0
    FROM dbo.forecast_accuracy WHERE wape IS NULL OR wape < 0
    UNION ALL
    SELECT 'abs error milli-units: accuracy (all weeks) vs. fact',
           CAST(SUM(abs_error) * 1000 AS bigint), @fc_abs_error_m
    FROM dbo.forecast_accuracy WHERE eval_window = 'All weeks'
    UNION ALL
    SELECT 'abs error milli-units: top errors vs. fact (last 52 weeks)',
           CAST(SUM(abs_error) * 1000 AS bigint), @fc_abs_error_52_m
    FROM dbo.forecast_top_errors;

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
        (SELECT COUNT_BIG(*) FROM dbo.fact_sales_weekly) AS weekly_fact_rows,
        (SELECT COUNT_BIG(*) FROM dbo.fact_forecast_weekly) AS forecast_fact_rows;

    -- Headline forecast accuracy for the README
    SELECT forecast_method, eval_window, first_week_key, last_week_key, weeks, wape, bias
    FROM dbo.forecast_accuracy
    ORDER BY CASE eval_window WHEN 'All weeks' THEN 1 WHEN 'Last 52 weeks' THEN 2 ELSE 3 END, wape;

    IF EXISTS (SELECT 1 FROM @checks WHERE actual <> expected)
        THROW 50001, 'Validation failed. See the check results above.', 1;
END;
GO
