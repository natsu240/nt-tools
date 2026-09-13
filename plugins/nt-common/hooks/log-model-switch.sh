#!/usr/bin/env bash
# PostModelSwitch hook。モデル切り替えの詳細をOTLP/HTTP(JSON)でローカルCollectorへ送る。
# setup-otel skillでCollectorをセットアップしていない環境でも安全なよう、失敗しても常にexit 0で終わる。

set -uo pipefail

OTLP_LOGS_ENDPOINT="http://localhost:4318/v1/logs"

send_model_switch_log() {
  local input_json="$1"

  local payload
  payload="$(
    jq -c '
      def attr($k; $v; $type):
        {key: $k, value: {($type): $v}};

      (now * 1000000000 | round | tostring) as $ts_ns
      | (
          [
            attr("session.id"; (.session_id // ""); "stringValue"),
            attr("from_model"; (.from_model // ""); "stringValue"),
            attr("to_model"; (.to_model // ""); "stringValue"),
            attr("requested_model"; (.requested_model // ""); "stringValue"),
            attr("source"; (.source // ""); "stringValue"),
            attr("cache_ttl"; (.cache_ttl // ""); "stringValue"),
            attr("pricing"; (.pricing // ""); "stringValue")
          ]
          + (if .context_tokens then [attr("context_tokens"; (.context_tokens | tostring); "intValue")] else [] end)
          + (if .estimated_cache_write_usd then [attr("estimated_cache_write_usd"; .estimated_cache_write_usd; "doubleValue")] else [] end)
          + (if .prompt_cache_warm != null then [attr("prompt_cache_warm"; .prompt_cache_warm; "boolValue")] else [] end)
        ) as $attributes
      | {
          resourceLogs: [{
            resource: {attributes: [attr("service.name"; "claude-code"; "stringValue")]},
            scopeLogs: [{
              scope: {name: "nt-common.log-model-switch"},
              logRecords: [{
                timeUnixNano: $ts_ns,
                severityText: "INFO",
                eventName: "model_switch",
                body: {stringValue: "model_switch"},
                attributes: $attributes
              }]
            }]
          }]
        }
    ' <<<"$input_json"
  )" || return 0

  curl -s -o /dev/null --max-time 2 \
    -X POST "$OTLP_LOGS_ENDPOINT" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    || return 0
}

send_model_switch_log "$(cat)" || true

exit 0
