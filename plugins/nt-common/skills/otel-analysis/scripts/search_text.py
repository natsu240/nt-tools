#!/usr/bin/env python3
"""発言・ツール入出力を日本語形態素解析(kuromoji)込みであいまい検索する。
使い方: python3 search_text.py "<検索したい語句>" [対象フィールド]
対象フィールドは prompt(既定) / tool_input / response / assistant のいずれか。
"""
import json
import sys
import urllib.request

ES_URL = "http://localhost:9200"
INDEX = "logs-generic.otel-default"

FIELD_TO_EVENT = {
    "prompt": ("user_prompt", "attributes.prompt"),
    "tool_input": ("tool_result", "attributes.tool_input"),
    "response": ("assistant_response", "attributes.response"),
    "assistant": ("assistant_response", "attributes.response"),
}


def main():
    if len(sys.argv) < 2:
        print("使い方: python3 search_text.py \"<検索したい語句>\" [prompt|tool_input|response]", file=sys.stderr)
        sys.exit(1)

    keyword = sys.argv[1]
    target = sys.argv[2] if len(sys.argv) > 2 else "prompt"
    if target not in FIELD_TO_EVENT:
        print(f"未対応の対象フィールド: {target}（prompt/tool_input/responseのいずれかを指定しろ）", file=sys.stderr)
        sys.exit(1)
    event_name, field = FIELD_TO_EVENT[target]

    body = {
        "size": 20,
        "query": {
            "bool": {
                "filter": [{"term": {"event_name": event_name}}],
                "must": [{"match": {field: keyword}}],
            }
        },
        "highlight": {"fields": {field: {}}},
        "runtime_mappings": {
            "ts_jst": {
                "type": "keyword",
                "script": (
                    "emit(DateTimeFormatter.ofPattern(\"yyyy-MM-dd HH:mm\")"
                    ".withZone(ZoneId.of(\"Asia/Tokyo\")).format(doc['@timestamp'].value))"
                ),
            }
        },
        "fields": ["ts_jst", "attributes.session.id"],
        "_source": False,
    }

    req = urllib.request.Request(
        f"{ES_URL}/{INDEX}/_search",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        result = json.load(resp)

    hits = result.get("hits", {}).get("hits", [])
    if not hits:
        print(f"「{keyword}」に一致する{target}は見つからなかった。")
        return

    print(f"「{keyword}」の検索結果（{target}、関連度順、上位{len(hits)}件）:")
    for h in hits:
        fields = h.get("fields", {})
        ts = fields.get("ts_jst", ["?"])[0]
        session_id = fields.get("attributes.session.id", ["?"])[0]
        snippet = " / ".join(h.get("highlight", {}).get(field, []))
        print(f"- {ts} (session: {session_id}): {snippet}")


if __name__ == "__main__":
    main()
