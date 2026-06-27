# deploy-cf.sh — バトルアリーナ生成 → CF Pagesデプロイ
set -e
cd "$(dirname "$0")"
python3 gen_battlefield.py
cmd.exe /c "wrangler pages deploy battlefield.html --project-name=stock-bqml-dashboard --branch=main"
echo "✅ Deployed: https://stock-bqml-dashboard.pages.dev"
