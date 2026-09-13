#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-bash-agent-rules-skill.sh"
[[ -f "$HOOK" ]] || { echo "deny-bash-agent-rules-skill.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# skill 未起動の状態。中身が空でもファイルとして実在させないと hook が素通しする。
EMPTY_TRANSCRIPT="$TMP_ROOT/empty.jsonl"
: >"$EMPTY_TRANSCRIPT"

# skill 起動済みの状態。会話ログに Skill ツールの呼び出しが残っている形を作る。
GIT_RULES_TRANSCRIPT="$TMP_ROOT/git-rules.jsonl"
jq -cn '{type: "assistant", message: {content: [{type: "tool_use", name: "Skill", input: {skill: "git-rules"}}]}}' >"$GIT_RULES_TRANSCRIPT"
AGENT_RULES_TRANSCRIPT="$TMP_ROOT/agent-rules.jsonl"
jq -cn '{type: "assistant", message: {content: [{type: "tool_use", name: "Skill", input: {skill: "nt-common:agent-rules"}}]}}' >"$AGENT_RULES_TRANSCRIPT"

# 実在しないセッション ID。hook が読む skills.log を「無い」状態にするため。
SESSION_ID="command-rules-gate-test-session"

failures=0
total=0

run_case() {
  local expected=$1 label=$2 cmd=$3 transcript=${4:-$EMPTY_TRANSCRIPT}
  local out actual
  total=$((total + 1))
  out="$(jq -n --arg c "$cmd" --arg t "$transcript" --arg s "$SESSION_ID" \
    '{tool_name: "Bash", session_id: $s, transcript_path: $t, tool_input: {command: $c}}' \
    | bash "$HOOK" 2>&1)"
  if [[ -z "$out" ]]; then
    actual="pass"
  elif grep -q '"permissionDecision": "deny"' <<<"$out"; then
    actual="deny"
  else
    actual="other"
  fi
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    printf '    コマンド: %s\n' "$cmd"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

run_agent_case() {
  local expected=$1 label=$2 transcript=${3:-$EMPTY_TRANSCRIPT}
  local out actual
  total=$((total + 1))
  out="$(jq -n --arg t "$transcript" --arg s "$SESSION_ID" \
    '{tool_name: "Agent", session_id: $s, transcript_path: $t, tool_input: {prompt: "調べて"}}' \
    | bash "$HOOK" 2>&1)"
  if [[ -z "$out" ]]; then
    actual="pass"
  elif grep -q '"permissionDecision": "deny"' <<<"$out"; then
    actual="deny"
  else
    actual="other"
  fi
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- ブランチを新しく作る形 → 拒否 ---
run_case deny "switch -c" 'git switch -c issue-1'
run_case deny "switch --create" 'git switch --create issue-1'
run_case deny "switch -C（強制作成）" 'git switch -C issue-1'
run_case deny "checkout -b" 'git checkout -b issue-1'
run_case deny "checkout -B（強制作成）" 'git checkout -B issue-1'
run_case deny "checkout の途中に -b" 'git checkout --track -b issue-1 origin/issue-1'
run_case deny "&& でつないだ2つ目が switch -c" 'git fetch origin && git switch -c issue-1'

# --- worktree の追加・PR の持ち込み → 拒否 ---
run_case deny "worktree add" 'git worktree add ../wt-issue-1 -b issue-1'
run_case deny "orca worktree create" 'orca worktree create --repo path:/tmp/repo --name issue-1 --base-branch main --json'
run_case deny "gh pr checkout" 'gh pr checkout 123'

# --- 既存の対象（push / tag の書き込み形） → 拒否 ---
run_case deny "push" 'git push'
run_case deny "push origin" 'git push origin issue-1'
run_case deny "tag -a" 'git tag -a v1.0.0 -m リリース'
run_case deny "tag の削除" 'git tag --delete v1.0.0'

# --- マージ・ブランチ配布・タグ付与の gh コマンド → 拒否 ---
run_case deny "gh pr merge" 'gh pr merge 123 --merge --delete-branch'
run_case deny "gh pr merge（番号なし）" 'gh pr merge --squash'
run_case deny "gh issue develop" 'gh issue develop 123 --name issue-123'
run_case deny "gh release create" 'gh release create nt-common--v2.0.148 --title nt-common--v2.0.148 --notes 本文'
run_case deny "gh release delete" 'gh release delete nt-common--v2.0.148 --yes'

# --- サブエージェントの起動 → 拒否 ---
run_agent_case deny "Agent 起動"

# --- ブランチの移動・ファイルの復元 → 素通し ---
run_case pass "switch でブランチ移動" 'git switch main'
run_case pass "switch -（直前のブランチへ）" 'git switch -'
run_case pass "switch --detach" 'git switch --detach HEAD~1'
run_case pass "checkout でブランチ移動" 'git checkout main'
run_case pass "checkout -- でファイル復元" 'git checkout -- src/foo.php'
run_case pass "checkout でファイル復元（-- なし）" 'git checkout src/foo.php'
run_case pass "checkout でブランチ指定のファイル復元" 'git checkout main -- docs/b-plan.md'

# --- 一覧・参照系 → 素通し ---
run_case pass "worktree list" 'git worktree list'
run_case pass "worktree remove" 'git worktree remove ../wt-issue-1'
run_case pass "orca worktree list" 'orca worktree list --json'
run_case pass "orca worktree rm" 'orca worktree rm --worktree path:/tmp/wt --json'
run_case pass "tag（一覧）" 'git tag'
run_case pass "tag -l" 'git tag -l "v1.*"'
run_case pass "gh pr view" 'gh pr view 123'
run_case pass "gh pr list" 'gh pr list --state open'
run_case pass "gh release list" 'gh release list --limit 5'
run_case pass "gh release view" 'gh release view nt-common--v2.0.147'
run_case pass "gh release delete-asset" 'gh release delete-asset v1.0.0 dist.zip'
run_case pass "gh issue view" 'gh issue view 123 --json body'
run_case pass "status" 'git status --porcelain'
run_case pass "log" 'git log --oneline -10'

# --- 文字列として現れるだけ → 素通し ---
run_case pass "コミットメッセージに push と書く" "git commit -m 'git push の手順を直した'"
run_case pass "コミットメッセージに switch -c と書く" "git commit -m 'git switch -c の順番を直した'"
run_case pass "worktree add を grep するだけ" "grep -rn 'git worktree add' ./docs"
run_case pass "PR 本文に gh pr merge と書く" "gh pr view 123 --json body --jq .body | grep 'gh pr merge'"

# --- 担当の skill が起動済み → 素通し ---
run_case pass "git-rules 起動済みなら switch -c も通る" 'git switch -c issue-1' "$GIT_RULES_TRANSCRIPT"
run_case pass "git-rules 起動済みなら push も通る" 'git push' "$GIT_RULES_TRANSCRIPT"
run_case pass "git-rules 起動済みなら gh pr merge も通る" 'gh pr merge 123 --merge --delete-branch' "$GIT_RULES_TRANSCRIPT"
run_agent_case pass "agent-rules 起動済みなら Agent も通る" "$AGENT_RULES_TRANSCRIPT"

# --- 別の分岐の skill だけ起動済み → 拒否（分岐ごとに要求する skill が違う） ---
run_case deny "agent-rules だけでは switch -c は通らない" 'git switch -c issue-1' "$AGENT_RULES_TRANSCRIPT"
run_agent_case deny "git-rules だけでは Agent は通らない" "$GIT_RULES_TRANSCRIPT"

if [[ "$failures" -gt 0 ]]; then
  printf '\ncommand-rules-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'command-rules-gate: %d 件すべて期待どおり\n' "$total"
