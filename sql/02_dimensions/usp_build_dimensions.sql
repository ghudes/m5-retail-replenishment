USE M5;
GO

/*
dbo.usp_build_dimensions
Rebuilds dim_week, dim_date, dim_item, dim_store from staging.
Surrogate keys for item and store are assigned deterministically by natural key.
*/
CREATE OR ALTER PROCEDURE dbo.usp_build_dimensions
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    ------------------------------------------------------------------
    -- dim_week: one row per Walmart week (wm_yr_wk), e.g. 11101 = fiscal 2011, week 01
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS dbo.dim_week;
    SELECT
        ISNULL(wm_yr_wk, 0)                       AS week_key,
        MIN(calendar_date)                        AS week_start_date,
        MAX(calendar_date)                        AS week_end_date,
        CAST(2000 + (wm_yr_wk / 100) % 100 AS smallint) AS fiscal_year,
        CAST(wm_yr_wk % 100 AS tinyint)           AS week_of_year
    INTO dbo.dim_week
    FROM stg.calendar
    GROUP BY wm_yr_wk;

    ALTER TABLE dbo.dim_week ADD CONSTRAINT PK_dim_week PRIMARY KEY (week_key);

    ------------------------------------------------------------------
    -- dim_date: one row per day; date_key is yyyymmdd
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS dbo.dim_date;
    SELECT
        ISNULL(CAST(CONVERT(char(8), calendar_date, 112) AS int), 0) AS date_key,
        calendar_date,
        d                                   AS d_label,
        day_num,
        wm_yr_wk                            AS week_key,
        weekday,
        wday                                AS weekday_num,   -- M5: 1 = Saturday
        [month],
        [year],
        event_name_1                        AS event_name,
        event_type_1                        AS event_type,
        event_name_2,
        event_type_2,
        CAST(CASE WHEN event_name_1 IS NOT NULL THEN 1 ELSE 0 END AS bit) AS is_event_day,
        snap_ca,
        snap_tx,
        snap_wi
    INTO dbo.dim_date
    FROM stg.calendar;

    ALTER TABLE dbo.dim_date ADD CONSTRAINT PK_dim_date PRIMARY KEY (date_key);

    ------------------------------------------------------------------
    -- dim_item: 3,049 items
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS dbo.dim_item;
    SELECT
        ISNULL(CAST(ROW_NUMBER() OVER (ORDER BY item_id) AS int), 0) AS item_key,
        item_id,
        dept_id,
        cat_id
    INTO dbo.dim_item
    FROM (SELECT DISTINCT item_id, dept_id, cat_id FROM stg.item_store) AS i;

    ALTER TABLE dbo.dim_item ADD CONSTRAINT PK_dim_item PRIMARY KEY (item_key);

    ------------------------------------------------------------------
    -- dim_store: 10 stores (CA, TX, WI)
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS dbo.dim_store;
    SELECT
        ISNULL(CAST(ROW_NUMBER() OVER (ORDER BY store_id) AS smallint), 0) AS store_key,
        store_id,
        state_id
    INTO dbo.dim_store
    FROM (SELECT DISTINCT store_id, state_id FROM stg.item_store) AS s;

    ALTER TABLE dbo.dim_store ADD CONSTRAINT PK_dim_store PRIMARY KEY (store_key);
END;
GO
