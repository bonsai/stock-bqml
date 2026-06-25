# stock-bqml

株価データをメダリオンアーキテクチャで処理し、BigQuery ML で多変量解析・予測するパイプライン。

## アーキテクチャ

| レイヤー | 実装 | 役割 |
|---|---|---|
| Bronze | Go (`bronze/collector.go`) | 株価APIから生データを取得し、BigQuery の JSON 型カラムへストリーミング投入 |
| Silver | BQML SQL (`silver/`) | テクニカル指標（移動平均、RSI、ラグ特徴量）を生成。特徴量ストア |
| Gold | BQML SQL (`gold/`) | XGBoost モデル学習・予測。ML.EXPLAIN_PREDICT で解釈性確保 |
| Orchestration | Colab (`colab/poc_pipeline.ipynb`) | Silver→Gold をノートブックで実行。可視化付き |

## クイックスタート

### Bronze: Go でデータ投入

```bash
cd bronze
go run collector.go -symbol=7203.T -interval=1d -project=your-gcp-project -dataset=stock_bronze
```

### Silver: 特徴量生成

BigQuery コンソールまたは Colab から:
```sql
CREATE OR REPLACE TABLE `your-project.stock_silver.features_daily` AS
SELECT * FROM `your-project.stock_bronze.raw_daily`;
-- + テクニカル指標計算 (silver/features_daily.sql を参照)
```

### Gold: モデル学習・予測

```sql
CREATE OR REPLACE MODEL `your-project.stock_gold.xgb_predictor`
OPTIONS(model_type='XGBOOST', input_label_cols=['next_day_return']) AS
SELECT * EXCEPT(date, symbol)
FROM `your-project.stock_silver.features_daily`
WHERE _PARTITIONDATE < '2024-01-01'; -- 学習期間を指定
```

## Colab で動かす

各記事末尾の `[▶ Colabで動かす]` リンクからノートブックを開き、自身の GCP プロジェクト ID を設定して実行。

## ディレクトリ構成

```
stock-bqml/
├── bronze/
│   └── collector.go         # Go: API→BQ ストリーミング
├── silver/
│   ├── features_daily.sql   # テクニカル指標計算
│   └── create_views.sql     # 分析用ビュー
├── gold/
│   ├── train_xgb.sql        # XGBoost モデル学習
│   ├── predict.sql          # 予測クエリ
│   └── explain.sql          # 特徴量重要度・SHAP風解釈
├── colab/
│   └── poc_pipeline.ipynb   # Silver→Gold 実行ノートブック
└── docs/
    └── ARCHITECTURE.md      # 詳細設計・データフロー図
```

---
Generated as a vibe-coding data-engineering portfolio.
