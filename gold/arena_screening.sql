-- gold/arena_screening.sql
-- ============================================================
-- 銘柄スクリーニング: 各戦略が毎日最大3銘柄に絞る
-- ルールベースで候補を絞り、シグナル強度順にキャップ
-- ============================================================

-- ============================================================
-- 1. スクリーニング済みシグナル
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.ga_screened_signals` AS
WITH base AS (
  SELECT
    s.date,
    s.symbol,
    s.gene_id,
    s.strategy_name,
    s.generation,
    s.final_signal,
    f.close,
    f.volume_vs_sma_ratio,
    -- 連続エントリー検出用: 前日も同じ遺伝子が同じ銘柄にエントリーしたか
    LAG(s.symbol) OVER (
      PARTITION BY s.gene_id ORDER BY s.date, s.symbol
    ) AS prev_symbol_lag,
    LAG(s.date) OVER (
      PARTITION BY s.gene_id ORDER BY s.date, s.symbol
    ) AS prev_date_lag
  FROM `{{project}}.stock_gold.ga_signals` s
  JOIN `{{project}}.stock_silver.features_daily` f
    ON s.date = f.date AND s.symbol = f.symbol
  WHERE f.next_day_return IS NOT NULL
),
filtered AS (
  SELECT *,
    -- ルール1: 出来高フィルタ
    volume_vs_sma_ratio > 0.5 AS vol_ok,
    -- ルール2: 価格フィルタ
    close > 100 AS price_ok,
    -- ルール3: 重複排除 (同じ銘柄に2日連続エントリーしない)
    (prev_symbol_lag IS NULL OR prev_symbol_lag <> symbol
     OR DATE_DIFF(date, prev_date_lag, DAY) > 1) AS dedup_ok,
    -- シグナル強度
    ABS(final_signal) AS signal_strength
  FROM base
  WHERE final_signal <> 0
),
ranked AS (
  SELECT
    date, symbol, gene_id, strategy_name, generation,
    final_signal, signal_strength,
    ROW_NUMBER() OVER (
      PARTITION BY gene_id, date
      ORDER BY signal_strength DESC
    ) AS rank_in_strategy
  FROM filtered
  WHERE vol_ok AND price_ok AND dedup_ok
)
SELECT
  date, gene_id, strategy_name, generation,
  symbol, final_signal, signal_strength,
  rank_in_strategy
FROM ranked
WHERE rank_in_strategy <= 3   -- キャップ: 最大3銘柄
ORDER BY gene_id, date, rank_in_strategy;
