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
  -- MACD（SMA近似）
  macd_line NUMERIC,            -- MACD線 = SMA12 - SMA26
  macd_signal NUMERIC,          -- シグナル線 = MACDの9日SMA
  macd_histogram NUMERIC,       -- ヒストグラム = macd_line - macd_signal
  -- ボリンジャーバンド
  bb_upper NUMERIC,             -- 上部 = sma_20 + 2*std_20
  bb_lower NUMERIC,             -- 下部 = sma_20 - 2*std_20
  bb_pct_b NUMERIC,             -- %B = (close - bb_lower) / (bb_upper - bb_lower)
  bb_bandwidth NUMERIC,         -- バンド幅 = (bb_upper - bb_lower) / sma_20
  -- ATR（Average True Range, 14日）
  atr_14 NUMERIC,               -- 14日平均True Range
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
  WITH base AS (
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
      -- 連続増加日数
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
  ),
  sma_feat AS (
    SELECT
      *,
      -- SMA12 / SMA26（MACD用）
      AVG(close) OVER (PARTITION BY symbol ORDER BY date ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) AS sma_12,
      AVG(close) OVER (PARTITION BY symbol ORDER BY date ROWS BETWEEN 25 PRECEDING AND CURRENT ROW) AS sma_26
    FROM base
  ),
  macd_feat AS (
    SELECT
      *,
      sma_12 - sma_26 AS macd_line,
      AVG(sma_12) OVER (PARTITION BY symbol ORDER BY date ROWS BETWEEN 8 PRECEDING AND CURRENT ROW) AS sma_12_sma_9,
      AVG(sma_26) OVER (PARTITION BY symbol ORDER BY date ROWS BETWEEN 8 PRECEDING AND CURRENT ROW) AS sma_26_sma_9
    FROM sma_feat
  )
  SELECT
    date, symbol, open, high, low, close, volume,
    close_lag_1d, close_lag_5d, close_lag_20d,
    sma_5, sma_20, sma_60,
    std_20,
    rsi_14,
    volume_sma_5,
    volume_vs_sma_ratio, volume_lag_1d, volume_chg_pct, volume_incr_streak, volume_surge_flag,
    -- MACD
    macd_line,
    sma_12_sma_9 - sma_26_sma_9 AS macd_signal,
    macd_line - (sma_12_sma_9 - sma_26_sma_9) AS macd_histogram,
    -- ボリンジャーバンド
    sma_20 + 2 * std_20 AS bb_upper,
    sma_20 - 2 * std_20 AS bb_lower,
    SAFE_DIVIDE(close - (sma_20 - 2 * std_20), 4 * std_20) AS bb_pct_b,
    SAFE_DIVIDE(4 * std_20, sma_20) AS bb_bandwidth,
    -- ATR（14日）
    AVG(GREATEST(
      high - low,
      ABS(high - close_lag_1d),
      ABS(low - close_lag_1d)
    )) OVER (PARTITION BY symbol ORDER BY date ROWS BETWEEN 13 PRECEDING AND CURRENT ROW) AS atr_14,
    -- 目的変数
    next_day_return,
    _extracted_at
  FROM macd_feat
) S
ON T.date = S.date AND T.symbol = S.symbol
WHEN NOT MATCHED THEN
  INSERT ROW;
