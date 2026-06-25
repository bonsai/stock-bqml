-- gold/strategies.sql
-- 投資戦略別特徴量セットとモデル定義
-- 一つのモデルですべてをやろうとせず、戦略別に特徴量を選別して学習

-- ============================================================
-- 1. モメンタム戦略 (Momentum)
-- 前提: 「上がっているものはさらに上がる」
-- 重視: 価格トレンド、出来高急増、RSI
-- ============================================================
CREATE OR REPLACE MODEL `{{project}}.stock_gold.momentum_model`
OPTIONS(
  MODEL_TYPE = 'BOOSTED_TREE_REGRESSOR',
  INPUT_LABEL_COLS = ['next_day_return'],
  MAX_ITERATIONS = 50,
  LEARN_RATE = 0.1,
  ENABLE_GLOBAL_EXPLAIN = TRUE
) AS
SELECT
  symbol,
  close,
  close_lag_1d,
  close_lag_5d,
  close_lag_20d,
  sma_5,
  sma_20,
  sma_60,
  rsi_14,
  volume_sma_5,
  volume_vs_sma_ratio,
  volume_chg_pct,
  volume_incr_streak,
  volume_surge_flag,
  next_day_return
FROM `{{project}}.stock_silver.features_daily`
WHERE date < '2024-01-01';

-- ============================================================
-- 2. ボラティリティブレイクアウト (Volatility Breakout)
-- 前提: 「静寂が破られたら大きく動く」
-- 重視: ボラティリティ収縮→拡大、出来高伴ってブレイク
-- ============================================================
CREATE OR REPLACE MODEL `{{project}}.stock_gold.breakout_model`
OPTIONS(
  MODEL_TYPE = 'BOOSTED_TREE_REGRESSOR',
  INPUT_LABEL_COLS = ['next_day_return'],
  MAX_ITERATIONS = 50,
  LEARN_RATE = 0.1,
  ENABLE_GLOBAL_EXPLAIN = TRUE
) AS
SELECT
  symbol,
  close,
  high,
  low,
  std_20,
  -- ボラティリティ収縮度 = 当日レンジ / 20日標準偏差
  SAFE_DIVIDE(high - low, std_20) AS volatility_compression,
  -- ボラティリティ拡大フラグ
  SAFE_DIVIDE(std_20, LAG(std_20) OVER (PARTITION BY symbol ORDER BY date)) >= 1.3 AS vol_expansion_flag,
  volume_vs_sma_ratio,
  volume_surge_flag,
  volume_chg_pct,
  next_day_return
FROM `{{project}}.stock_silver.features_daily`
WHERE date < '2024-01-01';

-- ============================================================
-- 3. 出来高漸増+価格追従 (Volume Confirmation)
-- 前提: 「出来高が先行して増え、その後価格が追いつく」
-- 重視: 出来高スコア、価格・出来高乖離
-- ============================================================
CREATE OR REPLACE MODEL `{{project}}.stock_gold.volume_confirm_model`
OPTIONS(
  MODEL_TYPE = 'BOOSTED_TREE_REGRESSOR',
  INPUT_LABEL_COLS = ['next_day_return'],
  MAX_ITERATIONS = 50,
  LEARN_RATE = 0.1,
  ENABLE_GLOBAL_EXPLAIN = TRUE
) AS
WITH scored AS (
  SELECT
    *,
    ROUND(GREATEST(LEAST(
      (volume_vs_sma_ratio - 1) * 20 +
      GREATEST(volume_chg_pct, 0) * 0.5 +
      volume_incr_streak * 5 +
      IF(volume_surge_flag, 30, 0),
      100
    ), 0), 2) AS volume_increase_score,
    -- 価格変化と出来高変化の乖離: 出来高が先行して上がり、価格はまだ遅れている
    SAFE_DIVIDE(volume_chg_pct, NULLIF(ABS(SAFE_DIVIDE(close - close_lag_1d, close_lag_1d) * 100), 0)) AS volume_price_divergence
  FROM `{{project}}.stock_silver.features_daily`
)
SELECT
  symbol,
  close,
  close_lag_1d,
  volume_increase_score,
  volume_vs_sma_ratio,
  volume_chg_pct,
  volume_incr_streak,
  volume_surge_flag,
  volume_price_divergence,
  next_day_return
