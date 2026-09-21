#!/usr/bin/env bash
# 不要な run_in_background:true の Bash 呼び出しを deny する。
# 対象: 他のバックグラウンド作業/ユーザーの手作業の完了を sleep + ポーリングで待つコマンド。

set -euo pipefail

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

input="$(cat)"

run_in_background="$(jq -r '.tool_input.run_in_background // false' <<<"$input")"
[[ "$run_in_background" != "true" ]] && exit 0

command="$(jq -r '.tool_input.command // ""' <<<"$input")"
[[ -z "$command" ]] && exit 0

respond_deny() {
  local reason="$1"
  emit_pretooluse_decision deny "$reason"
  exit 0
}

if grep -qE '\bsleep\b' <<<"$command" && grep -qE 'journal\.jsonl|\bpgrep\b|tasks/[^[:space:]]*\.output' <<<"$command"; then
  respond_deny "$(printf '%s\n' \
    "🚫 バックグラウンド作業の完了を sleep + ポーリングで待とうとするな。" \
    "   完了は harness が自動通知するので、通知を待つか他の作業を進めろ。Monitor ツールでストリームを見る方法もある。" \
    "   ユーザーの手作業の完了確認も同様に、ポーリングでなく声をかけて確認しろ。")"
fi

exit 0
