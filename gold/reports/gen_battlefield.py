#!/usr/bin/env python3
"""gold/reports/gen_battlefield.py — CF Pages: 週次バトル結果 + エージェント人格化"""
import json, os, tempfile
from datetime import datetime, timezone, timedelta
from google.cloud import bigquery

PROJECT = os.environ.get('BQ_PROJECT', 'gen-lang-client-0315818888')
TZ_JST = timezone(timedelta(hours=9))
NOW = datetime.now(TZ_JST)
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(__file__)))

_creds_json = os.environ.get('GCP_CREDENTIALS')
if _creds_json:
    _tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False)
    _tmp.write(_creds_json)
    _tmp.close()
    os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = _tmp.name

client = bigquery.Client(project=PROJECT)

# Load agent personas
with open(os.path.join(ROOT, "gold", "reports", "agents.json")) as f:
    AGENTS = json.load(f)

# ── 1. Leaderboard ──
leaderboard = []
try:
    job = client.query(
        f"SELECT entrant_name, ROUND(SUM(week_total_pnl), 4) AS total_pnl, "
        f"ROUND(AVG(win_rate), 4) AS avg_win_rate, "
        f"COUNT(*) AS n_weeks "
        f"FROM `{PROJECT}.stock_gold.arena_leaderboard` "
        f"GROUP BY entrant_name ORDER BY total_pnl DESC"
    )
    for row in job.result():
        leaderboard.append({
            "name": row.entrant_name,
            "pnl": float(row.total_pnl),
            "win_rate": float(row.avg_win_rate),
            "weeks": row.n_weeks,
        })
except: pass

# ── 2. Latest week results ──
latest_week = {}
try:
    job = client.query(
        f"SELECT entrant_name, week_total_pnl, win_rate, avg_daily_pnl, n_days "
        f"FROM `{PROJECT}.stock_gold.arena_leaderboard` "
        f"WHERE week_start = (SELECT MAX(week_start) FROM `{PROJECT}.stock_gold.arena_leaderboard`)"
    )
    for row in job.result():
        latest_week[row.entrant_name] = {
            "pnl": float(row.week_total_pnl),
            "win_rate": float(row.win_rate),
            "avg_daily": float(row.avg_daily_pnl),
            "days": row.n_days,
        }
except: pass

# ── Build HTML ──
def agent_card(name, rank, pnl_str, wr_str, spotlight=False):
    a = AGENTS.get(name, {"name": name, "emoji": "❓", "title": "", "quote": "", "personality": "", "color": "#666"})
    bg = "background:linear-gradient(135deg,#2d1b69,#0d1117)" if spotlight else ""
    cls = "card spotlight" if spotlight else "card"
    rank_badge = f"<span class='rank rank-{rank}'>{rank}</span>" if rank <= 3 else f"<span class='rank'>#{rank}</span>"
    return f"""<div class="{cls}" style="{bg}">
  <div class="agent-header">
    {rank_badge}
    <span class="agent-emoji">{a['emoji']}</span>
    <div class="agent-info">
      <div class="agent-name" style="color:{a['color']}">{a['name']}</div>
      <div class="agent-title">{a['title']}</div>
    </div>
  </div>
  <div class="agent-stats">
    <span class="stat">📈 {pnl_str}</span>
    <span class="stat">🎯 {wr_str}</span>
  </div>
  <div class="agent-quote">💬 "{a['quote']}"</div>
  <div class="agent-personality">{a['personality']}</div>
</div>"""

lb_rows = ""
for i, e in enumerate(leaderboard[:10], 1):
    pnl_s = f"{'+' if e['pnl'] >= 0 else ''}{e['pnl']:.4f}"
    wr_s = f"{e['win_rate']*100:.1f}%"
    spotlight = i == 1 and e['pnl'] > 0
    lb_rows += agent_card(e['name'], i, pnl_s, wr_s, spotlight)

