-- gold/arena_ga.sql
-- ============================================================
-- Genetic Algorithm 戦略進化アリーナ v2
-- ルール→スクリーニング(銘柄3つまで)→自由売買→週次決算
-- ============================================================

-- ============================================================
-- 1. 週タイプ分類器
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
    AVG(next_day_return) AS market_return
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
-- 2. 遺伝子プール
--    各戦略 = 8重み + 閾値 + 最大ポジション数
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.ga_gene_pool` (
  gene_id INT64,
  generation INT64,
  parent_a INT64,
  parent_b INT64,
  strategy_name STRING,
  -- シグナル重み (0.0〜1.0)
  w_momentum FLOAT64,
  w_volume FLOAT64,
  w_reversal FLOAT64,
  w_breakout FLOAT64,
  w_dow FLOAT64,
  w_monthend FLOAT64,
  w_sentiment FLOAT64,
  w_mean_rev FLOAT64,
  -- ルールパラメータ
  threshold FLOAT64,         -- シグナル発動しきい値
  max_positions INT64,       -- 最大同時保有銘柄数 (1〜3)
  stop_loss FLOAT64,         -- ストップロス幅(%)
  take_profit FLOAT64,       -- 利確幅(%)
  max_hold_days INT64,       -- 最大保有日数
  -- 適応度
  fitness FLOAT64,
  n_trades INT64,
  win_rate FLOAT64,
  weekly_pnl FLOAT64,
  created_at TIMESTAMP
);

-- 初期世代: 10個体
INSERT INTO `{{project}}.stock_gold.ga_gene_pool`
SELECT
  gene_id,
  1 AS generation,
  NULL, NULL,
  CONCAT('GA_gen1_', CAST(gene_id AS STRING)),
  RAND(), RAND(), RAND() * 0.8, RAND() * 0.7,
  RAND() * 0.4, RAND() * 0.4, RAND() * 0.6, RAND() * 0.5,
  0.2 + RAND() * 0.8,
  CAST(1 + RAND() * 2 AS INT64),  -- 1〜3
  2 + RAND() * 5,                 -- 2〜7% ストップロス
  3 + RAND() * 7,                 -- 3〜10% 利確
  CAST(3 + RAND() * 12 AS INT64), -- 3〜14日 最大保有
  NULL, 0, NULL, NULL,
  CURRENT_TIMESTAMP()
FROM UNNEST(GENERATE_ARRAY(1, 10)) AS gene_id;

-- ============================================================
-- 3. 日次スクリーニング: 全銘柄スコアリング→上位3銘柄
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.ga_daily_screen` AS
WITH feature_signals AS (
  SELECT
    f.date, f.symbol,
    LEAST(1, GREATEST(-1, f.macd_histogram * 10)) AS s_momentum,
    LEAST(1, GREATEST(-1, (f.volume_vs_sma_ratio - 1) * 3)) AS s_volume,
    LEAST(1, GREATEST(-1, (50 - f.rsi_14) / 20)) AS s_reversal,
    LEAST(0.5, GREATEST(-0.5,
      (f.bb_bandwidth - AVG(f.bb_bandwidth) OVER (PARTITION BY f.symbol ORDER BY f.date ROWS BETWEEN 19 PRECEDING AND CURRENT ROW))
      / NULLIF(STDDEV(f.bb_bandwidth) OVER (PARTITION BY f.symbol ORDER BY f.date ROWS BETWEEN 19 PRECEDING AND CURRENT ROW), 0)
    )) AS s_breakout,
    COALESCE(ds.dow_signal, 0) AS s_dow,
    COALESCE(ms.month_end_signal, 0) AS s_monthend,
    COALESCE(ss.sentiment_signal, 0) AS s_sentiment,
    COALESCE(mr.mean_rev_signal, 0) AS s_mean_rev,
    f.close, f.next_day_return
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
  g.threshold, g.max_positions,
  -- 合成スコア
  fs.s_momentum * g.w_momentum
  + fs.s_volume * g.w_volume
  + fs.s_reversal * g.w_reversal
  + fs.s_breakout * g.w_breakout
  + fs.s_dow * g.w_dow
  + fs.s_monthend * g.w_monthend
  + fs.s_sentiment * g.w_sentiment
  + fs.s_mean_rev * g.w_mean_rev
  AS composite_score,
  fs.close, fs.next_day_return,
  -- 銘柄内ランク: スコアが高い順
  ROW_NUMBER() OVER (
    PARTITION BY fs.date, g.gene_id
    ORDER BY composite_score DESC
  ) AS rank_long,
  ROW_NUMBER() OVER (
    PARTITION BY fs.date, g.gene_id
    ORDER BY composite_score ASC
  ) AS rank_short
FROM feature_signals fs
CROSS JOIN `{{project}}.stock_gold.ga_gene_pool` g;

-- ============================================================
-- 4. ポジションシミュレーション（簡易版）
--    各遺伝子が毎日TOP3銘柄を保有 + ストップロス/利確で決済
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.ga_positions` AS
WITH
-- 買いエントリ: 各遺伝子×日付でTOP3の買いシグナル
entries AS (
  SELECT
    date, symbol, gene_id, generation,
    composite_score, close AS entry_price,
    next_day_return AS day_return,
    DATE_ADD(date, INTERVAL max_hold_days DAY) AS forced_exit_date,
    -- ストップロス/利確価格
    close * (1 - stop_loss/100) AS stop_loss_price,
    close * (1 + take_profit/100) AS take_profit_price
  FROM `{{project}}.stock_gold.ga_daily_screen`
  WHERE rank_long <= max_positions
    AND composite_score > threshold
),
-- 売りエントリ
short_entries AS (
  SELECT
    date, symbol, gene_id, generation,
    composite_score, close AS entry_price,
    next_day_return AS day_return,
    DATE_ADD(date, INTERVAL max_hold_days DAY) AS forced_exit_date,
    close * (1 + stop_loss/100) AS stop_loss_price,
    close * (1 - take_profit/100) AS take_profit_price
  FROM `{{project}}.stock_gold.ga_daily_screen`
  WHERE rank_short <= max_positions
    AND composite_score < -threshold
)
SELECT *, 'LONG' AS direction FROM entries
UNION ALL
SELECT *, 'SHORT' AS direction FROM short_entries;

-- ============================================================
-- 5. 週次決算: 各戦略の週間P&L
-- ============================================================
-- 実際の決済は「翌日の終値で売買」を仮定
-- ストップロス/利確は日中のタッチをシミュレートできないので、
-- 保有期間中の最悪/最良リターンで近似
CREATE OR REPLACE TABLE `{{project}}.stock_gold.ga_weekly_pnl` AS
WITH position_pnl AS (
  SELECT
    p.gene_id, p.generation, p.direction,
    DATE_TRUNC(p.date, WEEK(SUNDAY)) AS entry_week,
    p.symbol, p.entry_price, p.stop_loss_price, p.take_profit_price,
    p.forced_exit_date,
    -- 実際のリターン
    CASE
      WHEN p.direction = 'LONG'
        THEN p.day_return / 100  -- 日次リターンをそのまま
      ELSE -p.day_return / 100
    END AS daily_pnl
  FROM `{{project}}.stock_gold.ga_positions` p
)
SELECT
  gene_id,
  generation,
  entry_week AS week_start,
  COUNT(*) AS n_positions,
  SUM(daily_pnl) AS week_pnl,
  AVG(daily_pnl) AS avg_pnl,
  AVG(IF(daily_pnl > 0, 1, 0)) AS win_rate,
  SUM(daily_pnl) / NULLIF(STDDEV(daily_pnl) * SQRT(COUNT(*)), 0) AS sharpe,
  COUNT(DISTINCT symbol) AS symbols_traded
FROM position_pnl
GROUP BY gene_id, generation, entry_week;

-- ============================================================
-- 6. 適応度更新: 各遺伝子の累積fitness
-- ============================================================
-- ColabのGAループから呼び出す:
--   CALL update_fitness() 相当
-- 適応度 = 直近4週の平均週次P&L（負の個体は淘汰対象）

-- ============================================================
-- 実行フロー（毎週日曜 自動 or Colab）
-- ============================================================
-- 0. ga_week_types 更新
-- 1. ga_daily_screen 再構築 (全遺伝子×全銘柄のスコアリング)
-- 2. ga_positions 再構築 (TOP3抽出)
-- 3. ga_weekly_pnl 更新
-- 4. 適応度計算 → 下位3淘汰
-- 5. 上位3交叉で新個体3つ生成
-- 6. 全個体に突然変異(5%)
-- 7. ga_gene_pool に新世代INSERT
-- 8. ループ

-- 最新Leaderboard:
-- SELECT gene_id, strategy_name, generation,
--   ROUND(week_pnl, 4) AS pnl,
--   ROUND(win_rate, 3) AS win_rate,
--   symbols_traded
-- FROM ga_weekly_pnl
-- WHERE week_start = (SELECT MAX(week_start) FROM ga_weekly_pnl)
-- ORDER BY week_pnl DESC
-- LIMIT 10;
