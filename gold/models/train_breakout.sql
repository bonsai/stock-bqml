-- gold/models/train_breakout.sql
-- ブレイクアウト戦略: ボラティリティ収縮→拡大、高値/安値、レンジ
CREATE OR REPLACE MODEL `{{project}}.stock_gold.breakout_model`
OPTIONS(
  MODEL_TYPE = 'BOOSTED_TREE_REGRESSOR',
  INPUT_LABEL_COLS = ['next_day_return'],
  MAX_ITERATIONS = 50,
  LEARN_RATE = 0.1,
  L1_REG = 0.1,
  L2_REG = 0.1,
  MIN_REL_PROGRESS = 0.01,
  DATA_SPLIT_METHOD = 'AUTO_SPLIT',
  EARLY_STOP = TRUE
) AS
SELECT
  -- ボラティリティ
  std_20, atr_14,
  -- ボリンジャーバンド (ブレイクアウト)
  bb_bandwidth, bb_pct_b, bb_upper, bb_lower,
  -- 価格レンジ
  close_lag_1d, close_lag_5d, close_lag_20d,
  -- 高値/安値
  high, low, close,
  -- 目的変数
  next_day_return
FROM `{{project}}.stock_silver.features_daily`
WHERE date < '2024-01-01'
  AND next_day_return IS NOT NULL;
