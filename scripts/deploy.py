#!/usr/bin/env python3
"""scripts/deploy.py — BQに全SQLを依存順でデプロイ"""
import os, re, time
from google.cloud import bigquery

PROJECT = 'gen-lang-client-0315818888'
os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = '/home/sexy/.config/gcloud/application_default_credentials.json'

client = bigquery.Client(project=PROJECT)

def run(sql, label):
    sql = sql.replace('{{project}}', PROJECT)
    try:
        job = client.query(sql)
        job.result()
        print(f"  ok  {label}")
    except Exception as e:
        print(f"  ERR {label}: {e}")

def run_file(path, label):
    raw = open(path).read()
    run(raw, label)

def split_statements(sql):
    """Split SQL into individual CREATE statements"""
    parts = []
    current = []
    for line in sql.splitlines():
        current.append(line)
        if line.strip().endswith(';'):
            parts.append('\n'.join(current))
            current = []
    if current:
        parts.append('\n'.join(current))
    return [p.strip() for p in parts if p.strip()]

# 1. Silver
print("=== Silver ===")
run_file("silver/features_daily.sql", "features_daily")

# 2. Gold: Rule signals (from arena.sql)
print("\n=== Gold: Rule Signals ===")
raw = open("gold/arena.sql").read().replace('{{project}}', PROJECT)
for stmt in split_statements(raw):
    m = re.search(r'TABLE\s+`?[\w.-]+`?\.(\w+)', stmt, re.IGNORECASE)
    label = m.group(1) if m else '?'
    if 'backtest_results' in stmt.lower():
        print(f"  ~   {label}: SKIP (needs backtest_results)")
        continue
    run(stmt, label)

# 3. GA Arena
print("\n=== Gold: GA Arena ===")
raw = open("gold/arena_ga.sql").read().replace('{{project}}', PROJECT)
for stmt in split_statements(raw):
    m = re.search(r'TABLE\s+`?[\w.-]+`?\.(\w+)', stmt, re.IGNORECASE)
    label = m.group(1) if m else '?'
    run(stmt, label)

# Verify
print("\n=== Tables ===")
for ds in ['stock_silver', 'stock_gold']:
    try:
        tables = list(client.list_tables(ds))
        print(f"{ds}: {len(tables)} tables")
        for t in tables:
            job = client.query(f"SELECT COUNT(*) AS n FROM `{PROJECT}.{ds}.{t.table_id}`")
            n = list(job.result())[0].n
            print(f"  {t.table_id}: {n:,} rows")
    except:
        print(f"{ds}: (empty)")

print("\nDone!")
