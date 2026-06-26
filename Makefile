# stock-bqml パイプライン
# make collect   → yfinance株価収集 (bronze/ingest/data/*.csv)
# make deploy    → BQデプロイ (silver+gold)
# make backtest  → バックテスト精度比較
# make all       → collect → deploy → backtest

.PHONY: collect deploy backtest all clean

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

deploy-full:
	BQ_SKIP_ARENA= python3 gold/arena/deploy.py

backtest:
	bq query --use_legacy_sql=false \
	  --project_id=$${BQ_PROJECT:-gen-lang-client-0315818888} \
	  "$$(cat gold/reports/backtest_accuracy.sql | sed 's/{{project}}/'"$${BQ_PROJECT:-gen-lang-client-0315818888}"'/g')"

# 全パイプライン: 収集→BQ→検証
all: collect deploy
	@echo "=== pipeline OK ==="

# CSV削除 (data/のみ)
clean:
	rm -f bronze/ingest/data/*.csv
	@echo "data/ cleared"
