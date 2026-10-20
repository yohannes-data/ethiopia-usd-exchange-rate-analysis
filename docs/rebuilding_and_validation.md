# Rebuilding and Validating the PostgreSQL Model

The master SQL script was successfully executed on PostgreSQL using `psql` after importing the original archive. The independent rebuilding test and read-only validation returned **21/21 PASS**.

## Prerequisites

- PostgreSQL, with permission to create a database.
- `psql` command-line client (the test used PostgreSQL 18.6).
- DBeaver or another CSV import tool.
- Independently obtained, authorized historical `all_exchange_rates.csv` from the [Addis Fortune source](https://exchange.addisfortune.news/currencies). The CSV is not distributed here.

## 1. Use a dedicated test database

**Never run the rebuild on an existing production or current Power BI source database without taking a backup.**

```sql
CREATE DATABASE ethiopia_fx_rebuild_test;
```

Use a connection pointing to `ethiopia_fx_rebuild_test`, not `ethiopia_fx`.

## 2. Create staging table and import data

The master script creates the staging table if it does not already exist, but the raw CSV must be imported **before** the rest of the master script can build fact/dimension objects. Create this table separately in the test database:

```sql
CREATE TABLE IF NOT EXISTS public.raw_exchange_rates (
    rate_date DATE,
    applicable_date TEXT,
    currency VARCHAR(3),
    currency_name VARCHAR(100),
    bank_id INTEGER,
    cash_buy NUMERIC(15,4),
    cash_sell NUMERIC(15,4),
    transfer_buy NUMERIC(15,4),
    transfer_sell NUMERIC(15,4)
);
```

Import CSV into `public.raw_exchange_rates` in DBeaver. **Important mapping detail:** the CSV header `date` must map to the SQL column `rate_date` (not to an accidentally created column called `date`). The other CSV headers map by name: `applicable_date`, `currency`, `currency_name`, `bank_id`, `cash_buy`, `cash_sell`, `transfer_buy`, `transfer_sell`. Use UTF-8/UTF-8-BOM, comma separator, and the `yyyy-MM-dd` date format.

After import, run:

```sql
SELECT COUNT(*) AS total_rows,
       COUNT(*) FILTER (WHERE currency = 'USD') AS usd_rows,
       COUNT(DISTINCT rate_date) AS observed_dates,
       MIN(rate_date) AS first_date,
       MAX(rate_date) AS last_date
FROM public.raw_exchange_rates;
```

Expected: `55,381 | 14,243 | 605 | 2024-10-01 | 2026-09-30`.

## 3. Execute master script using psql

Run **from the test database**. The paths below are examples, not actual filesystem paths on your computer.

```text
\set ON_ERROR_STOP on
\i 'C:/path/to/sql/ethiopia_fx_final_master.sql'
```

The master script executes in a transaction, and a successful clean rebuild ends with `COMMIT`. It creates/upserts the analytical model and views without deleting the raw archive. It does not download any source data.

> DBeaver's SQL script runner previously split some statements incorrectly in this project. Using `psql` avoided those parser errors. If the script fails, stop on the **first error** instead of repeatedly running a transaction that PostgreSQL has already marked aborted.

## 4. Read-only validation

```text
\i 'C:/path/to/sql/ethiopia_fx_final_validation.sql'
```

The first output is a **21-row PASS/CHECK** table; for the validated source all 21 returned `PASS`. The script also inspects 7-day age and uniqueness, the May 20–27 2025 correction, the set of banks valid on May 23, peer/day count consistency, two-year bank rankings and 24 monthly average/change rows.

**Expected invariants:**

| Check | Validated result |
| --- | --- |
| Row-count/coverage checks | 21/21 PASS |
| Seven-day quote age | 0 through 6 |
| Age violations | 0 |
| Duplicate eligible bank-date rows | 0 |
| NBE/DBE rows in eligibility view | 0 |
| Peer/daily market row-count discrepancies | 0 rows |
| Market bank participation | Minimum 9, mean 20.4, maximum 27 |
| May 23, 2025 eligible-bank buy/sell average | 131.8456 / 134.4825 ETB/USD |

## 5. Integrating with Power BI

Import these views/tables from the rebuilt PostgreSQL database:

- `vw_daily_usd_market`
- `vw_bank_quote_event_vs_peer`
- `dim_date`
- `dim_bank`

Create 1-to-many, single-direction relationships from `dim_date[date_key]` to daily/peer view dates, and from `dim_bank[bank_id]` to the peer view's `bank_id`. The old Power BI import label `Quote Events` points to `vw_bank_quote_event_vs_peer`, which **now represents seven-day-eligible daily bank observations**, not only change events. For dashboard behavior, see [Methodology](methodology.md).

## Data privacy and permissions

Do not commit PostgreSQL passwords, browser cookies, client data, a populated PBIX, or unlicensed third-party rate archives to a public repository. Confirm redistribution terms before adding data and check Power BI report metadata and connection details before publication.

**Source coverage caveat:** The archive has 605 observed USD dates in a 730-day period. The 125 missing dates and repeated quotes do not prove that banks failed to publish updated rates on those days. The seven-day window is only an analytical convention.
