# bronze / ingest

Go collector — 株価APIから生データをBQに投入

```bash
cd bronze/ingest
go run collector.go -symbol=7203.T -interval=1d -project=your-project -dataset=stock_bronze
```