FROM scored
WHERE date < '2024-01-01';

-- ============================================================
-- 4. リバーサル予測 (Mean Reversion)
-- 前提: 「極端な動きは戻る」
-- 重視: RSI過剰感、価格の極端な乖離
-- ============================================================
CREATE OR REPLACE MODEL `{{project}}.stock_gold.reversal_model`
OPTIONS(
  MODEL_TYPE = 'BOOSTED_TREE_REGRESSOR',
  INPUT_LABEL_COLS = ['next_day_return'],
  MAX_ITERATIONS = 50,
  LEARN_RATE = 0.1,
  ENABLE_GLOBAL_EXPLAIN = TRUE
) AS
SELECT
  symbol,
  close,
  close_lag_1d,
  close_lag_5d,
  sma_20,
  -- 価格がSMAからどれだけ離れているか
  SAFE_DIVIDE(close - sma_20, sma_20) * 100 AS price_sma_distance,
  rsi_14,
  -- RSI過買い/過売りの極端度
  ABS(rsi_14 - 50) AS rsi_extremity,
  std_20,
  next_day_return
FROM `{{project}}.stock_silver.features_daily`
WHERE date < '2024-01-01';

-- ============================================================
-- 戦略別予測スコア統合テーブル
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.strategy_scores` AS
WITH momentum_pred AS (
  SELECT date, symbol, predicted_next_day_return AS momentum_score
  FROM ML.PREDICT(MODEL `{{project}}.stock_gold.momentum_model`,
    (SELECT * EXCEPT(next_day_return) FROM `{{project}}.stock_silver.features_daily` WHERE date >= '2024-01-01'))
),
breakout_pred AS (
  SELECT date, symbol, predicted_next_day_return AS breakout_score
  FROM ML.PREDICT(MODEL `{{project}}.stock_gold.breakout_model`,
    (SELECT * EXCEPT(next_day_return) FROM `{{project}}.stock_silver.features_daily` WHERE date >= '2024-01-01'))
),
vol_confirm_pred AS (
  SELECT date, symbol, predicted_next_day_return AS volume_confirm_score
  FROM ML.PREDICT(MODEL `{{project}}.stock_gold.volume_confirm_model`,
    (SELECT * EXCEPT(next_day_return) FROM `{{project}}.stock_silver.features_daily` WHERE date >= '2024-01-01'))
),
reversal_pred AS (
  SELECT date, symbol, predicted_next_day_return AS reversal_score
  FROM ML.PREDICT(MODEL `{{project}}.stock_gold.reversal_model`,
    (SELECT * EXCEPT(next_day_return) FROM `{{project}}.stock_silver.features_daily` WHERE date >= '2024-01-01'))
)
SELECT
  m.date,
  m.symbol,
  m.momentum_score,
  b.breakout_score,
  v.volume_confirm_score,
  r.reversal_score,
  -- 戦略選択: 各モデルの予測方向と強度
  CASE
    WHEN m.momentum_score > 0 AND v.volume_confirm_score > m.momentum_score THEN 'STRONG_MOMENTUM'
    WHEN b.breakout_score > 2 AND v.volume_confirm_score > 0 THEN 'BREAKOUT_CONFIRM'
    WHEN m.momentum_score < 0 AND r.reversal_score > ABS(m.momentum_score) THEN 'REVERSAL_BUY'
    WHEN m.momentum_score > 0 AND r.reversal_score < -0.5 * m.momentum_score THEN 'REVERSAL_SELL'
    ELSE 'HOLD'
  END AS strategy_signal,
  CURRENT_TIMESTAMP() AS _updated_at
FROM momentum_pred m
LEFT JOIN breakout_pred b USING(date, symbol)
LEFT JOIN vol_confirm_pred v USING(date, symbol)
LEFT JOIN reversal_pred r USING(date, symbol);
