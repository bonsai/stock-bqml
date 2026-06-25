-- gold/volume_increase_watch.sql
-- 出来高漸増銘柄の検出・監視ビュー
-- 用途: 毎日バッチで実行し、注目銘柄リストを更新

CREATE OR REPLACE TABLE `{{project}}.stock_gold.volume_increase_watch` AS
WITH latest AS (
  SELECT
    symbol,
    date,
    close,
    volume,
    volume_sma_5,
    volume_vs_sma_ratio,
    volume_chg_pct,
    volume_incr_streak,
    volume_surge_flag,
    -- 出来高漸増スコア（0-100）
    ROUND(
      GREATEST(LEAST(
        (volume_vs_sma_ratio - 1) * 20 +
        GREATEST(volume_chg_pct, 0) * 0.5 +
        volume_incr_streak * 5 +
        IF(volume_surge_flag, 30, 0),
        100
      ), 0), 2
    ) AS volume_increase_score,
    -- 直近5日の平均出来高増加率
    AVG(volume_chg_pct) OVER (PARTITION BY symbol ORDER BY date ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) AS avg_vol_chg_5d,
    -- 直近価格変動
    SAFE_DIVIDE(close - LAG(close) OVER (PARTITION BY symbol ORDER BY date), LAG(close) OVER (PARTITION BY symbol ORDER BY date)) * 100 AS price_chg_pct
  FROM `{{project}}.stock_silver.features_daily`
  WHERE date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
)
SELECT
  symbol,
  date,
  close,
  volume,
  volume_sma_5,
  ROUND(volume_vs_sma_ratio, 2) AS volume_vs_sma_ratio,
  ROUND(volume_chg_pct, 2) AS volume_chg_pct,
  volume_incr_streak,
  volume_surge_flag,
  volume_increase_score,
  ROUND(avg_vol_chg_5d, 2) AS avg_vol_chg_5d,
  ROUND(price_chg_pct, 2) AS price_chg_pct,
  -- アラート条件
  CASE
    WHEN volume_increase_score >= 80 THEN '🔴 強烈'
    WHEN volume_increase_score >= 60 THEN '🟠 顕著'
    WHEN volume_increase_score >= 40 THEN '🟡 注意'
    ELSE '⚪ 静穏'
  END AS alert_level,
  CURRENT_TIMESTAMP() AS _updated_at
FROM latest
WHERE date = (SELECT MAX(date) FROM latest)
  AND volume_increase_score >= 30  -- 最低でも要注意レベル
ORDER BY volume_increase_score DESC, volume_surge_flag DESC;

-- 查詢用法:
-- SELECT * FROM `your-project.stock_gold.volume_increase_watch` ORDER BY volume_increase_score DESC LIMIT 20;
