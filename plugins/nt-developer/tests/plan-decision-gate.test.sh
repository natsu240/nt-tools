#!/usr/bin/env bash
# **検査用のリポジトリを /tmp や $TMPDIR 配下（mktemp -d の既定）へ移すな。** hook がそこを対象外にしているため、止めるべき操作が素通しになる。

set -uo pipefail

HOOKS_DIR="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)"
GATE_HOOK="$HOOKS_DIR/deny-plan-decision-gate.sh"
[[ -f "$GATE_HOOK" ]] || { echo "hook が見つかりません: $GATE_HOOK"; exit 1; }

mkdir -p "$HOME/.cache"
TMP_ROOT="$(mktemp -d "$HOME/.cache/nt-plan-decision.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_HOME="$TMP_ROOT/home"
mkdir -p "$FAKE_HOME/.claude/state"

# plans 経路（ブランチ名に issue-<番号> を使わない）のリポジトリ。hook 側の git-common-dir 解決（macOS の /private/var 正規化）に揃える。
mkdir -p "$TMP_ROOT/repo"
git -C "$TMP_ROOT/repo" init -q -b dev-user
git -C "$TMP_ROOT/repo" commit -q --allow-empty -m init
REPO="$(git -C "$TMP_ROOT/repo" rev-parse --show-toplevel)"

CODE_PATH="$REPO/src/Foo.php"
mkdir -p "$REPO/src"

write_plan() {
  local path=$1 body=$2
  printf '%s' "$body" >"$path"
}

record_plan() {
  local plan_path=$1
  jq -cn --arg repo "$REPO" --arg plan "$plan_path" '{repo: $repo, plan: $plan}' \
    >"$FAKE_HOME/.claude/state/plan-current$(printf '%s' "$REPO" | tr '/' '_').json"
}

DECIDED_PLAN="$TMP_ROOT/decided.md"
write_plan "$DECIDED_PLAN" '## 決めたこと

| 何を決めるか | 選べた案 | 決めた案 |
|---|---|---|
| hook の判定根拠 | A / B | A |

## 確認テスト

確認テスト: 合格（2026-09-07）

計画書レビュー: 合格（2026-09-07）
'

NO_DECIDED_SECTION_PLAN="$TMP_ROOT/no-decided.md"
write_plan "$NO_DECIDED_SECTION_PLAN" '## 実装ステップ

- [ ] Step 1: 何かをする
'

UNRESOLVED_ROW_PLAN="$TMP_ROOT/unresolved.md"
write_plan "$UNRESOLVED_ROW_PLAN" '## 決めたこと

| 何を決めるか | 選べた案 | 決めた案 |
|---|---|---|
| hook の判定根拠 | A / B | 未確定 |

## 確認テスト

確認テスト: 合格（2026-09-07）

計画書レビュー: 合格（2026-09-07）
'

NO_TEST_PASS_PLAN="$TMP_ROOT/no-test-pass.md"
write_plan "$NO_TEST_PASS_PLAN" '## 決めたこと

| 何を決めるか | 選べた案 | 決めた案 |
|---|---|---|
| hook の判定根拠 | A / B | A |

## 確認テスト

まだ確認していない
'

NO_PLAN_REVIEW_PLAN="$TMP_ROOT/no-plan-review.md"
write_plan "$NO_PLAN_REVIEW_PLAN" '## 決めたこと

| 何を決めるか | 選べた案 | 決めた案 |
|---|---|---|
| hook の判定根拠 | A / B | A |

確認テスト: 合格（2026-09-07）
'

failures=0
total=0

classify_gate() {
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
  out="$(printf '%s' "$payload" | HOME="$FAKE_HOME" TMPDIR="$FAKE_HOME/unused-tmpdir" bash "$GATE_HOOK" 2>&1)"
  actual="$(classify_gate "$out")"
  [[ "$actual" == "$expected" ]] || { failures=$((failures + 1)); printf 'NG  期待=%-6s 実際=%-6s %s\n出力: %s\n' "$expected" "$actual" "$label" "$out"; }
}

file_payload() {
  local path=$1 cwd=$2
  jq -cn --arg path "$path" --arg cwd "$cwd" \
    '{tool_name: "Edit", tool_input: {file_path: $path}, agent_type: "worker", cwd: $cwd}'
}

write_payload() {
  local path=$1 cwd=$2
  jq -cn --arg path "$path" --arg cwd "$cwd" \
    '{tool_name: "Write", tool_input: {file_path: $path}, agent_type: "worker", cwd: $cwd}'
}

skill_payload() {
  local skill=$1 cwd=$2
  jq -cn --arg skill "$skill" --arg cwd "$cwd" \
    '{tool_name: "Skill", tool_input: {skill: $skill}, agent_type: "worker", cwd: $cwd}'
}

bash_payload() {
  local command=$1 cwd=$2
  jq -cn --arg command "$command" --arg cwd "$cwd" \
    '{tool_name: "Bash", tool_input: {command: $command}, agent_type: "worker", cwd: $cwd}'
}

subagent_payload() {
  local path=$1 cwd=$2
  jq -cn --arg path "$path" --arg cwd "$cwd" \
    '{tool_name: "Edit", tool_input: {file_path: $path}, agent_id: "agent-abc", agent_type: "explorer", cwd: $cwd}'
}

