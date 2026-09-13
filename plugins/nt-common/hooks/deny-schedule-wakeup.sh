#!/usr/bin/env bash
# ScheduleWakeup で次のターンを予約する呼び出しを deny する PreToolUse hook。
# stop: true だけは素通しする（走っている /loop を終わらせる操作で、これを止めると /loop を明示的に終了できなくなる）。

set -euo pipefail

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

input="$(cat)"

stop="$(jq -r '.tool_input.stop // false' <<<"$input")"
[[ "$stop" == "true" ]] && exit 0

emit_pretooluse_decision "deny" "$(printf '%s\n' \
  "🚫 ScheduleWakeup で次のターンを予約するな。" \
  "   バックグラウンドのサブエージェント・Bash は終わると自動で通知が来て次のターンが始まる。待つための操作は要らない。" \
  "   今できることが無いなら通知が来るまで待って応答を終えろ。進められる作業があるならそれをやれ。" \
  "   決まった間隔で繰り返したいなら、間隔を指定した /loop をユーザーに実行してもらえ（ScheduleWakeup を使わない方式で動く）。")"

exit 0
