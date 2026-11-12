USE M5;
GO

/*
dbo.usp_build_forecast_accuracy
Scores dbo.fact_forecast_weekly. Builds two small tables:

    forecast_accuracy        method x evaluation window: WAPE and bias
    forecast_top_errors      method x series over the last 52 weeks, ranked
                             by share of that method's absolute error

    WAPE = sum(|forecast - actual|) / sum(actual)
    bias = sum(forecast - actual)   / sum(actual)    positive = over-forecast

WAPE is summed before dividing, so a week with 0 actual units still counts
its error but never divides by zero. (MAPE would divide by each row's actual,
which is undefined for the many zero-sale weeks in M5.)

Evaluation windows count back from the last forecast week:
    All weeks       every forecast week
    Last 52 weeks   the most recent year
    Last 4 weeks    the 4 most recent full weeks, close to M5's 28-day test period
*/
CREATE OR ALTER PROCEDURE dbo.usp_build_forecast_accuracy
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- 1 = the most recent forecast week
    DROP TABLE IF EXISTS #weeks_back;
    SELECT week_key, CAST(ROW_NUMBER() OVER (ORDER BY week_key DESC) AS int) AS weeks_back
    INTO #weeks_back
    FROM (SELECT DISTINCT week_key FROM dbo.fact_forecast_weekly) AS w;

    ------------------------------------------------------------------
    -- forecast_accuracy
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS dbo.forecast_accuracy;
    CREATE TABLE dbo.forecast_accuracy (
        forecast_method varchar(20)    NOT NULL,
        eval_window     varchar(20)    NOT NULL,
        first_week_key  int            NOT NULL,
        last_week_key   int            NOT NULL,
        weeks           int            NOT NULL,
        series_weeks    bigint         NOT NULL,
        actual_units    bigint         NOT NULL,
        forecast_units  decimal(16, 3) NOT NULL,
        abs_error       decimal(16, 3) NOT NULL,
        wape            decimal(9, 4)  NULL,
        bias            decimal(9, 4)  NULL,
        PRIMARY KEY (forecast_method, eval_window)
    );

    INSERT INTO dbo.forecast_accuracy
        (forecast_method, eval_window, first_week_key, last_week_key, weeks,
         series_weeks, actual_units, forecast_units, abs_error, wape, bias)
    SELECT
        f.forecast_method,
        win.eval_window,
        MIN(f.week_key),
        MAX(f.week_key),
        COUNT(DISTINCT f.week_key),
        COUNT_BIG(*),
        SUM(CAST(f.actual_units AS bigint)),
        SUM(f.forecast_units),
        SUM(f.abs_error),
        SUM(f.abs_error)   / NULLIF(SUM(CAST(f.actual_units AS bigint)), 0),
        SUM(f.error_units) / NULLIF(SUM(CAST(f.actual_units AS bigint)), 0)
    FROM dbo.fact_forecast_weekly AS f
    JOIN #weeks_back AS b ON b.week_key = f.week_key
    JOIN (VALUES ('All weeks',     NULL),
                 ('Last 52 weeks', 52),
                 ('Last 4 weeks',  4)) AS win (eval_window, max_weeks_back)
         ON win.max_weeks_back IS NULL OR b.weeks_back <= win.max_weeks_back
    GROUP BY f.forecast_method, win.eval_window;

    ------------------------------------------------------------------
    -- forecast_top_errors: which series drive each method's error.
    -- cumulative_share answers "how few series make up half the error?"
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS dbo.forecast_top_errors;
    CREATE TABLE dbo.forecast_top_errors (
        forecast_method    varchar(20)    NOT NULL,
        item_key           int            NOT NULL,
        store_key          smallint       NOT NULL,
        actual_units       int            NOT NULL,
        forecast_units     decimal(14, 3) NOT NULL,
        error_units        decimal(14, 3) NOT NULL,
        abs_error          decimal(14, 3) NOT NULL,
        share_of_abs_error decimal(9, 6)  NOT NULL,
        error_rank         int            NOT NULL,
        cumulative_share   decimal(9, 6)  NOT NULL,
        PRIMARY KEY (forecast_method, item_key, store_key)
    );

    WITH by_series AS (
        SELECT
            f.forecast_method,
            f.item_key,
            f.store_key,
            SUM(f.actual_units)   AS actual_units,
            SUM(f.forecast_units) AS forecast_units,
            SUM(f.error_units)    AS error_units,
            SUM(f.abs_error)      AS abs_error
        FROM dbo.fact_forecast_weekly AS f
        JOIN #weeks_back AS b ON b.week_key = f.week_key
        WHERE b.weeks_back <= 52
        GROUP BY f.forecast_method, f.item_key, f.store_key
    ),
    ranked AS (
        SELECT
            *,
            abs_error / SUM(abs_error) OVER (PARTITION BY forecast_method) AS share,
            ROW_NUMBER() OVER (PARTITION BY forecast_method
                               ORDER BY abs_error DESC, item_key, store_key) AS error_rank
        FROM by_series
    )
    INSERT INTO dbo.forecast_top_errors
        (forecast_method, item_key, store_key, actual_units, forecast_units, error_units,
         abs_error, share_of_abs_error, error_rank, cumulative_share)
    SELECT
        forecast_method, item_key, store_key, actual_units, forecast_units, error_units,
        abs_error,
        share,
        error_rank,
        SUM(share) OVER (PARTITION BY forecast_method ORDER BY error_rank
                         ROWS UNBOUNDED PRECEDING)
    FROM ranked;
END;
GO
