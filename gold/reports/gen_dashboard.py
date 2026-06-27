#!/usr/bin/env python3
"""gold/reports/gen_dashboard.py — stock-bqml 状況ダッシュボード (HTML)"""
import json, os, subprocess, tempfile
from datetime import datetime, timezone, timedelta
from google.cloud import bigquery

PROJECT = os.environ.get('BQ_PROJECT', 'gen-lang-client-0315818888')
TZ_JST = timezone(timedelta(hours=9))
NOW = datetime.now(TZ_JST)

_creds_json = os.environ.get('GCP_CREDENTIALS')
if _creds_json:
    _tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False)
    _tmp.write(_creds_json)
    _tmp.close()
    os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = _tmp.name

client = bigquery.Client(project=PROJECT)

# ── 1. Pipeline status ──
pipeline = {"status": "?", "conclusion": "?", "run_id": "?", "created": "?"}
try:
    res = subprocess.run(
        ["gh", "run", "list", "--repo", "bonsai/stock-bqml",
         "--workflow", "pipeline.yml", "--limit", "1",
         "--json", "databaseId,status,conclusion,createdAt",
         "--jq", ".[0]"],
        capture_output=True, text=True, timeout=10
    )
    if res.returncode == 0:
        r = json.loads(res.stdout)
        pipeline = {
            "run_id": r.get("databaseId", "?"),
            "status": r.get("status", "?"),
            "conclusion": r.get("conclusion", "?"),
            "created": r.get("createdAt", "?")[:19].replace("T", " ") if r.get("createdAt") else "?",
        }
except: pass

# ── 2. BQ tables ──
tables_info = []
for ds in ["stock_bronze", "stock_silver", "stock_gold"]:
    try:
        for t in client.list_tables(ds):
            try:
                job = client.query(f"SELECT COUNT(*) AS n FROM `{PROJECT}.{ds}.{t.table_id}`")
                n = list(job.result())[0].n
                # Try to get latest date
                try:
                    dj = client.query(f"SELECT MAX(date) AS d FROM `{PROJECT}.{ds}.{t.table_id}`")
                    latest = str(list(dj.result())[0].d or "")
                except:
                    latest = ""
                tables_info.append({"ds": ds, "table": t.table_id, "rows": n, "latest": latest})
            except Exception as e:
                tables_info.append({"ds": ds, "table": t.table_id, "rows": 0, "latest": f"ERR:{str(e)[:40]}"})
    except:
        pass

# ── 3. BQML Models ──
models = []
try:
    for row in client.query(f"SELECT model_name, model_type, last_refresh_time FROM `{PROJECT}.INFORMATION_SCHEMA.MODELS`").result():
        models.append({
            "name": row.model_name,
            "type": row.model_type,
            "refresh": str(row.last_refresh_time)[:19] if row.last_refresh_time else "-",
        })
except: pass

# ── 4. Strategy scores ──
strategy_scores = []
try:
    job = client.query(f"SELECT * FROM `{PROJECT}.stock_gold.backtest_signal_performance` ORDER BY signal")
    for row in job.result():
        strategy_scores.append(dict(row))
except: pass

# ── Build HTML ──
status_icon = {"success": "✅", "failure": "❌", "cancelled": "⏹️", "in_progress": "⏳", "pending": "⏸️"}.get(pipeline["status"], "❓")
conclusion_icon = {"success": "✅", "failure": "❌", "cancelled": "⏹️"}.get(pipeline["conclusion"], "⏳")

tables_rows = "".join(
    f"<tr><td>{t['ds']}</td><td>{t['table']}</td><td style='text-align:right'>{t['rows']:,}</td><td>{t['latest']}</td></tr>"
    for t in sorted(tables_info, key=lambda x: (x['ds'], x['table']))
)

models_rows = "".join(
    f"<tr><td>{m['name']}</td><td>{m['type']}</td><td>{m['refresh']}</td></tr>"
    for m in sorted(models, key=lambda x: x['name'])
)

ss_rows = ""
for s in strategy_scores:
    sig = s.get('signal', '?')
    r = s.get('raw_cumul', 0)
    short_pct = s.get('short_win_pct', 0)
    ss_rows += f"<tr><td>{sig}</td><td>{float(r):+.4f}</td><td>{float(short_pct):.1f}%</td></tr>"

