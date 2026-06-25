# Bronze: Go クライアント

## 依存関係

```bash
cd bronze
go mod init github.com/0501jp/stock-bqml/bronze
go get cloud.google.com/go/bigquery
```

## 実行

```bash
# ドライラン（データ取得のみ、BQへは挿入しない）
go run collector.go -symbol=7203.T -dry-run

# BQ投入
export GCP_PROJECT=your-project
export ALPHA_VANTAGE_API_KEY=your-key
go run collector.go -symbol=7203.T -interval=1d
```

## TODO

- [ ] Yahoo Finance / Alpha Vantage API 本実装 (#1)
- [ ] エラーリトライ・バッチ化 (#2)
- [ ] テスト (#3)
