#!/usr/bin/env bash
# Agent / Bash の PreToolUse hook。
# 要求する skill は Agent 起動なら agent-rules、Git 操作なら git-rules で、このセッションのトランスクリプト内でまだ Skill ツール経由で呼ばれていなければ deny する（ファイル名は hooks.json の書き換えを避けるため据え置いている）。一度呼べばセッション中は以降素通しする（使い切りにしない）。
# 内容が毎回変わるものではなく、コマンドのたびに読み直させると往復が増えるだけのため。
# skill は namespace 無し（personal skill 由来）・`nt-developer:` 付き（plugin 由来）のどちらで呼ばれても許可する。

set -euo pipefail

INPUT_JSON="$(cat)"

# クォートの中身を落としてから判定する。コミットメッセージ本文に git push と書いただけで止まるのを防ぐため。
# shellcheck source=lib-strip-quoted.sh
source "${BASH_SOURCE[0]%/*}/lib-strip-quoted.sh"
# shellcheck source=lib-branch-create.sh
source "${BASH_SOURCE[0]%/*}/lib-branch-create.sh"
# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"
# shellcheck source=lib-called-skills.sh
source "${BASH_SOURCE[0]%/*}/lib-called-skills.sh"

# git commit / gh pr create|edit|review は別の hook が専用の skill を強制するため、ここでは対象にしない（二重に止めない）。他に規約を読ませる仕組みが無いものだけを担当する。
CMD_HEAD='(^|[;&|(]|\$\()[[:space:]]*([A-Za-z0-9_.-]*/)*'
GIT_PUSH_RE="${CMD_HEAD}git[[:space:]]+push([[:space:]]|\$)"
# git tag は引数なし / -l / --list / -n が一覧表示なので、タグを作る・消す形だけを拾う。
GIT_TAG_WRITE_RE="${CMD_HEAD}git[[:space:]]+tag[[:space:]]+(-[adfsu]|--annotate|--sign|--delete|--force|[^-])"
# worktree は追加だけを拾う（list / remove / prune は素通し）。
GIT_WORKTREE_ADD_RE="${CMD_HEAD}git[[:space:]]+worktree[[:space:]]+add([[:space:]]|\$)"
ORCA_WORKTREE_CREATE_RE="${CMD_HEAD}orca[[:space:]]+worktree[[:space:]]+create([[:space:]]|\$)"
# gh pr checkout は手元にブランチが残るので、確認後に消す作法を読ませる。
GH_PR_CHECKOUT_RE="${CMD_HEAD}gh[[:space:]]+pr[[:space:]]+checkout([[:space:]]|\$)"
GH_PR_MERGE_RE="${CMD_HEAD}gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|\$)"
GH_ISSUE_DEVELOP_RE="${CMD_HEAD}gh[[:space:]]+issue[[:space:]]+develop([[:space:]]|\$)"
GH_RELEASE_WRITE_RE="${CMD_HEAD}gh[[:space:]]+release[[:space:]]+(create|delete)([[:space:]]|\$)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
case "$TOOL_NAME" in
  Agent)
    REQUIRED_SKILL_RE='^(nt-common:)?agent-rules$'
    DENY_REASON="🚫 サブエージェントを起動する前に agent-rules skill が未起動です。先に Skill ツールで \`agent-rules\`（plugin 経由なら \`nt-common:agent-rules\`）を起動し、テーマは1つだけ渡す／独立並列タスクは1メッセージにまとめて呼ぶ／起動済みエージェントへの追加依頼は SendMessage で継続する、といった運用規約を読んでから再試行しろ。"
    ;;
  Bash)
    COMMAND="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
    [[ -z "$COMMAND" ]] && exit 0
    STRIPPED="$(strip_quoted "$COMMAND")"
    REQUIRED_SKILL_RE='^(nt-developer:)?git-rules$'
    if is_branch_create_command "$STRIPPED" \
      || grep -qE "$GIT_WORKTREE_ADD_RE|$ORCA_WORKTREE_CREATE_RE|$GH_PR_CHECKOUT_RE" <<<"$STRIPPED"; then
      DENY_REASON="🚫 ブランチを作る・ワークツリーを足す・PR を手元に持ってくる前に git-rules skill が未起動です。先に Skill ツールで \`git-rules\`（plugin 経由なら \`nt-developer:git-rules\`）を起動し、base を最新化してから切る／ワークツリーは orca worktree create で作り渡す値はリポジトリごとに確認する／確認のために持ってきたブランチは終わったら消す、といった Git 作業の作法を読んでから再試行しろ。このセッションで一度読めば以降は止まりません。"
    elif grep -qE "$GIT_PUSH_RE|$GIT_TAG_WRITE_RE" <<<"$STRIPPED"; then
      DENY_REASON="🚫 git push / git tag の前に git-rules skill が未起動です。先に Skill ツールで \`git-rules\`（plugin 経由なら \`nt-developer:git-rules\`）を起動し、base を最新化してから切る／確認のために持ってきたブランチは終わったら消す、といった Git 作業の作法を読んでから再試行しろ。あわせて \`bash-rules\`（同 \`nt-common:bash-rules\`）も起動し、PR 本文・コミットメッセージは一時ファイルを経由せずインラインで渡す／ファイル読み書きは Bash より専用ツールを使う／ヒアドキュメントでファイルを作らない、といった Bash 利用ルールも読め。このセッションで一度読めば以降は止まりません。"
    elif grep -qE "$GH_PR_MERGE_RE|$GH_ISSUE_DEVELOP_RE|$GH_RELEASE_WRITE_RE" <<<"$STRIPPED"; then
      DENY_REASON="🚫 gh pr merge / gh issue develop / gh release create|delete の前に git-rules skill が未起動です。先に Skill ツールで \`git-rules\`（plugin 経由なら \`nt-developer:git-rules\`）を起動し、マージはマージコミット方式だけを使い PR 番号を明示する／ブランチを gh issue develop で作らない／タグ付け・Release 作成の手順がリポジトリに書かれていればそれに従う、といった Git 作業の作法を読んでから再試行しろ。このセッションで一度読めば以降は止まりません。"
    else
      exit 0
    fi
    ;;
  *)
    exit 0
    ;;
