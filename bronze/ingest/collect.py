#!/usr/bin/env python3
"""bronze/ingest/collect.py — yfinance で無料株価収集 → CSV保存"""

import argparse, csv, os, sys, time
from datetime import datetime, timedelta

TICKERS = [
    "6758.T",  # ソニーG
    "7203.T",  # トヨタ
    "9984.T",  # ソフトバンクG
    "6861.T",  # キーエンス
    "4063.T",  # 信越化学
    "8035.T",  # 東京エレクトロン
    "9432.T",  # NTT
    "9433.T",  # KDDI
    "6098.T",  # リクルートHD
    "4502.T",  # 武田薬品
    "6954.T",  # ファナック
    "7741.T",  # HOYA
    "6762.T",  # TDK
    "6857.T",  # アドバンテスト
    "6594.T",  # ニデック
    "7974.T",  # 任天堂
    "9983.T",  # ファーストリテイリング
    "9434.T",  # ソフトバンク
    "4519.T",  # 中外製薬
    "8801.T",  # 三井不動産
]

CSV_DIR = os.path.join(os.path.dirname(__file__), "data")

def fetch_yfinance(tickers, days_back=730, interval="1d"):
    """yfinance で一括ダウンロード"""
    # 遅延import (optional dep)
    import yfinance as yf
    start = (datetime.today() - timedelta(days=days_back)).strftime("%Y-%m-%d")
    end = datetime.today().strftime("%Y-%m-%d")
    print(f"Fetching {len(tickers)} tickers ({start}〜{end})...")
    data = yf.download(
        tickers,
        start=start, end=end,
        interval=interval,
        group_by="ticker",
        threads=True,
        auto_adjust=True,
    )
    return data

def save_csvs(data, tickers, csv_dir):
    """銘柄ごとにCSV保存。既存とマージ（同じ日付の行は上書き）"""
    os.makedirs(csv_dir, exist_ok=True)
    # level=0 = tickers (yfinance 1.4+ reverses the MultiIndex levels)
    ticker_level = 0 if hasattr(data.columns, 'get_level_values') else None
    for sym in tickers:
        try:
            if ticker_level is not None:
                df = data.xs(sym, axis=1, level=ticker_level).copy()
            else:
                df = data[sym].copy()
        except (KeyError, AttributeError):
            print(f"  ~ {sym}: no data, skip")
            continue
        if df.empty:
            print(f"  ~ {sym}: empty, skip")
            continue
        df.index.name = "date"
        # rename columns to lowercase
        df.columns = [c.lower() for c in df.columns]
        # add symbol column
        df.insert(0, "symbol", sym)
        # convert index to date string
        df.index = df.index.strftime("%Y-%m-%d")
        # sort by date
        df = df.sort_index()

        fpath = os.path.join(csv_dir, f"{sym}.csv")
        if os.path.exists(fpath):
            old = set()
            with open(fpath) as f:
                for row in csv.DictReader(f):
                    old.add(row["date"])
            new_rows = df[~df.index.isin(old)]
            if new_rows.empty:
                print(f"  {sym}: {len(old)} rows, no new data")
                continue
            # append new rows
            new_rows.to_csv(fpath, mode="a", header=False)
            print(f"  + {sym}: {len(new_rows)} new rows → {len(old)+len(new_rows)} total")
        else:
            df.to_csv(fpath)
            print(f"  + {sym}: {len(df)} rows (new file)")

def save_combined(data, tickers, csv_dir):
    """全銘柄を1つのCSVに統合"""
    ticker_level = 0 if hasattr(data.columns, 'get_level_values') else None
    frames = []
    for sym in tickers:
        try:
            if ticker_level is not None:
                df = data.xs(sym, axis=1, level=ticker_level).copy()
            else:
                df = data[sym].copy()
        except (KeyError, AttributeError):
            continue
        if df.empty:
            continue
        df.index.name = "date"
        df.columns = [c.lower() for c in df.columns]
        df.insert(0, "symbol", sym)
        df.index = df.index.strftime("%Y-%m-%d")
        frames.append(df)
    if not frames:
        return
    import pandas as pd
    combined = pd.concat(frames).sort_values(["symbol", "date"])
    fpath = os.path.join(csv_dir, "_combined.csv")
    old = set()
    if os.path.exists(fpath):
        with open(fpath) as f:
            for row in csv.DictReader(f):
                old.add((row["symbol"], row["date"]))
    new = combined[~combined.apply(lambda r: (r["symbol"], r.name), axis=1).isin(old)]
    if new.empty:
        print(f"  combined: no new data")
        return
    if old:
        new.to_csv(fpath, mode="a", header=False)
        print(f"  + combined: {len(new)} new rows")
    else:
        combined.to_csv(fpath, index=True)
        print(f"  + combined: {len(combined)} rows (new file)")

def to_bq(csv_dir, project, dataset):
    """CSVをBQにロード"""
    from google.cloud import bigquery
    client = bigquery.Client(project=project)
    table_id = f"{project}.{dataset}.raw_daily"
    # CSVファイルを順次ロード
    import glob, json
    for fpath in sorted(glob.glob(os.path.join(csv_dir, "*.csv"))):
        sym = os.path.basename(fpath).replace(".csv", "")
        if sym.startswith("_"):
            continue
        job_config = bigquery.LoadJobConfig(
            source_format=bigquery.SourceFormat.CSV,
            skip_leading_rows=1,
            autodetect=True,
            write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
        )
        with open(fpath, "rb") as f:
            job = client.load_table_from_file(f, table_id, job_config=job_config)
        job.result()
        print(f"  BQ: {sym} loaded")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="yfinance株価収集 → CSV")
    parser.add_argument("--tickers", nargs="*", default=TICKERS,
                        help=f"銘柄コード (default: {len(TICKERS)} major)")
    parser.add_argument("--days", type=int, default=730,
                        help="取得日数 (default: 730≒2年)")
    parser.add_argument("--interval", default="1d",
                        help="間隔 (1d, 1wk, 1mo)")
    parser.add_argument("--csv-dir", default=CSV_DIR,
                        help=f"CSV保存先 (default: {CSV_DIR})")
    parser.add_argument("--bq-project", help="BQプロジェクトID (指定でBQロード)")
    parser.add_argument("--bq-dataset", default="stock_bronze",
                        help="BQデータセット (default: stock_bronze)")
    args = parser.parse_args()

    data = fetch_yfinance(args.tickers, args.days, args.interval)
    save_csvs(data, args.tickers, args.csv_dir)
    save_combined(data, args.tickers, args.csv_dir)

    if args.bq_project:
        to_bq(args.csv_dir, args.bq_project, args.bq_dataset)
