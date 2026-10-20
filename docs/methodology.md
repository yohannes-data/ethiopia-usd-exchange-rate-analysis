# Methodology — Ethiopian USD/ETB Historical Analysis

## 1. Study questions and scope

**Period:** 2024-10-01 through 2026-09-30 (inclusive, 730 calendar dates). **Currency:** USD quotations against ETB. **Rate type used for calculations:** cash buying and cash selling, in ETB per USD. **Source:** [Addis Fortune exchange-rate archive](https://exchange.addisfortune.news/currencies), collected as date-and-bank snapshots. **Unit of observation for the final analysis:** a bank's quotation eligible on an observed USD archive date under the seven-day freshness assumption.

The project investigates (a) USD/ETB movement and monthly changes; (b) banks' relative historical cash buy/sell competitiveness. It deliberately does not analyze USD transactional volume, forecast rates or recommend a current currency transaction.

## 2. Archive and transformations

- Source archive: **55,381** rows across USD, EUR, GBP and AED, with fields for date, currency, bank ID and cash/transfer rate types.
- USD rows used for dimensional analysis: **14,243**.
- Observed dates with USD archive data: **605**; the date dimension contains the complete **730-day** calendar range. **125 dates are missing** (104 Sundays and 21 other dates). Missing archive dates are not synthesized, and missing observations do **not** establish that banks failed to update quotations.
- Date header in the original combined CSV is named **`date`**; the staging SQL column is named **`rate_date`**. Map it correctly when importing with DBeaver.
- `applicable_date` was not loaded into the fact table after the original archive was checked and its calendar date matched `rate_date` in this dataset. The raw staging table retains the field.
- `dim_bank` maps 30 original bank IDs to names and short codes. **NBE** and **DBE** are excluded from all commercial-bank market/peer views; 28 banks remain eligible.
- Valid quote-change analysis requires `cash_buy > 0` **and** `cash_sell > 0`; zero/invalid cash quotes do not generate events.

## 3. Detect cash quote changes

For each commercial bank and USD, order all valid observations by `rate_date` and compare cash buy/sell with the preceding valid observation using `LAG`.

A new event occurs if **either** current cash rate differs from its previous valid cash rate. The first valid quote of a bank after the initial archive day is **not** automatically called a new event because the quote's original setting date is unknown. Exception: the **23 commercial-bank rates observed on 2024-10-01** are inserted as assumed opening-baseline events so the study has a defined starting point.

This produced **6,468** detected/baseline events for **28 banks** across **601 dates**. A change event is an observed rate difference, **not evidence of the bank's original internal publication timestamp**. Banks could change rates on dates missing from Fortune Exchange or republish identical numeric quotes. Neither event can be reliably distinguished from this archive.

Relevant SQL view: `vw_bank_cash_quote_events`.

## 4. Quote validity and expansion

The observed source often repeats the same quotation on later dates. The study imposes a **maximum of seven calendar days** of analytical freshness, beginning on the date of an event:

```text
0 <= observed_date - quote_event_date <= 6 calendar days
observed_date < next quote-event date (if any)
```

- Each event is available on its own date and for up to six subsequent calendar dates.
- A newly detected change takes precedence immediately, ending the earlier quote's interval.
- An identical repeated source quote **does not** refresh the seven-day clock.
- Expansion is performed **only for dates that actually have USD observations in the archive**. No Sunday/weekend/holiday dates are invented.
- The result contains **at most one eligible USD cash quote per bank per observed date**.

**This is a modeling assumption, not a bank-issued validity guarantee.** It does not establish that a bank failed to update during this interval. Fortune Exchange is missing 125 calendar dates; a change on any missing date would not be directly observed. Repeated identical quotes also do not prove the absence of fresh bank publications. The rule is a compromise between treating every displayed repeat as a newly issued quote and including only the banks with a detected change that day.

Relevant SQL view: `vw_usd_valid_7d_bank_quotes`.

## 5. Daily market trend

For each observed date **d**, across the eligible commercial banks **B(d)**:

```text
Daily average buy(d)  = SUM[bank cash_buy(b,d)] / number of eligible banks
Daily average sell(d) = SUM[bank cash_sell(b,d)] / number of eligible banks
```

Daily rates are **equal-bank-weighted**, not weighted by the size of banks or value of USD traded. The result is **not** the National Bank of Ethiopia's volume-weighted indicative rate.

The original concern appeared on **2025-05-23**: only **one** bank's cash quote changed that day, giving an unrepresentative "market average" based on its fresh change. Under the seven-day rule, **16 banks** contributed, giving an average buy rate of **131.8456 ETB/USD** and average sell of **134.4825 ETB/USD**. This issue triggered the shared quote-validity methodology used on both report pages.

Coverage checks: **605 observed dates**, mean **20.4** eligible banks/day, minimum **9**, maximum **27**; **zero** observed dates with fewer than five banks and only **one** date with fewer than ten.

Relevant SQL view: `vw_daily_usd_market`.

## 6. Monthly USD/ETB movement

The mean daily USD cash buying quote in month **m** is computed from the observed market dates in that month; each observed date contributes **one** daily average. For month **m > first month**:

```text
Monthly change (ETB) = MonthlyAvgBuy(m) - MonthlyAvgBuy(m-1)
Monthly change (%)   = 100 * Monthly change (ETB) / MonthlyAvgBuy(m-1)
```

A month is not compared with an arbitrary day two years earlier. October 2024 has no prior month in the study, so the change is blank.

Selected validated results:

| Month | Average buy, ETB/USD | Change, ETB | Change, % |
| --- | ---: | ---: | ---: |
| Oct 2024 | 116.0468 | — | — |
| Nov 2024 | 121.6422 | +5.60 | +4.82% |
| Oct 2025 | 145.1553 | +4.31 | +3.06% |
| Nov 2025 | 150.6112 | +5.46 | +3.76% |
| Sep 2026 | 161.6597 | +0.65 | +0.40% |

The SQL verification uses `vw_monthly_usd_market`; Power BI reproduces the monthly comparison using date-aware DAX measures.

## 7. Bank competitiveness — leave-one-out same-day peers

For bank **b** on eligible observed date **d**, define other eligible banks **P(b,d) = B(d) excluding b**. The daily peer means are simple averages of the **other** banks:

```text
PeerBuy(b,d)  = AVERAGE[cash_buy of other eligible banks on d]
PeerSell(b,d) = AVERAGE[cash_sell of other eligible banks on d]

BuyVsPeerPct(b,d)  = 100 * (Buy(b,d)  - PeerBuy(b,d))  / PeerBuy(b,d)
SellVsPeerPct(b,d) = 100 * (Sell(b,d) - PeerSell(b,d)) / PeerSell(b,d)
```

**Meaning:**

- If the customer **sells USD** to the bank, **higher buying-rate difference** is better (more ETB per USD).
- If the customer **buys USD** from the bank, **lower selling-rate difference** is better (fewer ETB per USD).

To obtain a full-period bank score, Power BI calculates the **arithmetic mean of that bank's daily relative percentages on its eligible dates**, and orders banks descending for selling USD, ascending for buying USD. Daily percentages in the SQL view are rounded to two decimal places before averaging, which may produce small rounding differences versus unrounded calculations. Months are not assigned equal weights in the full-period score; each eligible observed bank-day is given equal weight. Selecting a month in the dashboard slicer restricts the bank-day rows to that month before recomputing averages.

If no peer is available, the SQL percentage is `NULL` (not 0); the validated dataset has enough banks that no such row occurred.

Selected validated **full-period** results:

| Bank | Average buy vs peers | Average sell vs peers | Eligible bank-days |
| --- | ---: | ---: | ---: |
| Oromia International Bank (ORO) | +1.65% | +1.68% | 441 |
| Amhara Bank (AMH) | +0.55% | +0.54% | 302 |
| Abay Bank (ABY) | +0.29% | +0.29% | 530 |
| Nib International Bank (NIB) | −0.52% | −0.51% | 407 |
| Commercial Bank of Ethiopia (CBE) | −0.91% | −0.96% | 279 |

This is a comparison of bank quotations **within the analysis' eligible observation windows**—not proof that any particular bank was best on every date, guaranteed executable or consistently available to customers.

Relevant SQL view: `vw_bank_quote_event_vs_peer` (legacy name retained for Power BI compatibility; the view now includes all eligible **seven-day-valid bank-days**, not only change events).

## 8. Model and report design

**Tables:** `raw_exchange_rates` (source staging; four currencies), `dim_date` (calendar), `dim_currency` (USD), `dim_bank` (30 entries), `fact_exchange_rate` (USD). The `fact_exchange_rate` model uses a composite `(rate_date, currency_code, bank_id)` primary key with foreign keys to dimensions.

**Core derived SQL views:**

| View | Purpose |
| --- | --- |
| `vw_bank_cash_quote_events` | Detect changed USD cash quotes and initial baseline |
| `vw_usd_valid_7d_bank_quotes` | Expand change events to seven-day-valid quotes on observed dates |
| `vw_daily_usd_market` | Daily eligible-bank average buy/sell and participation counts |
| `vw_bank_quote_event_vs_peer` | Daily leave-one-bank-out comparison; imported into Power BI as `Quote Events` |
| `vw_monthly_usd_market` | SQL-side monthly movement verification |

Additional legacy summary/spread-policy views are retained by the master SQL for compatibility, but are **not presented as extra dashboards**.

**Power BI pages:**

1. **USD Market Overview:** line chart for the two average rates; monthly change in ETB; monthly change in percent.
2. **Bank Competitiveness:** two sorted bank rankings and a Month Year dropdown slicer, with seven-day assumption disclosed on the page.

**DAX:** `[Avg Market Buy]` and `[Avg Market Sell]` use the SQL daily-market rows; `[Avg Buy vs Peer %]` and `[Avg Sell vs Peer %]` average the SQL peer difference fields. Monthly changes are computed from the current and previous month's daily-market buying averages. The SQL view's peer percentages already use the 0–100 scale, so the peer measures are formatted as numbers rather than Power BI Percentage type. Monthly change ratios in DAX should be represented as 0–1 and formatted as Percentage.

## 9. Verification

The complete staged archive was imported to a **separate empty PostgreSQL rebuild database**, and the master script was successfully executed using `psql`, ending in `COMMIT`. The independent validation script then returned:

- **21/21 PASS** for row totals, dimensions, baseline/events, coverage and problem-date daily averages.
- Valid quote age **0–6 days**, with **zero age violations**.
- **Zero duplicate bank-date rows** in the seven-day-valid view.
- **Zero NBE/DBE rows** in the commercial-bank validity view.
- **Zero discrepancies** in row/bank-count cross-checking of daily market versus peer analysis.
- Verified monthly average-and-change values and full-period bank competitiveness rankings.

Scripts: [`../sql/ethiopia_fx_final_master.sql`](../sql/ethiopia_fx_final_master.sql), [`../sql/ethiopia_fx_final_validation.sql`](../sql/ethiopia_fx_final_validation.sql).

## 10. Caveats, source rights and ethical use

This analysis is descriptive and historical. Published rates are not verified executions. Bank charges, branch availability, regulations, client eligibility, negotiated quotes, and rate types can affect transaction outcomes. The seven-day period is an **analytical carry-forward window**, not an official quotation expiry period or a verified measure of bank update frequency. Missing Fortune Exchange observations do not imply that banks did not update their rates. The original archive is not republished without permission, and this repo cannot fully reconstruct its raw data unless an authorized copy is supplied separately. The resulting averages are not the NBE indicative rate, which is based on prior-day transaction volumes ([NBE guidance](https://nbe.gov.et/fx/)).

SQL implementation and troubleshooting included AI assistance. The project author defined and revised the analytical goals, executed the queries, checked results against the original database, independently rebuilt the model, and evaluated the Power BI results.

### Interpretation of bank coverage

Each bank's two-year score is calculated over its **eligible observed bank-days**, which vary across banks. For example, ORO has 441 qualifying bank-days (72.9% of 605 observed dates), while CBE has 279 (46.1%). Peer composition also changes over time. Therefore the rankings are conditional historical comparisons under the seven-day rule—not rankings from a fixed common sample, nor claims of always-available transaction rates.
