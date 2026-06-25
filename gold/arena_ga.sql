-- gold/arena_ga.sql
-- ============================================================
-- Genetic Algorithm 戦略進化アリーナ
-- 遺伝子=特徴量重みベクトル。週次で適応度順に淘汰・交叉・突然変異
-- Colab arena_ga_evolution.ipynb と連携
-- ============================================================

-- ============================================================
-- 1. 遺伝子プール: 戦略 = 特徴量重みベクトル
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.ga_gene_pool` (
  gene_id INT64,                -- 個体ID
  generation INT64,             -- 世代数
  parent_a INT64,               -- 親A
  parent_b INT64,               -- 親B
  strategy_name STRING,         -- 名前

  -- === 遺伝子: 8つの特徴量重み (0.0〜1.0) ===
  w_momentum FLOAT64,
  w_volume FLOAT64,
  w_reversal FLOAT64,
  w_breakout FLOAT64,
  w_dow FLOAT64,
  w_monthend FLOAT64,
  w_sentiment FLOAT64,
  w_mean_rev FLOAT64,

  -- === 制御パラメータ ===
  threshold FLOAT64,            -- シグナル発動閾値 (0.1〜2.0)
  max_positions INT64,          -- 最大同時保有銘柄数 (1〜3)
  stop_loss FLOAT64,            -- ストップロス (%)  (0.5〜10.0)
  take_profit FLOAT64,          -- 利確 (%)         (1.0〜15.0)
  max_hold_days INT64,          -- 最大保有日数     (1〜21)

  -- === メタ ===
  fitness FLOAT64,
  n_trades INT64,
  win_rate FLOAT64,
  weekly_pnl FLOAT64,
  created_at TIMESTAMP
);

-- 初期世代: 10個体をランダム生成
INSERT INTO `{{project}}.stock_gold.ga_gene_pool`
SELECT
  gene_id,
  1 AS generation,
  NULL AS parent_a,
  NULL AS parent_b,
  CONCAT('GA_v1_', CAST(gene_id AS STRING)) AS strategy_name,
  RAND() AS w_momentum,
  RAND() AS w_volume,
  RAND() * 0.8 AS w_reversal,      -- 抑制
  RAND() * 0.7 AS w_breakout,
  RAND() * 0.4 AS w_dow,
  RAND() * 0.4 AS w_monthend,
  RAND() * 0.6 AS w_sentiment,
  RAND() * 0.5 AS w_mean_rev,
  0.2 + RAND() * 0.8 AS threshold,
  CAST(1 + RAND() * 2 AS INT64) AS max_positions,
  2 + RAND() * 5 AS stop_loss,
  3 + RAND() * 7 AS take_profit,
  CAST(3 + RAND() * 12 AS INT64) AS max_hold_days,
  NULL AS fitness,
  0 AS n_trades,
  NULL AS win_rate,
  NULL AS weekly_pnl,
  CURRENT_TIMESTAMP() AS created_at
FROM UNNEST(GENERATE_ARRAY(1, 10)) AS gene_id;

-- ============================================================
-- 2. 週タイプ分類器（帰納的: 過去のデータから週の特徴を抽出）
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.ga_week_types` AS
WITH weekly_stats AS (
  SELECT
    DATE_TRUNC(date, WEEK(SUNDAY)) AS week_start,
    AVG(std_20) AS avg_volatility,
    AVG(ABS(macd_histogram)) AS avg_trend_strength,
    AVG(volume_vs_sma_ratio) AS avg_volume_ratio,
    APPROX_TOP_COUNT(month_end_zone, 1)[OFFSET(0)].value AS dominant_zone,
    AVG(IF(rsi_14 < 30 OR rsi_14 > 70, 1, 0)) AS reversal_opportunity,
    AVG(next_day_return) AS market_return,
    CAST(NULL AS INT64) AS week_cluster
  FROM `{{project}}.stock_silver.features_daily`
  WHERE next_day_return IS NOT NULL
  GROUP BY week_start
)
SELECT
  *,
  CASE
    WHEN avg_volatility > (SELECT AVG(avg_volatility) + STDDEV(avg_volatility) FROM weekly_stats)
      THEN 'HIGH_VOL'
    WHEN avg_volatility < (SELECT AVG(avg_volatility) - STDDEV(avg_volatility) FROM weekly_stats)
      THEN 'LOW_VOL'
    ELSE 'MID_VOL'
  END AS vol_regime,
  CASE
    WHEN avg_trend_strength > (SELECT AVG(avg_trend_strength) FROM weekly_stats)
      THEN 'TRENDING'
    ELSE 'RANGING'
  END AS market_regime
FROM weekly_stats;

