#!/usr/bin/env python3
"""gold/reports/backtest_accuracy.py — Run backtest_accuracy.sql via BQ CLI-free"""
import os, sys, tempfile
from google.cloud import bigquery

PROJECT = os.environ.get('BQ_PROJECT', 'gen-lang-client-0315818888')

_creds = os.environ.get('GCP_CREDENTIALS')
if _creds:
    f = tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False)
    f.write(_creds)
    f.close()
    os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = f.name

client = bigquery.Client(project=PROJECT)

sql = open(os.path.join(os.path.dirname(__file__), 'backtest_accuracy.sql')).read()
sql = sql.replace('{{project}}', PROJECT)

for stmt in sql.split(';'):
    s = stmt.strip()
    if not s or s.startswith('--'):
        continue
    try:
        job = client.query(s)
        rows = list(job.result())
        if hasattr(job, 'statement_type') and job.statement_type:
            print(f'  ok  {len(rows)} rows | {job.statement_type}')
    except Exception as e:
        print(f'  ERR: {e}')
