# stock-bqml

株価データをメダリオンアーキテクチャで処理し、BigQuery ML で多変量解析・予測するパイプライン。

## アーキテクチャ

| レイヤー | 実装 | 役割 |
|---|---|---|
| Bronze | Go (`bronze/collector.go`) | 株価APIから生データを取得し、BigQuery の JSON 型カラムへストリーミング投入 |
| Silver | BQML SQL (`silver/`) | テクニカル指標（移動平均、RSI、ラグ特徴量、**出来高漸増指標**）を生成。特徴量ストア |
| Gold | BQML SQL (`gold/`) | XGBoost モデル学習・予測。ML.EXPLAIN_PREDICT で解釈性確保 + **出来高漸増銘柄監視** |
| Orchestration | Colab (`colab/poc_pipeline.ipynb`) | Silver→Gold をノートブックで実行。可視化付き |

## 出来高漸増監視（新機能）

Silver 層で以下の出来高指標を計算:
- `volume_vs_sma_ratio` — 当日出来高 / 5日移動平均
- `volume_chg_pct` — 前日比(%)
- `volume_incr_streak` — 連続増加日数
- `volume_surge_flag` — 急増フラグ(前日比150%以上)

Gold 層で `volume_increase_watch` テーブルを生成:
- 出来高漸増スコア（0-100）でランキング
- アラートレベル: 🔴強烈 / 🟠顕著 / 🟡注意 / ⚪静穏
- 毎日バッチで更新、注目銘柄を自動抽出

```sql
-- 最新の出来高漸増銘柄TOP20
SELECT * FROM `your-project.stock_gold.volume_increase_watch`
ORDER BY volume_increase_score DESC LIMIT 20;
```

## クイックスタート

### Bronze: Go でデータ投入

```bash
cd bronze
go run collector.go -symbol=7203.T -interval=1d -project=your-gcp-project -dataset=stock_bronze
```

### Silver: 特徴量生成

```bash
cat silver/features_daily.sql | sed 's/{{project}}/your-project/g' | bq query --use_legacy_sql=false
```

### Gold: 出来高漸増監視

```bash
cat gold/volume_increase_watch.sql | sed 's/{{project}}/your-project/g' | bq query --use_legacy_sql=false
```

### Gold: モデル学習・予測

```sql
-- BQML XGBoost
CREATE OR REPLACE MODEL `your-project.stock_gold.xgb_predictor` ...
```

## Colab で動かす

各記事末尾の `[▶ Colabで動かす]` リンクからノートブックを開き、自身の GCP プロジェクト ID を設定して実行。

## ディレクトリ構成

```
stock-bqml/
├── bronze/
│   └── collector.go         # Go: API→BQ ストリーミング
├── silver/
│   └── features_daily.sql   # テクニカル指標 + 出来高漸増指標計算
├── gold/
│   ├── train_xgb.sql        # XGBoost モデル学習
│   ├── predict.sql          # 予測クエリ
│   ├── explain.sql          # 特徴量重要度・SHAP風解釈
│   └── volume_increase_watch.sql  # 出来高漸増銘柄監視
├── colab/
│   └── poc_pipeline.ipynb   # Silver→Gold 実行ノートブック
└── docs/
    └── ARCHITECTURE.md      # 詳細設計・データフロー図
```

---
Generated as a vibe-coding data-engineering portfolio.
