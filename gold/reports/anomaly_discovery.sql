-- gold/anomaly_discovery.sql
-- データドリブンなアノマリー発掘
-- セグメントごとのリターン・出来高の統計的偏りを検出し、未知のパターンを発見する

-- ============================================================
-- 1. セグメント定義: DOW / 月 / 週ゾーン / 月末ゾーン
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.anomaly_segments` AS
WITH base AS (
  SELECT
    date,
    symbol,
    close,
    volume,
    next_day_return,
    EXTRACT(DAYOFWEEK FROM date) AS dow,
    EXTRACT(MONTH FROM date) AS mth,
    EXTRACT(WEEK FROM date) AS wk,
    CASE EXTRACT(DAYOFWEEK FROM date)
      WHEN 1 THEN 'Sun'
      WHEN 2 THEN 'Mon'
      WHEN 3 THEN 'Tue'
      WHEN 4 THEN 'Wed'
      WHEN 5 THEN 'Thu'
      WHEN 6 THEN 'Fri'
      WHEN 7 THEN 'Sat'
    END AS dow_name,
    month_end_zone,
    CASE
      WHEN EXTRACT(DAY FROM date) <= 7  THEN 'week1'
      WHEN EXTRACT(DAY FROM date) <= 14 THEN 'week2'
      WHEN EXTRACT(DAY FROM date) <= 21 THEN 'week3'
      ELSE 'week4'
    END AS month_week_zone,
    -- 季節: 3ヶ月単位
    CASE EXTRACT(MONTH FROM date)
      WHEN 1 THEN 'winter'
      WHEN 2 THEN 'winter'
      WHEN 3 THEN 'spring'
      WHEN 4 THEN 'spring'
      WHEN 5 THEN 'spring'
      WHEN 6 THEN 'summer'
      WHEN 7 THEN 'summer'
      WHEN 8 THEN 'summer'
      WHEN 9 THEN 'fall'
      WHEN 10 THEN 'fall'
      WHEN 11 THEN 'fall'
      WHEN 12 THEN 'winter'
    END AS season
  FROM `{{project}}.stock_silver.features_daily`
  WHERE next_day_return IS NOT NULL
),
-- 全セグメント×組み合わせで統計を計算
unpivoted AS (
  SELECT date, symbol, next_day_return, volume, 'segment' AS seg_type, 'all' AS seg_value FROM base
  UNION ALL
  SELECT date, symbol, next_day_return, volume, 'dow', CAST(dow AS STRING) FROM base
  UNION ALL
  SELECT date, symbol, next_day_return, volume, 'dow_name', dow_name FROM base
  UNION ALL
  SELECT date, symbol, next_day_return, volume, 'month', CAST(mth AS STRING) FROM base
  UNION ALL
  SELECT date, symbol, next_day_return, volume, 'month_week_zone', month_week_zone FROM base
  UNION ALL
  SELECT date, symbol, next_day_return, volume, 'month_end_zone', month_end_zone FROM base
  UNION ALL
  SELECT date, symbol, next_day_return, volume, 'season', season FROM base
)
SELECT
  seg_type,
  seg_value,
  COUNT(*) AS n,
  COUNT(DISTINCT symbol) AS n_symbols,
  ROUND(AVG(next_day_return), 4) AS avg_return,
  ROUND(STDDEV(next_day_return), 4) AS std_return,
  -- t統計量: 平均が0と有意に異なるか
  ROUND(AVG(next_day_return) / NULLIF(STDDEV(next_day_return) / SQRT(COUNT(*)), 0), 2) AS t_stat,
  -- 勝率
  ROUND(AVG(IF(next_day_return > 0, 1, 0)), 4) AS win_rate,
  -- 全体平均との差（アノマリースコア）
  ROUND(AVG(next_day_return) -
    AVG(AVG(next_day_return)) OVER (PARTITION BY seg_type), 6) AS excess_return,
  -- 出来高の偏り
  ROUND(AVG(volume) /
    NULLIF(AVG(AVG(volume)) OVER (PARTITION BY seg_type), 0), 4) AS volume_ratio,
  -- 符号検定p値近似 (正規近似)
  ROUND(
    2 * (1 - LEAST(0.9999, GREATEST(0.0001,
      ABS(AVG(next_day_return) / NULLIF(STDDEV(next_day_return) / SQRT(COUNT(*)), 0))
    ))),
    4
  ) AS p_value_approx
FROM unpivoted
GROUP BY seg_type, seg_value;

-- ============================================================
-- 2. クロスセグメント: DOW × month_end_zone など
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.anomaly_cross_segments` AS
WITH base AS (
  SELECT
    date, symbol, next_day_return, volume,
    EXTRACT(DAYOFWEEK FROM date) AS dow,
    EXTRACT(MONTH FROM date) AS mth,
    month_end_zone,
    quarter_end_flag,
    CASE WHEN volume_surge_flag THEN 'surge' ELSE 'normal' END AS vol_mode
  FROM `{{project}}.stock_silver.features_daily`
  WHERE next_day_return IS NOT NULL
)
SELECT
  -- DOW × month_end_zone
  CONCAT('dow=', CAST(dow AS STRING), '|mend=', month_end_zone) AS segment_key,
  COUNT(*) AS n,
  ROUND(AVG(next_day_return), 4) AS avg_return,
  ROUND(AVG(IF(next_day_return > 0, 1, 0)), 4) AS win_rate
