#!/usr/bin/env python3
"""gold/arena/deploy.py — BQに全SQLを依存順でデプロイ (CI対応)"""

import json, os, re, sys, tempfile
from google.cloud import bigquery

PROJECT = os.environ.get('BQ_PROJECT', 'gen-lang-client-0315818888')

# CI: GCP_CREDENTIALS env → temp file → client
_creds_json = os.environ.get('GCP_CREDENTIALS')
if _creds_json:
    _tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False)
    _tmp.write(_creds_json)
    _tmp.close()
    os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = _tmp.name
elif not os.environ.get('GOOGLE_APPLICATION_CREDENTIALS'):
    os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = os.path.expanduser(
        '~/.config/gcloud/application_default_credentials.json'
    )

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
    """Split SQL into individual statements, handling string literals."""
    parts = []
    current = []
    in_string = False
    string_char = None
    for line in sql.splitlines():
        # Track string literals to avoid splitting on ; inside strings
        i = 0
        while i < len(line):
            ch = line[i]
            if in_string:
                if ch == '\\':
                    i += 2
                    continue
                if ch == string_char:
                    in_string = False
                    string_char = None
            else:
                if ch in ("'", '"'):
                    in_string = True
                    string_char = ch
            i += 1
        current.append(line)
        if line.strip().endswith(';') and not in_string:
            parts.append('\n'.join(current))
            current = []
    if current:
        parts.append('\n'.join(current))
    # Filter: skip empty / comment-only / single-semicolon statements
    filtered = []
    for stmt in parts:
        clean = stmt.strip()
        if not clean or clean == ';':
            continue
        # Skip if every non-empty line is a comment or bare semicolon
        lines = [l.strip() for l in clean.splitlines() if l.strip()]
        if all(l.startswith('--') or l == ';' for l in lines):
            continue
        filtered.append(stmt)
    return filtered

# 1. Silver
print("=== Silver ===")
run_file("silver/features/features_daily.sql", "features_daily")

# 2. Gold: Rule signals (from arena.sql)
print("\n=== Gold: Rule Signals ===")
raw = open("gold/arena/arena.sql").read().replace('{{project}}', PROJECT)
for stmt in split_statements(raw):
    m = re.search(r'TABLE\s+`?[\w.-]+`?\.(\w+)', stmt, re.IGNORECASE)
    label = m.group(1) if m else '?'
    if 'backtest_results' in stmt.lower():
        print(f"  ~   {label}: SKIP (needs backtest_results)")
        continue
    run(stmt, label)

# 3. GA Arena
print("\n=== Gold: GA Arena ===")
raw = open("gold/arena/arena_ga.sql").read().replace('{{project}}', PROJECT)
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
