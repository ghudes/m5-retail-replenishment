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
    -- Eligible = listed, 7 selling days, and at least 4 listed weeks before.
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
    WHERE t > 4;

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
    SELECT 'fact_forecast_weekly rows',         COUNT_BIG(*), @eligible_rows
    FROM dbo.fact_forecast_weekly
    UNION ALL
    SELECT 'fact_forecast_weekly duplicate grain',
           COUNT_BIG(*), 0
    FROM (SELECT week_key, item_key, store_key FROM dbo.fact_forecast_weekly
          GROUP BY week_key, item_key, store_key HAVING COUNT(*) > 1) AS dup
    UNION ALL
    SELECT 'forecast actual units vs. weekly fact',
           SUM(CAST(actual_units AS bigint)), @eligible_units
    FROM dbo.fact_forecast_weekly
    UNION ALL
    SELECT 'forecast rows negative',            COUNT_BIG(*), 0
    FROM dbo.fact_forecast_weekly WHERE forecast_units < 0
    UNION ALL
    SELECT 'forecast_accuracy rows',            COUNT_BIG(*), 3   -- 3 windows
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

    ------------------------------------------------------------------
    -- Stockouts: reconcile series totals to the daily fact, then check
    -- every event against the daily rows it covers.
    ------------------------------------------------------------------
    DECLARE @listed_days bigint, @listed_units bigint;
    SELECT @listed_days  = COUNT_BIG(*),
           @listed_units = SUM(CAST(units_sold AS bigint))
    FROM dbo.fact_sales_daily
    WHERE is_listed = 1;

    -- Expand each event to its days and look them up in the daily fact.
    DECLARE @event_days bigint, @event_days_found bigint, @event_days_bad bigint;
    SELECT @event_days       = COUNT_BIG(*),
           @event_days_found = COUNT_BIG(f.date_key),
           @event_days_bad   = SUM(CASE WHEN f.units_sold > 0 OR f.is_listed = 0 THEN 1 ELSE 0 END)
    FROM dbo.fact_stockout_event AS e
    JOIN dbo.dim_date            AS d ON d.date_key BETWEEN e.start_date_key AND e.end_date_key
    LEFT JOIN dbo.fact_sales_daily AS f
           ON f.item_key = e.item_key AND f.store_key = e.store_key AND f.date_key = d.date_key;

    DECLARE @last_sales_date_key int = (SELECT MAX(date_key) FROM dbo.fact_sales_daily);

    INSERT INTO @checks (check_name, actual, expected)
    SELECT 'stockout_series rows',              COUNT_BIG(*), 30490 FROM dbo.stockout_series
    UNION ALL
    SELECT 'stockout_series listed days vs. daily fact',  SUM(CAST(listed_days AS bigint)), @listed_days
    FROM dbo.stockout_series
    UNION ALL
    SELECT 'stockout_series listed units vs. daily fact', SUM(listed_units), @listed_units
    FROM dbo.stockout_series
    UNION ALL
    SELECT 'stockout_series absence days vs. events',
           SUM(CAST(absence_days AS bigint)),
           (SELECT SUM(CAST(zero_sale_days AS bigint)) FROM dbo.fact_stockout_event
            WHERE event_type = 'extended_absence')
    FROM dbo.stockout_series
    UNION ALL
    SELECT 'fact_stockout_event duplicate grain', COUNT_BIG(*), 0
    FROM (SELECT item_key, store_key, start_date_key FROM dbo.fact_stockout_event
          GROUP BY item_key, store_key, start_date_key HAVING COUNT(*) > 1) AS dup
    UNION ALL
    SELECT 'fact_stockout_event overlapping events', COUNT_BIG(*), 0
    FROM (SELECT start_date_key,
                 LAG(end_date_key) OVER (PARTITION BY item_key, store_key
                                         ORDER BY start_date_key) AS prev_end_date_key
          FROM dbo.fact_stockout_event) AS e
    WHERE e.start_date_key <= e.prev_end_date_key
    UNION ALL
    SELECT 'stockout event days vs. zero_sale_days', @event_days,
           (SELECT SUM(CAST(zero_sale_days AS bigint)) FROM dbo.fact_stockout_event)
    UNION ALL
    SELECT 'stockout event days missing from daily fact', @event_days - @event_days_found, 0
    UNION ALL
    SELECT 'stockout event days with sales or unlisted',  @event_days_bad, 0
    UNION ALL
    -- Each event must be a whole run: the day before and the day after
    -- are not listed zero-sale days.
    SELECT 'stockout events that are not whole runs', COUNT_BIG(*), 0
    FROM dbo.fact_stockout_event AS e
    JOIN dbo.dim_date AS ds ON ds.date_key = e.start_date_key
    JOIN dbo.dim_date AS de ON de.date_key = e.end_date_key
    WHERE EXISTS (SELECT 1
                  FROM dbo.fact_sales_daily AS f
                  JOIN dbo.dim_date AS d ON d.date_key = f.date_key
                  WHERE f.item_key = e.item_key AND f.store_key = e.store_key
                    AND d.day_num IN (ds.day_num - 1, de.day_num + 1)
                    AND f.is_listed = 1 AND f.units_sold = 0)
    UNION ALL
    SELECT 'stockouts shorter than series threshold N', COUNT_BIG(*), 0
    FROM dbo.fact_stockout_event AS e
    JOIN dbo.stockout_series     AS s ON s.item_key = e.item_key AND s.store_key = e.store_key
    WHERE e.event_type = 'stockout'
      AND (s.min_run_days IS NULL OR e.zero_sale_days < s.min_run_days)
    UNION ALL
    SELECT 'extended absences shorter than pass-1 N', COUNT_BIG(*), 0
    FROM dbo.fact_stockout_event AS e
    JOIN dbo.stockout_series     AS s ON s.item_key = e.item_key AND s.store_key = e.store_key
    WHERE e.event_type = 'extended_absence'
      AND (s.min_run_days_all IS NULL OR e.zero_sale_days < s.min_run_days_all)
    UNION ALL
    SELECT 'stockouts as long as the shortest absence', COUNT_BIG(*), 0
    FROM dbo.fact_stockout_event
    WHERE event_type = 'stockout'
      AND zero_sale_days >= (SELECT MIN(zero_sale_days) FROM dbo.fact_stockout_event
                             WHERE event_type = 'extended_absence')
    UNION ALL
    SELECT 'stockouts starting on first listed day', COUNT_BIG(*), 0
    FROM dbo.fact_stockout_event AS e
    JOIN dbo.stockout_series     AS s ON s.item_key = e.item_key AND s.store_key = e.store_key
    WHERE e.event_type = 'stockout' AND e.start_date_key = s.first_listed_date_key
    UNION ALL
    SELECT 'stockout lost units missing or set on absences', COUNT_BIG(*), 0
    FROM dbo.fact_stockout_event
    WHERE (event_type = 'stockout'         AND (est_lost_units IS NULL OR est_lost_revenue IS NULL))
       OR (event_type = 'extended_absence' AND (est_lost_units IS NOT NULL OR est_lost_revenue IS NOT NULL))
    UNION ALL
    SELECT 'stockout is_open flag wrong', COUNT_BIG(*), 0
    FROM dbo.fact_stockout_event
    WHERE is_open <> CASE WHEN end_date_key = @last_sales_date_key THEN 1 ELSE 0 END
    UNION ALL
    SELECT 'stockout_sensitivity rows',        COUNT_BIG(*), 3 FROM dbo.stockout_sensitivity
    UNION ALL
    SELECT 'stockouts: sensitivity (selected) vs. events',
           (SELECT stockouts FROM dbo.stockout_sensitivity WHERE is_selected = 1),
           COUNT_BIG(*)
    FROM dbo.fact_stockout_event WHERE event_type = 'stockout'
    UNION ALL
    SELECT 'lost units cents: sensitivity (selected) vs. events',
           (SELECT CAST(est_lost_units * 100 AS bigint) FROM dbo.stockout_sensitivity WHERE is_selected = 1),
           CAST(SUM(est_lost_units) * 100 AS bigint)
    FROM dbo.fact_stockout_event WHERE event_type = 'stockout'
    UNION ALL
    -- A smaller alpha is a stricter test, so it can't find more stockouts.
    SELECT 'stockouts rising as alpha falls', COUNT_BIG(*), 0
    FROM (SELECT stockouts,
                 LAG(stockouts) OVER (ORDER BY alpha DESC) AS stockouts_at_larger_alpha
          FROM dbo.stockout_sensitivity) AS s
    WHERE s.stockouts > s.stockouts_at_larger_alpha;

    ------------------------------------------------------------------
    -- Replenishment simulation: row counts and demand reconcile to the
    -- forecast fact; every row's stock flow balances; each week opens
    -- with the previous week's closing stock; receipts are the orders
    -- placed one lead time earlier (the build's default L = 1 week).
    ------------------------------------------------------------------
    DECLARE @sim_rows bigint, @sim_demand bigint;
    SELECT @sim_rows   = COUNT_BIG(*),
           @sim_demand = SUM(CAST(actual_units AS bigint))
    FROM dbo.fact_forecast_weekly
    WHERE week_key IN (SELECT TOP (52) week_key
                       FROM (SELECT DISTINCT week_key FROM dbo.fact_forecast_weekly) AS w
                       ORDER BY week_key DESC);

    INSERT INTO @checks (check_name, actual, expected)
    SELECT 'fact_replenishment_weekly rows', COUNT_BIG(*), @sim_rows
    FROM dbo.fact_replenishment_weekly
    UNION ALL
    SELECT 'replenishment demand vs. forecast fact',
           SUM(CAST(actual_units AS bigint)), @sim_demand
    FROM dbo.fact_replenishment_weekly
    UNION ALL
    SELECT 'fact_replenishment_weekly duplicate grain', COUNT_BIG(*), 0
    FROM (SELECT week_key, item_key, store_key FROM dbo.fact_replenishment_weekly
          GROUP BY week_key, item_key, store_key HAVING COUNT(*) > 1) AS dup
    UNION ALL
    SELECT 'replenishment rows where stock does not balance', COUNT_BIG(*), 0
    FROM dbo.fact_replenishment_weekly
    WHERE available_units    <> on_hand_start + receipt_units
       OR inventory_position <> available_units + on_order_units
       OR on_hand_end        <> available_units - units_sold
       OR actual_units       <> units_sold + lost_units
       OR units_sold         >  available_units
       OR (lost_units > 0 AND on_hand_end <> 0)
    UNION ALL
    SELECT 'replenishment negative stock, sales, or orders', COUNT_BIG(*), 0
    FROM dbo.fact_replenishment_weekly
    WHERE on_hand_end < 0 OR units_sold < 0 OR lost_units < 0 OR suggested_order_qty < 0
       OR on_order_units < 0 OR safety_stock < 0
    UNION ALL
    SELECT 'replenishment weeks not opening at last week''s close', COUNT_BIG(*), 0
    FROM (SELECT on_hand_start,
                 LAG(on_hand_end) OVER (PARTITION BY item_key, store_key
                                        ORDER BY week_key) AS prev_on_hand_end
          FROM dbo.fact_replenishment_weekly) AS r
    WHERE r.prev_on_hand_end IS NOT NULL AND r.on_hand_start <> r.prev_on_hand_end
    UNION ALL
    SELECT 'replenishment receipts not equal to last week''s order', COUNT_BIG(*), 0
    FROM (SELECT receipt_units,
                 LAG(suggested_order_qty, 1, 0) OVER (PARTITION BY item_key, store_key
                                                      ORDER BY week_key) AS prev_order
          FROM dbo.fact_replenishment_weekly) AS r
    WHERE r.receipt_units <> r.prev_order
    UNION ALL
    SELECT 'projected stockout dates outside their week', COUNT_BIG(*), 0
    FROM dbo.fact_replenishment_weekly AS r
    JOIN dbo.dim_week AS w ON w.week_key = r.week_key
    WHERE r.projected_stockout_date NOT BETWEEN w.week_start_date AND w.week_end_date
       OR (r.projected_stockout_date IS NULL AND r.projected_lost_units > 0)
       OR (r.projected_stockout_date IS NOT NULL AND r.projected_lost_units = 0)
    UNION ALL
    -- Order-up-to policy: each order brings position up to order_up_to and
    -- no further (whole units, so at most 1 unit over). 0.01 of slack
    -- because order_up_to is stored rounded to 2 decimals.
    SELECT 'replenishment orders not reaching order-up-to level', COUNT_BIG(*), 0
    FROM dbo.fact_replenishment_weekly
    WHERE inventory_position + suggested_order_qty < order_up_to - 0.01
       OR (suggested_order_qty > 0
           AND inventory_position + suggested_order_qty - 1 >= order_up_to + 0.01)
    UNION ALL
    SELECT 'replenishment_summary rows', COUNT_BIG(*), 1 FROM dbo.replenishment_summary
    UNION ALL
    SELECT 'lost units: summary vs. fact', (SELECT lost_units FROM dbo.replenishment_summary),
           SUM(CAST(lost_units AS bigint))
    FROM dbo.fact_replenishment_weekly;

    ------------------------------------------------------------------
    -- Orphan keys: every key in every fact has a row in its dimension.
    -- Each fact is inner-joined to all its dimensions; rows that drop
    -- out of the join are orphans. Every dimension key is a primary key,
    -- so the join can't add rows, only lose them. (Written as joins
    -- because OR-ed NOT EXISTS ran row by row and took over 25 minutes
    -- on the 59M-row daily fact.)
    ------------------------------------------------------------------
    INSERT INTO @checks (check_name, actual, expected)
    SELECT 'orphan keys: fact_sales_daily',
           (SELECT COUNT_BIG(*) FROM dbo.fact_sales_daily)
         - (SELECT COUNT_BIG(*) FROM dbo.fact_sales_daily AS f
            JOIN dbo.dim_date  AS d ON d.date_key  = f.date_key
            JOIN dbo.dim_week  AS w ON w.week_key  = f.week_key
            JOIN dbo.dim_item  AS i ON i.item_key  = f.item_key
            JOIN dbo.dim_store AS s ON s.store_key = f.store_key), 0
    UNION ALL
    SELECT 'orphan keys: fact_sales_weekly',
           (SELECT COUNT_BIG(*) FROM dbo.fact_sales_weekly)
         - (SELECT COUNT_BIG(*) FROM dbo.fact_sales_weekly AS f
            JOIN dbo.dim_week  AS w ON w.week_key  = f.week_key
            JOIN dbo.dim_item  AS i ON i.item_key  = f.item_key
            JOIN dbo.dim_store AS s ON s.store_key = f.store_key), 0
    UNION ALL
    SELECT 'orphan keys: fact_forecast_weekly',
           (SELECT COUNT_BIG(*) FROM dbo.fact_forecast_weekly)
         - (SELECT COUNT_BIG(*) FROM dbo.fact_forecast_weekly AS f
            JOIN dbo.dim_week  AS w ON w.week_key  = f.week_key
            JOIN dbo.dim_item  AS i ON i.item_key  = f.item_key
            JOIN dbo.dim_store AS s ON s.store_key = f.store_key), 0
    UNION ALL
    SELECT 'orphan keys: fact_replenishment_weekly',
           (SELECT COUNT_BIG(*) FROM dbo.fact_replenishment_weekly)
         - (SELECT COUNT_BIG(*) FROM dbo.fact_replenishment_weekly AS f
            JOIN dbo.dim_week  AS w ON w.week_key  = f.week_key
            JOIN dbo.dim_item  AS i ON i.item_key  = f.item_key
            JOIN dbo.dim_store AS s ON s.store_key = f.store_key), 0
    UNION ALL
    SELECT 'orphan keys: fact_stockout_event',
           (SELECT COUNT_BIG(*) FROM dbo.fact_stockout_event)
         - (SELECT COUNT_BIG(*) FROM dbo.fact_stockout_event AS f
            JOIN dbo.dim_date  AS ds ON ds.date_key = f.start_date_key
            JOIN dbo.dim_date  AS de ON de.date_key = f.end_date_key
            JOIN dbo.dim_week  AS w  ON w.week_key  = f.start_week_key
            JOIN dbo.dim_item  AS i  ON i.item_key  = f.item_key
            JOIN dbo.dim_store AS s  ON s.store_key = f.store_key), 0
    UNION ALL
    SELECT 'stockout start_week_key not the start date''s week', COUNT_BIG(*), 0
    FROM dbo.fact_stockout_event AS f
    JOIN dbo.dim_date AS d ON d.date_key = f.start_date_key
    WHERE f.start_week_key <> d.week_key;

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
    SELECT eval_window, first_week_key, last_week_key, weeks, series_weeks, wape, bias
    FROM dbo.forecast_accuracy
    ORDER BY CASE eval_window WHEN 'All weeks' THEN 1 WHEN 'Last 52 weeks' THEN 2 ELSE 3 END;

    -- Inferred stockouts at each alpha, for the README
    SELECT alpha, is_selected, series_with_stockouts, stockouts, stockout_days,
           CAST(100.0 * stockout_days / @listed_days AS decimal(5, 2))   AS pct_listed_days,
           est_lost_units,
           CAST(100.0 * est_lost_units / @listed_units AS decimal(5, 2)) AS lost_pct_of_units_sold,
           est_lost_revenue, extended_absences, absence_days
    FROM dbo.stockout_sensitivity
    ORDER BY alpha DESC;

    -- Cost of being wrong, for the README
    SELECT first_week_key, last_week_key, wape, fill_rate, stockout_week_rate, lost_units,
           projected_lost_units, lost_revenue, avg_on_hand_units, avg_on_hand_value, avg_days_on_hand
    FROM dbo.replenishment_summary;

    IF EXISTS (SELECT 1 FROM @checks WHERE actual <> expected)
        THROW 50001, 'Validation failed. See the check results above.', 1;
END;
GO
