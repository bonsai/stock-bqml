# 金・銀・銅 — 3層メダリオンアーキテクチャ

## 概要

stock-bqml は **ブロンズ（銅）→ シルバー（銀）→ ゴールド（金）** の3層で株価データを段階的に加工する。

```
[外部API] → 銅(Bronze) → 銀(Silver) → 金(Gold) → [分析・トレード]
```

各層は BQ データセットとして分離: `stock_bronze` / `stock_silver` / `stock_gold`

---

## 銅 (Bronze) — `bronze/` / `stock_bronze`

| 項目 | 内容 |
|---|---|
| **目的** | 生データをそのまま保存。元データに常に戻れるセーフティネット |
| **BQテーブル** | `raw_daily` |
| **コード** | `bronze/ingest/collector.go` (Go) |
| **レコード** | 3銘柄×5年分 = 3,915行 |
| **特徴** | 一切の加工・変換なし。元のAPI応答をそのまま格納 |
| **更新** | 外部APIからGo collectorがバッチ投入 |

**原則:** 銅は絶対に変更しない。データソースのスナップショット。

---

## 銀 (Silver) — `silver/` / `stock_silver`

| 項目 | 内容 |
|---|---|
| **目的** | テクニカル指標・特徴量を計算。全モデルの共通特徴量ストア |
| **BQテーブル** | `features_daily` (48カラム) |
| **コード** | `silver/features/features_daily.sql` (BQ SQL) |
| **レコード** | 3,915行 (銅と同じ行数、横に拡張) |
| **主な特徴量** | SMA(5/20/60), RSI(14), MACD, ボリンジャーバンド, ATR, 出来高比, ラグ特徴量(N=1〜5) |
| **依存** | `stock_bronze.raw_daily` から計算 |

**原則:** 銀の出力は **決定論的** — 同じ銅データから常に同じ銀が得られる。
全モデル (BQML/GA/ルール) が銀を参照する。

### 銀の特徴量一覧 (window指定あり)

| グループ | カラム | window |
|---|---|---|
| 移動平均 | `sma_5/20/60` | 5/20/60 |
| 標準偏差 | `std_20` | 20 |
| RSI | `rsi_14` | 14 |
| MACD | `macd_line/signal/histogram` | 12/26/9 |
| ボリンジャー | `bb_upper/lower/bandwidth` | 20 |
| ATR | `atr_14` | 14 |
| 出来高 | `volume_sma_5/20`, `volume_vs_sma_ratio` | 5/20 |
| 騰落率 | `return_N` (N=1..5) | N |
| 価格ラグ | `price_lag_N` (N=1..5), `price_zscore_N` (N=1,5,21) | N |
| トレンド強度 | `trend_strength_N` (N=5,20) | N |
| 年率リターン | `annualized_return` | 252営業日 |
| 月間リターン | `monthly_return` | 当月 |

---

## 金 (Gold) — `gold/` / `stock_gold`

| 項目 | 内容 |
|---|---|
| **目的** | モデル構築・予測・戦略進化・レポート |
| **BQテーブル** | 〜12テーブル (シグナル, ポジション, P&L, 遺伝子プール, 週タイプ, ルールシグナル) |
| **コード** | `gold/{arena,models,reports}/` (BQ SQL, Python) |
| **レコード** | 39,120シグナル / 39,090ポジション / 2,610週次P&L |

### 金の3サブ領域

| 領域 | フォルダ | 内容 |
|---|---|---|
| **モデル** | `gold/models/` | BQML (BOOSTED_TREE_REGRESSOR), 4戦略, 予測, 説明可能性 |
| **アリーナ** | `gold/arena/` | GA進化エンジン (10エージェント週次生存競争), ルールシグナル, デプロイ |
| **レポート** | `gold/reports/` | バックテス, 異常検知, 出来高監視, Colabノートブック |

**原則:** 金の出力は **解釈可能でアクション可能** — シグナル→ポジション→P&L の因果が追える。

---

## 層間依存関係

```
銅 → 銀 → 金 (一方通行。逆流禁止)
```

- **銅** → **銀**: `raw_daily` から `features_daily` を計算 (SQL MERGE)
- **銀** → **金**: `features_daily` から GAシグナル・BQML予測・ルールシグナルを生成
- **金** 内: 遺伝子プール × 特徴量 → `ga_signals` → `ga_positions` → `ga_weekly_pnl` → 淘汰・交叉

---

## 配置ファイル構造

```
stock-bqml/
├── bronze/       # 銅層
│   ├── ingest/   # 収集コード
│   ├── raw/      # (将来: スキーマ定義)
│   └── meta/     # メタ情報
├── silver/       # 銀層
│   ├── features/ # 特徴量SQL
│   ├── transforms/ # (将来)
│   └── meta/     # (将来: 特徴量カタログ)
└── gold/         # 金層
    ├── models/   # BQMLモデル
    ├── arena/    # GA進化アリーナ
    └── reports/  # バックテスト・レポート
```

---

> **一言:** 銅は「あったもの」、銀は「そこから何が見えるか」、金は「それでどう動くか」
