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
  -- 月末・四半期末
  _days_to_month_end INT64,     -- 月末までの残日数
  month_end_zone STRING,        -- 'month_end'(3日以内), 'last_week'(4-7日), 'other'
  quarter_end_flag BOOL,        -- 四半期末3営業日以内
  -- 目的変数: 翌日リターン（%）
  next_day_return NUMERIC,
  -- その他メタ
  day_of_week INT64,             -- 曜日 (1=日, 2=月, ..., 7=土)
  month_of_year INT64,           -- 月 (1-12)
  _extracted_at TIMESTAMP
)
PARTITION BY date
CLUSTER BY symbol;

-- データ投入（冪等実行可能）
MERGE `{{project}}.stock_silver.features_daily` T
USING (
  WITH raw_base AS (
    SELECT
      DATE(timestamp) AS date,
      symbol,
      CAST(open AS NUMERIC) AS open,
      CAST(high AS NUMERIC) AS high,
      CAST(low AS NUMERIC) AS low,
      CAST(close AS NUMERIC) AS close,
      volume,
      LAG(CAST(close AS NUMERIC)) OVER (PARTITION BY symbol ORDER BY DATE(timestamp)) AS close_lag_1d,
      LAG(CAST(close AS NUMERIC), 5) OVER (PARTITION BY symbol ORDER BY DATE(timestamp)) AS close_lag_5d,
      LAG(CAST(close AS NUMERIC), 20) OVER (PARTITION BY symbol ORDER BY DATE(timestamp)) AS close_lag_20d,
      AVG(CAST(close AS NUMERIC)) OVER (PARTITION BY symbol ORDER BY DATE(timestamp) ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) AS sma_5,
      AVG(CAST(close AS NUMERIC)) OVER (PARTITION BY symbol ORDER BY DATE(timestamp) ROWS BETWEEN 19 PRECEDING AND CURRENT ROW) AS sma_20,
      AVG(CAST(close AS NUMERIC)) OVER (PARTITION BY symbol ORDER BY DATE(timestamp) ROWS BETWEEN 59 PRECEDING AND CURRENT ROW) AS sma_60,
      STDDEV(CAST(close AS NUMERIC)) OVER (PARTITION BY symbol ORDER BY DATE(timestamp) ROWS BETWEEN 19 PRECEDING AND CURRENT ROW) AS std_20,
      CAST(AVG(volume) OVER (PARTITION BY symbol ORDER BY DATE(timestamp) ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) AS INT64) AS volume_sma_5,
      SAFE_DIVIDE(CAST(volume AS NUMERIC), AVG(volume) OVER (PARTITION BY symbol ORDER BY DATE(timestamp) ROWS BETWEEN 4 PRECEDING AND CURRENT ROW)) AS volume_vs_sma_ratio,
      CAST(LAG(volume) OVER (PARTITION BY symbol ORDER BY DATE(timestamp)) AS INT64) AS volume_lag_1d,
      SAFE_DIVIDE(volume - LAG(volume) OVER (PARTITION BY symbol ORDER BY DATE(timestamp)), LAG(volume) OVER (PARTITION BY symbol ORDER BY DATE(timestamp))) * 100 AS volume_chg_pct,
      SAFE_DIVIDE(volume, LAG(volume) OVER (PARTITION BY symbol ORDER BY DATE(timestamp))) >= 1.5 AS volume_surge_flag,
      SAFE_DIVIDE(LEAD(close) OVER (PARTITION BY symbol ORDER BY DATE(timestamp)) - close, close) * 100 AS next_day_return,
      CURRENT_TIMESTAMP() AS _extracted_at
    FROM `{{project}}.stock_bronze.raw_daily`
    WHERE DATE(timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 5 YEAR)
  ),
  base AS (
    SELECT
      *,
      -- RSI 14 (close_lag_1dはraw_baseで計算済み)
      SAFE_CAST(100 - (100 / (1 + (
        AVG(IF(close > close_lag_1d, close - close_lag_1d, 0)) OVER (PARTITION BY symbol ORDER BY date ROWS BETWEEN 13 PRECEDING AND CURRENT ROW) /
        NULLIF(AVG(IF(close < close_lag_1d, close_lag_1d - close, 0)) OVER (PARTITION BY symbol ORDER BY date ROWS BETWEEN 13 PRECEDING AND CURRENT ROW), 0)
      ))) AS NUMERIC) AS rsi_14,
      -- 出来高増加フラグ
      IF(volume > LAG(volume) OVER (PARTITION BY symbol ORDER BY date), 1, 0) AS _vol_increase,
    FROM raw_base
  ),
  streak_grp_feat AS (
    SELECT
      * EXCEPT (_vol_increase),
      _vol_increase,
      SUM(1 - _vol_increase) OVER (PARTITION BY symbol ORDER BY date) AS _streak_grp
    FROM base
  ),
  streak_feat AS (
    SELECT
      * EXCEPT (_vol_increase, _streak_grp),
      ROW_NUMBER() OVER (PARTITION BY symbol, _streak_grp ORDER BY date) - 1 AS volume_incr_streak
    FROM streak_grp_feat
  ),
  sma_feat AS (
    SELECT
      *,
      -- SMA12 / SMA26（MACD用）
      AVG(close) OVER (PARTITION BY symbol ORDER BY date ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) AS sma_12,
      AVG(close) OVER (PARTITION BY symbol ORDER BY date ROWS BETWEEN 25 PRECEDING AND CURRENT ROW) AS sma_26
    FROM streak_feat
  ),
  macd_feat AS (
    SELECT
      *,
      sma_12 - sma_26 AS macd_line,
      AVG(sma_12) OVER (PARTITION BY symbol ORDER BY date ROWS BETWEEN 8 PRECEDING AND CURRENT ROW) AS sma_12_sma_9,
      AVG(sma_26) OVER (PARTITION BY symbol ORDER BY date ROWS BETWEEN 8 PRECEDING AND CURRENT ROW) AS sma_26_sma_9
    FROM sma_feat
  ),
  derived_feat AS (
    SELECT
      *,
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
      -- 月末・四半期末
      DATE_DIFF(LAST_DAY(date), date, DAY) AS _days_to_month_end,
      CASE
        WHEN DATE_DIFF(LAST_DAY(date), date, DAY) <= 2 THEN 'month_end'
        WHEN DATE_DIFF(LAST_DAY(date), date, DAY) <= 7 THEN 'last_week'
        ELSE 'other'
      END AS month_end_zone,
      EXTRACT(MONTH FROM date) IN (3,6,9,12)
        AND DATE_DIFF(LAST_DAY(date), date, DAY) <= 2 AS quarter_end_flag
    FROM macd_feat
  )
  SELECT
    date, symbol,
    CAST(open AS NUMERIC) AS open,
    CAST(high AS NUMERIC) AS high,
    CAST(low AS NUMERIC) AS low,
    CAST(close AS NUMERIC) AS close,
    CAST(volume AS INT64) AS volume,
    CAST(close_lag_1d AS NUMERIC) AS close_lag_1d,
    CAST(close_lag_5d AS NUMERIC) AS close_lag_5d,
    CAST(close_lag_20d AS NUMERIC) AS close_lag_20d,
    CAST(sma_5 AS NUMERIC) AS sma_5,
    CAST(sma_20 AS NUMERIC) AS sma_20,
    CAST(sma_60 AS NUMERIC) AS sma_60,
    CAST(std_20 AS NUMERIC) AS std_20,
    CAST(rsi_14 AS NUMERIC) AS rsi_14,
    CAST(volume_sma_5 AS INT64) AS volume_sma_5,
    CAST(volume_vs_sma_ratio AS NUMERIC) AS volume_vs_sma_ratio,
    CAST(volume_lag_1d AS INT64) AS volume_lag_1d,
    CAST(volume_chg_pct AS NUMERIC) AS volume_chg_pct,
    CAST(volume_incr_streak AS INT64) AS volume_incr_streak,
    volume_surge_flag,
    CAST(macd_line AS NUMERIC) AS macd_line,
    CAST(macd_signal AS NUMERIC) AS macd_signal,
    CAST(macd_histogram AS NUMERIC) AS macd_histogram,
    CAST(bb_upper AS NUMERIC) AS bb_upper,
    CAST(bb_lower AS NUMERIC) AS bb_lower,
    CAST(bb_pct_b AS NUMERIC) AS bb_pct_b,
    CAST(bb_bandwidth AS NUMERIC) AS bb_bandwidth,
    CAST(atr_14 AS NUMERIC) AS atr_14,
    _days_to_month_end,
    month_end_zone,
    quarter_end_flag,
    EXTRACT(DAYOFWEEK FROM date) AS day_of_week,
    EXTRACT(MONTH FROM date) AS month_of_year,
    CAST(next_day_return AS NUMERIC) AS next_day_return,
    _extracted_at
  FROM derived_feat
) S
ON T.date = S.date AND T.symbol = S.symbol
WHEN NOT MATCHED THEN
  INSERT ROW;
