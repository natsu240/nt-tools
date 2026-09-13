#!/usr/bin/env python3
"""query_source が 'agent:custom' / 'agent:builtin:*' の api_request を、実際のサブエージェント名別の
コストに集計する。

突き合わせの単位は span_id だ。span_id はサブエージェント1回の実行を一意に指す。
prompt.id は 1 ターン全体を指すため、同一ターンで複数のサブエージェントが動くと区別できず、
同じターンのメイン会話の消費まで巻き込んでサブエージェント側に計上される。

api_request 自体にはサブエージェント名が入っていないため、以下を順に試して名前を解決する。
- subagent_completed の agent_type: 同じ span_id を持つドキュメントから取る。1 対 1 で決まる
- workflow.name: Workflow ツール内の agent() 呼び出しは subagent_completed を出さないが、
  api_request 自体にワークフロー名が入っている
- Agent ツールの tool_result: tool_parameters に subagent_type が入っている。ただし持っている
  span_id は呼び出した側（親）のものなので、同一セッション内で実行時間帯が重なるかどうかで
  対応付ける。重なる候補が1つに絞れないときは候補を並べて「推定」と明示する

3経路すべて外れる分は、名前が分からないのではなくサブエージェントではない。query_source の
agent:custom にはメイン会話（Remote Control 経由が大半だが通常起動でも起きる）が混ざるため、
サブエージェント消費として合算すると過大評価になる。そのため合計から切り離して最後に出す。

Elasticsearch はドキュメント間 JOIN を持たないため、この突き合わせはこのスクリプトが行う。
"""
import json
import urllib.error
import urllib.request

ES_URL = "http://localhost:9200"
INDEX = "logs-generic.otel-default"

# 1回のリクエストで取る件数。全体はページングで舐めるので、この値を変えても集計結果は変わらない
PAGE_SIZE = 1000
PIT_KEEP_ALIVE = "2m"

NOT_SUBAGENT = "(サブエージェントではない: メイン会話が agent:custom として記録された分)"


def es_request(path, body=None, method="POST"):
    """Elasticsearch に JSON を投げて結果を dict で返す。body が None なら本文なしで送る"""
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        f"{ES_URL}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method=method,
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def iter_hits(query, source_fields, docvalue_fields=None):
    """条件に一致するドキュメントを PIT + search_after で全件列挙する。

    1回のリクエストで返せるドキュメント数には上限がある。名前解決用の対応表は
    全期間分そろって初めて正しくなるので、上限で打ち切ると欠けた分が
    「サブエージェントではない」側へ黙って流れ込む。
    """
    pit_id = es_request(f"/{INDEX}/_pit?keep_alive={PIT_KEEP_ALIVE}")["id"]
    try:
        search_after = None
        while True:
            body = {
                "size": PAGE_SIZE,
                "query": query,
                "_source": source_fields,
                "sort": [{"@timestamp": "asc"}, {"_shard_doc": "asc"}],
                "pit": {"id": pit_id, "keep_alive": PIT_KEEP_ALIVE},
            }
            if docvalue_fields:
                body["docvalue_fields"] = docvalue_fields
            if search_after:
                body["search_after"] = search_after
            result = es_request("/_search", body)
            hits = result["hits"]["hits"]
            if not hits:
                return
            yield from hits
            search_after = hits[-1]["sort"]
            pit_id = result.get("pit_id", pit_id)
    finally:
        close_pit(pit_id)


def close_pit(pit_id):
    """PIT を解放する。keep_alive で自動失効するため、失敗しても集計には影響しない"""
    try:
        es_request("/_pit", {"id": pit_id}, method="DELETE")
    except urllib.error.URLError:
        pass


def iter_composite_buckets(query, source_field, aggs):
    """指定フィールドの値ごとの集約バケットを after_key で全件列挙する。

    terms 集約は size に指定した数までしかバケットを返さないため、値の種類が
    それを超えると集計対象が静かに欠ける。composite なら全バケットを舐められる。
    """
    after_key = None
    while True:
        composite = {"size": PAGE_SIZE, "sources": [{"value": {"terms": {"field": source_field}}}]}
        if after_key:
            composite["after"] = after_key
        result = es_request(f"/{INDEX}/_search", {
            "size": 0,
            "query": query,
            "aggs": {"grouped": {"composite": composite, "aggs": aggs}},
        })
        grouped = result["aggregations"]["grouped"]
        if not grouped["buckets"]:
            return
        for bucket in grouped["buckets"]:
            yield {**bucket, "key": bucket["key"]["value"]}
        after_key = grouped.get("after_key")
        if not after_key:
            return


def fetch_subagent_completed_map():
    """span_id -> (agent_type, is_built_in)"""
    hits = iter_hits(
        {"term": {"event_name": "subagent_completed"}},
        ["span_id", "attributes.agent_type", "attributes.is_built_in"],
    )
    mapping = {}
    for hit in hits:
        attrs = hit["_source"]["attributes"]
        span_id = hit["_source"].get("span_id")
        if span_id:
            mapping[span_id] = (attrs.get("agent_type", "(不明)"), attrs.get("is_built_in", False))
    return mapping


