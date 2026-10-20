-- ============================================================================
-- ETHIOPIAN USD/ETB EXCHANGE RATE ANALYSIS | FINAL MASTER MODEL
-- PostgreSQL / Power BI portfolio | 2024-10-01 through 2026-09-30
-- ============================================================================
-- DATA PROVENANCE
--   Source: Fortune Exchange archive, captured into all_exchange_rates.csv.
--   Raw archive: USD, EUR, GBP, AED; analytical model: USD cash quotes only.
--   The raw data is NOT included in this script; confirm redistribution rights
--   before publishing the CSV or a populated PBIX to a public repository.
--
-- RUNNING THIS SCRIPT
--   Database: ethiopia_fx (or another PostgreSQL database you own).
--   Step A: Import the archived CSV into raw_exchange_rates using DBeaver.
--           Expected archive: 55,381 rows (including 14,243 USD rows).
--   Step B: Execute this entire script using DBeaver's SQL script execution.
--           Version 1.2: DBeaver-safe preflight + unambiguous UPSERT syntax.
--           It creates/updates analytical tables and views, without DROP.
--   Step C: Run ethiopia_fx_final_validation.sql (READ-ONLY).
--
-- SAFETY: Does NOT delete the raw archive or drop tables/views. Nevertheless,
-- it UPSERTS dim_bank, dim_currency and fact_exchange_rate and REPLACES views.
-- Make a database backup before running it against an existing Power BI model.
-- It is not necessary to rerun this rebuild against your already working DB;
-- run the separate validation script there first.
--
-- LOGIC
-- 1) Quote-change = valid cash buy OR cash sell differs from previous valid
--    observed quote for that bank. The 23 bank quotes on 2024-10-01 are
--    ASSUMED initial baseline events; first appearance on LATER dates is not.
-- 2) Each event starts a quotation-validity interval of seven calendar days,
--    including the event date (age 0..6); a new event supersedes the old one.
--    Repeated unchanged observations DO NOT renew the validity period.
-- 3) Expand only to dates actually observed in the USD raw archive.
--    Missing dates are NOT interpolated. NBE and DBE excluded from peers.
-- 4) Bank's peer average excludes the bank itself. If only one valid bank,
--    peer percentages are NULL. No indefinite rate carry-forward.
-- 5) This is an analytic freshness assumption, NOT a representation that
--    a quotation would necessarily have been executable on later dates.
--
-- COMPATIBILITY: Preserves Power BI's imported views and column names:
--   vw_daily_usd_market; vw_bank_quote_event_vs_peer
-- Other legacy SQL views are updated for a complete, reproducible model.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 01. RAW ARCHIVE STAGING TABLE (never truncate/delete its data)
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS raw_exchange_rates (
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

-- Validate source before changing any analytical objects.
-- These SQL CHECK constraints replace a PL/pgSQL DO dollar-quoted block,
-- which some DBeaver script execution modes incorrectly split at semicolons.
-- Each failing condition produces the corresponding constraint name.
CREATE TEMP TABLE fx_source_preflight (
    source_has_usd BOOLEAN NOT NULL
        CONSTRAINT ck_fx_source_has_usd CHECK (source_has_usd),
    source_unique_usd_keys BOOLEAN NOT NULL
        CONSTRAINT ck_fx_source_unique_usd_keys CHECK (source_unique_usd_keys),
    source_usd_required_fields BOOLEAN NOT NULL
        CONSTRAINT ck_fx_source_usd_required_fields CHECK (source_usd_required_fields),
    source_usd_dates_in_range BOOLEAN NOT NULL
        CONSTRAINT ck_fx_source_usd_dates_in_range CHECK (source_usd_dates_in_range)
) ON COMMIT DROP;

INSERT INTO fx_source_preflight (
    source_has_usd,
    source_unique_usd_keys,
    source_usd_required_fields,
    source_usd_dates_in_range
)
SELECT
    EXISTS (
        SELECT 1 FROM raw_exchange_rates WHERE currency = 'USD'
    ),
    NOT EXISTS (
        SELECT 1
        FROM raw_exchange_rates
        WHERE currency = 'USD'
        GROUP BY rate_date, currency, bank_id
        HAVING COUNT(*) > 1
    ),
    NOT EXISTS (
        SELECT 1 FROM raw_exchange_rates
        WHERE currency = 'USD'
          AND (rate_date IS NULL OR bank_id IS NULL
               OR cash_buy IS NULL OR cash_sell IS NULL
               OR transfer_buy IS NULL OR transfer_sell IS NULL)
    ),
    NOT EXISTS (
        SELECT 1 FROM raw_exchange_rates
        WHERE currency = 'USD'
          AND (rate_date < DATE '2024-10-01'
               OR rate_date > DATE '2026-09-30')
    );

-- --------------------------------------------------------------------------
-- 02. DIM_DATE: all 730 calendar days (including 125 unobserved days)
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_date (
    date_key DATE PRIMARY KEY,
    year INTEGER,
    month_no INTEGER,
    month_name TEXT,
    day_of_month INTEGER,
    day_of_week INTEGER,
    day_name TEXT,
    is_sunday BOOLEAN
);

INSERT INTO dim_date (
    date_key, year, month_no, month_name,
    day_of_month, day_of_week, day_name, is_sunday
)
SELECT
    g.day::date,
    EXTRACT(YEAR FROM g.day)::integer,
    EXTRACT(MONTH FROM g.day)::integer,
    TO_CHAR(g.day, 'Month'),
    EXTRACT(DAY FROM g.day)::integer,
    EXTRACT(ISODOW FROM g.day)::integer,
    TO_CHAR(g.day, 'Day'),
    EXTRACT(ISODOW FROM g.day) = 7
FROM generate_series(
    TIMESTAMP '2024-10-01',
    TIMESTAMP '2026-09-30',
    INTERVAL '1 day'
) AS g(day)
WHERE TRUE  -- disambiguates INSERT ... SELECT ... ON CONFLICT in PostgreSQL
ON CONFLICT (date_key) DO NOTHING;

-- --------------------------------------------------------------------------
-- 03. DIM_CURRENCY: USD only
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_currency (
    currency_code VARCHAR(3) PRIMARY KEY,
    currency_name VARCHAR(100)
);

INSERT INTO dim_currency(currency_code, currency_name)
SELECT 'USD', MIN(currency_name)
FROM raw_exchange_rates
WHERE currency = 'USD'
ON CONFLICT (currency_code) DO UPDATE
    SET currency_name = EXCLUDED.currency_name;

-- --------------------------------------------------------------------------
-- 04. DIM_BANK: exact 30-bank ID/code/name mapping from source metadata
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_bank (
    bank_id INTEGER PRIMARY KEY,
    bank_code VARCHAR(10) NOT NULL,
    bank_name VARCHAR(150) NOT NULL
);

INSERT INTO dim_bank(bank_id, bank_code, bank_name)
VALUES
    (1,  'CBE',   'Commercial Bank of Ethiopia'),
    (2,  'DBE',   'Development Bank of Ethiopia'),
    (3,  'AWS',   'Awash Bank S.C.'),
    (4,  'BOA',   'Bank of Abyssinia S.C.'),
    (5,  'COOP',  'Cooperative Bank of Oromia S.C.'),
    (6,  'GBE',   'Global Bank Ethiopia S.C.'),
    (7,  'HIJ',   'Hijra Bank S.C.'),
    (8,  'TES',   'Tsehay Bank S.C.'),
    (9,  'HIB',   'Hibret Bank S.C.'),
    (10, 'ZEM',   'Zemen Bank S.C.'),
    (11, 'WEG',   'Wegagen Bank S.C.'),
    (13, 'NIB',   'Nib International Bank S.C.'),
    (14, 'ABY',   'Abay Bank S.C.'),
    (15, 'ADB',   'Addis Bank S.C'),
    (16, 'BER',   'Berhan International Bank S.C'),
    (17, 'BUN',   'Bunna International Bank S.C'),
    (19, 'DAS',   'Dashen Bank S.C'),
    (20, 'ENT',   'Enat Bank S.C'),
    (21, 'LIB',   'Anbesa Bank'),
    (22, 'ORO',   'Oromia International Bank S.C'),
    (24, 'ZAM',   'ZamZam Bank S.C'),
    (25, 'SIN',   'Siinqee Bank S.C'),
    (27, 'AHD',   'Ahadu Bank S.C'),
    (28, 'GOH',   'Goh Betoch Bank SC'),
    (29, 'TSED',  'Tsedey Bank S.C'),
    (30, 'GAD',   'Gadaa Bank SC'),
    (31, 'AMH',   'Amhara Bank S.C'),
    (33, 'SID',   'Sidama Bank S.C'),
    (34, 'NBE',   'National Bank of Ethiopia'),
    (35, 'SIKET', 'Siket Bank')
ON CONFLICT (bank_id) DO UPDATE
    SET bank_code = EXCLUDED.bank_code,
        bank_name = EXCLUDED.bank_name;

-- --------------------------------------------------------------------------
-- 05. USD FACT TABLE: retains source observations, INCLUDING unchanged rates
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_exchange_rate (
    rate_date DATE NOT NULL,
    currency_code VARCHAR(3) NOT NULL,
    bank_id INTEGER NOT NULL,
    cash_buy NUMERIC(15,4) NOT NULL,
    cash_sell NUMERIC(15,4) NOT NULL,
    transfer_buy NUMERIC(15,4) NOT NULL,
    transfer_sell NUMERIC(15,4) NOT NULL,
    CONSTRAINT pk_fact_exchange_rate PRIMARY KEY (rate_date, currency_code, bank_id),
    CONSTRAINT fk_fact_date FOREIGN KEY (rate_date) REFERENCES dim_date(date_key),
    CONSTRAINT fk_fact_currency FOREIGN KEY (currency_code) REFERENCES dim_currency(currency_code),
    CONSTRAINT fk_fact_bank FOREIGN KEY (bank_id) REFERENCES dim_bank(bank_id)
);

INSERT INTO fact_exchange_rate (
    rate_date, currency_code, bank_id,
    cash_buy, cash_sell, transfer_buy, transfer_sell
)
SELECT
    rate_date, currency, bank_id,
    cash_buy, cash_sell, transfer_buy, transfer_sell
FROM raw_exchange_rates
WHERE currency = 'USD'
ON CONFLICT (rate_date, currency_code, bank_id) DO UPDATE SET
    cash_buy = EXCLUDED.cash_buy,
    cash_sell = EXCLUDED.cash_sell,
    transfer_buy = EXCLUDED.transfer_buy,
    transfer_sell = EXCLUDED.transfer_sell;

CREATE INDEX IF NOT EXISTS idx_fact_usd_bank_date
    ON fact_exchange_rate(bank_id, rate_date);

-- --------------------------------------------------------------------------
-- 06. QUOTE-CHANGE EVENTS, including ASSUMED initial 2024-10-01 baseline
-- --------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_bank_cash_quote_events AS
WITH valid_quotes AS (
    SELECT
        f.rate_date,
        f.currency_code,
        c.currency_name,
        f.bank_id,
        b.bank_code,
        b.bank_name,
        NULLIF(f.cash_buy, 0) AS cash_buy,
        NULLIF(f.cash_sell, 0) AS cash_sell,
        LAG(NULLIF(f.cash_buy, 0)) OVER (
            PARTITION BY f.bank_id, f.currency_code ORDER BY f.rate_date
        ) AS previous_cash_buy,
        LAG(NULLIF(f.cash_sell, 0)) OVER (
            PARTITION BY f.bank_id, f.currency_code ORDER BY f.rate_date
        ) AS previous_cash_sell
    FROM fact_exchange_rate f
    JOIN dim_bank b ON f.bank_id = b.bank_id
    JOIN dim_currency c ON f.currency_code = c.currency_code
    WHERE b.bank_code NOT IN ('NBE', 'DBE')
      AND f.currency_code = 'USD'
      AND f.cash_buy > 0 AND f.cash_sell > 0
),
changes AS (
    SELECT *,
        CASE
            WHEN rate_date = DATE '2024-10-01' THEN TRUE
            WHEN previous_cash_buy IS NULL OR previous_cash_sell IS NULL THEN FALSE
            WHEN cash_buy IS DISTINCT FROM previous_cash_buy
              OR cash_sell IS DISTINCT FROM previous_cash_sell THEN TRUE
            ELSE FALSE
        END AS is_quote_change
    FROM valid_quotes
)
SELECT
    rate_date, currency_code, currency_name,
    bank_id, bank_code, bank_name, cash_buy, cash_sell
FROM changes
WHERE is_quote_change = TRUE;

-- --------------------------------------------------------------------------
-- 07. EXPAND QUOTES TO OBSERVED DAYS DURING THEIR SEVEN-DAY VALIDITY
--     A change takes effect on its date, superseding the earlier quote.
-- --------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_usd_valid_7d_bank_quotes AS
WITH observed_dates AS (
    SELECT DISTINCT rate_date
    FROM fact_exchange_rate
    WHERE currency_code = 'USD'
),
quote_events AS (
    SELECT
        e.*,
        LEAD(e.rate_date) OVER (
            PARTITION BY e.bank_id, e.currency_code ORDER BY e.rate_date
        ) AS next_quote_date
    FROM vw_bank_cash_quote_events e
    WHERE e.currency_code = 'USD'
)
SELECT
    d.rate_date,
    e.currency_code,
    e.currency_name,
    e.bank_id,
    e.bank_code,
    e.bank_name,
    e.cash_buy,
    e.cash_sell,
    e.rate_date AS quote_date,
    (d.rate_date - e.rate_date) AS quote_age_days
FROM observed_dates d
JOIN quote_events e
  ON d.rate_date >= e.rate_date
 AND d.rate_date < e.rate_date + 7
 AND (e.next_quote_date IS NULL OR d.rate_date < e.next_quote_date);

-- --------------------------------------------------------------------------
-- 08. DAILY USD MARKET: avg of commercial-bank rates valid on observed date
--     IMPORTANT: first 9 columns preserve existing Power BI compatibility.
-- --------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_daily_usd_market AS
WITH market AS (
    SELECT
        rate_date,
        COUNT(*) AS banks_with_recent_quotes,
        ROUND(AVG(cash_buy), 4) AS avg_cash_buy,
        ROUND(AVG(cash_sell), 4) AS avg_cash_sell,
        MIN(cash_buy) AS min_cash_buy,
        MAX(cash_buy) AS max_cash_buy,
        MIN(cash_sell) AS min_cash_sell,
        MAX(cash_sell) AS max_cash_sell,
        ROUND(AVG((cash_sell - cash_buy) / NULLIF(cash_buy, 0) * 100), 2)
            AS avg_spread_pct
    FROM vw_usd_valid_7d_bank_quotes
    GROUP BY rate_date
),
daily_updates AS (
    SELECT rate_date, COUNT(*) AS updating_banks
    FROM vw_bank_cash_quote_events
    WHERE currency_code = 'USD'
    GROUP BY rate_date
)
SELECT
    m.rate_date,
    COALESCE(u.updating_banks, 0) AS updating_banks,
    m.avg_cash_buy,
    m.avg_cash_sell,
    m.min_cash_buy,
    m.max_cash_buy,
    m.min_cash_sell,
    m.max_cash_sell,
    m.avg_spread_pct,
    m.banks_with_recent_quotes
FROM market m
LEFT JOIN daily_updates u ON m.rate_date = u.rate_date;

-- --------------------------------------------------------------------------
-- 09. BANK VS SAME-DATE VALID PEERS (EXCLUDES BANK ITSELF)
--     Historical name retained for existing Power BI query compatibility.
--     Updating_banks = fresh events today, not number of valid peer quotes.
-- --------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_bank_quote_event_vs_peer AS
WITH active_quotes AS (
    SELECT
        q.*,
        COUNT(*) OVER (PARTITION BY q.rate_date) AS banks_with_recent_quotes,
        SUM(q.cash_buy) OVER (PARTITION BY q.rate_date) AS total_cash_buy,
        SUM(q.cash_sell) OVER (PARTITION BY q.rate_date) AS total_cash_sell
    FROM vw_usd_valid_7d_bank_quotes q
),
peer_comparison AS (
    SELECT *,
        (total_cash_buy - cash_buy) / NULLIF(banks_with_recent_quotes - 1, 0)
            AS peer_avg_cash_buy,
        (total_cash_sell - cash_sell) / NULLIF(banks_with_recent_quotes - 1, 0)
            AS peer_avg_cash_sell
    FROM active_quotes
),
daily_updates AS (
    SELECT rate_date, COUNT(*) AS updating_banks
    FROM vw_bank_cash_quote_events
    WHERE currency_code = 'USD'
    GROUP BY rate_date
)
SELECT
    p.rate_date,
    p.currency_code,
    p.currency_name,
    p.bank_id,
    p.bank_code,
    p.bank_name,
    p.cash_buy,
    p.cash_sell,
    COALESCE(u.updating_banks, 0) AS updating_banks,
    ROUND(p.peer_avg_cash_buy, 4) AS peer_avg_cash_buy,
    ROUND(p.peer_avg_cash_sell, 4) AS peer_avg_cash_sell,
    ROUND((p.cash_buy - p.peer_avg_cash_buy)
          / NULLIF(p.peer_avg_cash_buy, 0) * 100, 2) AS cash_buy_vs_peer_pct,
    ROUND((p.cash_sell - p.peer_avg_cash_sell)
          / NULLIF(p.peer_avg_cash_sell, 0) * 100, 2) AS cash_sell_vs_peer_pct,
    ROUND(p.cash_sell - p.cash_buy, 4) AS cash_spread,
    ROUND((p.cash_sell - p.cash_buy) / NULLIF(p.cash_buy, 0) * 100, 2)
        AS cash_spread_pct,
    p.banks_with_recent_quotes
FROM peer_comparison p
LEFT JOIN daily_updates u ON p.rate_date = u.rate_date;

-- --------------------------------------------------------------------------
-- 10. MONTHLY USD MARKET (optional SQL summary for analysis/verification)
--     Legacy column 'update_days' now counts OBSERVED dates in that month.
--     Each observed date gets equal weight in a month's average.
-- --------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_monthly_usd_market AS
SELECT
    DATE_TRUNC('month', rate_date)::date AS month_start,
    COUNT(*) AS update_days,
    ROUND(AVG(updating_banks), 1) AS avg_updating_banks,
    ROUND(AVG(avg_cash_buy), 4) AS avg_cash_buy,
    ROUND(AVG(avg_cash_sell), 4) AS avg_cash_sell,
    ROUND(AVG(min_cash_buy), 4) AS avg_daily_min_buy,
    ROUND(AVG(max_cash_buy), 4) AS avg_daily_max_buy,
    ROUND(AVG(avg_spread_pct), 2) AS avg_spread_pct
FROM vw_daily_usd_market
GROUP BY DATE_TRUNC('month', rate_date);

-- --------------------------------------------------------------------------
-- 11. BANK PERFORMANCE SUMMARY (optional; corrected daily vs event counts)
--     'comparison_updates' retained for older reports but represents daily
--     comparable quote observations (not the number of new quote events).
--     2024-10-01 baseline quotes are not counted as actual quote changes.
-- --------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_usd_bank_performance_summary AS
WITH bank_presence AS (
    SELECT
        f.bank_id,
        b.bank_code,
        b.bank_name,
        COUNT(*) FILTER (WHERE f.cash_buy > 0 AND f.cash_sell > 0)
            AS valid_quote_days
    FROM fact_exchange_rate f
    JOIN dim_bank b ON f.bank_id = b.bank_id
    WHERE f.currency_code = 'USD' AND b.bank_code NOT IN ('NBE', 'DBE')
    GROUP BY f.bank_id, b.bank_code, b.bank_name
),
event_summary AS (
    SELECT
        bank_id,
        COUNT(*) AS quote_updates,
        COUNT(*) FILTER (WHERE rate_date > DATE '2024-10-01')
            AS actual_quote_changes,
        MIN(rate_date) AS first_quote_update_date,
        MAX(rate_date) AS last_quote_update_date
    FROM vw_bank_cash_quote_events
    GROUP BY bank_id
),
comparison_summary AS (
    SELECT
        bank_id,
        COUNT(cash_buy_vs_peer_pct) AS comparison_updates,
        ROUND(AVG(cash_buy_vs_peer_pct), 2) AS avg_cash_buy_vs_peer_pct,
        ROUND(AVG(cash_sell_vs_peer_pct), 2) AS avg_cash_sell_vs_peer_pct,
        ROUND(
            COUNT(*) FILTER (WHERE cash_buy > peer_avg_cash_buy) * 100.0
            / NULLIF(COUNT(peer_avg_cash_buy), 0), 1
        ) AS buy_above_peer_pct,
        ROUND(
            COUNT(*) FILTER (WHERE cash_sell < peer_avg_cash_sell) * 100.0
            / NULLIF(COUNT(peer_avg_cash_sell), 0), 1
        ) AS sell_below_peer_pct
    FROM vw_bank_quote_event_vs_peer
    GROUP BY bank_id
),
combined AS (
    SELECT
        b.bank_id, b.bank_code, b.bank_name,
        b.valid_quote_days,
        COALESCE(e.quote_updates, 0) AS quote_updates,
        COALESCE(c.comparison_updates, 0) AS comparison_updates,
        e.first_quote_update_date,
        e.last_quote_update_date,
        ROUND(
            COALESCE(e.actual_quote_changes, 0) * 100.0
            / NULLIF(b.valid_quote_days - 1, 0), 1
        ) AS quote_change_rate_pct,
        c.avg_cash_buy_vs_peer_pct,
        c.buy_above_peer_pct,
        c.avg_cash_sell_vs_peer_pct,
        c.sell_below_peer_pct
    FROM bank_presence b
    LEFT JOIN event_summary e ON e.bank_id = b.bank_id
    LEFT JOIN comparison_summary c ON c.bank_id = b.bank_id
)
SELECT *,
    DENSE_RANK() OVER (
        ORDER BY avg_cash_buy_vs_peer_pct DESC NULLS LAST
    ) AS cash_buy_rank,
    DENSE_RANK() OVER (
        ORDER BY avg_cash_sell_vs_peer_pct ASC NULLS LAST
    ) AS cash_sell_rank
FROM combined;

-- --------------------------------------------------------------------------
-- 12. SPREAD POLICY EVENT-BASED SUMMARY (retained for legacy PBIX source)
--     Not displayed on the final two-page portfolio.
-- --------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_usd_spread_policy_summary AS
SELECT
    CASE
        WHEN rate_date < DATE '2024-10-16' THEN 'Pre 2% Spread Policy'
        ELSE 'Post 2% Spread Policy'
    END AS policy_period,
    COUNT(*) AS quote_updates,
    ROUND(AVG((cash_sell - cash_buy) / NULLIF(cash_buy, 0) * 100), 2)
        AS avg_spread_pct,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY (cash_sell - cash_buy) / NULLIF(cash_buy, 0) * 100
    )::numeric, 2) AS median_spread_pct,
    ROUND(
        COUNT(*) FILTER (
            WHERE (cash_sell - cash_buy) / NULLIF(cash_buy, 0) * 100 <= 2.01
        ) * 100.0 / NULLIF(COUNT(*), 0), 1
    ) AS pct_at_or_near_2
FROM vw_bank_cash_quote_events
GROUP BY CASE
    WHEN rate_date < DATE '2024-10-16' THEN 'Pre 2% Spread Policy'
    ELSE 'Post 2% Spread Policy'
END;

COMMIT;

-- FINAL CHECKS ARE IN: ethiopia_fx_final_validation.sql
-- Do not claim the model is independently verified until those pass in
-- PostgreSQL against the full archived CSV.