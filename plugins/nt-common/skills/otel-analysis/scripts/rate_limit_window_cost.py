#!/usr/bin/env python3
"""7日枠を1本ずつ切り出し、その枠の消費と「使用率100%相当の総コスト」を出す。

使用率は claude-rate-limits インデックス(ステータスラインが記録している)にあり、消費は
logs-generic.otel-default の api_request にある。Elasticsearch はドキュメント同士を
突き合わせられないため、枠の区切りを seven_day.resets_at から取り、その期間で消費を
集計し直してこのスクリプト側で結合する。

100%相当は「使用率と消費が比例する」と仮定した線形推定であって、実測値ではない。

使い方: python3 rate_limit_window_cost.py [表示する枠の本数(既定4)]
"""
import json
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

ES_URL = "http://localhost:9200"
RATE_LIMIT_INDEX = "claude-rate-limits"
LOG_INDEX = "logs-generic.otel-default"
JST = timezone(timedelta(hours=9))
WINDOW_LENGTH = timedelta(days=7)

# Claude Code のログ側単価が公式単価とズレているモデルと、その倍率。
# Sonnet 5 は input/output/cache すべてが公式($2/$10系)の 1.5 倍($3/$15系)で記録される。
LOG_PRICE_RATIO = {"sonnet-5": 1.5}


def search(index, body):
    request = urllib.request.Request(
        f"{ES_URL}/{index}/_search",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def price_ratio(model):
    """そのモデルのログ側単価が公式単価の何倍か"""
    for keyword, ratio in LOG_PRICE_RATIO.items():
        if keyword in model:
            return ratio
    return 1.0


def fetch_windows(limit):
    """7日枠を新しい順に取る。1つの resets_at が1本の枠に対応する"""
    body = {
        "size": 0,
        "aggs": {
            "windows": {
                "terms": {"field": "seven_day.resets_at", "size": limit, "order": {"_key": "desc"}},
                "aggs": {
                    "max_used": {"max": {"field": "seven_day.used_percentage"}},
                    "min_used": {"min": {"field": "seven_day.used_percentage"}},
                    "first_seen": {"min": {"field": "@timestamp"}},
                    "last_seen": {"max": {"field": "@timestamp"}},
                },
            }
        },
    }
    windows = []
    for bucket in search(RATE_LIMIT_INDEX, body)["aggregations"]["windows"]["buckets"]:
        resets_at = datetime.fromtimestamp(bucket["key"] / 1000, tz=JST)
        windows.append(
            {
                "starts_at": resets_at - WINDOW_LENGTH,
                "resets_at": resets_at,
                "max_used": bucket["max_used"]["value"],
                "min_used": bucket["min_used"]["value"],
                "records": bucket["doc_count"],
                "first_seen": datetime.fromtimestamp(bucket["first_seen"]["value"] / 1000, tz=JST),
                "last_seen": datetime.fromtimestamp(bucket["last_seen"]["value"] / 1000, tz=JST),
            }
        )
    return windows


def fetch_cost(starts_at, ends_at):
    """その期間の消費を、ログ側の生値と公式単価へ補正した値の両方でモデル別に取る"""
    body = {
        "size": 0,
        "query": {
            "bool": {
                "filter": [
                    {"term": {"event_name": "api_request"}},
                    {"range": {"@timestamp": {"gte": starts_at.isoformat(), "lt": ends_at.isoformat()}}},
                ]
            }
        },
        "aggs": {
            "by_model": {
                "terms": {"field": "attributes.model.keyword", "size": 20},
                "aggs": {"cost": {"sum": {"field": "attributes.cost_usd"}}},
            }
        },
    }
    models = []
    for bucket in search(LOG_INDEX, body)["aggregations"]["by_model"]["buckets"]:
        raw = bucket["cost"]["value"]
        ratio = price_ratio(bucket["key"])
        models.append({"model": bucket["key"], "raw": raw, "corrected": raw / ratio, "ratio": ratio})
    models.sort(key=lambda entry: entry["corrected"], reverse=True)
    return models


def print_window(window, models):
    total_raw = sum(entry["raw"] for entry in models)
    total_corrected = sum(entry["corrected"] for entry in models)

    print(f"枠 {window['starts_at']:%Y-%m-%d %H:%M} 〜 {window['resets_at']:%Y-%m-%d %H:%M}")
    print(f"  観測できた使用率      {window['min_used']:.1f}% 〜 {window['max_used']:.1f}%")
    print(
        f"  記録があった範囲      {window['first_seen']:%m-%d %H:%M} 〜 {window['last_seen']:%m-%d %H:%M}"
        f"（{window['records']:,} 点）"
    )
    print(f"  期間内の消費          {total_corrected:,.2f} USD相当（ログ側の生値 {total_raw:,.2f}）")

    if not window["max_used"]:
        print("  使用率が0%のため100%相当は推定できない")
        print()
        return

    full = total_corrected / (window["max_used"] / 100)
    print(f"  使用率100%相当        {full:,.2f} USD相当")
    print(f"  使用率50%相当         {full / 2:,.2f} USD相当")
    print("  モデル別（補正後）:")
    for entry in models:
        note = f"（ログ側の生値 {entry['raw']:,.2f}）" if entry["ratio"] != 1.0 else ""
        print(f"    {entry['model']:<32} {entry['corrected']:>12,.2f}  {note}")
    print()


def main():
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 4

    try:
        windows = fetch_windows(limit)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            print(f"{RATE_LIMIT_INDEX} インデックスがまだ無い。/setup-statusline で利用枠の記録を有効にしろ。")
            return
        raise

    if not windows:
        print("7日枠の使用率の記録が無い(ステータスラインが描画されていないか、記録が無効)。")
        return

    now = datetime.now(JST)
    print("7日枠ごとの消費と、使用率100%相当の推定コスト(JST):")
    print()
    for window in windows:
        ends_at = min(window["resets_at"], now)
        print_window(window, fetch_cost(window["starts_at"], ends_at))

    print("※ 100%相当は「使用率と消費が比例する」と仮定した線形推定だ。実測値として報告するな。")
    print("※ 使用率はステータスラインが描画された瞬間だけ記録される。枠の終盤に描画が無いと、")
    print("   観測できた最大使用率が実際より低く出て、100%相当が過大になる。")
    print("※ 消費は Sonnet 5 を公式単価($2/$10系)へ補正済み。ログ側は $3/$15 系で記録されている。")


if __name__ == "__main__":
    main()
