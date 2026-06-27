#!/usr/bin/env bash
# deploy-pages.sh — ダッシュボード生成 → CF Pagesデプロイ
set -e
cd "$(dirname "$0")/.."
python3 gold/reports/gen_dashboard.py
cmd.exe /c "wrangler pages deploy pages\ --project-name=stock-bqml-dashboard --branch=main"
echo "✅ Deployed: https://stock-bqml-dashboard.pages.dev"
