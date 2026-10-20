-- ============================================================================
-- READ-ONLY VALIDATION | Ethiopia USD/ETB Forex Portfolio
-- ============================================================================
-- Run this against your existing ethiopia_fx database in DBeaver.
-- Does not CREATE, DROP, INSERT, UPDATE or DELETE anything.
-- Expected values are from the actual October 2026 validation screenshots.
-- IMPORTANT: If results differ, inspect the discrepancy before publishing.
-- ============================================================================

-- A. COMPACT PASS/FAIL SUMMARY
WITH observed AS (
    SELECT DISTINCT rate_date
    FROM fact_exchange_rate
    WHERE currency_code = 'USD'
),
coverage AS (
    SELECT
        COUNT(*) AS days,
        MIN(COALESCE(m.banks_with_recent_quotes, 0)) AS min_banks,
        ROUND(AVG(COALESCE(m.banks_with_recent_quotes, 0)), 1) AS avg_banks,
        MAX(COALESCE(m.banks_with_recent_quotes, 0)) AS max_banks,
        COUNT(*) FILTER (WHERE COALESCE(m.banks_with_recent_quotes, 0) < 5)
            AS days_below_5,
        COUNT(*) FILTER (WHERE COALESCE(m.banks_with_recent_quotes, 0) < 10)
            AS days_below_10
    FROM observed d
    LEFT JOIN vw_daily_usd_market m ON d.rate_date = m.rate_date
),
checks AS (
    SELECT 'Raw archive rows' AS check_name,
           (SELECT COUNT(*) FROM raw_exchange_rates)::numeric AS actual,
           55381::numeric AS expected
    UNION ALL SELECT 'USD fact rows', COUNT(*)::numeric, 14243
        FROM fact_exchange_rate
    UNION ALL SELECT 'Date dimension days', COUNT(*)::numeric, 730
        FROM dim_date
    UNION ALL SELECT 'Bank dimension count', COUNT(*)::numeric, 30
        FROM dim_bank
    UNION ALL SELECT 'Currency dimension count', COUNT(*)::numeric, 1
        FROM dim_currency
    UNION ALL SELECT 'Distinct USD observed dates', COUNT(*)::numeric, 605
        FROM observed
    UNION ALL SELECT 'Assumed 2024-10-01 baseline bank events', COUNT(*)::numeric, 23
        FROM vw_bank_cash_quote_events WHERE rate_date = DATE '2024-10-01'
    UNION ALL SELECT '2024-10-02 bank change events', COUNT(*)::numeric, 7
        FROM vw_bank_cash_quote_events WHERE rate_date = DATE '2024-10-02'
    UNION ALL SELECT 'Total quote events (including baseline)', COUNT(*)::numeric, 6468
        FROM vw_bank_cash_quote_events
    UNION ALL SELECT 'Banks with quote events', COUNT(DISTINCT bank_id)::numeric, 28
        FROM vw_bank_cash_quote_events
    UNION ALL SELECT 'Dates with quote events', COUNT(DISTINCT rate_date)::numeric, 601
        FROM vw_bank_cash_quote_events
    UNION ALL SELECT 'Market daily rows', COUNT(*)::numeric, 605
        FROM vw_daily_usd_market
    UNION ALL SELECT 'Minimum banks in market average', min_banks::numeric, 9
        FROM coverage
    UNION ALL SELECT 'Average banks in market average', avg_banks::numeric, 20.4
        FROM coverage
    UNION ALL SELECT 'Maximum banks in market average', max_banks::numeric, 27
        FROM coverage
    UNION ALL SELECT 'Days with fewer than 5 banks', days_below_5::numeric, 0
        FROM coverage
    UNION ALL SELECT 'Days with fewer than 10 banks', days_below_10::numeric, 1
        FROM coverage
    UNION ALL SELECT '2025-05-23 actual updating banks',
        updating_banks::numeric, 1
        FROM vw_daily_usd_market WHERE rate_date = DATE '2025-05-23'
    UNION ALL SELECT '2025-05-23 banks valid under 7-day rule',
        banks_with_recent_quotes::numeric, 16
        FROM vw_daily_usd_market WHERE rate_date = DATE '2025-05-23'
    UNION ALL SELECT '2025-05-23 average USD buy', avg_cash_buy, 131.8456
        FROM vw_daily_usd_market WHERE rate_date = DATE '2025-05-23'
    UNION ALL SELECT '2025-05-23 average USD sell', avg_cash_sell, 134.4825
        FROM vw_daily_usd_market WHERE rate_date = DATE '2025-05-23'
)
SELECT
    check_name,
    actual,
    expected,
    CASE WHEN actual = expected THEN 'PASS' ELSE 'CHECK' END AS result
FROM checks
ORDER BY CASE WHEN actual = expected THEN 1 ELSE 0 END, check_name;

