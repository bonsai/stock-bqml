-- gold/models/train_volume_confirm.sql
-- 出来高確認戦略: 出来高先行、価格追従
CREATE OR REPLACE MODEL `{{project}}.stock_gold.volume_confirm_model`
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
  -- 出来高系
  volume, volume_sma_5,
  volume_vs_sma_ratio, volume_chg_pct,
  volume_incr_streak, volume_surge_flag,
  -- 価格・出来高乖離 (量が価格に先行するか)
  close_lag_1d, sma_5, sma_20,
  -- 目的変数
  next_day_return
FROM `{{project}}.stock_silver.features_daily`
WHERE date < '2024-01-01'
  AND next_day_return IS NOT NULL;
