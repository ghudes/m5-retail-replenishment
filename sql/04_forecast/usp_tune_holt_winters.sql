USE M5;
GO

/*
dbo.usp_tune_holt_winters
Grid search for one global set of Holt-Winters smoothing parameters.
Run once by hand, not part of the build (it takes much longer):

    EXEC dbo.usp_tune_holt_winters;

Tuning weeks vs. holdout
    The holdout is the last 52 full weeks, the same weeks as the
    'Last 52 weeks' window in dbo.forecast_accuracy. Tuning sees only the
    weeks before it: #series_weeks is cut off at the holdout start, so the
    model cannot read holdout actuals at all. Each parameter set is scored on
    unit WAPE over the tuning weeks (from each series' 53rd week, as in the
    build), and the winner is then judged on the holdout by the normal build.

Grid (8 sets)
    alpha (level)   0.4, 0.5
    beta  (trend)   0
    gamma (season)  0.6, 0.7, 0.8, 0.9
    This is the last of three runs. Each started where the previous run's
    best value sat at the edge of its grid, and overlapped it by one value
    so the runs can be checked against each other:
      1. alpha, gamma 0.05-0.3; beta 0-0.05 (48 sets).
         Best alpha = gamma = 0.3, the top of both ranges.
      2. alpha, gamma 0.3-0.6;  beta 0, 0.01 (32 sets).
         Best alpha 0.4, inside the range; gamma 0.6, the top again.
         beta 0 beat 0.01 at every alpha and gamma.
      3. This grid, to find where gamma stops improving.

Batches
    Every parameter set carries its own level, trend, and 52 season values
    per series, so all of them at once would not fit in Express's memory.
    @batch_size sets run through dbo.usp_holt_winters together.

Output: dbo.hw_tuning_results, one row per parameter set, ranked by WAPE.
The winning values are copied by hand into the defaults of
dbo.usp_build_forecast, so the build stays deterministic.
*/
CREATE OR ALTER PROCEDURE dbo.usp_tune_holt_winters
    @batch_size int = 4
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @msg nvarchar(200), @t0 datetime2;

    ------------------------------------------------------------------
    -- Holdout = last 52 full weeks; tuning uses only weeks before it
    ------------------------------------------------------------------
    DECLARE @holdout_start int = (
        SELECT MIN(week_key)
        FROM (SELECT DISTINCT TOP (52) week_key
              FROM dbo.fact_sales_weekly
              WHERE selling_days = 7
              ORDER BY week_key DESC) AS last_52
    );

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
      AND selling_days = 7
      AND week_key < @holdout_start;

    CREATE UNIQUE CLUSTERED INDEX IX_series_weeks ON #series_weeks (t, item_key, store_key);

    ------------------------------------------------------------------
    -- Grid
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS #grid;
    SELECT
        CAST(ROW_NUMBER() OVER (ORDER BY a.v, b.v, g.v) AS int) AS param_set,
        a.v AS alpha,
        b.v AS beta,
        g.v AS gamma
    INTO #grid
    FROM       (VALUES (0.4e0), (0.5e0))                   AS a (v)
    CROSS JOIN (VALUES (0e0))                              AS b (v)
    CROSS JOIN (VALUES (0.6e0), (0.7e0), (0.8e0), (0.9e0)) AS g (v);

    DROP TABLE IF EXISTS #hw_params;
    CREATE TABLE #hw_params (param_set int PRIMARY KEY, alpha float, beta float, gamma float);

    DROP TABLE IF EXISTS #hw_forecast;
    CREATE TABLE #hw_forecast (
        param_set      int      NOT NULL,
        week_key       int      NOT NULL,
        item_key       int      NOT NULL,
        store_key      smallint NOT NULL,
        forecast_units float    NOT NULL,
        actual_units   int      NOT NULL
    );

    DROP TABLE IF EXISTS dbo.hw_tuning_results;
    CREATE TABLE dbo.hw_tuning_results (
        param_set       int            NOT NULL PRIMARY KEY,
        alpha           decimal(4, 2)  NOT NULL,
        beta            decimal(4, 2)  NOT NULL,
        gamma           decimal(4, 2)  NOT NULL,
        first_week_key  int            NOT NULL,
        last_week_key   int            NOT NULL,
        series_weeks    bigint         NOT NULL,
        actual_units    bigint         NOT NULL,
        abs_error       float          NOT NULL,
        wape            decimal(9, 4)  NOT NULL,
        bias            decimal(9, 4)  NOT NULL,
        wape_rank       int            NULL
    );

    ------------------------------------------------------------------
    -- Run the grid in batches and score each set on the tuning weeks
    ------------------------------------------------------------------
    DECLARE @from int = 1, @sets int = (SELECT COUNT(*) FROM #grid);

    WHILE @from <= @sets
    BEGIN
        SET @t0 = SYSDATETIME();

        TRUNCATE TABLE #hw_params;
        INSERT INTO #hw_params (param_set, alpha, beta, gamma)
        SELECT param_set, alpha, beta, gamma
        FROM #grid
        WHERE param_set BETWEEN @from AND @from + @batch_size - 1;

        TRUNCATE TABLE #hw_forecast;
        EXEC dbo.usp_holt_winters;

        INSERT INTO dbo.hw_tuning_results
            (param_set, alpha, beta, gamma, first_week_key, last_week_key,
             series_weeks, actual_units, abs_error, wape, bias)
        SELECT
            f.param_set,
            p.alpha,
            p.beta,
            p.gamma,
            MIN(f.week_key),
            MAX(f.week_key),
            COUNT_BIG(*),
            SUM(CAST(f.actual_units AS bigint)),
            SUM(ABS(f.forecast_units - f.actual_units)),
            SUM(ABS(f.forecast_units - f.actual_units)) / SUM(CAST(f.actual_units AS bigint)),
            SUM(f.forecast_units - f.actual_units)      / SUM(CAST(f.actual_units AS bigint))
        FROM #hw_forecast AS f
        JOIN #hw_params   AS p ON p.param_set = f.param_set
        GROUP BY f.param_set, p.alpha, p.beta, p.gamma;

        SET @msg = CONCAT(N'Parameter sets ', @from, N'-', @from + @batch_size - 1, N' of ', @sets,
                          N' scored (', DATEDIFF(second, @t0, SYSDATETIME()), N's)');
        RAISERROR(@msg, 0, 1) WITH NOWAIT;

        SET @from += @batch_size;
    END;

    UPDATE r
    SET wape_rank = x.wape_rank
    FROM dbo.hw_tuning_results AS r
    -- Every set has the same actual_units, so ranking by abs_error is
    -- ranking by WAPE without the rounding of the stored wape column.
    JOIN (SELECT param_set, RANK() OVER (ORDER BY abs_error) AS wape_rank
          FROM dbo.hw_tuning_results) AS x ON x.param_set = r.param_set;

    ------------------------------------------------------------------
    -- Checks: every set scored on the same rows, and those rows reconcile
    -- to fact_sales_weekly computed independently.
    ------------------------------------------------------------------
    DECLARE @expected_rows bigint, @expected_units bigint;

    WITH listed AS (
        SELECT units_sold,
               ROW_NUMBER() OVER (PARTITION BY item_key, store_key ORDER BY week_key) AS t
        FROM dbo.fact_sales_weekly
        WHERE is_listed = 1 AND selling_days = 7 AND week_key < @holdout_start
    )
    SELECT @expected_rows  = COUNT_BIG(*),
           @expected_units = SUM(CAST(units_sold AS bigint))
    FROM listed
    WHERE t > 52;

    IF (SELECT COUNT(*) FROM dbo.hw_tuning_results) <> @sets
       OR EXISTS (SELECT 1 FROM dbo.hw_tuning_results
                  WHERE series_weeks <> @expected_rows
                     OR actual_units <> @expected_units
                     OR last_week_key >= @holdout_start)
        THROW 50002, 'Holt-Winters tuning results failed their checks.', 1;

    SELECT TOP (10) *
    FROM dbo.hw_tuning_results
    ORDER BY wape_rank;
END;
GO
