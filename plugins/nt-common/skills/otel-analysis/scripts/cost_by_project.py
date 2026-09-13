#!/usr/bin/env python3
"""プロジェクト(リポジトリ)別のコストに集計する。

プロジェクト名の判定には2つの経路がある。Claude Code は作業ディレクトリをテレメトリに含めないため、
どちらの経路も必要になる。
- resource.attributes.project: シェル側で OTEL_RESOURCE_ATTRIBUTES を渡している場合に入る。そのまま使える
- ~/.claude/projects/ 配下のディレクトリ名: 属性が無いドキュメント用。session_id.jsonl の置き場所から
  逆算する(元のパスの"/"を"-"に置換したエンコード形式のまま出す)

シェルラッパー未経由(Claude Desktop app・ラッパー未設定時・launchd で env 未指定等)のセッションは
属性が付かず、同じプロジェクトでもログ照合経由の生パス名(例: "-Users-foo-code-bar")で別グループに
分裂する。ログ照合名の末尾が既知の属性名(例: "bar")と一致する場合はその属性名へ統合する。単純な
"-"分割で末尾セグメントを取らないのは、リポジトリ名自体に"-"を含む場合にパス区切りとの区別がつかないため。

無人実行(launchd 等)のセッションは resource.attributes.job も持つので、プロジェクト名の後ろに併記する。
"""
import glob
import json
import os
import urllib.request

ES_URL = "http://localhost:9200"
INDEX = "logs-generic.otel-default"

SOURCE_ATTRIBUTE = "属性"
SOURCE_LOG_FILE = "ログ照合"
SOURCE_UNKNOWN = "不明"


def fetch_session_stats():
    """session.id ごとの合計コスト・project 属性・job 属性を1回のクエリで取る"""
    body = {
        "size": 0,
        "query": {"term": {"event_name": "api_request"}},
        "aggs": {
            "by_session": {
                "terms": {"field": "attributes.session.id.keyword", "size": 10000},
                "aggs": {
                    "total_cost": {"sum": {"field": "attributes.cost_usd"}},
                    "project_attr": {"terms": {"field": "resource.attributes.project.keyword", "size": 1}},
                    "job_attr": {"terms": {"field": "resource.attributes.job.keyword", "size": 1}},
                },
            }
        },
    }
    req = urllib.request.Request(
        f"{ES_URL}/{INDEX}/_search",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        result = json.load(resp)

    stats = {}
    for bucket in result["aggregations"]["by_session"]["buckets"]:
        project_buckets = bucket["project_attr"]["buckets"]
        job_buckets = bucket["job_attr"]["buckets"]
        stats[bucket["key"]] = {
            "cost": bucket["total_cost"]["value"],
            "project": project_buckets[0]["key"] if project_buckets else None,
            "job": job_buckets[0]["key"] if job_buckets else None,
        }
    return stats


def build_session_project_map():
    """会話ログの置き場所から session.id -> プロジェクト名を作る"""
    mapping = {}
    for path in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")):
        project = os.path.basename(os.path.dirname(path))
        session_id = os.path.basename(path)[: -len(".jsonl")]
        mapping[session_id] = project
    return mapping


def find_matching_attribute_name(raw_name, known_attribute_names):
    """ログ照合の生パス名が既知の属性名で終わっていれば、その属性名を返す

    複数マッチしたら最長一致を選ぶ(末尾が同じ短い名前への誤マッチを避けるため)。
    """
    matches = [
        name for name in known_attribute_names
        if raw_name == name or raw_name.endswith(f"-{name}")
    ]
    return max(matches, key=len) if matches else None


def resolve_project(stat, session_id, session_to_project, known_attribute_names):
    """プロジェクト名と、それをどの経路で特定したかを返す"""
    if stat["project"]:
        return stat["project"], SOURCE_ATTRIBUTE
    if session_id in session_to_project:
        raw_name = session_to_project[session_id]
        matched = find_matching_attribute_name(raw_name, known_attribute_names)
        return matched or raw_name, SOURCE_LOG_FILE
    if stat["job"]:
        return f"(作業ディレクトリなし: job={stat['job']})", SOURCE_ATTRIBUTE
    return "(不明: 削除済みセッション)", SOURCE_UNKNOWN


def main():
    session_stats = fetch_session_stats()
    session_to_project = build_session_project_map()
    known_attribute_names = {stat["project"] for stat in session_stats.values() if stat["project"]}

    totals = {}
    for session_id, stat in session_stats.items():
        project, source = resolve_project(stat, session_id, session_to_project, known_attribute_names)
        entry = totals.setdefault(project, {"cost": 0.0, "sessions": 0, "sources": {}, "jobs": set()})
        entry["cost"] += stat["cost"]
        entry["sessions"] += 1
        entry["sources"][source] = entry["sources"].get(source, 0) + 1
        if stat["job"]:
            entry["jobs"].add(stat["job"])

    ranked = sorted(totals.items(), key=lambda kv: kv[1]["cost"], reverse=True)
    print("プロジェクト別コスト内訳(合計コストUSD降順):")
    for project, entry in ranked:
        breakdown = " / ".join(f"{source} {count}" for source, count in sorted(entry["sources"].items()))
        line = f"  {project}: {round(entry['cost'], 4)} USD ({entry['sessions']} セッション、特定経路: {breakdown})"
        if entry["jobs"]:
            line += f" [無人実行: {', '.join(sorted(entry['jobs']))}]"
        print(line)


if __name__ == "__main__":
    main()
