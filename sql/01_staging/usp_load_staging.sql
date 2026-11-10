USE M5;
GO

/*
stg.usp_load_staging
Loads the three M5 CSVs from @raw_dir into staging tables.

Outputs
    stg.calendar      1,969 days, typed, with day_num (d_1 -> 1)
    stg.sell_prices   ~6.8M rows, price by store x item x Walmart week
    stg.item_store    30,490 series (line_id + six ID attributes)
    stg.sales_long    59,181,090 rows: line_id x day_num x units_sold

The sales file has 1,947 columns, above SQL Server's 1,024-column table limit.
Instead of a wide table, each line is loaded as one text value and split with
STRING_SPLIT(..., 1), whose ordinal gives each value's position:
positions 1-6 are ID fields, position n > 6 is day d_(n - 6).

Files are read as LF-terminated; any CR from CRLF files is stripped.
The SQL Server service account needs read access to @raw_dir.
*/
CREATE OR ALTER PROCEDURE stg.usp_load_staging
    @raw_dir nvarchar(260)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF RIGHT(@raw_dir, 1) <> N'\' SET @raw_dir += N'\';
    DECLARE @dir nvarchar(520) = REPLACE(@raw_dir, N'''', N'''''');
    DECLARE @sql nvarchar(max);

    ------------------------------------------------------------------
    -- Calendar
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS stg.calendar_raw;
    CREATE TABLE stg.calendar_raw (
        [date]        varchar(50), wm_yr_wk     varchar(50), weekday      varchar(50),
        wday          varchar(50), [month]      varchar(50), [year]       varchar(50),
        d             varchar(50), event_name_1 varchar(50), event_type_1 varchar(50),
        event_name_2  varchar(50), event_type_2 varchar(50), snap_CA      varchar(50),
        snap_TX       varchar(50), snap_WI      varchar(50)
    );

    SET @sql = N'BULK INSERT stg.calendar_raw FROM ''' + @dir + N'calendar.csv''
        WITH (FORMAT = ''CSV'', FIRSTROW = 2, FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'', TABLOCK);';
    EXEC sys.sp_executesql @sql;

    DROP TABLE IF EXISTS stg.calendar;
    SELECT
        CAST([date] AS date)                                    AS calendar_date,
        CAST(d AS varchar(10))                                  AS d,
        CAST(SUBSTRING(d, 3, 10) AS smallint)                   AS day_num,
        CAST(wm_yr_wk AS int)                                   AS wm_yr_wk,
        CAST(weekday AS varchar(10))                            AS weekday,
        CAST(wday AS tinyint)                                   AS wday,
        CAST([month] AS tinyint)                                AS [month],
        CAST([year] AS smallint)                                AS [year],
        CAST(NULLIF(event_name_1, '') AS varchar(30))           AS event_name_1,
        CAST(NULLIF(event_type_1, '') AS varchar(20))           AS event_type_1,
        CAST(NULLIF(event_name_2, '') AS varchar(30))           AS event_name_2,
        CAST(NULLIF(event_type_2, '') AS varchar(20))           AS event_type_2,
        CAST(snap_CA AS bit)                                    AS snap_ca,
        CAST(snap_TX AS bit)                                    AS snap_tx,
        CAST(REPLACE(snap_WI, CHAR(13), '') AS bit)             AS snap_wi
    INTO stg.calendar
    FROM stg.calendar_raw;

    DROP TABLE stg.calendar_raw;

    ------------------------------------------------------------------
    -- Sell prices
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS stg.sell_prices_raw;
    CREATE TABLE stg.sell_prices_raw (
        store_id varchar(50), item_id varchar(50), wm_yr_wk varchar(50), sell_price varchar(50)
    );

    SET @sql = N'BULK INSERT stg.sell_prices_raw FROM ''' + @dir + N'sell_prices.csv''
        WITH (FORMAT = ''CSV'', FIRSTROW = 2, FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'', TABLOCK);';
    EXEC sys.sp_executesql @sql;

    DROP TABLE IF EXISTS stg.sell_prices;
    SELECT
        CAST(store_id AS varchar(10))                                   AS store_id,
        CAST(item_id AS varchar(30))                                    AS item_id,
        CAST(wm_yr_wk AS int)                                           AS wm_yr_wk,
        CAST(REPLACE(sell_price, CHAR(13), '') AS decimal(10, 2))       AS sell_price
    INTO stg.sell_prices
    FROM stg.sell_prices_raw;

    DROP TABLE stg.sell_prices_raw;

    ------------------------------------------------------------------
    -- Sales: one text value per line, then split
    ------------------------------------------------------------------
    DROP TABLE IF EXISTS stg.sales_wide_raw;
    CREATE TABLE stg.sales_wide_raw (line varchar(max) NOT NULL);

    -- Tab never appears in the file, so each whole line lands in the single column.
    SET @sql = N'BULK INSERT stg.sales_wide_raw FROM ''' + @dir + N'sales_train_evaluation.csv''
        WITH (FIRSTROW = 2, FIELDTERMINATOR = ''\t'', ROWTERMINATOR = ''0x0a'', TABLOCK);';
    EXEC sys.sp_executesql @sql;

    -- Give each line a compact integer key (any unique number works; order doesn't matter).
    DROP TABLE IF EXISTS stg.sales_wide_lines;
    SELECT
        ISNULL(CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int), 0) AS line_id,
        REPLACE(line, CHAR(13), '')                                        AS line
    INTO stg.sales_wide_lines
    FROM stg.sales_wide_raw
    WHERE line <> '';

    ALTER TABLE stg.sales_wide_lines ADD CONSTRAINT PK_sales_wide_lines PRIMARY KEY (line_id);
    DROP TABLE stg.sales_wide_raw;

    -- Series attributes: first six positions (the ID fields fit well within 300 characters).
    DROP TABLE IF EXISTS stg.item_store;
    SELECT
        l.line_id,
        CAST(MAX(CASE WHEN s.ordinal = 1 THEN s.value END) AS varchar(60)) AS id,
        CAST(MAX(CASE WHEN s.ordinal = 2 THEN s.value END) AS varchar(30)) AS item_id,
        CAST(MAX(CASE WHEN s.ordinal = 3 THEN s.value END) AS varchar(20)) AS dept_id,
        CAST(MAX(CASE WHEN s.ordinal = 4 THEN s.value END) AS varchar(20)) AS cat_id,
        CAST(MAX(CASE WHEN s.ordinal = 5 THEN s.value END) AS varchar(10)) AS store_id,
        CAST(MAX(CASE WHEN s.ordinal = 6 THEN s.value END) AS varchar(2))  AS state_id
    INTO stg.item_store
    FROM stg.sales_wide_lines AS l
    CROSS APPLY STRING_SPLIT(LEFT(l.line, 300), ',', 1) AS s
    WHERE s.ordinal <= 6
    GROUP BY l.line_id;

    -- Daily units: positions 7+ map to d_1 ... d_1941.
    DROP TABLE IF EXISTS stg.sales_long;
    CREATE TABLE stg.sales_long (
        line_id    int      NOT NULL,
        day_num    smallint NOT NULL,
        units_sold int      NOT NULL,
        INDEX CCI_sales_long CLUSTERED COLUMNSTORE
    );

    INSERT INTO stg.sales_long WITH (TABLOCK) (line_id, day_num, units_sold)
    SELECT
        l.line_id,
        CAST(s.ordinal - 6 AS smallint),
        CAST(s.value AS int)
    FROM stg.sales_wide_lines AS l
    CROSS APPLY STRING_SPLIT(l.line, ',', 1) AS s
    WHERE s.ordinal > 6;

    DROP TABLE stg.sales_wide_lines;
END;
GO
