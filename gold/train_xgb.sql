-- gold/train_xgb.sql
-- Silver 特徴量 → XGBoost 回帰モデル
-- 目的変数: next_day_return（翌日の株価変動率%）
-- 利用可能なモデルタイプ: BOOSTED_TREE_REGRESSOR (XGBoost相当)

CREATE OR REPLACE MODEL `{{project}}.stock_gold.xgb_predictor`
OPTIONS(
  MODEL_TYPE = 'BOOSTED_TREE_REGRESSOR',
  INPUT_LABEL_COLS = ['next_day_return'],
  MAX_ITERATIONS = 50,
  LEARN_RATE = 0.1,
  L1_REG = 0.1,
  L2_REG = 0.1,
  MIN_REL_PROGRESS = 0.01,
  DATA_SPLIT_METHOD = 'AUTO_SPLIT',
  EARLY_STOP = TRUE,
  ENABLE_GLOBAL_EXPLAIN = TRUE  -- グローバルな特徴量重要度を取得
) AS
SELECT
  symbol,
  open,
  high,
  low,
  close,
  volume,
  close_lag_1d,
  close_lag_5d,
  close_lag_20d,
  sma_5,
  sma_20,
  sma_60,
  std_20,
  rsi_14,
  volume_sma_5,
  volume_vs_sma_ratio,
  volume_chg_pct,
  volume_incr_streak,
  volume_surge_flag,
  next_day_return
FROM `{{project}}.stock_silver.features_daily`
WHERE date < '2024-01-01'  -- 学習期間: ここを修正
;
