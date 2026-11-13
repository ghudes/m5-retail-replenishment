USE M5;
GO

/*
dbo.usp_build_forecast
Builds dbo.fact_forecast_weekly: one-week-ahead unit forecasts for every
item x store x Walmart week, from three methods.

    seasonal_naive   units sold 52 weeks earlier
    moving_avg_4     average units of the previous 4 weeks
    holt_winters     additive Holt-Winters (level + trend + 52-week season)

Which weeks get a forecast
    Only listed weeks (is_listed = 1) with all 7 selling days. Once an item is
    listed at a store it stays listed (usp_validate checks this), so a series'
    listed weeks run back to back and t, its week number counted from its first
    listed week, is just ROW_NUMBER over week_key. A series' first 52 weeks
    are history only (the seasonal methods need a full year), so forecasts
    start at t = 53. For the 10,932 series listed from the first week of the
    data, that is the first week of fiscal 2012. A series listed later starts
    one year after its listing. All three methods forecast exactly the same
    rows, so their accuracy compares like for like.

    The last week of the data has only 2 selling days, so it is left out.

No look-ahead
    Every forecast for week t uses only actuals from weeks before t.

Holt-Winters parameters
    The defaults below were tuned by dbo.usp_tune_holt_winters (run by hand,
    not part of the build) on unit WAPE over the weeks before the last 52 full
    weeks, then fixed here so the build stays deterministic. The tuning never
    saw the last 52 weeks, so the 'Last 52 weeks' window in
    dbo.forecast_accuracy is a true holdout for Holt-Winters. The 'All weeks'
    window includes the tuning weeks, so for Holt-Winters it is partly in
    sample and flatters it slightly; compare methods on 'Last 52 weeks'.

52-week season
    Fiscal 2013 has 53 weeks, so from fiscal 2014 on a 52-week lag lands one
    fiscal week earlier than the same fiscal week last year. Both seasonal
    methods share this.
*/
CREATE OR ALTER PROCEDURE dbo.usp_build_forecast
    @alpha float = 0.4,    -- level smoothing   (tuned)
    @beta  float = 0,      -- trend smoothing   (tuned; 0 = trend stays at its start value of 0)
    @gamma float = 0.6     -- season smoothing  (tuned)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @season_len int = 52;

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
        forecast_method varchar(20)    NOT NULL,
        forecast_units  decimal(12, 3) NOT NULL,
        actual_units    int            NOT NULL,
        error_units     AS (forecast_units - actual_units),
        abs_error       AS (ABS(forecast_units - actual_units)),
        INDEX CCI_fact_forecast_weekly CLUSTERED COLUMNSTORE
    );

    ------------------------------------------------------------------
    -- Baselines: window functions over each series' listed weeks.
    -- Reading straight from the columnstore fact lets SQL Server run the
    -- window functions in batch mode, which took about 2 minutes here
    -- versus about 5 from a rowstore temp table.
    ------------------------------------------------------------------
    WITH history AS (
        SELECT
            week_key,
            item_key,
            store_key,
            units_sold,
            ROW_NUMBER() OVER w                    AS t,
            LAG(units_sold, 52) OVER w             AS same_week_last_year,
            AVG(CAST(units_sold AS float))
                OVER (w ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS avg_prev_4
        FROM dbo.fact_sales_weekly
        WHERE is_listed = 1
          AND selling_days = 7
        WINDOW w AS (PARTITION BY item_key, store_key ORDER BY week_key)
    )
    INSERT INTO dbo.fact_forecast_weekly WITH (TABLOCK)
        (week_key, item_key, store_key, forecast_method, forecast_units, actual_units)
    SELECT week_key, item_key, store_key, m.forecast_method,
           CAST(ROUND(m.forecast_units, 3) AS decimal(12, 3)), units_sold
    FROM history
    CROSS APPLY (VALUES
        ('seasonal_naive', CAST(same_week_last_year AS float)),
        ('moving_avg_4',   avg_prev_4)
    ) AS m (forecast_method, forecast_units)
    WHERE t > @season_len;

    ------------------------------------------------------------------
    -- Holt-Winters (dbo.usp_holt_winters, shared with the tuning procedure).
    -- Listed, full weeks, numbered per series from its first listed week.
    -- Clustered on (t, series) because the loop reads one t at a time.
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS #series_weeks;
    SELECT
        item_key,
        store_key,
        week_key,
        units_sold,
        CAST(ROW_NUMBER() OVER (PARTITION BY item_key, store_key ORDER BY week_key) AS int) AS t
    INTO #series_weeks
    FROM dbo.fact_sales_weekly
    WHERE is_listed = 1
      AND selling_days = 7;

    CREATE UNIQUE CLUSTERED INDEX IX_series_weeks ON #series_weeks (t, item_key, store_key);

    DROP TABLE IF EXISTS #hw_params;
    CREATE TABLE #hw_params (param_set int PRIMARY KEY, alpha float, beta float, gamma float);
    INSERT INTO #hw_params VALUES (1, @alpha, @beta, @gamma);

    DROP TABLE IF EXISTS #hw_forecast;
    CREATE TABLE #hw_forecast (
        param_set      int      NOT NULL,
        week_key       int      NOT NULL,
        item_key       int      NOT NULL,
        store_key      smallint NOT NULL,
        forecast_units float    NOT NULL,
        actual_units   int      NOT NULL
    );

    EXEC dbo.usp_holt_winters;

    INSERT INTO dbo.fact_forecast_weekly WITH (TABLOCK)
        (week_key, item_key, store_key, forecast_method, forecast_units, actual_units)
    SELECT week_key, item_key, store_key, 'holt_winters',
           CAST(ROUND(forecast_units, 3) AS decimal(12, 3)), actual_units
    FROM #hw_forecast;
END;
GO
