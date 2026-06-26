-- gold/models/train_momentum.sql
-- モメンタム戦略: 価格ラグ、移動平均、RSI、出来高急増
CREATE OR REPLACE MODEL `{{project}}.stock_gold.momentum_model`
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
  -- 価格ラグ (モメンタム核)
  close_lag_1d, close_lag_5d, close_lag_20d,
  -- 移動平均
  sma_5, sma_20, sma_60,
  -- RSI (勢い)
  rsi_14,
  -- 出来高急増
  volume_surge_flag, volume_incr_streak, volume_vs_sma_ratio,
  -- 目的変数
  next_day_return
FROM `{{project}}.stock_silver.features_daily`
WHERE date < DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)
  AND next_day_return IS NOT NULL;
