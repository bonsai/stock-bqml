# stock-bqml Architecture

## Data Flow

```
[ Alpha Vantage / Yahoo API ]
            |
            v
+----------------------------+
| Bronze: stock_bronze.raw_daily |
| Go collector (JSON streaming)  |
+----------------------------+
            |
            v
+----------------------------+
| Silver: stock_silver.features_daily |
| SQL window functions (SMA, RSI, lag) |
+----------------------------+
            |
            v
+----------------------------+
| Gold: stock_gold.xgb_predictor     |
| BQML BOOSTED_TREE_REGRESSOR        |
| ML.PREDICT / ML.EXPLAIN_PREDICT    |
+----------------------------+
            |
            v
[ BI / Colab / Slack alerting ]
```

## Partitioning & Clustering

- `raw_daily` - PARTITION BY DATE(timestamp), CLUSTER BY symbol
- `features_daily` - PARTITION BY date, CLUSTER BY symbol
- `predictions` - PARTITION BY date, CLUSTER BY symbol

## Cost Guards

- Max query bytes billed: set per-query limit in Colab / dbt
- Short-circuit historical: 5 years sliding window in Silver MERGE
- Dry-run mode in Go (--dry-run)

## Security

- Service account per layer (bq-data-loader, bqml-trainer, bq-viewer)
- Authorized Views for Gold exposure
- No PII in public dataset (stock prices only)