if not lb_rows:
    lb_rows = "<p style='text-align:center;color:#8b949e;padding:40px'>まだバトルデータがありません⏳</p>"

html = f"""<!DOCTYPE html>
<html lang="ja">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>🏟️ stock-bqml バトルアリーナ</title>
<style>
* {{margin:0;padding:0;box-sizing:border-box}}
body {{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0d1117;color:#c9d1d9;min-height:100vh;display:flex;flex-direction:column}}
.hero {{background:linear-gradient(135deg,#1a1a2e,#16213e,#0f3460);padding:40px 20px;text-align:center;border-bottom:1px solid #30363d}}
.hero h1 {{font-size:36px;margin-bottom:8px}}
.hero h1 span {{font-size:40px}}
.hero p {{color:#8b949e;font-size:14px}}
.container {{max-width:900px;margin:0 auto;padding:20px}}
.card {{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:20px;margin-bottom:16px;transition:transform 0.2s}}
.card:hover {{transform:translateY(-2px)}}
.spotlight {{border-color:#6c5ce7}}
.agent-header {{display:flex;align-items:center;gap:12px;margin-bottom:12px}}
.rank {{background:#21262d;color:#8b949e;border-radius:50%;width:32px;height:32px;display:flex;align-items:center;justify-content:center;font-size:14px;font-weight:700;flex-shrink:0}}
.rank-1 {{background:#ffd700;color:#0d1117;box-shadow:0 0 12px rgba(255,215,0,0.5)}}
.rank-2 {{background:#c0c0c0;color:#0d1117}}
.rank-3 {{background:#cd7f32;color:#0d1117}}
.agent-emoji {{font-size:36px;flex-shrink:0;width:48px;text-align:center}}
.agent-info {{flex:1}}
.agent-name {{font-size:18px;font-weight:700}}
.agent-title {{font-size:12px;color:#8b949e}}
.agent-stats {{display:flex;gap:16px;margin-bottom:8px;font-size:13px}}
.agent-quote {{font-style:italic;color:#58a6ff;font-size:13px;margin-bottom:6px;padding:8px 12px;background:#0d1117;border-radius:8px}}
.agent-personality {{font-size:12px;color:#8b949e;line-height:1.5}}
.footer {{margin-top:auto;padding:20px;text-align:center;color:#484f58;font-size:12px;border-top:1px solid #21262d}}
.badge {{display:inline-block;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:600}}
.badge-hot {{background:#3d1f24;color:#f85149}}
.badge-cold {{background:#1c3d5a;color:#58a6ff}}
@media(max-width:600px){{.hero h1{{font-size:24px}}.card{{padding:14px}}.agent-emoji{{font-size:28px;width:40px}}}}
</style></head>
<body>
<div class="hero">
  <h1><span>🏟️</span> バトルアリーナ</h1>
  <p>10人のエージェントが週次で激突。勝ち残るのは誰だ。</p>
  <p style="margin-top:4px;color:#484f58;font-size:12px">Updated: {NOW.strftime('%Y-%m-%d %H:%M JST')}</p>
</div>
<div class="container">
  <div style="text-align:center;margin-bottom:20px;font-size:13px;color:#8b949e">
    全 {len(leaderboard)} エントラント
  </div>
  {lb_rows}
  <div style="text-align:center;margin:24px 0;padding:16px;background:#161b22;border-radius:8px;border:1px dashed #30363d">
    <p style="color:#8b949e;font-size:13px">📋 ランキングは毎週バトル終了後に更新されます</p>
  </div>
</div>
<div class="footer">
  <p>stock-bqml · BigQuery ML × GA進化アリーナ</p>
  <p style="margin-top:4px">⚡ 10エージェント週次生存競争</p>
</div>
</body></html>"""

path = os.path.join(ROOT, "pages", "index.html")
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    f.write(html)
print(f"Battlefield: {path} ({len(html)} bytes)")
