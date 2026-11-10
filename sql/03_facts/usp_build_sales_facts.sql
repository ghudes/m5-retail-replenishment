USE M5;
GO

/*
dbo.usp_build_sales_facts
Builds the two sales facts from staging.

    fact_sales_daily    date x item x store   59,181,090 rows   (stockout inference)
    fact_sales_weekly   week x item x store   ~8.5M rows        (Power BI, forecasting)

Price is published weekly (store x item x wm_yr_wk). An item has no price in
weeks before it was first stocked at a store, so sell_price is NULL there and
is_listed = 0. Those rows are kept so every series has a complete daily
calendar, but downstream logic (stockout inference, forecast accuracy) should
filter to is_listed = 1.
*/
CREATE OR ALTER PROCEDURE dbo.usp_build_sales_facts
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    ------------------------------------------------------------------
    -- Key maps: resolve natural keys once, so the 59M-row insert joins
    -- on small integer keys only.
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS #series_keys;
    SELECT
        s.line_id,
        i.item_key,
        st.store_key,
        s.item_id,
        s.store_id
    INTO #series_keys
    FROM stg.item_store AS s
    JOIN dbo.dim_item  AS i  ON i.item_id   = s.item_id
    JOIN dbo.dim_store AS st ON st.store_id = s.store_id;

    CREATE UNIQUE CLUSTERED INDEX IX_series_keys ON #series_keys (line_id);

    DROP TABLE IF EXISTS #day_keys;
    SELECT day_num, date_key, week_key
    INTO #day_keys
    FROM dbo.dim_date
    WHERE day_num IS NOT NULL;

    CREATE UNIQUE CLUSTERED INDEX IX_day_keys ON #day_keys (day_num);

    DROP TABLE IF EXISTS #prices;
    SELECT
        k.item_key,
        k.store_key,
        p.wm_yr_wk AS week_key,
        p.sell_price
    INTO #prices
    FROM stg.sell_prices AS p
    JOIN #series_keys    AS k ON k.item_id = p.item_id AND k.store_id = p.store_id;

    CREATE UNIQUE CLUSTERED INDEX IX_prices ON #prices (item_key, store_key, week_key);

    ------------------------------------------------------------------
    -- fact_sales_daily
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS dbo.fact_sales_daily;
    CREATE TABLE dbo.fact_sales_daily (
        date_key    int            NOT NULL,
        week_key    int            NOT NULL,
        item_key    int            NOT NULL,
        store_key   smallint       NOT NULL,
        units_sold  int            NOT NULL,
        sell_price  decimal(10, 2) NULL,
        revenue     decimal(14, 2) NULL,
        is_listed   bit            NOT NULL,
        INDEX CCI_fact_sales_daily CLUSTERED COLUMNSTORE
    );

    INSERT INTO dbo.fact_sales_daily WITH (TABLOCK)
        (date_key, week_key, item_key, store_key, units_sold, sell_price, revenue, is_listed)
    SELECT
        d.date_key,
        d.week_key,
        k.item_key,
        k.store_key,
        s.units_sold,
        p.sell_price,
        s.units_sold * p.sell_price,
        CAST(CASE WHEN p.sell_price IS NULL THEN 0 ELSE 1 END AS bit)
    FROM stg.sales_long  AS s
    JOIN #series_keys    AS k ON k.line_id = s.line_id
    JOIN #day_keys       AS d ON d.day_num = s.day_num
    LEFT JOIN #prices    AS p ON p.item_key  = k.item_key
                             AND p.store_key = k.store_key
                             AND p.week_key  = d.week_key;

    ------------------------------------------------------------------
    -- fact_sales_weekly
    -- selling_days < 7 only in the final, partial week of the data.
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS dbo.fact_sales_weekly;
    CREATE TABLE dbo.fact_sales_weekly (
        week_key      int            NOT NULL,
        item_key      int            NOT NULL,
        store_key     smallint       NOT NULL,
        units_sold    int            NOT NULL,
        revenue       decimal(16, 2) NULL,
        sell_price    decimal(10, 2) NULL,
        selling_days  tinyint        NOT NULL,
        is_listed     bit            NOT NULL,
        INDEX CCI_fact_sales_weekly CLUSTERED COLUMNSTORE
    );

    INSERT INTO dbo.fact_sales_weekly WITH (TABLOCK)
        (week_key, item_key, store_key, units_sold, revenue, sell_price, selling_days, is_listed)
    SELECT
        week_key,
        item_key,
        store_key,
        SUM(units_sold),
        SUM(revenue),
        MAX(sell_price),                 -- one price per week, so MAX just carries it
        CAST(COUNT(*) AS tinyint),
        MAX(CAST(is_listed AS tinyint))
    FROM dbo.fact_sales_daily
    GROUP BY week_key, item_key, store_key;
END;
GO
