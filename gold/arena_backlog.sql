-- gold/arena_backlog.sql
-- ============================================================
-- バックログ: トレード履歴管理
-- 各戦略のエントリー・決済・損益を記録
-- ============================================================

-- ============================================================
-- 1. トレードログテーブル
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.ga_trade_log` (
  trade_id INT64,           -- 一意ID
  entry_date DATE,          -- エントリー日
  gene_id INT64,            -- 戦略個体ID
  strategy_name STRING,     -- 戦略名
  generation INT64,         -- 世代
  symbol STRING,            -- 銘柄
  signal_type STRING,       -- 'LONG' / 'SHORT'
  entry_signal FLOAT64,     -- エントリー時のシグナル強度
  entry_close NUMERIC,      -- エントリー日の終値
  exit_date DATE,           -- 決済日
  exit_close NUMERIC,       -- 決済日の終値
  pnl NUMERIC,              -- 損益(%)
  exit_reason STRING,       -- 'SIGNAL_REVERSAL', 'WEEK_END', 'STOP_LOSS'
  week_start DATE,          -- 所属週
  created_at TIMESTAMP
);

-- ============================================================
-- 2. 日次バックログ生成（スクリーニング済みシグナル → トレード）
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.ga_daily_backlog` AS
WITH
-- 当日（エントリー日）の価格
entry AS (
  SELECT
    s.date,
    s.gene_id,
    s.strategy_name,
    s.generation,
    s.symbol,
    s.final_signal,
    f.close AS entry_close,
    DATE_TRUNC(s.date, WEEK(SUNDAY)) AS week_start
  FROM `{{project}}.stock_gold.ga_screened_signals` s
  JOIN `{{project}}.stock_silver.features_daily` f
    ON s.date = f.date AND s.symbol = f.symbol
  WHERE f.next_day_return IS NOT NULL
),
-- 翌日（決済日）の価格
exit_prices AS (
  SELECT
    DATE_ADD(f.date, INTERVAL 1 DAY) AS entry_date,
    f.date AS exit_date,
    f.symbol,
    f.close AS exit_close
  FROM `{{project}}.stock_silver.features_daily` f
)
SELECT
  ROW_NUMBER() OVER (ORDER BY e.date, e.gene_id, e.symbol) AS trade_id,
  e.date AS entry_date,
  e.gene_id,
  e.strategy_name,
  e.generation,
  e.symbol,
  CASE WHEN e.final_signal > 0 THEN 'LONG' ELSE 'SHORT' END AS signal_type,
  e.final_signal AS entry_signal,
  e.entry_close,
  x.exit_date,
  x.exit_close,
  -- P&L: LONG = (exit - entry)/entry, SHORT = (entry - exit)/entry
  CASE
    WHEN e.final_signal > 0
      THEN SAFE_DIVIDE(x.exit_close - e.entry_close, e.entry_close) * 100
    ELSE SAFE_DIVIDE(e.entry_close - x.exit_close, e.entry_close) * 100
  END AS pnl,
  -- 出口理由: シグナル反転 or 週末クローズ
  'WEEK_END' AS exit_reason,
  e.week_start,
  CURRENT_TIMESTAMP() AS created_at
FROM entry e
LEFT JOIN exit_prices x
  ON e.date = x.entry_date AND e.symbol = x.symbol;

-- ============================================================
-- 3. 週次サマリー: 個体別週次成績（バックログベース）
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.ga_weekly_pnl` AS
SELECT
  gene_id,
  strategy_name,
  generation,
  week_start,
  COUNT(*) AS n_trades,
  COUNT(DISTINCT symbol) AS n_symbols,
  ROUND(AVG(pnl), 4) AS avg_pnl,
  ROUND(STDDEV(pnl), 4) AS std_pnl,
  ROUND(SUM(pnl), 4) AS total_pnl,
  ROUND(AVG(IF(pnl > 0, 1, 0)), 4) AS win_rate,
  ROUND(MIN(pnl), 4) AS max_loss,
  ROUND(MAX(pnl), 4) AS max_gain,
  ROUND(AVG(pnl) / NULLIF(STDDEV(pnl), 0) * SQRT(252), 2) AS sharpe_approx
FROM `{{project}}.stock_gold.ga_daily_backlog`
GROUP BY gene_id, strategy_name, generation, week_start;

-- ============================================================
-- 4. 個体別生存スコア（直近4週の加重平均）
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.ga_survival_scores` AS
SELECT
  gene_id,
  strategy_name,
  generation,
  week_start,
  total_pnl,
  win_rate,
  n_trades,
  -- 直近4週の加重P&L (最新ほど重い)
  AVG(total_pnl) OVER (
    PARTITION BY gene_id
    ORDER BY week_start
    ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
  ) AS rolling_4w_pnl
FROM `{{project}}.stock_gold.ga_weekly_pnl`;