FROM base
GROUP BY dow, month_end_zone
UNION ALL
SELECT
  -- month × quarter_end
  CONCAT('mon=', CAST(mth AS STRING), '|qend=', CAST(quarter_end_flag AS STRING)),
  COUNT(*),
  ROUND(AVG(next_day_return), 4),
  ROUND(AVG(IF(next_day_return > 0, 1, 0)), 4)
FROM base
GROUP BY mth, quarter_end_flag
UNION ALL
SELECT
  -- DOW × volume_mode
  CONCAT('dow=', CAST(dow AS STRING), '|vol=', vol_mode),
  COUNT(*),
  ROUND(AVG(next_day_return), 4),
  ROUND(AVG(IF(next_day_return > 0, 1, 0)), 4)
FROM base
GROUP BY dow, vol_mode
ORDER BY avg_return DESC;

-- ============================================================
-- 3. 注目銘柄: セグメント×銘柄のパーソナライズドアノマリー
-- ============================================================
CREATE OR REPLACE TABLE `{{project}}.stock_gold.anomaly_by_symbol` AS
SELECT
  symbol,
  seg_type,
  seg_value,
  COUNT(*) AS n,
  ROUND(AVG(next_day_return), 4) AS avg_return,
  ROUND(AVG(IF(next_day_return > 0, 1, 0)), 4) AS win_rate
FROM (
  SELECT
    symbol, next_day_return,
    'dow' AS seg_type, CAST(EXTRACT(DAYOFWEEK FROM date) AS STRING) AS seg_value
  FROM `{{project}}.stock_silver.features_daily`
  WHERE next_day_return IS NOT NULL
  UNION ALL
  SELECT
    symbol, next_day_return,
    'month', CAST(EXTRACT(MONTH FROM date) AS STRING)
  FROM `{{project}}.stock_silver.features_daily`
  WHERE next_day_return IS NOT NULL
  UNION ALL
  SELECT
    symbol, next_day_return,
    'month_end_zone', month_end_zone
  FROM `{{project}}.stock_silver.features_daily`
  WHERE next_day_return IS NOT NULL
)
GROUP BY symbol, seg_type, seg_value
HAVING COUNT(*) >= 10  -- 最低サンプル数

-- ============================================================
-- 発見レポート
-- ============================================================
-- セグメント別に全体平均から有意に乖離している条件をリスト:
-- SELECT * FROM `{{project}}.stock_gold.anomaly_segments`
-- WHERE n >= 20 AND ABS(t_stat) > 2.0
-- ORDER BY ABS(excess_return) DESC;

-- クロスセグメントで最もリターンの高い組み合わせ:
-- SELECT * FROM `{{project}}.stock_gold.anomaly_cross_segments`
-- WHERE n >= 10 ORDER BY avg_return DESC LIMIT 20;

-- 銘柄別DOWアノマリー（例: この銘柄は月曜だけ異常に強い）:
-- SELECT * FROM `{{project}}.stock_gold.anomaly_by_symbol`
-- WHERE seg_type = 'dow' AND win_rate > 0.6
-- ORDER BY win_rate DESC;
