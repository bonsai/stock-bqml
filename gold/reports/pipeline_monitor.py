#!/usr/bin/env python3
"""
gold/reports/pipeline_monitor.py — BQパイプライン健全性チェック
GH Actions + BQクエリでデータ整備状況を把握

Usage:
  python gold/reports/pipeline_monitor.py
  # → status_summary.json + 標準出力
"""
import json, os, subprocess, sys, tempfile
from datetime import datetime, timezone, timedelta
from google.cloud import bigquery

PROJECT = os.environ.get('BQ_PROJECT', 'gen-lang-client-0315818888')
TZ_JST = timezone(timedelta(hours=9))

def check_pipeline_last_run():
    """Return latest pipeline workflow status."""
    try:
        res = subprocess.run(
            ["gh", "run", "list", "--repo", "bonsai/stock-bqml",
             "--workflow", "pipeline.yml", "--limit", "1",
             "--json", "databaseId,status,conclusion,createdAt,updatedAt",
             "--jq", ".[0]"],
            capture_output=True, text=True, timeout=15
        )
        if res.returncode != 0:
            return {"error": res.stderr.strip()}
        run = json.loads(res.stdout)
        if not run:
            return {"error": "no pipeline runs found"}
        return {
            "id": run["databaseId"],
            "status": run["status"],
            "conclusion": run["conclusion"],
            "created_at": run["createdAt"],
            "updated_at": run["updatedAt"],
        }
    except Exception as e:
        return {"error": str(e)}

def check_bq_tables(client):
    """Return row counts for key tables."""
    tables = [
        ("Bronze", "stock_bronze", "stock_prices"),
        ("Silver", "stock_silver", "features_daily"),
        ("Gold", "stock_gold", "arena_dow_signal"),
        ("Gold", "stock_gold", "backtest_results"),
        ("Gold", "stock_gold", "backtest_model_summary"),
        ("Gold", "stock_gold", "ga_signals"),
    ]
    results = []
    for tier, ds, table in tables:
        try:
            job = client.query(
                f"SELECT COUNT(*) AS n, MAX(date) AS latest "
                f"FROM `{PROJECT}.{ds}.{table}`"
            )
            row = list(job.result())[0]
            results.append({
                "tier": tier,
                "dataset": ds,
                "table": table,
                "rows": row.n,
                "latest_date": str(row.latest) if row.latest else None,
            })
        except Exception as e:
            results.append({
                "tier": tier,
                "dataset": ds,
                "table": table,
                "error": str(e)[:80],
            })
    return results

def check_models(client):
    """Return BQML model info."""
    try:
        job = client.query(
            f"SELECT model_name, model_type, last_refresh_time, input_label_cols, feature_columns "
            f"FROM `{PROJECT}.INFORMATION_SCHEMA.MODELS`"
        )
        models = []
        for row in job.result():
            models.append({
                "name": row.model_name,
                "type": row.model_type,
                "last_refresh": str(row.last_refresh_time)[:19] if row.last_refresh_time else None,
            })
        return models
    except Exception as e:
        return [{"error": str(e)[:80]}]

def main():
    print(f"{'='*50}")
    print(f"Stock-BQML Pipeline Monitor — {datetime.now(TZ_JST).strftime('%Y-%m-%d %H:%M JST')}")
    print(f"{'='*50}\n")

    # 1. Pipeline status
    pipeline = check_pipeline_last_run()
    print("1. Pipeline Last Run:")
    print(f"   Run #{pipeline.get('id','?')} — {pipeline.get('status','?')}/{pipeline.get('conclusion','?')}")
    if pipeline.get("created_at"):
        created = datetime.fromisoformat(pipeline["created_at"]).astimezone(TZ_JST)
        print(f"   Created: {created.strftime('%Y-%m-%d %H:%M JST')}")
    print()

    # 2. BQ table health
    _creds_json = os.environ.get('GCP_CREDENTIALS')
    if _creds_json:
        _tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False)
        _tmp.write(_creds_json)
        _tmp.close()
        os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = _tmp.name

    client = bigquery.Client(project=PROJECT)

    print("2. BQ Table Status:")
    for t in check_bq_tables(client):
        tier = t["tier"]
        name = t["table"]
        rows = f"{t.get('rows','?'):,} rows" if "rows" in t else f"ERR: {t.get('error','?')}"
        latest = f"  latest: {t.get('latest_date','?')}" if t.get("latest_date") else ""
        print(f"   [{tier:6s}] {name:30s} {rows}{latest}")
    print()

    # 3. BQML models
    print("3. BQML Models:")
    for m in check_models(client):
        if "error" in m:
            print(f"   ERR: {m['error']}")
        else:
            print(f"   {m['name']:30s} {m['type']:30s} refreshed: {m.get('last_refresh','?')}")
    print()

    # 4. Overall health
    print("4. Health Summary:")
    status = "✅ HEALTHY" if pipeline.get("conclusion") == "success" else "⚠️ WARNING"
    print(f"   Pipeline: {status}")
    print()

if __name__ == "__main__":
    main()
