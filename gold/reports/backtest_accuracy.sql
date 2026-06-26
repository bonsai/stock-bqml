-- gold/backtest_accuracy.sql
-- 全戦略モデルの過去バックテスト精度比較
-- 各戦略の予測 vs 実際の翌日リターンを検証し、横並びで評価する

-- ============================================================
-- 1. 予測結合テーブル: 全モデルの予測値を実際値と横並び
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.backtest_results` AS
WITH actuals AS (
  SELECT date, symbol, next_day_return
  FROM `{{project}}.stock_silver.features_daily`
  WHERE date >= DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY) AND next_day_return IS NOT NULL
),
momentum_pred AS (
  SELECT date, symbol, predicted_next_day_return AS momentum_pred
  FROM ML.PREDICT(MODEL `{{project}}.stock_gold.momentum_model`,
    (SELECT * EXCEPT(next_day_return) FROM `{{project}}.stock_silver.features_daily` WHERE date >= DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)))
),
breakout_pred AS (
  SELECT date, symbol, predicted_next_day_return AS breakout_pred
  FROM ML.PREDICT(MODEL `{{project}}.stock_gold.breakout_model`,
    (SELECT * EXCEPT(next_day_return) FROM `{{project}}.stock_silver.features_daily` WHERE date >= DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)))
),
vol_confirm_pred AS (
  SELECT date, symbol, predicted_next_day_return AS volume_confirm_pred
  FROM ML.PREDICT(MODEL `{{project}}.stock_gold.volume_confirm_model`,
    (SELECT * EXCEPT(next_day_return) FROM `{{project}}.stock_silver.features_daily` WHERE date >= DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)))
),
reversal_pred AS (
  SELECT date, symbol, predicted_next_day_return AS reversal_pred
  FROM ML.PREDICT(MODEL `{{project}}.stock_gold.reversal_model`,
    (SELECT * EXCEPT(next_day_return) FROM `{{project}}.stock_silver.features_daily` WHERE date >= DATE_SUB(CURRENT_DATE(), INTERVAL 180 DAY)))
)
SELECT
  a.date,
  a.symbol,
  a.next_day_return AS actual_return,
  m.momentum_pred,
  b.breakout_pred,
  v.volume_confirm_pred,
  r.reversal_pred,
  -- 方向一致フラグ (各モデル)
  SIGN(m.momentum_pred) = SIGN(a.next_day_return) AS momentum_dir_correct,
  SIGN(b.breakout_pred) = SIGN(a.next_day_return) AS breakout_dir_correct,
  SIGN(v.volume_confirm_pred) = SIGN(a.next_day_return) AS volume_confirm_dir_correct,
  SIGN(r.reversal_pred) = SIGN(a.next_day_return) AS reversal_dir_correct,
  -- 戦略合成シグナル（strategy_scores と同じロジック）
  CASE
    WHEN m.momentum_pred > 0 AND v.volume_confirm_pred > m.momentum_pred THEN 'STRONG_MOMENTUM'
    WHEN b.breakout_pred > 2 AND v.volume_confirm_pred > 0 THEN 'BREAKOUT_CONFIRM'
    WHEN m.momentum_pred < 0 AND r.reversal_pred > ABS(m.momentum_pred) THEN 'REVERSAL_BUY'
    WHEN m.momentum_pred > 0 AND r.reversal_pred < -0.5 * m.momentum_pred THEN 'REVERSAL_SELL'
    ELSE 'HOLD'
  END AS signal
FROM actuals a
LEFT JOIN momentum_pred m USING(date, symbol)
LEFT JOIN breakout_pred b USING(date, symbol)
LEFT JOIN vol_confirm_pred v USING(date, symbol)
LEFT JOIN reversal_pred r USING(date, symbol)
ORDER BY a.date, a.symbol;

-- ============================================================
-- 2. モデル別精度サマリー
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.backtest_model_summary` AS
WITH stats AS (
  SELECT
    -- モメンタム
    COUNT(*) AS total_days,
    ROUND(AVG(actual_return), 4) AS avg_actual_return,
    -- MAE
    ROUND(AVG(ABS(momentum_pred - actual_return)), 4) AS momentum_mae,
    ROUND(AVG(ABS(breakout_pred - actual_return)), 4) AS breakout_mae,
    ROUND(AVG(ABS(volume_confirm_pred - actual_return)), 4) AS volume_confirm_mae,
    ROUND(AVG(ABS(reversal_pred - actual_return)), 4) AS reversal_mae,
    -- RMSE
    ROUND(SQRT(AVG(POW(momentum_pred - actual_return, 2))), 4) AS momentum_rmse,
    ROUND(SQRT(AVG(POW(breakout_pred - actual_return, 2))), 4) AS breakout_rmse,
    ROUND(SQRT(AVG(POW(volume_confirm_pred - actual_return, 2))), 4) AS volume_confirm_rmse,
    ROUND(SQRT(AVG(POW(reversal_pred - actual_return, 2))), 4) AS reversal_rmse,
    -- 方向一致率
    ROUND(AVG(IF(SIGN(momentum_pred) = SIGN(actual_return), 1, 0)), 4) AS momentum_dir_accuracy,
    ROUND(AVG(IF(SIGN(breakout_pred) = SIGN(actual_return), 1, 0)), 4) AS breakout_dir_accuracy,
    ROUND(AVG(IF(SIGN(volume_confirm_pred) = SIGN(actual_return), 1, 0)), 4) AS volume_confirm_dir_accuracy,
    ROUND(AVG(IF(SIGN(reversal_pred) = SIGN(actual_return), 1, 0)), 4) AS reversal_dir_accuracy,
    -- 的中した日の平均リターン（方向一致＝売買した場合の平均リターン）
    ROUND(AVG(IF(SIGN(momentum_pred) = SIGN(actual_return), actual_return, 0)), 4) AS momentum_avg_return_when_correct,
    ROUND(AVG(IF(SIGN(breakout_pred) = SIGN(actual_return), actual_return, 0)), 4) AS breakout_avg_return_when_correct,
    ROUND(AVG(IF(SIGN(volume_confirm_pred) = SIGN(actual_return), actual_return, 0)), 4) AS volume_confirm_avg_return_when_correct,
    ROUND(AVG(IF(SIGN(reversal_pred) = SIGN(actual_return), actual_return, 0)), 4) AS reversal_avg_return_when_correct
  FROM `{{project}}.stock_gold.backtest_results`
)
SELECT
  total_days,
  avg_actual_return,
  -- MAE
  momentum_mae, breakout_mae, volume_confirm_mae, reversal_mae,
  -- RMSE
  momentum_rmse, breakout_rmse, volume_confirm_rmse, reversal_rmse,
  -- 方向一致率
  momentum_dir_accuracy, breakout_dir_accuracy,
  volume_confirm_dir_accuracy, reversal_dir_accuracy,
  -- 的中平均リターン
  momentum_avg_return_when_correct, breakout_avg_return_when_correct,
  volume_confirm_avg_return_when_correct, reversal_avg_return_when_correct
