# Historical data provenance and availability

The historical exchange-rate archive was collected from [Fortune Exchange](https://exchange.addisfortune.news/currencies) for the period **2024-10-01 through 2026-09-30**.

The original four-currency local archive contained **55,381 rows**, including **14,243 USD** records, on **605 distinct observation dates**. The full analytical date dimension covers 730 calendar dates; 125 dates were not observed in the source archive (104 Sundays and 21 other dates).

**No raw Fortune Exchange CSV is included in this public repository.** Third-party data access, extraction and redistribution permissions have not been established. Attribution is not a license to republish the underlying dataset.

Missing source observations **do not mean** banks did not issue or update quotations on those dates. Repeated identical displayed values likewise do not prove a lack of bank publication activity. The seven-day analytical carry-forward method is a modeling assumption, not an official quotation validity guarantee.

The SQL scripts require an appropriately obtained source archive loaded into `raw_exchange_rates`, as described in [Rebuilding and Validation](../docs/rebuilding_and_validation.md). Reported counts and results refer to the author's archived dataset; a later source download may differ.