html = f"""<!DOCTYPE html>
<html lang="ja">
<head><meta charset="utf-8"><meta http-equiv="refresh" content="60"><title>stock-bqml Dashboard</title>
<style>
* {{margin:0;padding:0;box-sizing:border-box}}
body {{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0d1117;color:#c9d1d9;padding:20px}}
h1 {{font-size:24px;margin-bottom:8px}}
h2 {{font-size:18px;margin:24px 0 12px;border-bottom:1px solid #30363d;padding-bottom:6px}}
.meta {{color:#8b949e;font-size:13px;margin-bottom:16px}}
.card {{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px;margin-bottom:16px}}
table {{width:100%;border-collapse:collapse;font-size:13px}}
th,td {{padding:8px 12px;text-align:left;border-bottom:1px solid #21262d}}
th {{background:#1c2128;color:#8b949e;font-weight:600;position:sticky;top:0}}
tr:hover {{background:#1c2128}}
.badge {{display:inline-block;padding:2px 10px;border-radius:12px;font-size:12px;font-weight:600}}
.badge-pass {{background:#1b3a2d;color:#3fb950}}
.badge-fail {{background:#3d1f24;color:#f85149}}
.badge-run {{background:#1c3d5a;color:#58a6ff}}
.status-bar {{display:flex;gap:20px;flex-wrap:wrap;margin-bottom:12px}}
.stat {{font-size:14px}}
.stat-label {{color:#8b949e}}
.stat-val {{font-weight:600}}
</style></head>
<body>
<h1>📊 stock-bqml Pipeline Dashboard</h1>
<div class="meta">Updated: {NOW.strftime('%Y-%m-%d %H:%M JST')} · Project: {PROJECT}</div>

<div class="card">
<h2>Pipeline Status</h2>
<div class="status-bar">
<div class="stat"><span class="stat-label">Run #</span> <span class="stat-val">{pipeline['run_id']}</span></div>
<div class="stat"><span class="stat-label">Status</span> <span class="stat-val">{status_icon} {pipeline['status']}</span></div>
<div class="stat"><span class="stat-label">Result</span> <span class="stat-val">{conclusion_icon} {pipeline['conclusion']}</span></div>
<div class="stat"><span class="stat-label">Started</span> <span class="stat-val">{pipeline['created'][:16]}</span></div>
<div class="stat"><span class="stat-label">Auto-refresh</span> <span class="stat-val">60s</span></div>
</div>
<p style="margin-top:8px"><a href="https://github.com/bonsai/stock-bqml/actions" target="_blank" style="color:#58a6ff">→ GitHub Actions</a></p>
</div>

<div class="card">
<h2>BigQuery Tables</h2>
<div style="max-height:400px;overflow-y:auto">
<table>
<thead><tr><th>Dataset</th><th>Table</th><th>Rows</th><th>Latest Date</th></tr></thead>
<tbody>{tables_rows}</tbody>
</table>
</div>
</div>

<div class="card">
<h2>BQML Models</h2>
<table><thead><tr><th>Model</th><th>Type</th><th>Last Refresh</th></tr></thead>
<tbody>{models_rows}</tbody></table>
</div>

<div class="card">
<h2>Strategy Signal Performance</h2>
<table><thead><tr><th>Signal</th><th>Cumul Return</th><th>Win%</th></tr></thead>
<tbody>{ss_rows}</tbody></table>
<p style="margin-top:10px;color:#8b949e;font-size:12px">
• <b>MOMENTUM</b> — 価格ラグ+SMA+RSI+出来高 · <b>BREAKOUT</b> — ボラ収縮→拡大
• <b>VOLUME_CONFIRM</b> — 出来高先行 · <b>REVERSAL</b> — RSI過剰感+乖離
</p>
</div>

<div class="card" style="background:#1c3d5a;border-color:#58a6ff">
<h2 style="color:#58a6ff">💰 無料枠見積もり (BigQuery + BQML)</h2>
<table>
<thead><tr><th>項目</th><th>使用量</th><th>無料枠</th><th>超過?</th></tr></thead>
<tbody>
<tr><td>ストレージ</td><td>~50 MB</td><td>10 GB/月</td><td style="color:#3fb950">❌ 超過なし</td></tr>
<tr><td>クエリ処理</td><td>~200 MB/日</td><td>1 TB/月</td><td style="color:#3fb950">❌ 超過なし</td></tr>
<tr><td>BQML学習</td><td>~1 MB/モデル</td><td>10 GB/月</td><td style="color:#3fb950">❌ 超過なし</td></tr>
<tr><td>ストリーミング</td><td>不使用</td><td>-</td><td style="color:#3fb950">❌ 該当なし</td></tr>
</tbody>
</table>
<p style="margin-top:8px;color:#8b949e;font-size:13px">
✅ 現状のデータ量（20銘柄×2年×4戦略）はすべて無料枠に収まります。
BQML CREATE MODELの最初の10GBは無料。クエリ月1TBも問題なし。
GH Actionsはパブリックリポジトリで無料（2000分/月）。
<strong>無料範囲内で運用可能です。</strong>
</p>
</div>
</body></html>"""

path = os.path.join(os.path.dirname(__file__), "..", "..", "pages", "index.html")
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    f.write(html)
print(f"Dashboard: {path}")
print(f"Size: {len(html)} bytes")
