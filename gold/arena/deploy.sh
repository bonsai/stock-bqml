#!/usr/bin/env bash
# scripts/deploy.sh
# stock-bqml 全SQLをBQにデプロイ
# 使い方: ./scripts/deploy.sh <project_id> [dataset_suffix]
#   ./scripts/deploy.sh my-gcp-project
#   ./scripts/deploy.sh my-gcp-project dev   # stock_silver_dev, stock_gold_dev

set -euo pipefail

PROJECT_ID="${1:?Usage: $0 <project_id> [dataset_suffix]}"
SUFFIX="${2:-}"
SILVER="stock_silver${SUFFIX}"
GOLD="stock_gold${SUFFIX}"

# 依存順に実行
SQL_FILES=(
  # === Silver ===
  "silver/features_daily.sql"

  # === Arena 前処理 (rule signals) ===
  "gold/arena.sql"              # arena_dow_signal, arena_monthend_signal, etc.

  # === Arena GA 本体 ===
  "gold/arena_ga.sql"           # ga_gene_pool, ga_signals, ga_positions, ga_weekly_pnl
)

echo "=== Deploying to $PROJECT_ID ==="
echo "  Silver: $SILVER"
echo "  Gold:   $GOLD"

for sql_file in "${SQL_FILES[@]}"; do
  [ -f "$sql_file" ] || { echo "SKIP (not found): $sql_file"; continue; }

  echo "  → $sql_file"

  # {{project}} と {{dataset}} を置換して実行
  sed -e "s/{{project}}/$PROJECT_ID/g" \
      -e "s/stock_silver/$SILVER/g" \
      -e "s/stock_gold/$GOLD/g" \
      "$sql_file" |
    bq query --use_legacy_sql=false --project_id="$PROJECT_ID"

  echo "    OK"
done

echo "=== Deploy complete ==="
echo ""
echo "Next: 初期遺伝子プールを確認 → open Colab arena_ga_evolution.ipynb"
echo "  bq query 'SELECT COUNT(*) FROM $GOLD.ga_gene_pool'"
