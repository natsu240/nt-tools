#!/bin/bash
set -euo pipefail

ES_URL="http://localhost:9200"
INDEX="logs-generic.otel-default"

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl が見つからない" >&2
  exit 1
fi

if ! curl -s -o /dev/null -w "" --max-time 3 "$ES_URL" 2>/dev/null; then
  echo "ERROR: Elasticsearchに接続できない($ES_URL)。'docker compose -f ~/.claude/otel/compose.yaml up -d' でコンテナが起動しているか確認しろ" >&2
  exit 1
fi

DOC_COUNT=$(curl -s "$ES_URL/$INDEX/_count" | python3 -c "import json,sys; print(json.load(sys.stdin).get('count', 0))" 2>/dev/null || echo 0)

if [ "$DOC_COUNT" -eq 0 ]; then
  echo "ERROR: $INDEX にドキュメントが無い。/setup-otel でセットアップ済みか、OTel Collectorが実際にログを送っているか確認しろ" >&2
  exit 1
fi

echo "OK: Elasticsearch は使用可能($DOC_COUNT 件のログドキュメント)"