def fetch_agent_tool_calls():
    """Agent ツールの呼び出しを session.id ごとに「実行時間帯 + サブエージェント名」の一覧にする"""
    hits = iter_hits(
        {"bool": {"filter": [
            {"term": {"event_name": "tool_result"}},
            {"term": {"attributes.tool_name.keyword": "Agent"}},
        ]}},
        ["attributes.session.id", "attributes.tool_parameters", "attributes.duration_ms"],
        docvalue_fields=[{"field": "@timestamp", "format": "epoch_millis"}],
    )
    calls = {}
    for hit in hits:
        attrs = hit["_source"]["attributes"]
        session_id = attrs.get("session.id")
        if not session_id:
            continue
        try:
            subagent_type = json.loads(attrs.get("tool_parameters", "{}")).get("subagent_type")
        except json.JSONDecodeError:
            subagent_type = None
        if not subagent_type:
            continue
        ended_at = int(hit["fields"]["@timestamp"][0])
        duration_ms = int(float(attrs.get("duration_ms", 0)))
        calls.setdefault(session_id, []).append({
            "name": subagent_type,
            "started_at": ended_at - duration_ms,
            "ended_at": ended_at,
        })
    return calls


def fetch_agent_api_requests():
    """agent:* の api_request を span_id ごとに集計する(コスト・session.id・実行時間帯・workflow 名)"""
    buckets = iter_composite_buckets(
        {"bool": {"filter": [
            {"term": {"event_name": "api_request"}},
            {"prefix": {"attributes.query_source.keyword": "agent:"}},
        ]}},
        "span_id",
        {
            "total_cost": {"sum": {"field": "attributes.cost_usd"}},
            "session": {"terms": {"field": "attributes.session.id.keyword", "size": 1}},
            "workflow": {"terms": {"field": "attributes.workflow.name.keyword", "size": 1}},
            "started_at": {"min": {"field": "@timestamp"}},
            "ended_at": {"max": {"field": "@timestamp"}},
        },
    )
    requests = {}
    for bucket in buckets:
        session_buckets = bucket["session"]["buckets"]
        workflow_buckets = bucket["workflow"]["buckets"]
        requests[bucket["key"]] = {
            "cost": bucket["total_cost"]["value"],
            "session_id": session_buckets[0]["key"] if session_buckets else None,
            "workflow": workflow_buckets[0]["key"] if workflow_buckets else None,
            "started_at": bucket["started_at"]["value"],
            "ended_at": bucket["ended_at"]["value"],
        }
    return requests


def match_by_time(request, agent_calls):
    """実行時間帯が重なる Agent 呼び出しからサブエージェント名を推定する"""
    candidates = agent_calls.get(request["session_id"], [])
    overlapped = {
        call["name"] for call in candidates
        if call["started_at"] <= request["ended_at"] and request["started_at"] <= call["ended_at"]
    }
    if not overlapped:
        return None
    if len(overlapped) == 1:
        return f"{overlapped.pop()} (推定)"
    return f"{' or '.join(sorted(overlapped))} (推定・候補複数)"


def resolve_name(span_id, request, subagent_map, agent_calls):
    if span_id in subagent_map:
        agent_type, is_built_in = subagent_map[span_id]
        return f"{agent_type}{' (built-in)' if is_built_in else ''}"
    if request["workflow"]:
        return f"Workflow: {request['workflow']}"
    return match_by_time(request, agent_calls) or NOT_SUBAGENT


def main():
    subagent_map = fetch_subagent_completed_map()
    agent_calls = fetch_agent_tool_calls()
    api_requests = fetch_agent_api_requests()

    totals = {}
    for span_id, request in api_requests.items():
        name = resolve_name(span_id, request, subagent_map, agent_calls)
        entry = totals.setdefault(name, {"cost": 0.0, "count": 0})
        entry["cost"] += request["cost"]
        entry["count"] += 1

    not_subagent = totals.pop(NOT_SUBAGENT, {"cost": 0.0, "count": 0})
    ranked = sorted(totals.items(), key=lambda kv: kv[1]["cost"], reverse=True)
    subagent_cost = sum(entry["cost"] for _, entry in ranked)

    print("サブエージェント別コスト内訳(合計コストUSD降順):")
    for name, entry in ranked:
        print(f"  {name}: {round(entry['cost'], 4)} USD ({entry['count']} 回)")
    print(f"  --- サブエージェント消費 合計: {round(subagent_cost, 4)} USD ---")

    if not_subagent["count"]:
        total = subagent_cost + not_subagent["cost"]
        ratio = not_subagent["cost"] / total * 100 if total else 0
        print(f"\n{NOT_SUBAGENT}")
        print(f"  {round(not_subagent['cost'], 4)} USD ({not_subagent['count']} 回) / query_source が agent:* の全体 {round(total, 4)} USD の {ratio:.1f}%")
        print("  サブエージェント消費として合算するな（合算すると過大評価になる）")


if __name__ == "__main__":
    main()
