#!/usr/bin/env bash
# Skill ツールの PreToolUse hook。
# code-review を自動レビューの保存結果パス付きで再開するとき、パスが指す repo と cwd の repo が違えば deny する。

set -euo pipefail

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Skill" ]] && exit 0

SKILL_NAME="$(jq -r '.tool_input.skill // empty' <<<"$INPUT_JSON")"
case "$SKILL_NAME" in
  code-review|nt-developer:code-review) ;;
  *) exit 0 ;;
esac

ARGS="$(jq -r '.tool_input.args // empty' <<<"$INPUT_JSON")"
[[ -z "$ARGS" ]] && exit 0

case "$ARGS" in
  */_auto-results/*.json) ;;
  *) exit 0 ;;
esac

# shellcheck source=lib-repo-identity.sh
source "${BASH_SOURCE[0]%/*}/lib-repo-identity.sh"
# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

RESULT_ORG_REPO_PR="$(parse_auto_results_filename "$ARGS")"
[[ -z "$RESULT_ORG_REPO_PR" ]] && exit 0

RESULT_ORG="$(awk '{print $1}' <<<"$RESULT_ORG_REPO_PR")"
RESULT_REPO="$(awk '{print $2}' <<<"$RESULT_ORG_REPO_PR")"
RESULT_PR="$(awk '{print $3}' <<<"$RESULT_ORG_REPO_PR")"

CWD="$(jq -r '.cwd // empty' <<<"$INPUT_JSON")"
[[ -z "$CWD" ]] && exit 0

CWD_ORG_REPO="$(git_remote_owner_repo "$CWD")"
[[ -z "$CWD_ORG_REPO" ]] && exit 0

if [[ "$CWD_ORG_REPO" == "$RESULT_ORG/$RESULT_REPO" ]]; then
  exit 0
fi

REASON="🚫 この保存結果は ${RESULT_ORG}/${RESULT_REPO} の PR #${RESULT_PR} のものだ。今のセッションのリポジトリは ${CWD_ORG_REPO} で一致しない。${RESULT_REPO} のリポジトリのセッションで実行しろ。"

emit_pretooluse_decision deny "$REASON"

exit 0
