# silver / features

特徴量SQL — テクニカル指標・出来高指標を生成

```bash
cat features_daily.sql | sed 's/{{project}}/your-project/g' | bq query --use_legacy_sql=false
```

または:
```bash
python3 ../../gold/arena/deploy.py
```
