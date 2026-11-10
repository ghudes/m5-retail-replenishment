# Getting the M5 data

The raw files are not committed (they total several hundred MB and are governed by Kaggle's competition rules).

1. Sign in to Kaggle and accept the rules at https://www.kaggle.com/competitions/m5-forecasting-accuracy/rules
2. Download from the **Data** tab: https://www.kaggle.com/competitions/m5-forecasting-accuracy/data
3. Keep these three files:

| File | Rows | Notes |
|---|---|---|
| `sales_train_evaluation.csv` | 30,490 | 6 ID columns + `d_1` … `d_1941` |
| `calendar.csv` | 1,969 | Covers the 1,941 sales days plus the 28-day forecast horizon |
| `sell_prices.csv` | ~6.8M | Price by store × item × Walmart week |

`sales_train_validation.csv` (d_1–d_1913) and `sample_submission.csv` are not used.

4. Put all three in **`C:\m5\raw`** (or any folder, and set `RawDir` in `build.sql` to match).

   Keep it outside your Windows user folders (Documents, Downloads, Desktop). `BULK INSERT` reads files as the SQL Server service account, which usually can't see inside them.
