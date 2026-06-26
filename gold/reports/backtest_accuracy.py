#!/usr/bin/env python3
"""gold/reports/backtest_accuracy.py — Query backtest results for accuracy report"""
import os, sys, json, tempfile
from google.cloud import bigquery

PROJECT = os.environ.get('BQ_PROJECT', 'gen-lang-client-0315818888')

# CI: GCP_CREDENTIALS env → temp file → client
_creds_json = os.environ.get('GCP_CREDENTIALS')
if _creds_json:
    _tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False)
    _tmp.write(_creds_json)
    _tmp.close()
    os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = _tmp.name

client = bigquery.Client(project=PROJECT)

print("=== Backtest Model Summary ===")
job = client.query(f"SELECT * FROM `{PROJECT}.stock_gold.backtest_model_summary`")
for row in job.result():
    print(f"  {dict(row)}")

print("\n=== Signal Performance ===")
job = client.query(f"SELECT * FROM `{PROJECT}.stock_gold.backtest_signal_performance` ORDER BY signal")
for row in job.result():
    print(f"  {dict(row)}")

print("\n=== Recent Cumulative Returns ===")
job = client.query(f"SELECT * FROM `{PROJECT}.stock_gold.backtest_cumulative_returns` ORDER BY date DESC LIMIT 5")
for row in job.result():
    print(f"  {row.date}: raw={row.raw_cumul:.4f} momentum={row.momentum_cumul:.4f} signal={row.signal_cumul:.4f}")

print("\nDone!")
