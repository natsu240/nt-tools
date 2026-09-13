#!/usr/bin/env bash
# Artifact ツールの PreToolUse hook。
# このセッションで artifact-templates / artifact-architecture のどちらも未起動なら、書き込み系の action を deny する。
#
# artifact-design を解除条件に含めない。design だけ起動して templates が取り残される形が、実際に苦情になった失敗そのものだ。
# 起動の順序は問わない。artifact-templates は artifact-design を前提にしたスキルなので、design を先に起動する流れを壊さない。

set -euo pipefail

INPUT_JSON="$(cat)"

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"
# shellcheck source=lib-called-skills.sh
source "${BASH_SOURCE[0]%/*}/lib-called-skills.sh"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
if [[ "$TOOL_NAME" != "Artifact" ]]; then
  exit 0
fi

# action 未指定は publish。読み取り系（list / read / comments / status 等）は既存 Artifact を読んでから直す流れを止めないため素通しする。
ACTION="$(jq -r '.tool_input.action // "publish"' <<<"$INPUT_JSON")"
case "$ACTION" in
  publish|upload_asset|delete_asset) ;;
  *) exit 0 ;;
esac

# 判定にトランスクリプトのパスを使うな。transcript_path は session_id から機械的に導出され、サブエージェントの session_id は親と同じなので、渡ってくるのは常に親セッションの記録になる。
# 共通フィールドの agent_id / agent_type で判定する（メインは agent_type="worker" かつ agent_id 未設定）。
AGENT_ID="$(jq -r '.agent_id // empty' <<<"$INPUT_JSON")"
AGENT_TYPE="$(jq -r '.agent_type // empty' <<<"$INPUT_JSON")"
if [[ -n "$AGENT_ID" || ( -n "$AGENT_TYPE" && "$AGENT_TYPE" != "worker" ) ]]; then
  exit 0
fi

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT_JSON")"
TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$INPUT_JSON")"
CALLED_SKILLS="$(collect_called_skills "$SESSION_ID" "$TRANSCRIPT_PATH")"

# grep はパイプの終端に置くな。set -o pipefail 下では grep -q がマッチした瞬間に終了して上流が SIGPIPE で死に、その終了ステータスがパイプライン全体の結果になる。here-string で渡す。
if grep -qE '^(artifact-templates|nt-common:artifact-templates|artifact-architecture|nt-common:artifact-architecture)$' <<<"$CALLED_SKILLS"; then
  exit 0
fi

REASON="$(jq -n -r --arg action "$ACTION" '
  "🚫 artifact-templates skill が未起動のまま Artifact(" + $action + ") を実行しようとしています。先に Skill ツールで nt-common:artifact-templates を起動しろ。\n\nテーブル・一覧・比較資料なら型のテンプレートをコピーして使え。インフラ構成図なら nt-common:artifact-architecture を起動しろ。単発の説明ページ・図解のようにどちらの型にも当たらない場合も、対象外だと判定するために一度起動しろ。\n\nartifact-design だけでは代わりにならない。design が起動済みでもこの hook は止める。"
')"
emit_pretooluse_decision deny "$REASON"

exit 0
