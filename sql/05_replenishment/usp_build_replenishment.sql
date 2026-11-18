USE M5;
GO

-- The procedure rebuilds both output tables on every run. Dropping them here
-- too lets this procedure (and dbo.usp_validate, deployed after it) compile
-- when a column has been added since the last build: SQL Server checks
-- column names against a table that already exists, but defers the check
-- for one that doesn't.
DROP TABLE IF EXISTS dbo.replenishment_summary;
DROP TABLE IF EXISTS dbo.fact_replenishment_weekly;
GO

/*
dbo.usp_build_replenishment
Simulates inventory under a weekly replenishment policy, driven by the
4-week moving-average forecast, over the last @weeks full weeks.

M5 has no inventory, so stock is simulated. Demand is M5's actual weekly
units; the forecast is what the planner would have known at review time.
Comparing the two is the cost of being wrong.

Policy: periodic review with an order-up-to level, (R, S): every R = 1 week,
order enough to bring stock on hand plus on order up to S. Lead time
L = @lead_time_weeks. Lost sales: unmet demand is lost, not backordered.
For each series and week t:

    sigma          RMSE of the series' last 13 forecast errors (weeks before t,
                   so no look-ahead). With no earlier error, SQRT(forecast),
                   the Poisson standard deviation.
    safety_stock   z x sigma x SQRT(L + R)    L + R is the protection period:
                                              what is ordered now must last
                                              until the next order arrives.
    order_up_to    forecast x (L + R) + safety_stock
    reorder_point  forecast x L + safety_stock
                   Reported, not used to trigger orders: stock below it won't
                   last until an order placed today arrives, so it flags
                   urgent series. (An earlier version ordered only when
                   position fell to the reorder point. With weekly review
                   that leaves a skipped week's stock to cover two weeks, and
                   about three quarters of stockout weeks came right after a
                   skipped order.)

    1. Receive the order placed L weeks ago.
       available = last week's on_hand_end + receipt
    2. Review. inventory_position = available + on_order (placed, not yet
       received). If position < order_up_to, order
       CEILING(order_up_to - position).
    3. Project: if this week's forecast exceeds available stock, stock runs
       out before the next delivery, so the planner sees a projected
       stockout date and projected lost units.
    4. Sell: units_sold = MIN(actual, available); the rest is lost_units.
       on_hand_end = available - units_sold.
    5. days_on_hand = on_hand_end / (next week's forecast / 7): the demand
       closing stock has to cover. The last simulated week has no next
       forecast, so it uses its own.

A series starts on policy: its first simulated week opens at
CEILING(order_up_to), with nothing on order.

Why a loop: each week's opening stock is the previous week's closing stock,
which depends on the previous week's order, so week t can't be computed
until week t - 1 is done. The loop runs once per week (52 passes), and each
pass handles every series in one set-based INSERT plus three small
statements that roll the state forward: about 200 statements in all, not
52 x 30,000 row-by-row steps.

Outputs:
    dbo.fact_replenishment_weekly  week x item x store
    dbo.replenishment_summary      one row: inventory carried, fill rate,
                                   lost units and revenue, WAPE
*/
CREATE OR ALTER PROCEDURE dbo.usp_build_replenishment
    @weeks           int   = 52,
    @lead_time_weeks int   = 1,
    @z               float = 1.65    -- 95% cycle service level
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @review_weeks int = 1;

    ------------------------------------------------------------------
    -- Simulation weeks: the last @weeks forecast weeks, numbered 1..@weeks
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS #sim_weeks;
    SELECT
        w.week_key,
        dw.week_start_date,
        ROW_NUMBER() OVER (ORDER BY w.week_key) AS week_seq
    INTO #sim_weeks
    FROM (SELECT TOP (@weeks) week_key
          FROM (SELECT DISTINCT week_key FROM dbo.fact_forecast_weekly) AS d
          ORDER BY week_key DESC) AS w
    JOIN dbo.dim_week AS dw ON dw.week_key = w.week_key;

    ------------------------------------------------------------------
    -- Policy inputs for every simulated row. None of these depend on the
    -- simulated stock, so they are computed once, set-based, before the loop.
    -- The 13-week error window also reads the 13 forecast weeks before the
    -- simulation, so the first simulated week already has 13 errors behind
    -- it. Reading only those weeks, not all forecast history, cuts the
    -- window's input by about two thirds. (A series' forecast weeks run back to
    -- back, so 13 rows back is 13 weeks back. ROWS BETWEEN needs a literal,
    -- so 13 is written into the window.)
    ------------------------------------------------------------------
    DECLARE @first_error_week int =
        (SELECT MIN(week_key)
         FROM (SELECT TOP (@weeks + 13) week_key
               FROM (SELECT DISTINCT week_key FROM dbo.fact_forecast_weekly) AS d
               ORDER BY week_key DESC) AS w);

    DROP TABLE IF EXISTS #inputs;
    WITH errors AS (
        SELECT
            f.week_key,
            f.item_key,
            f.store_key,
            CAST(f.forecast_units AS float) AS forecast_units,
            CAST(LEAD(f.forecast_units) OVER w AS float) AS next_forecast_units,
            f.actual_units,
            SQRT(AVG(SQUARE(CAST(f.error_units AS float)))
                 OVER (w ROWS BETWEEN 13 PRECEDING AND 1 PRECEDING)) AS rmse_13
        FROM dbo.fact_forecast_weekly AS f
        WHERE f.week_key >= @first_error_week
        WINDOW w AS (PARTITION BY f.item_key, f.store_key ORDER BY f.week_key)
    )
    SELECT
        e.item_key,
        e.store_key,
        w.week_key,
        w.week_seq,
        w.week_start_date,
        e.forecast_units,
        ISNULL(e.next_forecast_units, e.forecast_units) AS next_forecast_units,
        e.actual_units,
        s.sell_price,
        p.safety_stock,
        e.forecast_units * @lead_time_weeks + p.safety_stock AS reorder_point,
        e.forecast_units * (@lead_time_weeks + @review_weeks) + p.safety_stock AS order_up_to
    INTO #inputs
    FROM errors AS e
    JOIN #sim_weeks AS w ON w.week_key = e.week_key
    JOIN dbo.fact_sales_weekly AS s
      ON s.week_key = e.week_key AND s.item_key = e.item_key AND s.store_key = e.store_key
    CROSS APPLY (SELECT ISNULL(e.rmse_13, SQRT(e.forecast_units)) AS sigma) AS sg
    CROSS APPLY (SELECT @z * sg.sigma * SQRT(@lead_time_weeks + @review_weeks) AS safety_stock) AS p;

    CREATE UNIQUE CLUSTERED INDEX IX_inputs ON #inputs (week_seq, item_key, store_key);

    ------------------------------------------------------------------
    -- Simulation, one pass per week
    -- The loop keeps its state in two small tables, so every pass costs
    -- the same however many weeks are done:
    --     #last      one row per series: last week's closing stock and
    --                units on order after last week's order
    --     #pipeline  orders placed but not yet received, with the week
    --                they arrive
    -- #sim is only written during the loop. It holds every output column,
    -- so the fact is a straight copy afterwards. (Reading last week back
    -- from #sim instead made each pass scan the whole, growing table.)
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS #last;
    CREATE TABLE #last (
        item_key         int         NOT NULL,
        store_key        smallint    NOT NULL,
        on_hand_end      int         NOT NULL,
        on_order_end     int         NOT NULL,
        PRIMARY KEY (item_key, store_key)
    );

    DROP TABLE IF EXISTS #pipeline;
    CREATE TABLE #pipeline (
        item_key         int         NOT NULL,
        store_key        smallint    NOT NULL,
        arrive_seq       int         NOT NULL,
        order_qty        int         NOT NULL,
        PRIMARY KEY (arrive_seq, item_key, store_key)
    );

    DROP TABLE IF EXISTS #sim;
    CREATE TABLE #sim (
        week_seq                 int            NOT NULL,
        item_key                 int            NOT NULL,
        store_key                smallint       NOT NULL,
        week_key                 int            NOT NULL,
        forecast_units           decimal(12, 3) NOT NULL,
        next_forecast_units      decimal(12, 3) NOT NULL,
        actual_units             int            NOT NULL,
        sell_price               decimal(10, 2) NOT NULL,
        safety_stock             decimal(12, 2) NOT NULL,
        reorder_point            decimal(12, 2) NOT NULL,
        order_up_to              decimal(12, 2) NOT NULL,
        on_hand_start            int            NOT NULL,
        receipt_units            int            NOT NULL,
        available_units          int            NOT NULL,
        on_order_units           int            NOT NULL,
        inventory_position       int            NOT NULL,
        order_qty                int            NOT NULL,
        on_order_end             int            NOT NULL,
        units_sold               int            NOT NULL,
        lost_units               int            NOT NULL,
        on_hand_end              int            NOT NULL,
        days_on_hand             decimal(10, 1) NULL,
        projected_stockout_date  date           NULL,
        projected_lost_units     decimal(12, 3) NOT NULL,
        PRIMARY KEY (week_seq, item_key, store_key)
    );

    DECLARE @t int = 1;
    WHILE @t <= @weeks
    BEGIN
        INSERT INTO #sim
        SELECT
            @t,
            i.item_key, i.store_key, i.week_key,
            CAST(i.forecast_units AS decimal(12, 3)),
            CAST(i.next_forecast_units AS decimal(12, 3)),
            i.actual_units,
            i.sell_price,
            CAST(ROUND(i.safety_stock,  2) AS decimal(12, 2)),
            CAST(ROUND(i.reorder_point, 2) AS decimal(12, 2)),
            CAST(ROUND(i.order_up_to,   2) AS decimal(12, 2)),
            st.on_hand_start,
            rc.receipt_units,
            av.available_units,
            ip.on_order_units,
            ip.inventory_position,
            oq.order_qty,
            ip.on_order_units + oq.order_qty,
            sl.units_sold,
            i.actual_units - sl.units_sold,
            av.available_units - sl.units_sold,
            CASE WHEN i.next_forecast_units > 0
                 THEN CAST(ROUND((av.available_units - sl.units_sold) / (i.next_forecast_units / 7), 1)
                           AS decimal(10, 1)) END,
            -- Stock runs out partway through the week at the forecast daily rate
            CASE WHEN i.forecast_units > av.available_units
                 THEN DATEADD(day, FLOOR(av.available_units / (i.forecast_units / 7)), i.week_start_date) END,
            CAST(ROUND(CASE WHEN i.forecast_units > av.available_units
                            THEN i.forecast_units - av.available_units ELSE 0 END, 3) AS decimal(12, 3))
        FROM #inputs AS i
        -- Last week (missing in a series' first simulated week)
        LEFT JOIN #last AS prev
               ON prev.item_key = i.item_key AND prev.store_key = i.store_key
        -- The order that arrives this week
        LEFT JOIN #pipeline AS rcv
               ON rcv.arrive_seq = @t
              AND rcv.item_key = i.item_key AND rcv.store_key = i.store_key
        CROSS APPLY (SELECT ISNULL(prev.on_hand_end, CAST(CEILING(i.order_up_to) AS int)) AS on_hand_start) AS st
        CROSS APPLY (SELECT ISNULL(rcv.order_qty, 0) AS receipt_units) AS rc
        CROSS APPLY (SELECT st.on_hand_start + rc.receipt_units AS available_units) AS av
        CROSS APPLY (SELECT ISNULL(prev.on_order_end, 0) - rc.receipt_units AS on_order_units,
                            av.available_units + ISNULL(prev.on_order_end, 0) - rc.receipt_units
                                AS inventory_position) AS ip
        CROSS APPLY (SELECT CASE WHEN ip.inventory_position < i.order_up_to
                                 THEN CAST(CEILING(i.order_up_to - ip.inventory_position) AS int)
                                 ELSE 0 END AS order_qty) AS oq
        CROSS APPLY (SELECT CASE WHEN i.actual_units < av.available_units
                                 THEN i.actual_units ELSE av.available_units END AS units_sold) AS sl
        WHERE i.week_seq = @t;

        -- Roll the state forward to this week
        DELETE FROM #pipeline WHERE arrive_seq = @t;

        INSERT INTO #pipeline (item_key, store_key, arrive_seq, order_qty)
        SELECT item_key, store_key, @t + @lead_time_weeks, order_qty
        FROM #sim
        WHERE week_seq = @t AND order_qty > 0;

        TRUNCATE TABLE #last;
        INSERT INTO #last (item_key, store_key, on_hand_end, on_order_end)
        SELECT item_key, store_key, on_hand_end, on_order_end
        FROM #sim
        WHERE week_seq = @t;

        SET @t += 1;
    END;

    ------------------------------------------------------------------
    -- dbo.fact_replenishment_weekly
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS dbo.fact_replenishment_weekly;
    CREATE TABLE dbo.fact_replenishment_weekly (
        week_key                 int            NOT NULL,
        item_key                 int            NOT NULL,
        store_key                smallint       NOT NULL,
        forecast_units           decimal(12, 3) NOT NULL,
        next_forecast_units      decimal(12, 3) NOT NULL,   -- demand closing stock must cover
        actual_units             int            NOT NULL,   -- demand
        sell_price               decimal(10, 2) NOT NULL,
        safety_stock             decimal(12, 2) NOT NULL,
        reorder_point            decimal(12, 2) NOT NULL,   -- urgent flag; orders use order_up_to
        order_up_to              decimal(12, 2) NOT NULL,
        on_hand_start            int            NOT NULL,
        receipt_units            int            NOT NULL,
        available_units          int            NOT NULL,
        on_order_units           int            NOT NULL,   -- before this week's order
        inventory_position       int            NOT NULL,
        suggested_order_qty      int            NOT NULL,
        units_sold               int            NOT NULL,
        lost_units               int            NOT NULL,   -- simulated: demand not met
        on_hand_end              int            NOT NULL,
        days_on_hand             decimal(10, 1) NULL,       -- vs. next week's forecast; NULL when it is 0
        projected_stockout_date  date           NULL,       -- NULL when stock lasts until the next delivery
        projected_lost_units     decimal(12, 3) NOT NULL,   -- forecast not covered by available stock
        INDEX CCI_fact_replenishment_weekly CLUSTERED COLUMNSTORE
    );

    INSERT INTO dbo.fact_replenishment_weekly WITH (TABLOCK)
        (week_key, item_key, store_key, forecast_units, next_forecast_units,
         actual_units, sell_price,
         safety_stock, reorder_point, order_up_to, on_hand_start, receipt_units, available_units,
         on_order_units, inventory_position, suggested_order_qty, units_sold, lost_units,
         on_hand_end, days_on_hand, projected_stockout_date, projected_lost_units)
    SELECT
        week_key, item_key, store_key, forecast_units, next_forecast_units,
        actual_units, sell_price,
        safety_stock, reorder_point, order_up_to, on_hand_start, receipt_units, available_units,
        on_order_units, inventory_position, order_qty, units_sold, lost_units,
        on_hand_end, days_on_hand, projected_stockout_date, projected_lost_units
    FROM #sim;

    ------------------------------------------------------------------
    -- dbo.replenishment_summary: the cost of being wrong, in one row
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS dbo.replenishment_summary;
    CREATE TABLE dbo.replenishment_summary (
        first_week_key           int            NOT NULL,
        last_week_key            int            NOT NULL,
        weeks                    int            NOT NULL,
        series                   int            NOT NULL,
        wape                     decimal(9, 4)  NULL,      -- same weeks, from dbo.forecast_accuracy
        demand_units             bigint         NOT NULL,
        units_sold               bigint         NOT NULL,
        lost_units               bigint         NOT NULL,  -- simulated: what actually happened
        projected_lost_units     decimal(16, 1) NOT NULL,  -- what the planner saw at review time
        fill_rate                decimal(9, 4)  NOT NULL,  -- units sold / demand
        stockout_week_rate       decimal(9, 4)  NOT NULL,  -- share of series-weeks with lost units
        lost_revenue             decimal(16, 2) NOT NULL,
        avg_on_hand_units        decimal(16, 1) NOT NULL,  -- average weekly closing stock, all series
        avg_on_hand_value        decimal(16, 2) NOT NULL,  -- same, at sell price
        avg_days_on_hand         decimal(9, 1)  NULL,      -- closing stock / next week's forecast daily demand, all series
        units_ordered            bigint         NOT NULL
    );

    INSERT INTO dbo.replenishment_summary
        (first_week_key, last_week_key, weeks, series, wape, demand_units, units_sold, lost_units,
         projected_lost_units, fill_rate,
         stockout_week_rate, lost_revenue, avg_on_hand_units, avg_on_hand_value,
         avg_days_on_hand, units_ordered)
    SELECT
        MIN(r.week_key),
        MAX(r.week_key),
        COUNT(DISTINCT r.week_key),
        (SELECT COUNT(*) FROM (SELECT DISTINCT item_key, store_key
                               FROM dbo.fact_replenishment_weekly) AS s),
        (SELECT a.wape FROM dbo.forecast_accuracy AS a WHERE a.eval_window = 'Last 52 weeks'),
        SUM(CAST(r.actual_units AS bigint)),
        SUM(CAST(r.units_sold   AS bigint)),
        SUM(CAST(r.lost_units   AS bigint)),
        CAST(SUM(r.projected_lost_units) AS decimal(16, 1)),
        CAST(1.0 * SUM(CAST(r.units_sold AS bigint)) / NULLIF(SUM(CAST(r.actual_units AS bigint)), 0) AS decimal(9, 4)),
        CAST(AVG(CASE WHEN r.lost_units > 0 THEN 1.0 ELSE 0 END) AS decimal(9, 4)),
        SUM(r.lost_units * r.sell_price),
        CAST(1.0 * SUM(CAST(r.on_hand_end AS bigint)) / COUNT(DISTINCT r.week_key) AS decimal(16, 1)),
        CAST(SUM(r.on_hand_end * r.sell_price) / COUNT(DISTINCT r.week_key) AS decimal(16, 2)),
        CAST(SUM(CAST(r.on_hand_end AS float)) / NULLIF(SUM(CAST(r.next_forecast_units AS float)) / 7, 0) AS decimal(9, 1)),
        SUM(CAST(r.suggested_order_qty AS bigint))
    FROM dbo.fact_replenishment_weekly AS r;
END;
GO