esac

# サブエージェントが更にサブエージェントを起動する経路は対象外にする。Skill ツールを持たない構成のサブエージェントでは条件を満たす手段が無く、恒久 deny になってしまうため。
# 判定にトランスクリプトのパスを使うな。hook payload の transcript_path は session_id から機械的に導出され（Claude Code 2.1.220 では transcript_path: nP(session_id)）、サブエージェントの session_id は親と同じなので、渡ってくるのは常に親セッションの記録になる。
# 実体は <セッションID>/subagents/[workflows/wf_*/]agent-*.jsonl に置かれるが、そのパスは hook に渡らない。
# 共通フィールドの agent_id / agent_type で判定する（メインは agent_type="worker" かつ agent_id 未設定）。
AGENT_ID="$(jq -r '.agent_id // empty' <<<"$INPUT_JSON")"
AGENT_TYPE="$(jq -r '.agent_type // empty' <<<"$INPUT_JSON")"
if [[ -n "$AGENT_ID" || ( -n "$AGENT_TYPE" && "$AGENT_TYPE" != "worker" ) ]]; then
  exit 0
fi

TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$INPUT_JSON")"
if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT_JSON")"
CALLED_SKILLS="$(collect_called_skills "$SESSION_ID" "$TRANSCRIPT_PATH")"

# grep はパイプの終端に置くな。set -o pipefail 下では grep -q がマッチした瞬間に終了して上流が SIGPIPE で死に、その終了ステータスがパイプライン全体の結果になる（マッチしているのにマッチしなかったと判定される）。here-string で渡す。
if grep -qE "$REQUIRED_SKILL_RE" <<<"$CALLED_SKILLS"; then
  exit 0
fi

emit_pretooluse_decision deny "$DENY_REASON"

exit 0
