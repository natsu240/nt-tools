#!/usr/bin/env bash
# launchd / systemd は最小限の PATH で起動するので、claude / jq / curl のインストール先を自分で並べる。
#
# **Discord Webhook URL をログに出すな。**

set -euo pipefail

export TZ=Asia/Tokyo
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# 設定の置き場所。動作確認のときだけ VERSION_NOTIFY_CONFIG で差し替えられる。
CONFIG_FILE="${VERSION_NOTIFY_CONFIG:-$HOME/.claude/version-upgrade-notify.json}"
STATE_DIR="$HOME/.claude/state/version-upgrade-notify"
LOG_DIR="$STATE_DIR/logs"
LOCK_DIR="$STATE_DIR/lock"
STATE_FILE="$STATE_DIR/state.json"
PROMPT_TEMPLATE="${VERSION_NOTIFY_PROMPT:-$HOME/.claude/scripts/version-upgrade-notify-prompt.md}"
SUMMARY_FILE="$STATE_DIR/summary.md"
DISCORD_EMBED_DESCRIPTION_LIMIT=4096

# CHANGELOG の要約が主な仕事で、コードの正誤判断を含まないため上位モデルは使わない。
MODEL="${VERSION_NOTIFY_MODEL:-haiku}"
# 同じ失敗を毎回繰り返してトークンを使い続けないための打ち切り回数。
MAX_CONSECUTIVE_FAILURES=3
# ログを残す日数。
LOG_RETENTION_DAYS=30

LOG_FILE=""

