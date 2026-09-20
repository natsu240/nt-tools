#!/usr/bin/env bash
# orca のブラウザ操作コマンドと Agent(nt-common:browser-operator) を、browser-operation skill 未起動なら deny する PreToolUse hook。

set -euo pipefail

INPUT_JSON="$(cat)"

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"
# shellcheck source=lib-called-skills.sh
source "${BASH_SOURCE[0]%/*}/lib-called-skills.sh"
# shellcheck source=lib-strip-quoted.sh
source "${BASH_SOURCE[0]%/*}/lib-strip-quoted.sh"

# orca のサブコマンドのうちブラウザを操作するものだけ。terminal / worktree / open は対象外。
readonly ORCA_BROWSER_SUBCOMMANDS='goto|back|reload|snapshot|screenshot|get|is|click|hover|focus|check|clear|fill|select|type|inserttext|keypress|scroll|upload|wait|eval|console|network|tab'

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
case "$TOOL_NAME" in
  Agent)
    SUBAGENT_TYPE="$(jq -r '.tool_input.subagent_type // empty' <<<"$INPUT_JSON")"
    [[ "$SUBAGENT_TYPE" != "nt-common:browser-operator" ]] && exit 0
    TARGET_LABEL="Agent(nt-common:browser-operator)"
    ;;
  Bash)
    COMMAND="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
    STRIPPED="$(strip_quoted "$COMMAND")"
    if ! grep -qE "(^|[;&|(])[[:space:]]*orca[[:space:]]+($ORCA_BROWSER_SUBCOMMANDS)([[:space:]]|$)" <<<"$STRIPPED"; then
      exit 0
    fi
    TARGET_LABEL="orca のブラウザ操作コマンド"
    ;;
  *) exit 0 ;;
esac

# 判定にトランスクリプトのパスを使うな。transcript_path は session_id から機械的に導出され、サブエージェントの session_id は親と同じなので、渡ってくるのは常に親セッションの記録になる。
AGENT_ID="$(jq -r '.agent_id // empty' <<<"$INPUT_JSON")"
AGENT_TYPE="$(jq -r '.agent_type // empty' <<<"$INPUT_JSON")"
if [[ -n "$AGENT_ID" || ( -n "$AGENT_TYPE" && "$AGENT_TYPE" != "worker" ) ]]; then
  exit 0
fi

if [[ -n "${NT_BROWSER_OPERATION_SUBPROCESS:-}" ]]; then
  exit 0
fi

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT_JSON")"
TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$INPUT_JSON")"
CALLED_SKILLS="$(collect_called_skills "$SESSION_ID" "$TRANSCRIPT_PATH")"

# grep をパイプの終端に置くな。pipefail 下では上流が SIGPIPE で死に、マッチしたのに「しなかった」と判定される。
if grep -qE '^(browser-operation|nt-common:browser-operation|artifact-architecture|nt-common:artifact-architecture)$' <<<"$CALLED_SKILLS"; then
  exit 0
fi

REASON="$(jq -n -r --arg target "$TARGET_LABEL" '
  "🚫 browser-operation skill が未起動のまま " + $target + " を実行しようとしています。先に Skill ツールで nt-common:browser-operation を起動し、メイン直叩き / 別タブの対話 claude のどちらで進めるかをユーザーに選ばせてから再試行しろ。"
')"
emit_pretooluse_decision deny "$REASON"

exit 0
