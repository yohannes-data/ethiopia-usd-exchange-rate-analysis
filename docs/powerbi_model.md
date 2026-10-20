# Power BI report configuration

This repository documents the Power BI report but does **not** redistribute the populated PBIX or original Fortune Exchange archive. The following instructions describe how to reproduce the report after rebuilding the PostgreSQL database and importing the source with permission.

## Data sources

Use PostgreSQL Import mode; connect to the rebuilt database (original working database was `ethiopia_fx`). Import:

- `dim_date`
- `dim_bank`
- `vw_daily_usd_market`
- `vw_bank_quote_event_vs_peer`

The historical market report uses `vw_daily_usd_market`. Bank competitiveness uses `vw_bank_quote_event_vs_peer`, which now represents daily valid-quote comparisons rather than only same-day update events, despite the legacy SQL view name.

## Model relationships

- `dim_date[date_key]` (one) → `vw_daily_usd_market[rate_date]` (many), active, single direction.
- `dim_date[date_key]` (one) → `vw_bank_quote_event_vs_peer[rate_date]` (many), active, single direction.
- `dim_bank[bank_id]` (one) → `vw_bank_quote_event_vs_peer[bank_id]` (many), active, single direction.

Set date columns to Date type. **Mark `dim_date` as the Date table, selecting `date_key`.** Keep the date dimension's complete consecutive calendar even though the raw source has missing observation dates.

The report below assumes the Power BI table names `dim_date`, `dim_bank`, `daily_usd_market`, and `Quote Events` (rename the imported SQL views accordingly).

## Calendar columns

```dax
Month Year = FORMAT(dim_date[date_key], "MMM yyyy")
Month Sort = YEAR(dim_date[date_key]) * 100 + MONTH(dim_date[date_key])
```

Sort `Month Year` by `Month Sort`.

## Measures

```dax
Avg Market Buy =
AVERAGE(daily_usd_market[avg_cash_buy])

Avg Market Sell =
AVERAGE(daily_usd_market[avg_cash_sell])

Avg Buy vs Peer % =
AVERAGE('Quote Events'[cash_buy_vs_peer_pct])

Avg Sell vs Peer % =
AVERAGE('Quote Events'[cash_sell_vs_peer_pct])

Previous Month Avg Buy =
CALCULATE(
    [Avg Market Buy],
    DATEADD(dim_date[date_key], -1, MONTH)
)

Monthly Buy Change (ETB) =
VAR CurrentRate = [Avg Market Buy]
VAR PreviousRate = [Previous Month Avg Buy]
RETURN
    IF(
        ISBLANK(CurrentRate) || ISBLANK(PreviousRate),
        BLANK(),
        CurrentRate - PreviousRate
    )

Monthly Buy Change % =
DIVIDE(
    [Monthly Buy Change (ETB)],
    [Previous Month Avg Buy]
)
```

**Formatting:** `Avg Buy vs Peer %` and `Avg Sell vs Peer %` are already on a 0–100 percentage scale in SQL. Format them as decimal numbers with two digits rather than Power BI Percent format. `Monthly Buy Change %` returns a 0–1 ratio and should be formatted as Percentage.

## Page 1 — USD/ETB Market Overview

- Line chart: X-axis `dim_date[date_key]`; Y-axis `Avg Market Buy` and `Avg Market Sell` (ETB/USD).
- Column chart: X-axis `dim_date[Month Year]`; Y-axis `Monthly Buy Change (ETB)`.
- Column chart: X-axis `dim_date[Month Year]`; Y-axis `Monthly Buy Change %`.

Each monthly average gives equal weight to observed source dates with eligible seven-day quotations, not equal weight to every individual bank quotation across a month. October 2024 has no previous month in the source period and should have a blank month-over-month change.

## Page 2 — Bank Competitiveness

- Two clustered column charts with `dim_bank[bank_code]` as category.
- Selling USD to a bank: `Avg Buy vs Peer %`, descending (higher is better).
- Buying USD from a bank: `Avg Sell vs Peer %`, ascending (lower is better).
- Dropdown slicer: `dim_date[Month Year]`; clearing the slicer compares the full two-year period.

The underlying peer mean **excludes the bank itself** and includes other eligible commercial banks on each observed source date. Monthly selections recompute the average of eligible daily comparisons. A zero score is different from a missing score; do not replace blanks with zero.

## Verification and scope

Published screenshots reflect two report pages. The supplied text describes the intended model, but a populated PBIX and historical data are not shared for independent Power BI refresh. Source restrictions and limitations are in [Methodology](methodology.md). Data and SQL checks are documented in [Rebuilding and Validation](rebuilding_and_validation.md).
