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
    Every forecast for week t uses only actuals from weeks before t. The
    Holt-Winters smoothing parameters are fixed inputs, not fitted to the data,
    so every forecast is out of sample.

52-week season
    Fiscal 2013 has 53 weeks, so from fiscal 2014 on a 52-week lag lands one
    fiscal week earlier than the same fiscal week last year. Both seasonal
    methods share this.
*/
CREATE OR ALTER PROCEDURE dbo.usp_build_forecast
    @alpha float = 0.2,    -- level smoothing
    @beta  float = 0.05,   -- trend smoothing
    @gamma float = 0.1     -- season smoothing
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
    -- Holt-Winters, additive
    --
    -- Each week's state depends on the previous week's, so this is a loop
    -- over t. Each pass updates every series at once (about 30,000 rows), so
    -- there are roughly 225 set-based passes, not one per series.
    --
    -- Start (from the series' first 52 weeks):
    --     level  = average weekly units
    --     trend  = 0
    --     season = that week's units - level
    -- Each week t >= 53, with y = actual units:
    --     forecast   = level + trend + season(t-52)       [floored at 0]
    --     new level  = alpha * (y - season(t-52)) + (1 - alpha) * (level + trend)
    --     new trend  = beta  * (new level - level) + (1 - beta) * trend
    --     season(t)  = gamma * (y - new level) + (1 - gamma) * season(t-52)
    -- Additive, not multiplicative, because many weeks sell 0 units and the
    -- multiplicative form divides by the level.
    --
    -- The season table keeps one value per series per week of the season:
    -- slot = t % 52. Week t and week t-52 share a slot, so each pass reads
    -- the slot (last year's value) and then overwrites it with this year's.
    ------------------------------------------------------------------

    -- Listed, full weeks, numbered per series from its first listed week.
    -- Clustered on (t, series) because the loop reads one t at a time.
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

    DROP TABLE IF EXISTS #hw_state;
    SELECT
        item_key,
        store_key,
        AVG(CAST(units_sold AS float)) AS level,
        CAST(0 AS float)               AS trend
    INTO #hw_state
    FROM #series_weeks
    WHERE t <= @season_len
    GROUP BY item_key, store_key
    HAVING COUNT(*) = @season_len;   -- every series that has at least one full year

    ALTER TABLE #hw_state ADD PRIMARY KEY (item_key, store_key);

    DROP TABLE IF EXISTS #hw_season;
    SELECT
        w.t % @season_len      AS slot,
        w.item_key,
        w.store_key,
        w.units_sold - s.level AS season
    INTO #hw_season
    FROM #series_weeks AS w
    JOIN #hw_state     AS s ON s.item_key = w.item_key AND s.store_key = w.store_key
    WHERE w.t <= @season_len;

    CREATE UNIQUE CLUSTERED INDEX IX_hw_season ON #hw_season (slot, item_key, store_key);

    DROP TABLE IF EXISTS #hw_step;
    CREATE TABLE #hw_step (
        item_key    int      NOT NULL,
        store_key   smallint NOT NULL,
        week_key    int      NOT NULL,
        y           int      NOT NULL,
        level       float    NOT NULL,
        trend       float    NOT NULL,
        season_prev float    NOT NULL,
        new_level   float    NOT NULL,
        PRIMARY KEY (item_key, store_key)
    );

    -- Collected here and written to the fact in one insert after the loop
    DROP TABLE IF EXISTS #hw_forecast;
    CREATE TABLE #hw_forecast (
        week_key       int      NOT NULL,
        item_key       int      NOT NULL,
        store_key      smallint NOT NULL,
        forecast_units float    NOT NULL,
        actual_units   int      NOT NULL
    );

    DECLARE @t int = @season_len + 1,
            @max_t int = (SELECT MAX(t) FROM #series_weeks);

    WHILE @t <= @max_t
    BEGIN
        TRUNCATE TABLE #hw_step;

        -- Gather this week's inputs: actual, current level/trend, season a year ago
        INSERT INTO #hw_step (item_key, store_key, week_key, y, level, trend, season_prev, new_level)
        SELECT
            w.item_key,
            w.store_key,
            w.week_key,
            w.units_sold,
            s.level,
            s.trend,
            se.season,
            @alpha * (w.units_sold - se.season) + (1 - @alpha) * (s.level + s.trend)
        FROM #series_weeks AS w
        JOIN #hw_state     AS s  ON s.item_key  = w.item_key AND s.store_key  = w.store_key
        JOIN #hw_season    AS se ON se.item_key = w.item_key AND se.store_key = w.store_key
                                AND se.slot = @t % @season_len
        WHERE w.t = @t;

        -- Forecast uses only the state from before week t
        INSERT INTO #hw_forecast (week_key, item_key, store_key, forecast_units, actual_units)
        SELECT week_key, item_key, store_key, GREATEST(0e0, level + trend + season_prev), y
        FROM #hw_step;

        -- Then fold in week t's actual
        UPDATE s
        SET level = st.new_level,
            trend = @beta * (st.new_level - st.level) + (1 - @beta) * st.trend
        FROM #hw_state AS s
        JOIN #hw_step  AS st ON st.item_key = s.item_key AND st.store_key = s.store_key;

        UPDATE se
        SET season = @gamma * (st.y - st.new_level) + (1 - @gamma) * st.season_prev
        FROM #hw_season AS se
        JOIN #hw_step   AS st ON st.item_key = se.item_key AND st.store_key = se.store_key
        WHERE se.slot = @t % @season_len;

        SET @t += 1;
    END;

    INSERT INTO dbo.fact_forecast_weekly WITH (TABLOCK)
        (week_key, item_key, store_key, forecast_method, forecast_units, actual_units)
    SELECT week_key, item_key, store_key, 'holt_winters',
           CAST(ROUND(forecast_units, 3) AS decimal(12, 3)), actual_units
    FROM #hw_forecast;
END;
GO