-- B. SEVEN-DAY VALIDITY / DISTINCT BANK-DATE / NO NON-COMMERCIAL PEERS
SELECT
    MIN(quote_age_days) AS min_age_days,
    MAX(quote_age_days) AS max_age_days,
    COUNT(*) FILTER (WHERE quote_age_days NOT BETWEEN 0 AND 6)
        AS age_violations,
    COUNT(*) - COUNT(DISTINCT (rate_date, bank_id))
        AS duplicate_bank_date_rows,
    COUNT(*) FILTER (WHERE bank_code IN ('NBE', 'DBE'))
        AS noncommercial_rows
FROM vw_usd_valid_7d_bank_quotes;
-- EXPECT: min age 0; max age 6; other three counts 0.

-- C. ORIGINAL PROBLEM-DATE, BANK COVERAGE, RATE LEVELS
SELECT rate_date, updating_banks, banks_with_recent_quotes,
       avg_cash_buy, avg_cash_sell
FROM vw_daily_usd_market
WHERE rate_date BETWEEN DATE '2025-05-20' AND DATE '2025-05-27'
ORDER BY rate_date;
-- EXPECT:
-- 2025-05-20 | 6 | 16 | 131.7857 | 134.4214
-- 2025-05-21 | 7 | 16 | 131.8224 | 134.4589
-- 2025-05-22 | 7 | 17 | 131.8401 | 134.4769
-- 2025-05-23 | 1 | 16 | 131.8456 | 134.4825
-- 2025-05-24 | 6 | 18 | 131.7116 | 134.3458
-- 2025-05-26 | 6 | 17 | 131.7184 | 134.3528
-- 2025-05-27 | 7 | 19 | 131.7827 | 134.4184

-- D. BANKS CONTRIBUTING TO THE ORIGINAL PROBLEM-DATE
SELECT bank_code, quote_date, quote_age_days, cash_buy, cash_sell
FROM vw_usd_valid_7d_bank_quotes
WHERE rate_date = DATE '2025-05-23'
ORDER BY bank_code;
-- EXPECT: 16 banks, including ORO with age=0;
-- CBE excluded (its most recent detected quote is outside 7-day window).

-- E. CROSS-CHECK PEER ANALYSIS COUNTS AGAINST DAILY MARKET COUNTS
SELECT p.rate_date,
       COUNT(*) AS bank_comparison_rows,
       MAX(p.banks_with_recent_quotes) AS peer_view_banks,
       MAX(m.banks_with_recent_quotes) AS daily_market_banks,
       COUNT(*) FILTER (WHERE p.peer_avg_cash_buy IS NULL) AS null_peer_buy
FROM vw_bank_quote_event_vs_peer p
JOIN vw_daily_usd_market m ON m.rate_date = p.rate_date
GROUP BY p.rate_date
HAVING COUNT(*) <> MAX(m.banks_with_recent_quotes)
    OR MAX(p.banks_with_recent_quotes) <> MAX(m.banks_with_recent_quotes)
    OR COUNT(*) FILTER (WHERE p.peer_avg_cash_buy IS NULL) > 0
ORDER BY p.rate_date;
-- EXPECT: 0 rows (all dates have at least nine valid banks).

-- F. FULL-PERIOD COMPETITIVENESS (compare to Power BI ALL-months chart)
SELECT bank_code, bank_name,
       COUNT(*) AS valid_bank_days,
       ROUND(AVG(cash_buy_vs_peer_pct), 2) AS avg_buy_vs_peer_pct,
       ROUND(AVG(cash_sell_vs_peer_pct), 2) AS avg_sell_vs_peer_pct
FROM vw_bank_quote_event_vs_peer
GROUP BY bank_code, bank_name
ORDER BY avg_buy_vs_peer_pct DESC;
-- EXPECT near previous dashboard screenshot: ORO about +1.65% buy;
-- CBE about -0.96% sell. This is based on rounded daily peer percentages.

-- G. MONTHLY AVERAGE MARKET RATE + MONTH-ON-MONTH ETB AND PCT MOVEMENT
WITH m AS (
    SELECT month_start, avg_cash_buy,
           LAG(avg_cash_buy) OVER (ORDER BY month_start) AS previous_avg_buy
    FROM vw_monthly_usd_market
)
SELECT month_start, avg_cash_buy, previous_avg_buy,
       ROUND(avg_cash_buy - previous_avg_buy, 2) AS monthly_change_etb,
       ROUND((avg_cash_buy - previous_avg_buy)
           / NULLIF(previous_avg_buy, 0) * 100, 2) AS monthly_change_pct
FROM m
ORDER BY month_start;
-- EXPECT October 2024 NULL changes; Power BI monthly charts should agree
-- within display rounding (e.g. Nov 2024 about +5.60 ETB / +4.82%).