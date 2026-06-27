# stock-bqml パイプライン
#
# make collect   → yfinance株価収集 (bronze/ingest/data/*.csv)
# make deploy    → BQデプロイ (silver + gold + backtest)
# make backtest  → バックテスト精度表示
# make dashboard → 運用ダッシュボード生成 (ops/index.html)
# make battlefield → バトルアリーナ生成 → CF Pagesデプロイ
# make all       → collect → deploy

.PHONY: collect deploy backtest all clean dashboard battlefield

# デフォルト20銘柄, 上書: make collect TICKERS="7203.T 9984.T"
TICKERS ?=
DAYS ?= 5

collect:
	python3 bronze/ingest/collect.py $(if $(TICKERS),--tickers $(TICKERS),) --days $(DAYS)

# 全履歴: make bulk DAYS=3650
bulk:
	python3 bronze/ingest/collect.py $(if $(TICKERS),--tickers $(TICKERS),) --days $(DAYS)

deploy:
	python3 gold/arena/deploy.py

deploy-dev:
	BQ_SKIP_MODEL=1 python3 gold/arena/deploy.py

backtest:
	python3 gold/reports/backtest_accuracy.py

dashboard:
	python3 gold/reports/gen_dashboard.py
	@echo "→ ops/index.html"

battlefield:
	python3 gold/reports/gen_battlefield.py
	@echo "→ pages/index.html (deploy: make deploy-cf)"

deploy-cf:
	cmd.exe /c "wrangler pages deploy pages\ --project-name=stock-bqml-dashboard --branch=main"

# 全パイプライン: 収集→BQ
all: collect deploy
	@echo "=== pipeline OK ==="

# CSV削除 (data/のみ)
clean:
	rm -f bronze/ingest/data/*.csv
	@echo "data/ cleared"