log() {
    if [[ -n "$LOG_FILE" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    fi
}

# --- 前提の確認 -------------------------------------------------------------

# 設定ファイルが無い環境（このスキルを実行していない利用者）では何もしない。
if [[ ! -f "$CONFIG_FILE" ]]; then
    exit 0
fi

for cmd in jq curl claude; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        exit 0
    fi
done

DISCORD_WEBHOOK_URL="$(jq -r '.discord_webhook_url // empty' "$CONFIG_FILE")"

if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
    exit 0
fi

mkdir -p "$STATE_DIR" "$LOG_DIR"

# --- 記録の読み書き ---------------------------------------------------------

read_state() {
    local key="$1" fallback="$2"
    if [[ -f "$STATE_FILE" ]]; then
        jq -r --arg k "$key" --arg f "$fallback" '.[$k] // $f' "$STATE_FILE" 2>/dev/null || printf '%s' "$fallback"
    else
        printf '%s' "$fallback"
    fi
}

write_state() {
    local last_seen="$1" failures="$2"
    jq -n \
        --arg last_seen_version "$last_seen" \
        --arg last_checked_at "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        --argjson consecutive_failures "$failures" \
        '{last_seen_version: $last_seen_version, last_checked_at: $last_checked_at, consecutive_failures: $consecutive_failures}' \
        > "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

LAST_SEEN_VERSION="$(read_state last_seen_version "")"
FAILURES="$(read_state consecutive_failures 0)"

# --- 失敗したときの記録と通知 -----------------------------------------------

log_response() {
    local text="$1"
    if [[ -z "$text" ]]; then
        log "  応答本文は空だった"
        return
    fi
    local oneline
    oneline="$(printf '%s' "$text" | tr '\n' ' ')"
    log "  応答本文（先頭500文字）: ${oneline:0:500}"
}

# claude を経由せず curl だけで送る。認証切れで claude が起動できないときでも届く。
notify_giveup_to_discord() {
    local version="$1"
    local payload_file
    payload_file="$(mktemp)"
    jq -n --arg content "Claude Code ${version} がリリースされましたが、要約の生成に${MAX_CONSECUTIVE_FAILURES}回続けて失敗したため本文を送れませんでした。" \
        '{content: $content}' > "$payload_file"
    if curl -s -o /dev/null -X POST -H 'Content-Type: application/json' --data @"$payload_file" "$DISCORD_WEBHOOK_URL"; then
        log "要約を諦めたことを Discord へ通知した"
    else
        log "要約を諦めたことの Discord への通知にも失敗した"
    fi
    rm -f "$payload_file"
}

send_summary_to_discord() {
    local version="$1"
    local payload_file body_file http_code
    payload_file="$(mktemp)"
    body_file="$(mktemp)"
    jq -n --rawfile summary "$SUMMARY_FILE" \
        --arg title "Claude Code ${version} がリリースされました" \
        --argjson limit "$DISCORD_EMBED_DESCRIPTION_LIMIT" \
        '{embeds: [{title: $title, description: $summary[0:$limit]}]}' > "$payload_file"
    http_code="$(curl -s --max-time 30 -o "$body_file" -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' --data @"$payload_file" "$DISCORD_WEBHOOK_URL" || true)"
    if [[ "$http_code" != "204" && "$http_code" != "200" ]]; then
        log "Discord への送信に失敗した（HTTP ${http_code}）"
        log_response "$(cat "$body_file" 2>/dev/null || true)"
        rm -f "$payload_file" "$body_file"
        return 1
    fi
    rm -f "$payload_file" "$body_file"
}

# --- 新着の判定 -------------------------------------------------------------

# ここで claude は起動しない。CHANGELOG.md を1回見に行くだけなのでトークンは消費しない。
CHANGELOG_HEAD_LINE="$(curl -s --max-time 15 https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md | grep -m 1 '^## ' || true)"
LATEST_VERSION="$(awk '{print $2}' <<< "$CHANGELOG_HEAD_LINE")"

if [[ -z "$LATEST_VERSION" ]]; then
    # 取得に失敗した（ネットワーク断・CHANGELOG フォーマット変更など）。記録は進めず次回に回す。
    write_state "$LAST_SEEN_VERSION" "$FAILURES"
    exit 0
fi

if [[ "$LATEST_VERSION" == "$LAST_SEEN_VERSION" ]]; then
    # 新着なし。claude を起動せずに終わる。
    write_state "$LAST_SEEN_VERSION" 0
    exit 0
fi

if [[ "$FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]]; then
    # 同じ新着で連続して失敗している。毎回やり直してトークンを使い続けないよう、記録だけ進めて打ち切る。
    LOG_FILE="${LOG_DIR}/$(date '+%Y%m%d-%H%M%S').log"
    log "${MAX_CONSECUTIVE_FAILURES}回続けて失敗したため、この新着（${LATEST_VERSION}）は諦めて記録だけ進める"
    notify_giveup_to_discord "$LATEST_VERSION"
    write_state "$LATEST_VERSION" 0
    exit 0
fi

# --- 二重起動の防止 ---------------------------------------------------------

# 前回の実行がまだ終わっていなければ、今回は何もせず次の起動に回す。
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    owner="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
    if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
        exit 0
    fi
    # 持ち主のプロセスが不在なら、取り残されたロックを片付けて取り直す。
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || exit 0
fi
echo $$ > "${LOCK_DIR}/pid"
trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT

LOG_FILE="${LOG_DIR}/$(date '+%Y%m%d-%H%M%S').log"
log "新着を検知した（${LAST_SEEN_VERSION:-<記録なし>} -> ${LATEST_VERSION}）"

# 古いログを片付ける。
find "$LOG_DIR" -name '*.log' -type f -mtime "+${LOG_RETENTION_DAYS}" -delete 2>/dev/null || true

# --- 指示文の組み立て -------------------------------------------------------

if [[ ! -f "$PROMPT_TEMPLATE" ]]; then
    log "指示文のテンプレートが見つからない: ${PROMPT_TEMPLATE}"
    write_state "$LAST_SEEN_VERSION" "$((FAILURES + 1))"
    exit 1
fi

prompt="$(cat "$PROMPT_TEMPLATE")"
prompt="${prompt//__PREVIOUS_VERSION__/${LAST_SEEN_VERSION:-なし（初回セットアップ）}}"
prompt="${prompt//__LATEST_VERSION__/$LATEST_VERSION}"
prompt="${prompt//__SUMMARY_FILE__/$SUMMARY_FILE}"

# OTel（/setup-otel 導入時）に、どの自動処理かを載せる。
# launchd / systemd から起動されたプロセスは対話シェルの設定を読まないため、ここで自分で渡す。
export OTEL_RESOURCE_ATTRIBUTES="job=version-upgrade-notify,project=version-upgrade-notify"

# 動作確認用。claude を起動せず、ここまでの組み立てが通ったことだけ確かめて終わる。
if [[ "${VERSION_NOTIFY_DRY_RUN:-}" == "1" ]]; then
    log "試し実行のため claude は起動しない（指示文 ${#prompt} 文字・対象バージョン ${LATEST_VERSION}）"
    exit 0
fi

# --- 実行 -------------------------------------------------------------------

rm -f "$SUMMARY_FILE"

result_file="$(mktemp)"

# pipe + set -e だと claude 失敗時に終了コードを拾う前に落ちるため set +e で囲む。
set +e
claude -p --model "$MODEL" --effort low \
  --output-format stream-json --verbose \
  --allowedTools \
    "Read" "Write" "Bash" \
  <<< "$prompt" \
  2> >(while IFS= read -r errline; do log "stderr: ${errline}"; done) \
  | while IFS= read -r line; do
      ev="$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)"
      if [[ "$ev" == "assistant" ]]; then
          tools="$(printf '%s' "$line" | jq -r '[.message.content[]? | select(.type=="tool_use") | .name] | join(", ")' 2>/dev/null)"
          if [[ -n "$tools" ]]; then
              log "  step: tool=${tools}"
          fi
      elif [[ "$ev" == "result" ]]; then
          printf '%s' "$line" | jq -r '.result // empty' 2>/dev/null > "$result_file"
          summary="$(printf '%s' "$line" | jq -r '"usage in=\(.usage.input_tokens) out=\(.usage.output_tokens) turns=\(.num_turns) dur=\(.duration_ms)ms"' 2>/dev/null)"
          if [[ -n "$summary" ]]; then
              log "$summary"
          fi
      fi
  done
exit_code=${PIPESTATUS[0]}
set -e

final_text="$(cat "$result_file" 2>/dev/null || true)"
rm -f "$result_file"

if [[ "$exit_code" -ne 0 ]]; then
    log "異常終了（exit code ${exit_code}）。記録は進めず次回に回す"
    log_response "$final_text"
    write_state "$LAST_SEEN_VERSION" "$((FAILURES + 1))"
    exit 1
fi

# 指示文で最後に出させている1行を拾う。
#   VERSION_NOTIFY_RESULT: ok|fail | <一言>
result_line="$(grep -o 'VERSION_NOTIFY_RESULT:.*' <<<"$final_text" | tail -1 || true)"
status="$(awk -F'|' '{gsub(/^ *VERSION_NOTIFY_RESULT: *| *$/, "", $1); print $1}' <<<"$result_line")"
detail="$(awk -F'|' '{gsub(/^ *| *$/, "", $2); print $2}' <<<"$result_line")"

if [[ "$status" != "ok" ]]; then
    log "未完了: ${detail:-理由の申告なし}。記録は進めず次回に回す"
    log_response "$final_text"
    write_state "$LAST_SEEN_VERSION" "$((FAILURES + 1))"
    exit 1
fi

if [[ ! -s "$SUMMARY_FILE" ]]; then
    log "要約が書き出されていない: ${SUMMARY_FILE}。記録は進めず次回に回す"
    log_response "$final_text"
    write_state "$LAST_SEEN_VERSION" "$((FAILURES + 1))"
    exit 1
fi

if ! send_summary_to_discord "$LATEST_VERSION"; then
    write_state "$LAST_SEEN_VERSION" "$((FAILURES + 1))"
    exit 1
fi

log "完了: Discord へ通知した（${detail:-理由の記載なし}）"
write_state "$LATEST_VERSION" 0