FROM stats;

-- ============================================================
-- 3. 戦略シグナル別パフォーマンス
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.backtest_signal_performance` AS
WITH signal_stats AS (
  SELECT
    signal,
    COUNT(*) AS signal_count,
    ROUND(AVG(actual_return), 4) AS avg_return,
    ROUND(AVG(ABS(actual_return)), 4) AS avg_abs_return,
    -- 勝率（正のリターンが出た割合）
    ROUND(AVG(IF(actual_return > 0, 1, 0)), 4) AS win_rate,
    -- 平均勝ち幅 / 負け幅
    ROUND(AVG(IF(actual_return > 0, actual_return, NULL)), 4) AS avg_win,
    ROUND(AVG(IF(actual_return < 0, actual_return, NULL)), 4) AS avg_loss,
    -- 最大ドローダウン（累積リターンの最大下落）
    ROUND(MIN(actual_return), 4) AS max_loss_single,
    ROUND(MAX(actual_return), 4) AS max_gain_single,
    -- Sharpe比（日次、年換算用に×√252）
    ROUND(
      CASE WHEN STDDEV(actual_return) = 0
        THEN 0
        ELSE AVG(actual_return) / STDDEV(actual_return) * SQRT(252)
      END, 4
    ) AS sharpe_ratio_annualized
  FROM `{{project}}.stock_gold.backtest_results`
  GROUP BY signal
)
SELECT
  signal,
  signal_count,
  avg_return,
  avg_abs_return,
  win_rate,
  avg_win,
  avg_loss,
  max_loss_single,
  max_gain_single,
  sharpe_ratio_annualized
FROM signal_stats
ORDER BY
  CASE signal
    WHEN 'STRONG_MOMENTUM' THEN 1
    WHEN 'BREAKOUT_CONFIRM' THEN 2
    WHEN 'REVERSAL_BUY' THEN 3
    WHEN 'REVERSAL_SELL' THEN 4
    WHEN 'HOLD' THEN 5
  END;

-- ============================================================
-- 4. 累積リターン曲線（可視化用）
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.backtest_cumulative_returns` AS
WITH daily_pnl AS (
  SELECT
    date,
    -- 各モデルの戦略に従った場合の日次リターン
    -- 方向一致 = 買い or 売り = 絶対値リターン
    actual_return AS raw_return,
    IF(SIGN(momentum_pred) = SIGN(actual_return), ABS(actual_return), -ABS(actual_return)) AS momentum_pnl,
    IF(SIGN(breakout_pred) = SIGN(actual_return), ABS(actual_return), -ABS(actual_return)) AS breakout_pnl,
    IF(SIGN(volume_confirm_pred) = SIGN(actual_return), ABS(actual_return), -ABS(actual_return)) AS volume_confirm_pnl,
    IF(SIGN(reversal_pred) = SIGN(actual_return), ABS(actual_return), -ABS(actual_return)) AS reversal_pnl,
    -- 合成シグナルによるP&L（HOLDは0）
    CASE
      WHEN signal = 'HOLD' THEN 0
      WHEN signal IN ('STRONG_MOMENTUM', 'BREAKOUT_CONFIRM', 'REVERSAL_BUY') THEN
        IF(actual_return > 0, actual_return, -ABS(actual_return))
      WHEN signal = 'REVERSAL_SELL' THEN
        IF(actual_return < 0, ABS(actual_return), -actual_return)
      ELSE 0
    END AS signal_pnl
  FROM `{{project}}.stock_gold.backtest_results`
)
SELECT
  date,
  raw_return,
  momentum_pnl, breakout_pnl, volume_confirm_pnl, reversal_pnl, signal_pnl,
  -- 累積（指数関数的に複利計算: 1+r の累積積）
  SUM(raw_return) OVER (ORDER BY date) / 100 + 1 AS raw_cumul,
  SUM(momentum_pnl) OVER (ORDER BY date) / 100 + 1 AS momentum_cumul,
  SUM(breakout_pnl) OVER (ORDER BY date) / 100 + 1 AS breakout_cumul,
  SUM(volume_confirm_pnl) OVER (ORDER BY date) / 100 + 1 AS volume_confirm_cumul,
  SUM(reversal_pnl) OVER (ORDER BY date) / 100 + 1 AS reversal_cumul,
  SUM(signal_pnl) OVER (ORDER BY date) / 100 + 1 AS signal_cumul
FROM daily_pnl
ORDER BY date;

-- ============================================================
-- 5. レポート用クエリ: 横並び比較
-- ============================================================
-- 実行例:
-- SELECT * FROM `{{project}}.stock_gold.backtest_model_summary`;
-- SELECT * FROM `{{project}}.stock_gold.backtest_signal_performance`;
-- SELECT * FROM `{{project}}.stock_gold.backtest_cumulative_returns`
-- ORDER BY date DESC LIMIT 10;
