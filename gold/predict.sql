-- gold/predict.sql
-- 最新データに対する翌日リターン予測

CREATE OR REPLACE TABLE `{{project}}.stock_gold.predictions` AS
SELECT
  date,
  symbol,
  predicted_next_day_return
FROM ML.PREDICT(
  MODEL `{{project}}.stock_gold.xgb_predictor`,
  (
    SELECT * EXCEPT(next_day_return)
    FROM `{{project}}.stock_silver.features_daily`
    WHERE date >= '2024-01-01'
  )
);