# --- 計画が特定できない → 素通し ---
record_plan "$TMP_ROOT/does-not-exist.md"
run_gate pass "計画書が実在しない（特定できない）" "$(file_payload "$CODE_PATH" "$REPO")"

# --- 決めたこと・確認テストが揃っている計画 → 素通し ---
record_plan "$DECIDED_PLAN"
run_gate pass "決めたこと・確認テストが揃っている計画の Edit" "$(file_payload "$CODE_PATH" "$REPO")"
run_gate pass "決めたこと・確認テストが揃っている計画での commit skill 起動" "$(skill_payload commit "$REPO")"

# --- サブエージェント配下も同じ判定にかける ---
record_plan "$NO_DECIDED_SECTION_PLAN"
run_gate deny "「決めたこと」節が無い計画でのサブエージェント配下からの Edit" "$(subagent_payload "$CODE_PATH" "$REPO")"

# --- /tmp 配下への書き込み → 素通し ---
run_gate pass "/tmp 配下への Edit" "$(file_payload /tmp/scratch.php "$REPO")"


# --- 揃っている計画ならサブエージェント配下でも素通し ---
record_plan "$DECIDED_PLAN"
run_gate pass "決めたこと・確認テストが揃っている計画でのサブエージェント配下からの Edit" "$(subagent_payload "$CODE_PATH" "$REPO")"

# --- 「決めたこと」節が無い → 拒否 ---
record_plan "$NO_DECIDED_SECTION_PLAN"
run_gate deny "「決めたこと」節が無い計画の Edit" "$(file_payload "$CODE_PATH" "$REPO")"

# --- 「決めたこと」表に未確定の行が残っている → 拒否 ---
record_plan "$UNRESOLVED_ROW_PLAN"
run_gate deny "未確定の行が残っている計画の Edit" "$(file_payload "$CODE_PATH" "$REPO")"
run_gate deny "未確定の行が残っている計画での pr skill 起動" "$(skill_payload pr "$REPO")"

# --- 「確認テスト: 合格」が無い → 拒否 ---
record_plan "$NO_TEST_PASS_PLAN"
run_gate deny "確認テスト: 合格が無い計画の Edit" "$(file_payload "$CODE_PATH" "$REPO")"

record_plan "$NO_PLAN_REVIEW_PLAN"
run_gate deny "計画書レビュー: 合格が無い計画の Edit" "$(file_payload "$CODE_PATH" "$REPO")"
run_gate deny "計画書レビュー: 合格が無い計画での commit skill 起動" "$(skill_payload commit "$REPO")"
run_gate pass "計画書レビュー: 合格が無い状態での計画書への Write" "$(write_payload "$REPO/plans/進行中/other/計画.md" "$REPO")"
run_gate pass "計画書レビュー: 合格が無い状態でのスクラッチパッドへの Edit" "$(file_payload /tmp/scratch.php "$REPO")"

record_plan "$TMP_ROOT/does-not-exist.md"
run_gate pass "計画が特定できない作業（計画書レビューの検査も適用しない）" "$(file_payload "$CODE_PATH" "$REPO")"

record_plan "$NO_TEST_PASS_PLAN"

# --- 計画書そのものへの書き込み → 素通し ---
run_gate pass "確認テスト: 合格が無い状態での計画書への Edit" "$(file_payload "$REPO/plans/進行中/other/計画.md" "$REPO")"
run_gate pass "確認テスト: 合格が無い状態での計画書への Write" "$(write_payload "$REPO/plans/進行中/other/計画.md" "$REPO")"
run_gate deny "plans を名前に含むだけのコードファイルへの Edit" "$(file_payload "$REPO/src/plans.php" "$REPO")"

# --- 計画を Issue の description へ書き込むだけの Bash → 素通し ---
record_plan "$NO_DECIDED_SECTION_PLAN"
run_gate pass "description の書き込み（パスをクォートしない）" "$(bash_payload "gh issue edit 720 --body-file $REPO/body.md" "$REPO")"
run_gate pass "description の書き込み（パスをクォートする）" "$(bash_payload "gh issue edit 720 --body-file \"$REPO/body.md\"" "$REPO")"
run_gate pass "description の書き込み（--body-file=<パス> 形式）" "$(bash_payload "gh issue edit 720 --body-file=$REPO/body.md" "$REPO")"
run_gate pass "description の書き込み（--body に直接渡す）" "$(bash_payload 'gh issue edit 720 --body "計画"' "$REPO")"

# --- description の書き込み以外・他のコマンドとの連結 → 拒否 ---
run_gate deny "label だけを足す gh issue edit" "$(bash_payload 'gh issue edit 720 --add-label gripe' "$REPO")"
run_gate deny "description の書き込みに他のコマンドを連結" "$(bash_payload "gh issue edit 720 --body-file $REPO/body.md && git commit -m plan" "$REPO")"
run_gate deny "description の書き込みにコマンド置換を含める" "$(bash_payload 'gh issue edit 720 --body-file "$(mktemp)"' "$REPO")"
run_gate deny "description の書き込みを装ったリダイレクト" "$(bash_payload "gh issue edit 720 --body-file $REPO/body.md > $REPO/out.txt" "$REPO")"
run_gate deny "通常のコミット" "$(bash_payload 'git commit -m plan' "$REPO")"

if [[ "$failures" -gt 0 ]]; then
  printf '\nplan-decision-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'plan-decision-gate: %d 件すべて期待どおり\n' "$total"
