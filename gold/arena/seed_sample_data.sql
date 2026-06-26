-- scripts/seed_sample_data.sql
-- サンプル株価データ生成 (Alpha Vantage / Yahoo Finance の代わり)
-- 日本株3銘柄 × 5年分の日次データを生成

CREATE OR REPLACE TABLE `{{project}}.stock_bronze.raw_daily` AS
WITH
-- 銘柄定義
symbols AS (
  SELECT '7203.T' AS symbol, 2500 AS base_price, 0.0008 AS daily_vol, 0.02 AS drift UNION ALL  -- トヨタ
  SELECT '6758.T', 4500, 0.0012, 0.015  -- ソニー
  UNION ALL
  SELECT '9984.T', 8000, 0.0015, 0.01   -- ソフトバンク
),
-- 日付系列: 直近5年分
dates AS (
  SELECT day FROM UNNEST(
    GENERATE_DATE_ARRAY(
      DATE_SUB(CURRENT_DATE(), INTERVAL 5 YEAR),
      CURRENT_DATE(),
      INTERVAL 1 DAY
    )
  ) AS day
  WHERE EXTRACT(DAYOFWEEK FROM day) NOT IN (1, 7)  -- 平日のみ
),
-- 幾何ブラウン運動で株価生成
price_path AS (
  SELECT
    s.symbol,
    d.day,
    s.base_price AS _base,
    s.daily_vol,
    s.drift,
    -- ランダムウォーク (決定論的なseedで再現可能)
    EXP(
      SUM(LN(1 + s.drift/252 + s.daily_vol * (
        RAND() * 2 - 1  -- -1〜1 の一様乱数 (簡易版)
      ))) OVER (PARTITION BY s.symbol ORDER BY d.day)
    ) * s.base_price AS simulated_close
  FROM symbols s
  CROSS JOIN dates d
)
SELECT
  symbol,
  day AS timestamp,
  -- OHLC: closeを中心に ±2% でopen/high/lowを生成
  ROUND(simulated_close * (1 - RAND() * 0.02), 2) AS open,
  ROUND(simulated_close * (1 + RAND() * 0.03), 2) AS high,
  ROUND(simulated_close * (1 - RAND() * 0.03), 2) AS low,
  ROUND(simulated_close, 2) AS close,
  CAST(100000 * (5000 + RAND() * 15000) AS INT64) AS volume,
  TO_JSON_STRING(STRUCT(
    'AlphaVantage' AS provider,
    CURRENT_TIMESTAMP() AS fetched_at
  )) AS _raw_json,
  CURRENT_TIMESTAMP() AS _inserted_at
FROM price_path;
