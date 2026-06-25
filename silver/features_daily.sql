-- silver/features_daily.sql
-- Bronze 生データ → Silver テクニカル指標付き特徴量テーブル
-- BigQuery 標準SQL

CREATE OR REPLACE TABLE `{{project}}.stock_silver.features_daily` (
  date DATE,
  symbol STRING,
  open NUMERIC,
  high NUMERIC,
  low NUMERIC,
  close NUMERIC,
  volume INT64,
  -- ラグ特徴量
  close_lag_1d NUMERIC,
  close_lag_5d NUMERIC,
  close_lag_20d NUMERIC,
  -- 移動平均
  sma_5 NUMERIC,
  sma_20 NUMERIC,
  sma_60 NUMERIC,
  -- ボラティリティ
  std_20 NUMERIC,
  -- RSI（14日）
  rsi_14 NUMERIC,
  -- 出来高移動平均
  volume_sma_5 INT64,
  -- 出来高漸増指標
  volume_vs_sma_ratio NUMERIC,  -- 当日出来高 / SMA5
  volume_lag_1d INT64,
  volume_chg_pct NUMERIC,       -- 前日比(%)
  volume_incr_streak INT64,     -- 連続増加日数
  volume_surge_flag BOOL,       -- 急増フラグ(前日比150%以上)
  -- 目的変数: 翌日リターン（%）
  next_day_return NUMERIC,
  -- その他メタ
  _extracted_at TIMESTAMP
)
PARTITION BY date
CLUSTER BY symbol;

-- データ投入（冪等実行可能）
MERGE `{{project}}.stock_silver.features_daily` T
USING (
  SELECT
    DATE(timestamp) AS date,
    symbol,
    open,
    high,
    low,
    close,
    volume,
    -- ラグ
    LAG(close) OVER (PARTITION BY symbol ORDER BY DATE(timestamp)) AS close_lag_1d,
    LAG(close, 5) OVER (PARTITION BY symbol ORDER BY DATE(timestamp)) AS close_lag_5d,
    LAG(close, 20) OVER (PARTITION BY symbol ORDER BY DATE(timestamp)) AS close_lag_20d,
    -- 移動平均
    AVG(close) OVER (PARTITION BY symbol ORDER BY DATE(timestamp) ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) AS sma_5,
    AVG(close) OVER (PARTITION BY symbol ORDER BY DATE(timestamp) ROWS BETWEEN 19 PRECEDING AND CURRENT ROW) AS sma_20,
    AVG(close) OVER (PARTITION BY symbol ORDER BY DATE(timestamp) ROWS BETWEEN 59 PRECEDING AND CURRENT ROW) AS sma_60,
    -- ボラティリティ
    STDDEV(close) OVER (PARTITION BY symbol ORDER BY DATE(timestamp) ROWS BETWEEN 19 PRECEDING AND CURRENT ROW) AS std_20,
    -- RSI 14
    SAFE_CAST(100 - (100 / (1 + (
      AVG(IF(close > close_lag_1d, close - close_lag_1d, 0)) OVER (PARTITION BY symbol ORDER BY DATE(timestamp) ROWS BETWEEN 13 PRECEDING AND CURRENT ROW) /
      NULLIF(AVG(IF(close < close_lag_1d, close_lag_1d - close, 0)) OVER (PARTITION BY symbol ORDER BY DATE(timestamp) ROWS BETWEEN 13 PRECEDING AND CURRENT ROW), 0)
    ))) AS NUMERIC) AS rsi_14,
    -- 出来高移動平均
    CAST(AVG(volume) OVER (PARTITION BY symbol ORDER BY DATE(timestamp) ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) AS INT64) AS volume_sma_5,
    -- 出来高漸増指標
    SAFE_DIVIDE(volume, CAST(AVG(volume) OVER (PARTITION BY symbol ORDER BY DATE(timestamp) ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) AS INT64)) AS volume_vs_sma_ratio,
    LAG(volume) OVER (PARTITION BY symbol ORDER BY DATE(timestamp)) AS volume_lag_1d,
    SAFE_DIVIDE(volume - LAG(volume) OVER (PARTITION BY symbol ORDER BY DATE(timestamp)), LAG(volume) OVER (PARTITION BY symbol ORDER BY DATE(timestamp))) * 100 AS volume_chg_pct,
    -- 連続増加日数: 過去20日で volume > lag(volume) が連続している日数
    ARRAY_LENGTH(
      ARRAY(
        SELECT AS STRUCT 1
        FROM UNNEST(GENERATE_ARRAY(0, 19)) AS n
        WHERE LAG(volume, n + 1) OVER (PARTITION BY symbol ORDER BY DATE(timestamp)) > IFNULL(LAG(volume, n + 2) OVER (PARTITION BY symbol ORDER BY DATE(timestamp)), -1)
        AND LAG(volume, n + 1) OVER (PARTITION BY symbol ORDER BY DATE(timestamp)) IS NOT NULL
      )
    ) AS volume_incr_streak,
    SAFE_DIVIDE(volume, LAG(volume) OVER (PARTITION BY symbol ORDER BY DATE(timestamp))) >= 1.5 AS volume_surge_flag,
    -- 目的変数（翌日の終値変化率）
    SAFE_DIVIDE(LEAD(close) OVER (PARTITION BY symbol ORDER BY DATE(timestamp)) - close, close) * 100 AS next_day_return,
    CURRENT_TIMESTAMP() AS _extracted_at
  FROM `{{project}}.stock_bronze.raw_daily`
  WHERE DATE(timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 5 YEAR)
) S
ON T.date = S.date AND T.symbol = S.symbol
WHEN NOT MATCHED THEN
  INSERT ROW;