-- ============================================================
-- 3. シグナル合成: 遺伝子×特徴量 → 日次シグナル
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.ga_signals` AS
WITH feature_signals AS (
  SELECT
    f.date, f.symbol,
    LEAST(1, GREATEST(-1, macd_histogram * 10)) AS s_momentum,
    LEAST(1, GREATEST(-1, (volume_vs_sma_ratio - 1) * 3)) AS s_volume,
    LEAST(1, GREATEST(-1, (50 - rsi_14) / 20)) AS s_reversal,
    LEAST(0.5, GREATEST(-0.5,
      (bb_bandwidth - AVG(bb_bandwidth) OVER (PARTITION BY f.symbol ORDER BY f.date ROWS BETWEEN 19 PRECEDING AND CURRENT ROW))
      / NULLIF(STDDEV(bb_bandwidth) OVER (PARTITION BY f.symbol ORDER BY f.date ROWS BETWEEN 19 PRECEDING AND CURRENT ROW), 0)
    )) AS s_breakout,
    COALESCE(ds.dow_signal, 0) AS s_dow,
    COALESCE(ms.month_end_signal, 0) AS s_monthend,
    COALESCE(ss.sentiment_signal, 0) AS s_sentiment,
    COALESCE(mr.mean_rev_signal, 0) AS s_mean_rev,
    f.next_day_return
  FROM `{{project}}.stock_silver.features_daily` f
  LEFT JOIN `{{project}}.stock_gold.arena_dow_signal` ds USING(date, symbol)
  LEFT JOIN `{{project}}.stock_gold.arena_monthend_signal` ms USING(date, symbol)
  LEFT JOIN `{{project}}.stock_gold.arena_sentiment_signal` ss USING(date, symbol)
  LEFT JOIN `{{project}}.stock_gold.arena_mean_rev_signal` mr USING(date, symbol)
  WHERE f.next_day_return IS NOT NULL
)
SELECT
  fs.date, fs.symbol,
  g.gene_id, g.generation,
  g.strategy_name,
  g.threshold, g.stop_loss, g.take_profit, g.max_hold_days,
  -- 合成シグナル
  fs.s_momentum * g.w_momentum
  + fs.s_volume * g.w_volume
  + fs.s_reversal * g.w_reversal
  + fs.s_breakout * g.w_breakout
  + fs.s_dow * g.w_dow
  + fs.s_monthend * g.w_monthend
  + fs.s_sentiment * g.w_sentiment
  + fs.s_mean_rev * g.w_mean_rev
  AS raw_signal,
  fs.next_day_return,
  fs.s_momentum, fs.s_volume, fs.s_reversal,
  fs.s_breakout, fs.s_dow, fs.s_monthend,
  fs.s_sentiment, fs.s_mean_rev
FROM feature_signals fs
CROSS JOIN `{{project}}.stock_gold.ga_gene_pool` g;

-- ============================================================
-- 4. 日次ポジション（スクリーニング後）
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.ga_positions` AS
WITH ranked AS (
  SELECT
    date, symbol, gene_id, strategy_name, generation,
    raw_signal,
    ABS(raw_signal) AS signal_strength,
    ROW_NUMBER() OVER (
      PARTITION BY gene_id, date
      ORDER BY ABS(raw_signal) DESC
    ) AS rank
  FROM `{{project}}.stock_gold.ga_signals`
  WHERE raw_signal <> 0
)
SELECT
  date, gene_id, strategy_name, generation,
  symbol, raw_signal,
  CASE WHEN raw_signal > 0 THEN 'LONG' ELSE 'SHORT' END AS side,
  signal_strength
FROM ranked
WHERE rank <= 3      -- 1戦略あたり最大3銘柄
ORDER BY gene_id, date, rank;

-- ============================================================
-- 5. 週次適応度評価
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.ga_weekly_pnl` AS
WITH pnl AS (
  SELECT
    p.gene_id,
    p.strategy_name,
    p.generation,
    DATE_TRUNC(p.date, WEEK(SUNDAY)) AS week_start,
    p.symbol,
    p.raw_signal,
    p.side,
    f.close AS entry_close,
    LEAD(f.close) OVER (
      PARTITION BY p.gene_id, p.symbol
      ORDER BY p.date
    ) AS exit_close,
    p.date AS entry_date,
    LEAD(p.date) OVER (
      PARTITION BY p.gene_id, p.symbol
      ORDER BY p.date
    ) AS exit_date
  FROM `{{project}}.stock_gold.ga_positions` p
  JOIN `{{project}}.stock_silver.features_daily` f
    ON p.date = f.date AND p.symbol = f.symbol
)
SELECT
  gene_id, strategy_name, generation, week_start,
  COUNT(*) AS n_trades,
  ROUND(AVG(
    CASE
      WHEN side = 'LONG' THEN (exit_close - entry_close) / entry_close * 100
      ELSE (entry_close - exit_close) / entry_close * 100
    END
  ), 4) AS avg_pnl,
  ROUND(STDDEV(
    CASE
      WHEN side = 'LONG' THEN (exit_close - entry_close) / entry_close * 100
      ELSE (entry_close - exit_close) / entry_close * 100
    END
  ), 4) AS std_pnl,
  ROUND(SUM(
    CASE
      WHEN side = 'LONG' THEN (exit_close - entry_close) / entry_close * 100
      ELSE (entry_close - exit_close) / entry_close * 100
    END
  ), 4) AS week_pnl,
  ROUND(AVG(IF(
    CASE
      WHEN side = 'LONG' THEN (exit_close - entry_close) / entry_close * 100
      ELSE (entry_close - exit_close) / entry_close * 100
    END > 0, 1, 0
  )), 4) AS win_rate
FROM pnl
WHERE exit_close IS NOT NULL
GROUP BY gene_id, strategy_name, generation, week_start;
