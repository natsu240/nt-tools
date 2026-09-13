#!/usr/bin/env bash
# Bash の PreToolUse hook。
# Elasticsearch(localhost:9200)への集計コマンドを otel-analysis skill 未起動のまま直接叩こうとしたら deny する。
#
# otel-analysis skill が起動する `claude -p` サブプロセス（NT_OTEL_ANALYSIS_SUBPROCESS=1 で識別）は対象外にする。
# サブプロセスは Skill ツールを持たず collect_called_skills でも検知できないため、対象外にしないと恒久 deny になる。

set -euo pipefail

INPUT_JSON="$(cat)"

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"
# shellcheck source=lib-called-skills.sh
source "${BASH_SOURCE[0]%/*}/lib-called-skills.sh"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

COMMAND="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -z "$COMMAND" ]] && exit 0

OTEL_ES_RE='(localhost|127\.0\.0\.1):9200'
if ! grep -qE "$OTEL_ES_RE" <<<"$COMMAND"; then
  exit 0
fi

# 判定にトランスクリプトのパスを使うな。transcript_path は session_id から機械的に導出され、サブエージェントの session_id は親と同じなので、渡ってくるのは常に親セッションの記録になる。
# 共通フィールドの agent_id / agent_type で判定する（メインは agent_type="worker" かつ agent_id 未設定）。
AGENT_ID="$(jq -r '.agent_id // empty' <<<"$INPUT_JSON")"
AGENT_TYPE="$(jq -r '.agent_type // empty' <<<"$INPUT_JSON")"
if [[ -n "$AGENT_ID" || ( -n "$AGENT_TYPE" && "$AGENT_TYPE" != "worker" ) ]]; then
  exit 0
fi

if [[ -n "${NT_OTEL_ANALYSIS_SUBPROCESS:-}" ]]; then
  exit 0
fi

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT_JSON")"
TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$INPUT_JSON")"
CALLED_SKILLS="$(collect_called_skills "$SESSION_ID" "$TRANSCRIPT_PATH")"

# grep はパイプの終端に置くな。set -o pipefail 下では grep -q がマッチした瞬間に終了して上流が SIGPIPE で死に、その終了ステータスがパイプライン全体の結果になる。here-string で渡す。
if grep -qE '^(otel-analysis|nt-common:otel-analysis)$' <<<"$CALLED_SKILLS"; then
  exit 0
fi

emit_pretooluse_decision deny "🚫 otel-analysis skill が未起動のまま Elasticsearch への集計コマンドを実行しようとしています。先に Skill ツールで nt-common:otel-analysis を起動してから再試行しろ。"

exit 0
