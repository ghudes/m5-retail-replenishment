USE M5;
GO

/*
dbo.usp_holt_winters
Additive Holt-Winters with a 52-week season, one week ahead. Shared by
dbo.usp_build_forecast (one parameter set) and dbo.usp_tune_holt_winters
(a grid of parameter sets), so the parameters are tuned on exactly the code
that produces the forecasts.

The caller creates three temp tables (a procedure can read and write temp
tables its caller created):

    #series_weeks   (item_key, store_key, week_key, units_sold, t)
                    listed, full weeks; t = week number within the series.
                    Only weeks in this table are used, so the caller
                    controls what history the model can see.
    #hw_params      (param_set, alpha, beta, gamma)
    #hw_forecast    (param_set, week_key, item_key, store_key,
                     forecast_units, actual_units)      filled here

Start (from the series' first 52 weeks):
    level  = average weekly units
    trend  = 0
    season = that week's units - level
Each week t >= 53, with y = actual units:
    forecast   = level + trend + season(t-52)       [floored at 0]
    new level  = alpha * (y - season(t-52)) + (1 - alpha) * (level + trend)
    new trend  = beta  * (new level - level) + (1 - beta) * trend
    season(t)  = gamma * (y - new level) + (1 - gamma) * season(t-52)
Additive, not multiplicative, because many weeks sell 0 units and the
multiplicative form divides by the level.

Each week's state depends on the previous week's, so this is a loop over t.
Each pass updates every series (and every parameter set) at once, so it is
roughly 225 set-based passes, not one per series.

The season table keeps one value per series per week of the season:
slot = t % 52. Week t and week t-52 share a slot, so each pass reads the
slot (last year's value) and then overwrites it with this year's.
*/
CREATE OR ALTER PROCEDURE dbo.usp_holt_winters
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @season_len int = 52;

    -- Starting level and trend, one row per parameter set x series
    -- (every series that has at least one full year)
    DROP TABLE IF EXISTS #hw_state;
    SELECT
        p.param_set,
        i.item_key,
        i.store_key,
        i.level,
        CAST(0 AS float) AS trend
    INTO #hw_state
    FROM (
        SELECT item_key, store_key, AVG(CAST(units_sold AS float)) AS level
        FROM #series_weeks
        WHERE t <= @season_len
        GROUP BY item_key, store_key
        HAVING COUNT(*) = @season_len
    ) AS i
    CROSS JOIN #hw_params AS p;

    ALTER TABLE #hw_state ADD PRIMARY KEY (param_set, item_key, store_key);

    DROP TABLE IF EXISTS #hw_season;
    SELECT
        w.t % @season_len      AS slot,
        s.param_set,
        w.item_key,
        w.store_key,
        w.units_sold - s.level AS season
    INTO #hw_season
    FROM #series_weeks AS w
    JOIN #hw_state     AS s ON s.item_key = w.item_key AND s.store_key = w.store_key
    WHERE w.t <= @season_len;

    CREATE UNIQUE CLUSTERED INDEX IX_hw_season ON #hw_season (slot, param_set, item_key, store_key);

    DROP TABLE IF EXISTS #hw_step;
    CREATE TABLE #hw_step (
        param_set   int      NOT NULL,
        item_key    int      NOT NULL,
        store_key   smallint NOT NULL,
        week_key    int      NOT NULL,
        y           int      NOT NULL,
        level       float    NOT NULL,
        trend       float    NOT NULL,
        season_prev float    NOT NULL,
        new_level   float    NOT NULL,
        PRIMARY KEY (param_set, item_key, store_key)
    );

    DECLARE @t int = @season_len + 1,
            @max_t int = (SELECT MAX(t) FROM #series_weeks);

    WHILE @t <= @max_t
    BEGIN
        TRUNCATE TABLE #hw_step;

        -- Gather this week's inputs: actual, current level/trend, season a year ago
        INSERT INTO #hw_step (param_set, item_key, store_key, week_key, y, level, trend, season_prev, new_level)
        SELECT
            s.param_set,
            w.item_key,
            w.store_key,
            w.week_key,
            w.units_sold,
            s.level,
            s.trend,
            se.season,
            p.alpha * (w.units_sold - se.season) + (1 - p.alpha) * (s.level + s.trend)
        FROM #series_weeks AS w
        JOIN #hw_state     AS s  ON s.item_key  = w.item_key AND s.store_key  = w.store_key
        JOIN #hw_params    AS p  ON p.param_set = s.param_set
        JOIN #hw_season    AS se ON se.param_set = s.param_set
                                AND se.item_key  = w.item_key AND se.store_key = w.store_key
                                AND se.slot = @t % @season_len
        WHERE w.t = @t;

        -- Forecast uses only the state from before week t
        INSERT INTO #hw_forecast (param_set, week_key, item_key, store_key, forecast_units, actual_units)
        SELECT param_set, week_key, item_key, store_key, GREATEST(0e0, level + trend + season_prev), y
        FROM #hw_step;

        -- Then fold in week t's actual
        UPDATE s
        SET level = st.new_level,
            trend = p.beta * (st.new_level - st.level) + (1 - p.beta) * st.trend
        FROM #hw_state  AS s
        JOIN #hw_step   AS st ON st.param_set = s.param_set
                             AND st.item_key = s.item_key AND st.store_key = s.store_key
        JOIN #hw_params AS p  ON p.param_set = s.param_set;

        UPDATE se
        SET season = p.gamma * (st.y - st.new_level) + (1 - p.gamma) * st.season_prev
        FROM #hw_season AS se
        JOIN #hw_step   AS st ON st.param_set = se.param_set
                             AND st.item_key = se.item_key AND st.store_key = se.store_key
        JOIN #hw_params AS p  ON p.param_set = se.param_set
        WHERE se.slot = @t % @season_len;

        SET @t += 1;
    END;
END;
GO
