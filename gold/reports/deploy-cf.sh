# deploy-cf.sh — バトルアリーナ生成 → CF Pagesデプロイ
set -e
DIR="$(dirname "$0")"
cd "$DIR"
python3 gen_battlefield.py

# CF Pages deployment needs a directory; use /tmp/cf-pages/
mkdir -p /tmp/cf-pages/
cp battlefield.html /tmp/cf-pages/index.html
cmd.exe /c "wrangler pages deploy C:\tmp\cf-pages --project-name=stock-bqml-dashboard --branch=main"
echo "✅ Deployed: https://stock-bqml-dashboard.pages.dev"
