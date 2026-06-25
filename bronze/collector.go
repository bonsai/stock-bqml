package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"cloud.google.com/go/bigquery"
	"google.golang.org/api/iterator"
	"google.golang.org/api/option"
)

// StockQuote は株価APIのレスポンスを受ける構造体
type StockQuote struct {
	Symbol    string    `json:"symbol"`
	Open      float64   `json:"open"`
	High      float64   `json:"high"`
	Low       float64   `json:"low"`
	Close     float64   `json:"close"`
	Volume    int64     `json:"volume"`
	Timestamp time.Time `json:"timestamp"`
	RawJSON   string    `json:"_raw_json"` // API生レスポンスをそのまま保持
}

var (
	symbol    = flag.String("symbol", "7203.T", "Ticker symbol")
	interval  = flag.String("interval", "1d", "Data interval (1d, 1h)")
	project   = flag.String("project", os.Getenv("GCP_PROJECT"), "GCP Project ID")
	dataset   = flag.String("dataset", "stock_bronze", "BigQuery dataset")
	table     = flag.String("table", "raw_daily", "BigQuery table")
	apiKey    = flag.String("api-key", os.Getenv("ALPHA_VANTAGE_API_KEY"), "API key for data provider")
	dryRun    = flag.Bool("dry-run", false, "Print payload instead of inserting")
)

func main() {
	flag.Parse()
	ctx := context.Background()

	if *project == "" {
		log.Fatal("GCP project required (--project or GCP_PROJECT env)")
	}
	if *apiKey == "" {
		log.Println("WARN: no API key provided, running in dry-run")
		*dryRun = true
	}

	quotes, err := fetchQuotes(ctx, *symbol, *interval, *apiKey)
	if err != nil {
		log.Fatalf("fetch failed: %v", err)
	}
	log.Printf("fetched %d quotes for %s", len(quotes), *symbol)

	if *dryRun {
		for _, q := range quotes {
			b, _ := json.MarshalIndent(q, "", "  ")
			fmt.Println(string(b))
		}
		return
	}

	client, err := bigquery.NewClient(ctx, *project, option.WithScopes(bigquery.Scope))
	if err != nil {
		log.Fatalf("bigquery client: %v", err)
	}
	defer client.Close()

	inserter := client.Dataset(*dataset).Table(*table).Inserter()
	inserter.SkipInvalidRows = true
	inserter.IgnoreUnknownValues = true

	if err := inserter.Put(ctx, quotes); err != nil {
		log.Fatalf("insert failed: %v", err)
	}
	log.Printf("inserted %d rows to %s.%s.%s", len(quotes), *project, *dataset, *table)
}

// fetchQuotes はダミー実装。実際には Yahoo Finance / Alpha Vantage 等を呼ぶ。
// TODO(#1): APIプロバイダー選定と本実装。
func fetchQuotes(ctx context.Context, symbol, interval, apiKey string) ([]*StockQuote, error) {
	// ここに HTTP GET + JSON parse で置き換える
	// Alpha Vantage: https://www.alphavantage.co/query?function=TIME_SERIES_DAILY&symbol=XXX&apikey=XXX
	// Yahoo Finance: yfinance 互換エンドポイント
	return []*StockQuote{}, nil
}
