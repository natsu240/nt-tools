#!/usr/bin/env python3
"""利用枠(5時間枠・7日枠)の使用率の増え方を、同じ時間帯の消費内訳と並べて出す。

使用率は claude-rate-limits インデックス(ステータスラインが記録している)にあり、消費は
logs-generic.otel-default の api_request にある。Elasticsearch はドキュメント同士を
突き合わせられないため、双方を1時間単位に丸めてこのスクリプト側で結合する。

使い方: python3 rate_limit_timeline.py [遡る日数(既定3)]
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


def search(index, body):
    req = urllib.request.Request(
        f"{ES_URL}/{index}/_search",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def hour_key(ts):
    return ts.strftime("%Y-%m-%d %H:00")


def fetch_rate_limit_points(since_iso):
    """使用率の記録を古い順に取る"""
    body = {
        "size": 10000,
        "query": {"range": {"@timestamp": {"gte": since_iso}}},
        "sort": [{"@timestamp": "asc"}],
        "_source": ["@timestamp", "five_hour", "seven_day", "project"],
    }
    points = []
    for hit in search(RATE_LIMIT_INDEX, body)["hits"]["hits"]:
        source = hit["_source"]
        timestamp = datetime.fromisoformat(source["@timestamp"].replace("Z", "+00:00")).astimezone(JST)
        points.append(
            {
                "ts": timestamp,
                "five_hour": (source.get("five_hour") or {}).get("used_percentage"),
                "seven_day": (source.get("seven_day") or {}).get("used_percentage"),
                "project": source.get("project"),
            }
        )
    return points


def accumulate_increase(points, window):
    """隣り合う記録の差を1時間ごとに足し上げる。

    差が負になるのは枠がリセットされて0付近に戻ったときなので、その区間は増加として数えず
    リセット回数だけ記録する。
    """
    per_hour = {}
    resets = {}
    previous = None
    for point in points:
        value = point[window]
        if value is None:
            continue
        if previous is not None:
            key = hour_key(point["ts"])
            delta = value - previous
            if delta < 0:
                resets[key] = resets.get(key, 0) + 1
            elif delta > 0:
                per_hour[key] = per_hour.get(key, 0.0) + delta
        previous = value
    return per_hour, resets


def collect_projects_by_hour(points):
    """その時間帯に描画していたセッションの作業リポジトリ名を集める"""
    per_hour = {}
    for point in points:
        if not point["project"]:
            continue
        per_hour.setdefault(hour_key(point["ts"]), set()).add(point["project"])
    return per_hour


def fetch_cost_by_hour(since_iso):
    """1時間ごとの消費(USD相当)と、その内訳上位を取る"""
    body = {
        "size": 0,
        "query": {
            "bool": {
                "filter": [
                    {"term": {"event_name": "api_request"}},
                    {"range": {"@timestamp": {"gte": since_iso}}},
                ]
            }
        },
        "aggs": {
            "by_hour": {
                "date_histogram": {
                    "field": "@timestamp",
                    "calendar_interval": "hour",
                    "time_zone": "Asia/Tokyo",
                    "format": "yyyy-MM-dd HH:00",
                },
                "aggs": {
                    "cost": {"sum": {"field": "attributes.cost_usd"}},
                    "by_source": {
                        "terms": {"field": "attributes.query_source.keyword", "size": 3},
                        "aggs": {"cost": {"sum": {"field": "attributes.cost_usd"}}},
                    },
                },
            }
        },
    }
    per_hour = {}
    for bucket in search(LOG_INDEX, body)["aggregations"]["by_hour"]["buckets"]:
        sources = [
            f"{source['key']} {round(source['cost']['value'], 3)}"
            for source in bucket["by_source"]["buckets"]
            if source["cost"]["value"] > 0
        ]
        per_hour[bucket["key_as_string"]] = {
            "cost": bucket["cost"]["value"],
            "sources": sources,
        }
    return per_hour


def pad_display(text, width, align="left"):
    """全角文字を2幅として数えてパディングする。

    Python の書式指定は文字数で数えるため、全角の見出しと半角の値が混じった表は桁がずれる。
    """
    display_width = sum(2 if ord(char) > 0x2E80 else 1 for char in text)
    padding = " " * max(0, width - display_width)
    if align == "right":
        return padding + text
    return text + padding


def format_row(time_text, five, seven, cost, detail):
    return (
        f"  {pad_display(time_text, 18)}"
        f" {pad_display(five, 7, 'right')}"
        f" {pad_display(seven, 7, 'right')}"
        f" {pad_display(cost, 14, 'right')}"
        f"  {detail}"
    )


def print_timeline(hours, five_h, seven_d, resets_5h, resets_7d, costs, projects):
    print("時刻ごとの利用枠の増え方と消費(JST):")
    print(format_row("時刻", "5h増", "7d増", "消費(USD相当)", "内訳 / 作業先"))
    for key in hours:
        cost_entry = costs.get(key, {"cost": 0.0, "sources": []})
        detail = " / ".join(cost_entry["sources"]) or "-"
        repos = projects.get(key)
        if repos:
            detail += f"  [{', '.join(sorted(repos))}]"
        reset_note = []
        if key in resets_5h:
            reset_note.append("5hリセット")
        if key in resets_7d:
            reset_note.append("7dリセット")
        if reset_note:
            detail += f"  ({'・'.join(reset_note)})"
        five = f"+{five_h[key]:.1f}" if key in five_h else "-"
        seven = f"+{seven_d[key]:.1f}" if key in seven_d else "-"
        print(format_row(key, five, seven, str(round(cost_entry["cost"], 4)), detail))


def print_top_hours(seven_d, costs):
    ranked = sorted(seven_d.items(), key=lambda kv: kv[1], reverse=True)[:3]
    if not ranked:
        return
    print()
    print("7日枠を最も食った時間帯:")
    for rank, (key, increase) in enumerate(ranked, start=1):
        cost_entry = costs.get(key, {"cost": 0.0, "sources": []})
        main_source = cost_entry["sources"][0] if cost_entry["sources"] else "消費の記録なし"
        print(f"  {rank}. {key}  +{increase:.1f}%（消費 {round(cost_entry['cost'], 4)} USD相当、主に {main_source}）")


def main():
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    since_iso = (datetime.now(JST) - timedelta(days=days)).isoformat()

    try:
        points = fetch_rate_limit_points(since_iso)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            print(f"{RATE_LIMIT_INDEX} インデックスがまだ無い。/setup-statusline で利用枠の記録を有効にしろ。")
            return
        raise

    if not points:
        print(f"直近 {days} 日の使用率の記録が無い(ステータスラインが描画されていない期間か、記録が無効)。")
        return

    five_h, resets_5h = accumulate_increase(points, "five_hour")
    seven_d, resets_7d = accumulate_increase(points, "seven_day")
    projects = collect_projects_by_hour(points)
    costs = fetch_cost_by_hour(since_iso)

    hours = sorted(set(five_h) | set(seven_d) | set(resets_5h) | set(resets_7d))
    if not hours:
        print(f"直近 {days} 日は記録が1点しかなく、増減を出せない(2点以上必要)。")
        return

    print_timeline(hours, five_h, seven_d, resets_5h, resets_7d, costs, projects)
    print_top_hours(seven_d, costs)
    print()
    print("※ 使用率はステータスラインが描画された瞬間だけ記録される。描画が飛んだ区間の増加は、")
    print("   次に記録された時刻にまとめて計上される。")
    print("※ 利用枠はアカウント全体で共有される値。[ ] 内のリポジトリ名はその時間帯に描画していた")
    print("   セッションの作業先であって、枠を食った主体の特定ではない。")


if __name__ == "__main__":
    main()
