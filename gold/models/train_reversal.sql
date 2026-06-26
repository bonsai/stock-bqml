-- gold/models/train_reversal.sql
-- 逆張り戦略: RSI過剰感、極端な価格変動
CREATE OR REPLACE MODEL `{{project}}.stock_gold.reversal_model`
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
  -- RSI (過剰感)
  rsi_14,
  -- ボリンジャー乖離
  bb_pct_b, bb_bandwidth, bb_lower, bb_upper,
  -- 価格-SMA距離 (乖離の大きさ)
  close,
  sma_5, sma_20,
  close_lag_1d, close_lag_5d, close_lag_20d,
  -- 出来高急増 (逆張りの確認材料)
  volume_surge_flag, volume_vs_sma_ratio,
  -- 月末効果
  month_end_zone, quarter_end_flag,
  -- 目的変数
  next_day_return
FROM `{{project}}.stock_silver.features_daily`
WHERE date < '2024-01-01'
  AND next_day_return IS NOT NULL;
