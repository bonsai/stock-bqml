-- gold/explain.sql
-- モデルの特徴量重要度 + SHAP風個別説明

-- 1) グローバル特徴量重要度
SELECT
  *
FROM
  ML.GLOBAL_EXPLAIN(MODEL `{{project}}.stock_gold.xgb_predictor`);

-- 2) 個別予測の説明（SHAP近似）
SELECT
  *
FROM
  ML.EXPLAIN_PREDICT(
    MODEL `{{project}}.stock_gold.xgb_predictor`,
    (
      SELECT * EXCEPT(next_day_return)
      FROM `{{project}}.stock_silver.features_daily`
      WHERE date >= '2024-01-01'
      LIMIT 10
    ),
    STRUCT(10 AS top_k_features)
  );
