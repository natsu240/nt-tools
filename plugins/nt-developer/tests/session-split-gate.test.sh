#!/usr/bin/env bash
# **検査用のリポジトリを /tmp や $TMPDIR 配下（mktemp -d の既定）へ移すな。** hook がそこを対象外にしているため、止めるべき操作が素通しになる。

set -uo pipefail
unset GIT_DIR GIT_WORK_TREE

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-session-split.sh"
[[ -f "$HOOK" ]] || { echo "hook が見つかりません: $HOOK"; exit 1; }

mkdir -p "$HOME/.cache"
TMP_ROOT="$(mktemp -d "$HOME/.cache/nt-session-split.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_HOME="$TMP_ROOT/home"
mkdir -p "$FAKE_HOME/.claude/state" "$FAKE_HOME/.claude/hook-state"

GIT_QUIET=(git -c user.name=test -c user.email=test@example.com -c init.defaultBranch=main)

# plans 経路のリポジトリ。本体のチェックアウトとワークツリーを両方作る。
"${GIT_QUIET[@]}" init --quiet "$TMP_ROOT/repo"
"${GIT_QUIET[@]}" -C "$TMP_ROOT/repo" commit --quiet --allow-empty -m init
REPO="$(git -C "$TMP_ROOT/repo" rev-parse --show-toplevel)"
"${GIT_QUIET[@]}" -C "$REPO" worktree add --quiet "$TMP_ROOT/gripe-20260910-000000" -b gripe-work
GRIPE_WT="$(git -C "$TMP_ROOT/gripe-20260910-000000" rev-parse --show-toplevel)"

PLAN="$TMP_ROOT/plan.md"
printf '## 実装ステップ\n\n- [ ] Step 1\n' >"$PLAN"

record_plan() {
  jq -cn --arg repo "$REPO" --arg plan "$1" '{repo: $repo, plan: $plan}' \
    >"$FAKE_HOME/.claude/state/plan-current$(printf '%s' "$REPO" | tr '/' '_').json"
}

write_skill_log() {
  local session=$1
  shift
  printf '%s\n' "$@" >"$FAKE_HOME/.claude/hook-state/${session}_skills.log"
}

failures=0
total=0

classify() {
  if [[ -z "$1" ]]; then
    echo pass
  elif grep -q '"permissionDecision": "deny"' <<<"$1"; then
    echo deny
  else
    echo other
  fi
}

run_gate() {
  local expected=$1 label=$2 payload=$3
  local out actual
  total=$((total + 1))
  out="$(printf '%s' "$payload" | HOME="$FAKE_HOME" bash "$HOOK" 2>&1)"
  actual="$(classify "$out")"
  [[ "$actual" == "$expected" ]] || { failures=$((failures + 1)); printf 'NG  期待=%-6s 実際=%-6s %s\n出力: %s\n' "$expected" "$actual" "$label" "$out"; }
}

payload() {
  local skill=$1 cwd=$2 session=$3
  jq -cn --arg skill "$skill" --arg cwd "$cwd" --arg session "$session" \
    '{tool_name: "Skill", tool_input: {skill: $skill}, cwd: $cwd, session_id: $session}'
}

record_plan "$PLAN"

# --- 工程を跨いだ連続起動 → 拒否 ---
write_skill_log plan-then-implement "nt-developer:plan"
run_gate deny "計画セッションから続けて implement を起動" "$(payload nt-developer:implement "$REPO" plan-then-implement)"
run_gate deny "プレフィックス無しの skill 名でも止める" "$(payload implement "$REPO" plan-then-implement)"

write_skill_log implement-then-review "nt-developer:implement"
run_gate deny "実装セッションから続けて review を起動" "$(payload nt-developer:review "$REPO" implement-then-review)"

# --- 止めてはいけない例: 工程を跨がない再起動 ---
run_gate pass "実装セッションで implement を起動し直す" "$(payload nt-developer:implement "$REPO" implement-then-review)"
write_skill_log plan-only "nt-developer:plan"
run_gate pass "計画セッションで plan-review を起動" "$(payload nt-developer:plan-review "$REPO" plan-only)"
run_gate pass "計画セッションで plan を起動し直す" "$(payload nt-developer:plan "$REPO" plan-only)"

# --- 止めてはいけない例: 担当外の skill ---
run_gate pass "前工程が起動済みでも commit は止めない" "$(payload nt-developer:commit "$REPO" plan-then-implement)"

# --- 止めてはいけない例: 前工程を起動していないセッション ---
write_skill_log fresh "nt-developer:git-rules"
run_gate pass "前工程を起動していないセッションでの implement" "$(payload nt-developer:implement "$REPO" fresh)"

# --- 止めてはいけない例: 計画が特定できない作業 ---
record_plan "$TMP_ROOT/does-not-exist.md"
run_gate pass "計画が特定できない作業での implement" "$(payload nt-developer:implement "$REPO" plan-then-implement)"
record_plan "$PLAN"

# --- 止めてはいけない例: 一時ディレクトリ配下 ---
run_gate pass "スクラッチパッド配下での implement" "$(payload nt-developer:implement /tmp/scratch plan-then-implement)"

# --- 止めてはいけない例: gripe のワークツリー ---
run_gate pass "gripe のワークツリーでの implement" "$(payload nt-developer:implement "$GRIPE_WT" plan-then-implement)"

# --- 止めてはいけない例: マーカー行を持つリポジトリ ---
mkdir -p "$REPO/project_notes"
printf 'claude-session-split: skip\n' >"$REPO/project_notes/automation.md"
run_gate pass "マーカー行を持つリポジトリでの implement" "$(payload nt-developer:implement "$REPO" plan-then-implement)"
run_gate pass "マーカー行を持つリポジトリのワークツリーでの review" "$(payload nt-developer:review "$GRIPE_WT" implement-then-review)"
printf 'claude-merge-approval: skip\n' >"$REPO/project_notes/automation.md"
run_gate deny "別のマーカー行だけでは通さない" "$(payload nt-developer:implement "$REPO" plan-then-implement)"

if [[ "$failures" -gt 0 ]]; then
  printf '\nsession-split-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'session-split-gate: %d 件すべて期待どおり\n' "$total"
