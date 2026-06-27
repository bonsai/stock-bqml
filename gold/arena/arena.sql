-- gold/arena.sql
-- ============================================================
-- ストラテジーアリーナ — 10人のエージェントが生き残りをかけて戦う
-- 毎週のパフォーマンスでランク付け、下位は脱落・上位はウェイト増
-- ============================================================

-- ============================================================
-- 0. エントラント定義（10人）
-- ============================================================
-- 各エントラントは日次のシグナル(-1〜1)を出力する。
-- 正 = ロング推奨, 負 = ショート推奨, 0 = HOLD
-- 4人のBQMLモデル + 6人のルールベーススペシャリスト
-- ============================================================

-- ============================================================
-- 1. 日次シグナル生成: 10人の予測を横並び
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.arena_signals` AS
WITH bqml_preds AS (
  SELECT date, symbol,
    momentum_pred, breakout_pred,
    volume_confirm_pred, reversal_pred
  FROM `{{project}}.stock_gold.backtest_results`
),
rule_signals AS (
  SELECT
    date, symbol,
    -- 5. DOWスペシャリスト: 曜日別過去平均リターン
    NULL AS dow_signal,
    -- 6. 月末ハンター: 月末3日はポジション圧縮狙い
    NULL AS month_end_signal,
    -- 7. 凪の前の嵐: ボラ収縮→拡大狙い
    NULL AS calm_before_storm_signal,
    -- 8. センチメント: 騰落レシオ連動
    NULL AS sentiment_signal,
    -- 9. 逆張り: RSI極端+BB乖離
    NULL AS mean_rev_signal,
    -- 10. アンサンブルキャプテン: 上位3人の平均
    NULL AS ensemble_signal
  FROM `{{project}}.stock_silver.features_daily`
  WHERE next_day_return IS NOT NULL
)
SELECT * FROM bqml_preds
-- ← ここにrule_signalsを結合。rule_signalsは下で実装
;

-- ============================================================
-- 1b. ルールベースシグナル実装（個別CTE）
-- ============================================================
-- 以下が6人のスペシャリストの実装。arena_signalsにUNIONする。

-- 5. DOWスペシャリスト: 過去20週の同日曜日の平均リターンでバイアス
--    「火曜は買い、金曜は利確」などのパターンを学習
CREATE OR REPLACE TABLE `{{project}}.stock_gold.arena_dow_signal` AS
SELECT
  f.date,
  f.symbol,
  CASE WHEN s.dow_return_std > 0 AND s.dow_return_mean IS NOT NULL
    THEN LEAST(1, GREATEST(-1, s.dow_return_mean / s.dow_return_std * 0.5))
    ELSE 0
  END AS dow_signal
FROM `{{project}}.stock_silver.features_daily` f
LEFT JOIN (
  SELECT
    date,
    symbol,
    AVG(next_day_return) OVER (
      PARTITION BY symbol, EXTRACT(DAYOFWEEK FROM date)
      ORDER BY date
      ROWS BETWEEN 20 PRECEDING AND 1 PRECEDING
    ) AS dow_return_mean,
    STDDEV(next_day_return) OVER (
      PARTITION BY symbol, EXTRACT(DAYOFWEEK FROM date)
      ORDER BY date
      ROWS BETWEEN 20 PRECEDING AND 1 PRECEDING
    ) AS dow_return_std
  FROM `{{project}}.stock_silver.features_daily`
  WHERE next_day_return IS NOT NULL
) s ON f.date = s.date AND f.symbol = s.symbol;

-- 6. 月末ハンター: 月末・四半期末のポジション整理を先取り
--    月末3日はショートバイアス、翌月初1日はリバウンド狙い
CREATE OR REPLACE TABLE `{{project}}.stock_gold.arena_monthend_signal` AS
WITH monthly_pattern AS (
  SELECT
    symbol,
    month_end_zone,
    quarter_end_flag,
    AVG(next_day_return) OVER (
      PARTITION BY symbol, month_end_zone
      ORDER BY date
      ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING
    ) AS zone_return_mean,
    STDDEV(next_day_return) OVER (
      PARTITION BY symbol, month_end_zone
      ORDER BY date
      ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING
    ) AS zone_return_std
  FROM `{{project}}.stock_silver.features_daily`
  WHERE next_day_return IS NOT NULL
)
SELECT DISTINCT
  f.date,
  f.symbol,
  CASE
    WHEN f.month_end_zone = 'month_end' AND p.zone_return_mean IS NOT NULL AND p.zone_return_std > 0
      THEN LEAST(1, GREATEST(-1, p.zone_return_mean / p.zone_return_std * 0.5))
    WHEN f.month_end_zone = 'last_week' AND p.zone_return_mean IS NOT NULL AND p.zone_return_std > 0
      THEN LEAST(0.5, GREATEST(-0.5, p.zone_return_mean / p.zone_return_std * 0.3))
    ELSE 0
  END AS month_end_signal
FROM `{{project}}.stock_silver.features_daily` f
JOIN monthly_pattern p USING (symbol, month_end_zone);

-- 7. 凪の前の嵐: ボラティリティ収縮→拡大のブレイクを先取り
--    bb_bandwidthが縮小している銘柄で拡大方向に賭ける
CREATE OR REPLACE TABLE `{{project}}.stock_gold.arena_calm_before_storm_signal` AS
SELECT
  f.date,
  f.symbol,
  CASE
    -- bb_bandwidthが20日最低値付近（収縮）かつ出来高静穏 → 拡大を待つ
    WHEN f.bb_bandwidth IS NOT NULL AND f.atr_14 IS NOT NULL
      AND f.bb_bandwidth < 0.05  -- 極端な収縮
      AND f.volume_vs_sma_ratio < 1.2  -- 出来高も大人しい
      THEN 0.3  -- 弱めのロング（拡大方向は不確実）
    WHEN f.volume_surge_flag
      AND f.bb_bandwidth > 0.10  -- バンド拡大中
      THEN 0.5  -- 拡大確定なら強め
    ELSE 0
  END AS calm_before_storm_signal
FROM `{{project}}.stock_silver.features_daily` f;

-- 8. センチメント: 市場全体の流れに乗る
--    銘柄の騰落と市場全体の騰落の相関を利用
--    単純化: 全銘柄平均リターンが正なら強気バイアス
CREATE OR REPLACE TABLE `{{project}}.stock_gold.arena_sentiment_signal` AS
WITH market_daily AS (
  SELECT
    date,
    AVG(next_day_return) AS market_avg_return
  FROM `{{project}}.stock_silver.features_daily`
  WHERE next_day_return IS NOT NULL
  GROUP BY date
)
SELECT
  f.date,
  f.symbol,
  LEAST(1, GREATEST(-1, m.market_avg_return * 3)) AS sentiment_signal
FROM `{{project}}.stock_silver.features_daily` f
JOIN market_daily m USING (date);

-- 9. 逆張り: RSIとBBで極端な値を狙う
--    RSI < 30 かつ BB %B < 0 → 買い、RSI > 70 かつ BB %B > 1 → 売り
CREATE OR REPLACE TABLE `{{project}}.stock_gold.arena_mean_rev_signal` AS
SELECT
  date,
  symbol,
  CASE
    WHEN rsi_14 < 30 AND bb_pct_b < 0.1 THEN 1.0    -- 強気逆張り買い
    WHEN rsi_14 < 35 AND bb_pct_b < 0.2 THEN 0.5    -- 弱気買い
    WHEN rsi_14 > 70 AND bb_pct_b > 0.9 THEN -1.0   -- 強気逆張り売り
    WHEN rsi_14 > 65 AND bb_pct_b > 0.8 THEN -0.5   -- 弱気売り
    ELSE 0
  END AS mean_rev_signal
FROM `{{project}}.stock_silver.features_daily`;

-- 10. アンサンブルキャプテン: 現時点の上位3人のシグナルを平均
--     リーダーボード更新後に再計算される
CREATE OR REPLACE TABLE `{{project}}.stock_gold.arena_ensemble_signal` AS
-- プレースホルダ: leaderboardからTOP3を取得して平均
SELECT
  date,
  symbol,
  0 AS ensemble_signal  -- 実行時に上書き
FROM `{{project}}.stock_silver.features_daily`
WHERE 1=0;

-- ============================================================
-- 2. ウィークリーリーダーボード
-- ============================================================
-- 毎週日曜日に実行: 各エントラントの週次パフォーマンスを評価
CREATE OR REPLACE TABLE `{{project}}.stock_gold.arena_leaderboard` AS
WITH weekly_pnl AS (
  SELECT
    entrant_name,
    DATE_TRUNC(date, WEEK(SUNDAY)) AS week_start,
    COUNT(*) AS n_days,
    ROUND(AVG(pnl), 4) AS avg_daily_pnl,
    ROUND(STDDEV(pnl), 4) AS std_daily_pnl,
    ROUND(AVG(IF(pnl > 0, 1, 0)), 4) AS win_rate,
    ROUND(SUM(pnl), 4) AS week_total_pnl,
    -- 生存スコア = 直近4週の加重平均 (最新ほど重い)
    SUM(SUM(pnl)) OVER (
      PARTITION BY entrant_name
      ORDER BY DATE_TRUNC(date, WEEK(SUNDAY))
      ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
    ) / 4 AS rolling_4w_pnl
  FROM (
    -- P&L計算: 各エントラントの日次成績をUNION
    SELECT '1_momentum' AS entrant_name, date, symbol,
      IF(SIGN(momentum_pred) = SIGN(actual_return),
         ABS(actual_return), -ABS(actual_return)) AS pnl
    FROM `{{project}}.stock_gold.backtest_results`
    UNION ALL
    SELECT '2_breakout', date, symbol,
      IF(SIGN(breakout_pred) = SIGN(actual_return),
         ABS(actual_return), -ABS(actual_return))
    FROM `{{project}}.stock_gold.backtest_results`
    UNION ALL
    SELECT '3_volume_confirm', date, symbol,
      IF(SIGN(volume_confirm_pred) = SIGN(actual_return),
         ABS(actual_return), -ABS(actual_return))
    FROM `{{project}}.stock_gold.backtest_results`
    UNION ALL
    SELECT '4_reversal', date, symbol,
      IF(SIGN(reversal_pred) = SIGN(actual_return),
         ABS(actual_return), -ABS(actual_return))
    FROM `{{project}}.stock_gold.backtest_results`
    UNION ALL
    SELECT '5_dow_specialist', date, symbol, (dow_signal * actual_return)
    FROM `{{project}}.stock_gold.arena_dow_signal`
    JOIN `{{project}}.stock_gold.backtest_results` USING(date, symbol)
    UNION ALL
    SELECT '6_month_end_hunter', date, symbol, (month_end_signal * actual_return)
    FROM `{{project}}.stock_gold.arena_monthend_signal`
    JOIN `{{project}}.stock_gold.backtest_results` USING(date, symbol)
    UNION ALL
    SELECT '7_calm_before_storm', date, symbol, (calm_before_storm_signal * actual_return)
    FROM `{{project}}.stock_gold.arena_calm_before_storm_signal`
    JOIN `{{project}}.stock_gold.backtest_results` USING(date, symbol)
    UNION ALL
    SELECT '8_sentiment', date, symbol, (sentiment_signal * actual_return)
    FROM `{{project}}.stock_gold.arena_sentiment_signal`
    JOIN `{{project}}.stock_gold.backtest_results` USING(date, symbol)
    UNION ALL
    SELECT '9_mean_reversion', date, symbol, (mean_rev_signal * actual_return)
    FROM `{{project}}.stock_gold.arena_mean_rev_signal`
    JOIN `{{project}}.stock_gold.backtest_results` USING(date, symbol)
    UNION ALL
    SELECT '10_ensemble', date, symbol, 0  -- Ensemble Captain: 実行時に計算
    FROM `{{project}}.stock_gold.backtest_results`
    WHERE 1=0
  )
  GROUP BY entrant_name, week_start
)
SELECT
  entrant_name,
  week_start,
  n_days,
  avg_daily_pnl,
  std_daily_pnl,
  win_rate,
  week_total_pnl,
  rolling_4w_pnl,
  -- 今週のランク
  ROW_NUMBER() OVER (PARTITION BY week_start ORDER BY week_total_pnl DESC) AS week_rank,
  -- 生存ステータス
  CASE
    WHEN rolling_4w_pnl > 0 THEN 'ALIVE'
    ELSE 'WARNING'
  END AS status
FROM weekly_pnl;

-- ============================================================
-- 3. 生存管理: 警告→脱落の履歴
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.arena_survival_log` (
  week_start DATE,
  entrant_name STRING,
  status STRING,        -- 'ALIVE', 'WARNING_1', 'WARNING_2', 'ELIMINATED'
  week_rank INT64,
  rolling_4w_pnl NUMERIC,
  reason STRING,
  _updated_at TIMESTAMP
);

-- ============================================================
-- 4. 実行・更新クエリ
-- ============================================================
-- 毎週日曜:
-- 1. 各signalテーブルを再構築（学習期間を拡張）
-- 2. arena_leaderboard を更新
-- 3. arena_survival_log に今週の生存判定を追記
-- 4. 脱落者がいる場合、arena_signals の該当エントラントをマスク
-- 5. TOP3でensemble_signalを再計算
--
-- ランキング集計:
-- SELECT * FROM arena_leaderboard
-- WHERE week_start = (SELECT MAX(week_start) FROM arena_leaderboard)
-- ORDER BY week_rank;

-- 脱落者一覧:
-- SELECT * FROM arena_survival_log
-- WHERE status = 'ELIMINATED'
-- ORDER BY week_start;

-- 生存者＋警告:
-- SELECT entrant_name, status, rolling_4w_pnl
-- FROM arena_leaderboard
-- WHERE week_start = (SELECT MAX(week_start) FROM arena_leaderboard)
-- ORDER BY rolling_4w_pnl DESC;
