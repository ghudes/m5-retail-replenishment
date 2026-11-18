USE M5;
GO

/*
dbo.usp_build_forecast
Builds dbo.fact_forecast_weekly: a one-week-ahead unit forecast for every
item x store x Walmart week, from a 4-week moving average.

    forecast for week t = average units sold in weeks t-1 ... t-4

The forecast is deliberately simple. The project's focus is what happens
after the forecast: the replenishment decision and what forecast error
costs in stock and lost sales.

Which weeks get a forecast
    Only listed weeks (is_listed = 1) with all 7 selling days. Once an item is
    listed at a store it stays listed (usp_validate checks this), so a series'
    listed weeks run back to back and t, its week number counted from its first
    listed week, is just ROW_NUMBER over week_key. A series' first 4 weeks
    are history only, so forecasts start at t = 5.

    The last week of the data has only 2 selling days, so it is left out.

No look-ahead
    Every forecast for week t uses only actuals from weeks before t.
*/
CREATE OR ALTER PROCEDURE dbo.usp_build_forecast
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    ------------------------------------------------------------------
    -- fact_forecast_weekly
    -- error_units = forecast - actual, so positive means over-forecast.
    -- Both error columns are computed from the stored (rounded) forecast,
    -- so they always add up exactly.
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS dbo.fact_forecast_weekly;
    CREATE TABLE dbo.fact_forecast_weekly (
        week_key        int            NOT NULL,
        item_key        int            NOT NULL,
        store_key       smallint       NOT NULL,
        forecast_units  decimal(12, 3) NOT NULL,
        actual_units    int            NOT NULL,
        error_units     AS (forecast_units - actual_units),
        abs_error       AS (ABS(forecast_units - actual_units)),
        INDEX CCI_fact_forecast_weekly CLUSTERED COLUMNSTORE
    );

    ------------------------------------------------------------------
    -- Window functions over each series' listed weeks. Reading straight
    -- from the columnstore fact lets SQL Server run them in batch mode.
    ------------------------------------------------------------------
    WITH history AS (
        SELECT
            week_key,
            item_key,
            store_key,
            units_sold,
            ROW_NUMBER() OVER w AS t,
            AVG(CAST(units_sold AS float))
                OVER (w ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS avg_prev_4
        FROM dbo.fact_sales_weekly
        WHERE is_listed = 1
          AND selling_days = 7
        WINDOW w AS (PARTITION BY item_key, store_key ORDER BY week_key)
    )
    INSERT INTO dbo.fact_forecast_weekly WITH (TABLOCK)
        (week_key, item_key, store_key, forecast_units, actual_units)
    SELECT week_key, item_key, store_key,
           CAST(ROUND(avg_prev_4, 3) AS decimal(12, 3)), units_sold
    FROM history
    WHERE t > 4;
END;
GO
