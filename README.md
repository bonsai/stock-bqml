# stock-bqml

株価データをメダリオンアーキテクチャで処理し、BigQuery ML で多変量解析・予測するパイプライン。

## アーキテクチャ

| レイヤー | 実装 | 役割 |
|---|---|---|
| Bronze | Go (`bronze/ingest/collector.go`) | 株価APIから生データを取得し、BigQuery に投入 |
| Silver | BQML SQL (`silver/features/`) | テクニカル指標（移動平均、RSI、MACD、ボリンジャーバンド、ATR、ラグ特徴量、出来高漸増指標）を生成 |
| Gold | BQML SQL (`gold/models/`, `gold/arena/`, `gold/reports/`) | XGBoost モデル学習・予測 + GA進化アリーナ + 異常検知・レポート |

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

## バックテスト

```bash
# 全戦略のバックテストを一括実行
cat gold/backtest_accuracy.sql | sed 's/{{project}}/your-project/g' | bq query --use_legacy_sql=false
```

結果テーブル:
| テーブル | 内容 |
|---|---|
| `backtest_results` | 日次×全モデル予測横並び + 実際リターン + 合成シグナル |
| `backtest_model_summary` | モデル別: MAE/RMSE/方向一致率/的中平均リターン |
| `backtest_signal_performance` | シグナル別: 勝率/平均リターン/Sharpe比/DD |
| `backtest_cumulative_returns` | 累積リターン曲線（可視化用） |

```sql
-- 最優秀戦略を確認
SELECT * FROM `your-project.stock_gold.backtest_signal_performance`
ORDER BY sharpe_ratio_annualized DESC;
```

## Colab で動かす

各記事末尾の `[▶ Colabで動かす]` リンクからノートブックを開き、自身の GCP プロジェクト ID を設定して実行。

## ディレクトリ構成

```
stock-bqml/
├── bronze/               # 生データ (Go collector)
│   ├── ingest/           # 収集コード (collector.go)
│   ├── raw/              # (将来: 生データスキーマ定義)
│   └── meta/             # メタ情報
├── silver/               # 特徴量エンジニアリング
│   ├── features/         # 特徴量SQL (features_daily.sql)
│   ├── transforms/       # (将来: データ変換)
│   └── meta/             # (将来: 特徴量カタログ)
└── gold/                 # モデル・分析・レポート
    ├── models/           # BQMLモデル (strategies, xgb, predict, explain)
    ├── arena/            # GA進化アリーナ (arena_ga.sql, arena.sql, deploy, notebook)
    └── reports/          # バックテスト, 異常検知, レポート


---
Generated as a vibe-coding data-engineering portfolio.
