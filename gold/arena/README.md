# gold / arena

GA進化アリーナ — 10エージェント週次生存競争

| ファイル | 内容 |
|---|---|
| `arena_ga.sql` | GA核: 遺伝子プール・シグナル合成・ポジション・週次P&L |
| `arena.sql` | ルールベースシグナル (dow/monthend/sentiment/mean_rev) |
| `arena_ga_evolution.ipynb` | GAエンジン: 淘汰・交叉・突然変異ループ |
| `deploy.py` | BQ一括デプロイ |
| `seed_sample_data.sql` | サンプル株価データ |

```bash
python3 deploy.py
```
