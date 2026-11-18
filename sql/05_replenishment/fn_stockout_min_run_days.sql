USE M5;
GO

/*
dbo.fn_stockout_min_run_days
Shortest zero-sale run that is unlikely (probability < @alpha) for a series
selling @avg_daily_units a day, if daily sales were Poisson:

    P(0 sales on a day)        = e^(-lambda)
    P(k zero days in a row)    = e^(-lambda * k)
    smallest k with e^(-lambda * k) < alpha  =  CEILING( LN(1 / alpha) / lambda )

Floored at @floor_days. NULL when the series never sold (no threshold).
T-SQL LOG() is the natural log.

Inline table-valued function, so the optimizer folds it into the calling
query like a CROSS APPLY with the formula written out.
*/
CREATE OR ALTER FUNCTION dbo.fn_stockout_min_run_days
(
    @avg_daily_units float,
    @alpha           float,
    @floor_days      int
)
RETURNS TABLE
AS
RETURN
    SELECT CASE
               WHEN @avg_daily_units IS NULL OR @avg_daily_units <= 0 THEN NULL
               WHEN CEILING(LOG(1.0 / @alpha) / @avg_daily_units) < @floor_days THEN @floor_days
               ELSE CAST(CEILING(LOG(1.0 / @alpha) / @avg_daily_units) AS int)
           END AS min_run_days;
GO
