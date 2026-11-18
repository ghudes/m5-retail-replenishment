USE M5;
GO

/*
dbo.usp_build_stockouts
Infers historical stockouts from runs of consecutive zero-sale days.

M5 has no inventory, so a stockout can't be observed. What can be observed is
a run of days with no sales. A short run is normal for a slow seller; a run
much longer than its sales rate explains is more likely an empty shelf.

Threshold N (dbo.fn_stockout_min_run_days): the shortest run with probability
below @alpha if daily sales were Poisson at the series' average rate lambda,
    N = CEILING( LN(1 / @alpha) / lambda ),  floored at @min_run_days.

Two passes, because very long runs distort lambda:
    1. lambda from all listed days. A run longer than @max_run_days that is
       also at least that pass's N is an extended absence: the store wasn't
       really carrying the item, which is an assortment issue, not a
       replenishment one. (A long run that is normal for a very slow seller
       is neither an absence nor a stockout.)
    2. lambda again, leaving out extended-absence days, so it reflects demand
       while the item was on the shelf. A run from N to @max_run_days days is
       a stockout.

Rules:
    - Only listed days count (is_listed = 1). Days before an item is first
      priced at a store are not stockouts.
    - A run that starts on the series' first listed day is never a stockout:
      it is either the item reaching the shelf after its price was published,
      or a run already under way when the data starts, so its start can't be
      seen. If it is long enough it is still an extended absence.
    - A run still going on the last day of the data is kept, with is_open = 1.

Lost units for a stockout = zero_sale_days x lambda (pass 2).
Lost revenue = lambda x the sum of the daily price over the run.
Extended absences get no lost-sales estimate (NULL).

Outputs:
    dbo.stockout_series      one row per series: lambda and N from both passes
    dbo.fact_stockout_event  stockouts and extended absences at @alpha
    dbo.stockout_sensitivity totals at several alpha values, to show how much
                             the result depends on the threshold
*/
CREATE OR ALTER PROCEDURE dbo.usp_build_stockouts
    @alpha        float = 0.01,
    @min_run_days int   = 7,
    @max_run_days int   = 28
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    ------------------------------------------------------------------
    -- Listed days and units per series
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS #series_all;
    SELECT
        item_key,
        store_key,
        COUNT(*)                          AS listed_days,
        SUM(CAST(units_sold AS bigint))   AS listed_units,
        MIN(date_key)                     AS first_listed_date_key,
        SUM(CAST(units_sold AS float)) / COUNT(*) AS avg_daily_units
    INTO #series_all
    FROM dbo.fact_sales_daily
    WHERE is_listed = 1
    GROUP BY item_key, store_key;

    CREATE UNIQUE CLUSTERED INDEX IX_series_all ON #series_all (item_key, store_key);

    ------------------------------------------------------------------
    -- Zero-sale runs (gaps and islands)
    -- Keep listed zero-sale days only. Within a series, day_num minus
    -- ROW_NUMBER() is constant across consecutive days and jumps whenever
    -- a sale (or an unlisted day) breaks the run, so it labels each run.
    -- Every threshold is at least @min_run_days, so shorter runs are
    -- dropped here.
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS #runs;
    WITH zero_days AS (
        SELECT
            f.item_key,
            f.store_key,
            f.date_key,
            f.sell_price,
            d.day_num
              - ROW_NUMBER() OVER (PARTITION BY f.item_key, f.store_key
                                   ORDER BY d.day_num) AS run_id
        FROM dbo.fact_sales_daily AS f
        JOIN dbo.dim_date         AS d ON d.date_key = f.date_key
        WHERE f.is_listed = 1
          AND f.units_sold = 0
    )
    SELECT
        item_key,
        store_key,
        MIN(date_key)    AS start_date_key,
        MAX(date_key)    AS end_date_key,
        COUNT(*)         AS zero_sale_days,
        SUM(sell_price)  AS sum_price
    INTO #runs
    FROM zero_days
    GROUP BY item_key, store_key, run_id
    HAVING COUNT(*) >= @min_run_days;

    CREATE CLUSTERED INDEX IX_runs ON #runs (item_key, store_key);

    DECLARE @last_date_key int = (SELECT MAX(date_key) FROM dbo.fact_sales_daily);

    ------------------------------------------------------------------
    -- Alpha values: the selected @alpha plus the sensitivity values
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS #alphas;
    SELECT CAST(alpha AS float) AS alpha
    INTO #alphas
    FROM (VALUES (0.05), (0.01), (0.001)) AS v (alpha)
    UNION
    SELECT @alpha;

    ------------------------------------------------------------------
    -- Pass 1: extended absences, judged against lambda over all listed days
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS #absences;
    SELECT
        a.alpha,
        r.item_key,
        r.store_key,
        r.start_date_key,
        r.end_date_key,
        r.zero_sale_days
    INTO #absences
    FROM #runs       AS r
    JOIN #series_all AS s ON s.item_key = r.item_key AND s.store_key = r.store_key
    CROSS JOIN #alphas AS a
    CROSS APPLY dbo.fn_stockout_min_run_days(s.avg_daily_units, a.alpha, @min_run_days) AS n
    WHERE r.zero_sale_days >  @max_run_days
      AND r.zero_sale_days >= n.min_run_days;

    ------------------------------------------------------------------
    -- Pass 2: lambda and N without extended-absence days
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS #series;
    SELECT
        a.alpha,
        s.item_key,
        s.store_key,
        s.listed_days,
        s.listed_units,
        s.first_listed_date_key,
        s.avg_daily_units                           AS avg_daily_units_all,
        n1.min_run_days                             AS min_run_days_all,
        ISNULL(ab.absence_days, 0)                  AS absence_days,
        CAST(s.listed_units AS float)
          / (s.listed_days - ISNULL(ab.absence_days, 0)) AS avg_daily_units
    INTO #series
    FROM #series_all AS s
    CROSS JOIN #alphas AS a
    CROSS APPLY dbo.fn_stockout_min_run_days(s.avg_daily_units, a.alpha, @min_run_days) AS n1
    LEFT JOIN (
        SELECT alpha, item_key, store_key, SUM(zero_sale_days) AS absence_days
        FROM #absences
        GROUP BY alpha, item_key, store_key
    ) AS ab ON ab.alpha = a.alpha AND ab.item_key = s.item_key AND ab.store_key = s.store_key;
    -- The denominator can't be 0: an absence needs a finite N, so the
    -- series sold something, so it has listed days outside its absences.

    CREATE UNIQUE CLUSTERED INDEX IX_series ON #series (alpha, item_key, store_key);

    ------------------------------------------------------------------
    -- Events at each alpha: stockouts (pass 2 lambda) and absences
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS #events;
    SELECT
        s.alpha,
        r.item_key,
        r.store_key,
        r.start_date_key,
        r.end_date_key,
        CAST('stockout' AS varchar(20))  AS event_type,
        r.zero_sale_days,
        CAST(ROUND(r.zero_sale_days * s.avg_daily_units, 2) AS decimal(12, 2)) AS est_lost_units,
        CAST(ROUND(r.sum_price      * s.avg_daily_units, 2) AS decimal(14, 2)) AS est_lost_revenue
    INTO #events
    FROM #runs   AS r
    JOIN #series AS s ON s.item_key = r.item_key AND s.store_key = r.store_key
    CROSS APPLY dbo.fn_stockout_min_run_days(s.avg_daily_units, s.alpha, @min_run_days) AS n
    WHERE r.zero_sale_days BETWEEN n.min_run_days AND @max_run_days   -- NULL N never qualifies
      AND r.start_date_key > s.first_listed_date_key                  -- start must be visible

    UNION ALL

    SELECT
        alpha, item_key, store_key, start_date_key, end_date_key,
        'extended_absence', zero_sale_days, NULL, NULL
    FROM #absences;

    ------------------------------------------------------------------
    -- dbo.stockout_series (selected alpha)
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS dbo.stockout_series;
    CREATE TABLE dbo.stockout_series (
        item_key               int            NOT NULL,
        store_key              smallint       NOT NULL,
        listed_days            int            NOT NULL,
        listed_units           bigint         NOT NULL,
        first_listed_date_key  int            NOT NULL,
        avg_daily_units_all    decimal(12, 6) NOT NULL,   -- pass 1: all listed days
        min_run_days_all       int            NULL,       -- pass 1 N
        absence_days           int            NOT NULL,
        avg_daily_units        decimal(12, 6) NOT NULL,   -- pass 2: without absence days
        min_run_days           int            NULL,       -- pass 2 N, the stockout threshold
        CONSTRAINT PK_stockout_series PRIMARY KEY (item_key, store_key)
    );

    INSERT INTO dbo.stockout_series
        (item_key, store_key, listed_days, listed_units, first_listed_date_key,
         avg_daily_units_all, min_run_days_all, absence_days, avg_daily_units, min_run_days)
    SELECT
        s.item_key,
        s.store_key,
        s.listed_days,
        s.listed_units,
        s.first_listed_date_key,
        CAST(s.avg_daily_units_all AS decimal(12, 6)),
        s.min_run_days_all,
        s.absence_days,
        CAST(s.avg_daily_units AS decimal(12, 6)),
        n.min_run_days
    FROM #series AS s
    CROSS APPLY dbo.fn_stockout_min_run_days(s.avg_daily_units, s.alpha, @min_run_days) AS n
    WHERE s.alpha = @alpha;

    ------------------------------------------------------------------
    -- dbo.fact_stockout_event (selected alpha)
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS dbo.fact_stockout_event;
    CREATE TABLE dbo.fact_stockout_event (
        item_key          int            NOT NULL,
        store_key         smallint       NOT NULL,
        start_date_key    int            NOT NULL,
        end_date_key      int            NOT NULL,
        event_type        varchar(20)    NOT NULL,   -- stockout | extended_absence
        zero_sale_days    int            NOT NULL,
        est_lost_units    decimal(12, 2) NULL,       -- NULL for extended_absence
        est_lost_revenue  decimal(14, 2) NULL,
        is_open           bit            NOT NULL,   -- still going on the last day of the data
        CONSTRAINT PK_fact_stockout_event PRIMARY KEY (item_key, store_key, start_date_key)
    );

    INSERT INTO dbo.fact_stockout_event
        (item_key, store_key, start_date_key, end_date_key, event_type, zero_sale_days,
         est_lost_units, est_lost_revenue, is_open)
    SELECT
        item_key, store_key, start_date_key, end_date_key, event_type, zero_sale_days,
        est_lost_units, est_lost_revenue,
        CAST(CASE WHEN end_date_key = @last_date_key THEN 1 ELSE 0 END AS bit)
    FROM #events
    WHERE alpha = @alpha;

    ------------------------------------------------------------------
    -- dbo.stockout_sensitivity: one row per alpha
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS dbo.stockout_sensitivity;
    CREATE TABLE dbo.stockout_sensitivity (
        alpha                  float          NOT NULL PRIMARY KEY,
        is_selected            bit            NOT NULL,
        series_with_stockouts  int            NOT NULL,
        stockouts              int            NOT NULL,
        stockout_days          bigint         NOT NULL,
        est_lost_units         decimal(16, 2) NOT NULL,
        est_lost_revenue       decimal(16, 2) NOT NULL,
        extended_absences      int            NOT NULL,
        absence_days           bigint         NOT NULL
    );

    INSERT INTO dbo.stockout_sensitivity
        (alpha, is_selected, series_with_stockouts, stockouts, stockout_days,
         est_lost_units, est_lost_revenue, extended_absences, absence_days)
    SELECT
        a.alpha,
        CAST(CASE WHEN a.alpha = @alpha THEN 1 ELSE 0 END AS bit),
        (SELECT COUNT(*) FROM (SELECT DISTINCT item_key, store_key FROM #events AS e
                               WHERE e.alpha = a.alpha AND e.event_type = 'stockout') AS x),
        SUM(CASE WHEN e.event_type = 'stockout' THEN 1 ELSE 0 END),
        SUM(CASE WHEN e.event_type = 'stockout' THEN CAST(e.zero_sale_days AS bigint) ELSE 0 END),
        SUM(CASE WHEN e.event_type = 'stockout' THEN e.est_lost_units   ELSE 0 END),
        SUM(CASE WHEN e.event_type = 'stockout' THEN e.est_lost_revenue ELSE 0 END),
        SUM(CASE WHEN e.event_type = 'extended_absence' THEN 1 ELSE 0 END),
        SUM(CASE WHEN e.event_type = 'extended_absence' THEN CAST(e.zero_sale_days AS bigint) ELSE 0 END)
    FROM #alphas AS a
    LEFT JOIN #events AS e ON e.alpha = a.alpha
    GROUP BY a.alpha;
END;
GO
