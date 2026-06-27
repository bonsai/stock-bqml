# stock-bqml

株価データを**メダリオンアーキテクチャ**で処理し、BigQuery ML で多変量解析・予測するパイプライン。

```
[外部API] → 銅(Bronze) → 銀(Silver) → 金(Gold) → [分析・トレード]
```

各層は BQ データセットとして分離: `stock_bronze` / `stock_silver` / `stock_gold`

**ダッシュボード:** https://stock-bqml-dashboard.pages.dev

---

## 銅 (Bronze) — `bronze/` / `stock_bronze`

| 項目 | 内容 |
|---|---|
| **目的** | 生データをそのまま保存。元データに常に戻れるセーフティネット |
| **BQテーブル** | `stock_prices` |
| **コード** | `bronze/ingest/collect.py` (yfinance + Python) |
| **レコード** | 20銘柄×2年分 = ~9,740行 |
| **特徴** | 一切の加工なし。API応答をそのまま格納 |
| **更新** | GH Actions pipeline.yml (schedule JST 18:30 / 手動) |

## 銀 (Silver) — `silver/` / `stock_silver`

| 項目 | 内容 |
|---|---|
| **目的** | テクニカル指標・特徴量を計算。全モデルの共通特徴量ストア |
| **BQテーブル** | `features_daily` (38カラム) |
| **コード** | `silver/features/features_daily.sql` (BQ SQL MERGE) |
| **レコード** | ~9,740行 (銅と同じ行数、横に拡張) |
| **主な特徴量** | SMA(5/20/60), RSI(14), MACD, ボリンジャーバンド, ATR, 出来高比, ラグ特徴量, 曜日/月ダミー |

**特徴量一覧:**

| グループ | カラム | window |
|---|---|---|
| 移動平均 | `sma_5/20/60` | 5/20/60 |
| 標準偏差 | `std_20` | 20 |
| RSI | `rsi_14` | 14 |
| MACD | `macd_line/signal/histogram` | 12/26/9 |
| ボリンジャー | `bb_upper/lower/pct_b/bandwidth` | 20 |
| ATR | `atr_14` | 14 |
| 出来高 | `volume_sma_5`, `volume_vs_sma_ratio`, `volume_chg_pct`, `volume_incr_streak`, `volume_surge_flag` | 5 |
| カレンダー | `day_of_week`, `month_of_year`, `month_end_zone`, `quarter_end_flag` | — |
| 目的変数 | `next_day_return` | 翌日 |

## 金 (Gold) — `gold/` / `stock_gold`

| 項目 | 内容 |
|---|---|
| **目的** | モデル構築・予測・戦略進化・レポート |
| **BQテーブル** | 18テーブル |
| **レコード** | シグナル12,384 / 累積リターン12,384 |

### 金の3サブ領域

| 領域 | フォルダ | 内容 |
|---|---|---|
| **モデル** | `gold/models/` | BQML 4戦略 (momentum/breakout/volume_confirm/reversal) |
| **アリーナ** | `gold/arena/` | ルールシグナル(10種), GA進化エンジン, deploy.py |
| **レポート** | `gold/reports/` | バックテスト, ダッシュボード生成, pipeline_monitor.py |

### 4戦略

| 戦略 | 前提 | 重視する特徴量 |
|---|---|---|
| momentum | 上がるものはさらに上がる | 価格ラグ、SMA、RSI、出来高急増 |
| breakout | 静寂破壊で大きく動く | 高値/安値、ボラティリティ収縮→拡大、レンジ breakout |
| volume-confirm | 出来高先行、価格追従 | volume_increase_score、価格・出来高乖離 |
| reversal | 極端は戻る | RSI過剰感、価格-SMA距離、極端度 |

### 戦略シグナル合成

`strategy_scores` 統合テーブルで各モデルの予測を横並び + 信号合成:
- **STRONG_MOMENTUM** — モメンタム+出来高両方強い
- **BREAKOUT_CONFIRM** — ボラブレイクアウト+出来高確認
- **REVERSAL_BUY / REVERSAL_SELL** — 逆張りシグナル
- **HOLD** — 該当なし

### ルールシグナル (arena.sql)

| # | シグナル | ロジック |
|---|---|---|
| 5 | DOWスペシャリスト | 過去20週の同日曜日平均リターンでバイアス |
| 6 | 月末ハンター | 月末特有の上昇/下落パターン |
| 7 | 静寂前の嵐 | BB収縮+出来高低迷→拡大期待 |
| 8 | センチメント | 市場全体の騰落率に連動 |
| 9 | 平均回帰 | RSI極端+BBバンドタッチ→逆張り |

---

## パイプライン

`pipeline.yml` (GH Actions) が依存順に自動実行:

```
collect (yfinance) → deploy (BQ: Silver→Gold→backtest) → report
```

- **Schedule:** JST 18:30 月〜金 (日本引け後)
- **WF trigger:** `workflow_dispatch` / push to `bronze/` `silver/` `gold/`
- **BQML models:** 初回のみ学習、以降は再学習スキップ (INFORMATION_SCHEMA.MODELS 確認)

## ダッシュボード

`gold/reports/gen_dashboard.py` が BQ を全件クエリして `pages/index.html` を生成。

- **公開:** https://stock-bqml-dashboard.pages.dev (CF Pages)
- **更新:** cron (平日 10/12/14/16/18/20時)
- **手動更新:**
  ```bash
  python3 gold/reports/gen_dashboard.py
  wrangler pages deploy pages/ --project-name=stock-bqml-dashboard --branch=main
  ```

## バックテスト結果

| テーブル | 内容 |
|---|---|
| `backtest_results` | 日次×全モデル予測横並び + 実際リターン + 合成シグナル |
| `backtest_model_summary` | モデル別: MAE/RMSE/方向一致率/的中平均リターン |
| `backtest_signal_performance` | シグナル別: 勝率/平均リターン/Sharpe比/DD |
| `backtest_cumulative_returns` | 累積リターン曲線（可視化用） |

## ディレクトリ構成

```
stock-bqml/
├── bronze/               # 銅層 — 生データ (yfinance)
│   └── ingest/           # collect.py, requirements.txt
├── silver/               # 銀層 — 特徴量
│   └── features/         # features_daily.sql
└── gold/                 # 金層 — モデル・分析・レポート
    ├── models/           # BQML 4戦略 training SQL
    ├── arena/            # deploy.py, arena.sql, arena_ga.sql, setup-gh-secrets.sh
    └── reports/          # backtest_accuracy.*, gen_dashboard.py, pipeline_monitor.py, deploy-pages.sh
```

## 無料枠

| 項目 | 使用量 | 無料枠 |
|---|---|---|
| BQ ストレージ | ~50 MB | 10 GB/月 |
| BQ クエリ | ~200 MB/日 | 1 TB/月 |
| BQML 学習 | ~1 MB/モデル | 10 GB/月 |
| GH Actions | ~25 min/run | 2000 分/月 |

---

> **銅は「あったもの」、銀は「そこから何が見えるか」、金は「それでどう動くか」**
