# GA Arena — Genetic Algorithm Strategy Arena PRD

## 概要

10人の戦略エージェントが遺伝的アルゴリズムで進化しながら週次で生存競争を行う。各エージェントは特徴量重みベクトル（遺伝子）を持ち、週次のパフォーマンスで淘汰・交叉・突然変異を繰り返し、最適な戦略集団へ進化する。

## アーキテクチャ

```
週次ループ:
  [SQL] 1. 週タイプ分類 (ga_week_types)
  [SQL] 2. 全個体の日次シグナル生成 (ga_signals)
  [SQL] 3. 週次適応度評価 (ga_fitness)
  [PY]  4. 淘汰: 下位30%を特定
  [PY]  5. 交叉: 上位2個体の遺伝子をブレンド → 子個体生成
  [PY]  6. 突然変異: 子個体の遺伝子を微小ランダム変異
  [SQL] 7. 新世代を ga_gene_pool にINSERT
  [PY]  8. バックログ更新 → 週タイプ×戦略の帰納的マッピング学習
```

## コンポーネント

### 既存 (gold/arena_ga.sql)
| テーブル | 状態 | 説明 |
|---|---|---|
| `ga_gene_pool` | ✅ | 遺伝子プール: 8重み+2制御パラメータ |
| `ga_week_types` | ✅ | 週タイプ分類器 (vol_regime, market_regime) |
| `ga_signals` | ✅ | 遺伝子×特徴量→日次シグナル合成 |
| `ga_fitness` | ✅ | 週次適応度・P&L・Sharpe比評価 |
| `ga_leaderboard` | ✅ | 世代追跡・累積パフォーマンス |

### 未実装
| コンポーネント | 優先度 | 説明 |
|---|---|---|
| GA Engine (Colab) | P0 | 淘汰→交叉→突然変異→新世代生成のループ |
| 銘柄スクリーニング | P0 | 各戦略が全銘柄評価→ルールで3銘柄に絞る |
| バックログ | P0 | 先週のトレード履歴・エントリー理由・P&L |
| 週タイプ×戦略マッピング | P1 | 今週の特徴から最適戦略を帰納予測 |
| 可視化 (Colab) | P1 | 進化の過程・適応度推移・遺伝子多様性 |

## GA遺伝子設計

### 遺伝子: 8次元重みベクトル
```
gene = [
  weight_momentum,   // 0.0〜1.0
  weight_volume,     // 0.0〜1.0
  weight_reversal,   // 0.0〜1.0
  weight_breakout,   // 0.0〜1.0
  weight_dow,        // 0.0〜0.5 (抑制)
  weight_monthend,   // 0.0〜0.5 (抑制)
  weight_sentiment,  // 0.0〜0.7
  weight_mean_rev,   // 0.0〜0.6
]
```

### 制御パラメータ
```
threshold:    0.3〜2.0  // シグナル発動閾値
max_position: 0.5〜1.0  // 最大ポジションサイズ
```

### 適応度関数
```
fitness = avg_daily_pnl * win_rate / pnl_std
         - 0.1 * n_trades  // 過剰トレードペナルティ
```

## GAオペレーター

### 選択 (Selection)
- トップ3: 生存 + 親として交叉
- ミドル4: 生存のみ
- ボトム3: 淘汰

### 交叉 (Crossover)
- 2点交叉: 親Aの前半 + 親Bの中間 + 親Aの後半
- ブレンド交叉: 各遺伝子を親A/Bの加重平均（α=0.3）

### 突然変異 (Mutation)
- 確率15%で各遺伝子に ±0.1 のランダム変異
- 閾値外はクリッピング

## 銘柄スクリーニングルール

各戦略が毎日全銘柄を評価し、以下のルールで最大3銘柄に絞る:

1. **シグナル強度順**: final_signal の絶対値 TOP20
2. **出来高フィルタ**: volume_vs_sma_ratio > 0.5（流動性確保）
3. **価格フィルタ**: close > 100（低価格銘柄除外）
4. **重複排除**: 同じ戦略で同じ銘柄を2日連続エントリーしない
5. **キャップ**: 最大3銘柄。シグナル強度順でTOP3を採用

## バックログ設計

```
ga_trade_log:
  date        DATE        -- エントリー日
  gene_id     INT64       -- どの個体が
  symbol      STRING      -- どの銘柄を
  signal_type STRING      -- 'LONG' / 'SHORT'
  entry_price NUMERIC     -- エントリー価格
  exit_date   DATE        -- 決済日（翌日）
  exit_price  NUMERIC     -- 決済価格
  pnl         NUMERIC     -- 損益(%)
  exit_reason STRING      -- 'TP_SL' / 'SIGNAL_REVERSAL' / 'WEEK_END'
  week_start  DATE        -- 所属週
```

## 帰納的マッピング

週タイプ×戦略の関係を学習:

```
ga_week_strategy_map:
  week_cluster  INT64     -- ga_week_types のクラスタ
  gene_id       INT64     -- その週に勝った個体
  weight_vector STRING    -- 遺伝子の特徴 (JSON)
  win_count     INT64     -- このクラスタで勝った回数
```

→ 新週の週タイプが決まったら「このクラスタでは Momentum 重み高い個体が勝つ」を予測可能に。

## フェーズ計画

| Phase | 内容 | 期間 |
|---|---|---|
| **P0** | GA Engine (Colab) + 銘柄スクリーニング + バックログ | 今週 |
| **P1** | 週タイプ×戦略マッピング + 可視化 | 来週 |
| **P2** | 実運用: 毎週日曜自動実行 + Slack通知 | 2週間後 |
