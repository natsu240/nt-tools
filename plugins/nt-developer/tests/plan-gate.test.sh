#!/usr/bin/env bash
# **検査用のリポジトリを /tmp や $TMPDIR 配下（mktemp -d の既定）へ移すな。** hook がそこを対象外にしているため、止めるべき操作が素通しになる。

set -uo pipefail

HOOKS_DIR="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)"
GATE_HOOK="$HOOKS_DIR/deny-plan-skill-gate.sh"
[[ -f "$GATE_HOOK" ]] || { echo "hook が見つかりません: $GATE_HOOK"; exit 1; }

mkdir -p "$HOME/.cache"
TMP_ROOT="$(mktemp -d "$HOME/.cache/nt-plan-gate.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_HOME="$TMP_ROOT/home"
FAKE_TMPDIR="$TMP_ROOT/tmpdir"
mkdir -p "$FAKE_HOME/.claude/hook-state" "$FAKE_TMPDIR"

# skill 未起動の状態。中身が空でもファイルとして実在させないと hook が会話ログを読まない。
EMPTY_TRANSCRIPT="$TMP_ROOT/empty.jsonl"
: >"$EMPTY_TRANSCRIPT"

# plan 起動済みの状態を会話ログ側だけで表した形（skills.log は無い）。
CALLED_TRANSCRIPT="$TMP_ROOT/called.jsonl"
jq -cn '{type: "assistant", message: {content: [{type: "tool_use", name: "Skill", input: {skill: "nt-developer:plan"}}]}}' >"$CALLED_TRANSCRIPT"

# skills.log 側だけで plan 起動済みを表した形（会話ログには残っていない）。
printf 'nt-developer:plan\n' >"$FAKE_HOME/.claude/hook-state/called-via-log_skills.log"
printf 'nt-developer:implement\n' >"$FAKE_HOME/.claude/hook-state/implement_skills.log"
printf 'nt-developer:review\n' >"$FAKE_HOME/.claude/hook-state/review_skills.log"
printf 'nt-developer:deploy-watch\n' >"$FAKE_HOME/.claude/hook-state/deploy-watch_skills.log"
printf 'nt-developer:pr-comment\n' >"$FAKE_HOME/.claude/hook-state/pr-comment_skills.log"
printf 'nt-developer:pr-followup\n' >"$FAKE_HOME/.claude/hook-state/pr-followup_skills.log"
# 名前空間なしの短縮名で起動した形。
printf 'plan\n' >"$FAKE_HOME/.claude/hook-state/short-name_skills.log"
# 別の skill だけ起動している形（plan / implement / review は未起動として扱われるべき）。
printf 'nt-developer:code-style\n' >"$FAKE_HOME/.claude/hook-state/other-skill_skills.log"
printf 'nt-developer:past-plan-research\n' >"$FAKE_HOME/.claude/hook-state/partial-name_skills.log"

CODE_PATH="/home/user/project/src/Foo.php"

unset GIT_DIR GIT_WORK_TREE
MAIN_TREE="$TMP_ROOT/nt-tools"
mkdir -p "$MAIN_TREE/plugins"
git -C "$MAIN_TREE" init -q -b main
git -C "$MAIN_TREE" commit -q --allow-empty -m init
WORKTREE="$TMP_ROOT/nt-tools-issue-1"
git -C "$MAIN_TREE" worktree add -q -b issue-1 "$WORKTREE" >/dev/null 2>&1
AUTO_REVIEW_WORKTREE="$TMP_ROOT/auto-review-1"
git -C "$MAIN_TREE" worktree add -q -b auto-review-branch "$AUTO_REVIEW_WORKTREE" >/dev/null 2>&1

failures=0
total=0

report_ng() {
  local expected=$1 actual=$2 label=$3 out=$4
  failures=$((failures + 1))
  printf 'NG  期待=%-6s 実際=%-6s %s\n' "$expected" "$actual" "$label"
  [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
}

# 出力を pass / deny / other のいずれかに分類する。
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
  out="$(printf '%s' "$payload" | HOME="$FAKE_HOME" TMPDIR="$FAKE_TMPDIR" bash "$GATE_HOOK" 2>&1)"
  actual="$(classify_gate "$out")"
  [[ "$actual" == "$expected" ]] || report_ng "$expected" "$actual" "$label" "$out"
}

# ファイル編集系ツールの入力を組み立てる。
file_payload() {
  local tool=$1 path=$2 session=$3 transcript=${4:-$EMPTY_TRANSCRIPT}
  jq -cn --arg tool "$tool" --arg path "$path" --arg s "$session" --arg t "$transcript" \
    '{tool_name: $tool, tool_input: {file_path: $path}, session_id: $s, transcript_path: $t, agent_type: "worker"}'
}

# Bash の入力を組み立てる。
bash_payload() {
  local cmd=$1 session=$2 transcript=${3:-$EMPTY_TRANSCRIPT}
  jq -cn --arg c "$cmd" --arg s "$session" --arg t "$transcript" \
    '{tool_name: "Bash", tool_input: {command: $c}, session_id: $s, transcript_path: $t, agent_type: "worker"}'
}

# サブエージェント配下からの呼び出しを組み立てる。
subagent_payload() {
  local tool=$1 path=$2 session=${3:-no-skill}
  jq -cn --arg tool "$tool" --arg path "$path" --arg s "$session" --arg t "$EMPTY_TRANSCRIPT" \
    '{tool_name: $tool, tool_input: {file_path: $path}, session_id: $s, transcript_path: $t, agent_id: "agent-abc", agent_type: "explorer"}'
}

# --- plan / implement / review 未起動での編集・状態変更 → 拒否 ---
run_gate deny "Write（コード）" "$(file_payload Write "$CODE_PATH" no-skill)"
run_gate deny "Edit（コード）" "$(file_payload Edit "$CODE_PATH" no-skill)"
run_gate deny "MultiEdit（コード）" "$(file_payload MultiEdit "$CODE_PATH" no-skill)"
run_gate deny "Write（Markdown も対象）" "$(file_payload Write /home/user/project/README.md no-skill)"
run_gate deny "mkdir" "$(bash_payload 'mkdir -p /home/user/project/out' no-skill)"
run_gate deny "git commit" "$(bash_payload "git commit -m '修正した'" no-skill)"
run_gate deny "git branch 削除" "$(bash_payload 'git branch -d feature-x' no-skill)"
run_gate deny "git branch 削除（大文字）" "$(bash_payload 'git branch -D feature-x' no-skill)"
run_gate deny "git branch リネーム" "$(bash_payload 'git branch -m old-name new-name' no-skill)"
run_gate deny "git branch 新規作成" "$(bash_payload 'git branch feature-x' no-skill)"
run_gate deny "gh issue create" "$(bash_payload 'gh issue create --title タイトル' no-skill)"
run_gate deny "実ファイルへのリダイレクト" "$(bash_payload 'printf x > /home/user/project/out.txt' no-skill)"
run_gate deny "python3 -c の出力をファイルへリダイレクト" "$(bash_payload 'python3 -c "print(1698.69 / 1.5)" > /home/user/project/out.txt' no-skill)"
run_gate deny "クォートの中に rm がある bash -c" "$(bash_payload 'bash -c "rm -rf /home/user/project/out"' no-skill)"
run_gate deny "別の skill だけ起動済み" "$(file_payload Write "$CODE_PATH" other-skill)"
run_gate deny "名前の一部が一致するだけの skill" "$(file_payload Write "$CODE_PATH" partial-name)"

# --- plan / implement / review / deploy-watch のいずれかが起動済み → 素通し ---
run_gate pass "plan が skills.log で起動済み" "$(file_payload Write "$CODE_PATH" called-via-log)"
run_gate pass "implement で起動済み" "$(file_payload Write "$CODE_PATH" implement)"
run_gate pass "review で起動済み" "$(file_payload Write "$CODE_PATH" review)"
run_gate pass "deploy-watch で起動済み" "$(file_payload Write "$CODE_PATH" deploy-watch)"
run_gate pass "deploy-watch 起動済みなら gh issue edit も通る" "$(bash_payload 'gh issue edit 613 --body-file /home/user/body.md' deploy-watch)"
run_gate pass "pr-comment 起動済みなら gh pr review も通る" "$(bash_payload 'gh pr review 301 --request-changes --body-file /home/user/body.md' pr-comment)"
run_gate pass "pr-followup で起動済み" "$(file_payload Write "$CODE_PATH" pr-followup)"
run_gate pass "短縮名で起動済み" "$(file_payload Write "$CODE_PATH" short-name)"
run_gate pass "会話ログで起動済み" "$(file_payload Write "$CODE_PATH" no-skill "$CALLED_TRANSCRIPT")"
run_gate pass "起動済みなら git commit も通る" "$(bash_payload "git commit -m '修正した'" called-via-log)"

# --- 一時ディレクトリ配下 → 素通し（使い捨ての調査スクリプトを書けないと退路が塞がる） ---
run_gate pass "/tmp への Write" "$(file_payload Write /tmp/scratch.py no-skill)"
run_gate pass "/private/tmp への Write" "$(file_payload Write /private/tmp/claude-501/x/aggregate.py no-skill)"
run_gate pass "TMPDIR 配下への Write" "$(file_payload Write "$FAKE_TMPDIR/aggregate.py" no-skill)"
run_gate pass "code-review キャッシュ配下への Write" "$(file_payload Write "$FAKE_HOME/.claude/cache/code-review/_pr311/pr_context.txt" no-skill)"
run_gate deny "キャッシュ配下から親をたどる Write" "$(file_payload Write "$FAKE_HOME/.claude/cache/code-review/../../../project/src/Foo.php" no-skill)"

# --- Bash の一時領域・内部状態領域限定の状態変更コマンド → 素通し ---
run_gate pass "/tmp 配下の rm" "$(bash_payload 'rm -f /tmp/scratch.log' no-skill)"
run_gate pass "/private/tmp 配下の rm" "$(bash_payload 'rm -f /private/tmp/claude-501/x/aggregate.py' no-skill)"
run_gate pass "TMPDIR 配下の rm" "$(bash_payload "rm -f $FAKE_TMPDIR/scratch.log" no-skill)"
run_gate pass "\$HOME/.claude/state 配下の rm" "$(bash_payload "rm -f $FAKE_HOME/.claude/state/plan-current.json" no-skill)"
run_gate pass "\$HOME/.claude/hook-state 配下の rm" "$(bash_payload "rm -f $FAKE_HOME/.claude/hook-state/called-via-log_skills.log" no-skill)"
run_gate pass "cache-io.sh 経由の \$HOME/.claude/cache/code-review 配下 mkdir" "$(bash_payload "bash /home/user/plugins/nt-developer/scripts/cache-io.sh mkdir $FAKE_HOME/.claude/cache/code-review/_pr301" no-skill)"
run_gate pass "cache-io.sh 経由の \$HOME/.claude/cache/code-review 配下 write" "$(bash_payload "gh issue view 301 --json body --jq .body | bash /home/user/plugins/nt-developer/scripts/cache-io.sh write $FAKE_HOME/.claude/cache/code-review/_issue-docs/issue-301.md" no-skill)"


# --- 除外パスに見せかけつつ他のパスも含む状態変更コマンド → 拒否（一時領域限定であることを潰さない） ---
run_gate deny "除外パスと非除外パスが混在する rm" "$(bash_payload "rm -rf /tmp/scratch.log $CODE_PATH" no-skill)"
run_gate deny "\$HOME/.claude/state 配下に見せかけつつ他ファイルも消す rm" "$(bash_payload "rm -rf $FAKE_HOME/.claude/state/plan-current.json /etc/passwd" no-skill)"
run_gate deny "cache-io.sh 経由に見せかけつつ cache-review-with-codex 配下外も触る" "$(bash_payload "bash /home/user/plugins/nt-developer/scripts/cache-io.sh mkdir /etc/passwd" no-skill)"

# --- 読み取りだけの Bash → 素通し ---
run_gate pass "ls" "$(bash_payload 'ls -la /etc' no-skill)"
run_gate pass "grep 再帰" "$(bash_payload "grep -rn 'foo' ./src" no-skill)"
run_gate pass "find とパイプ" "$(bash_payload 'find . -name "*.json" | jq -s length' no-skill)"
run_gate pass "git status" "$(bash_payload 'git status --porcelain' no-skill)"
run_gate pass "git branch 一覧（引数なし）" "$(bash_payload 'git branch' no-skill)"
run_gate pass "git branch -r" "$(bash_payload 'git branch -r' no-skill)"
run_gate pass "git branch --show-current" "$(bash_payload 'git branch --show-current' no-skill)"
run_gate pass "gh pr view" "$(bash_payload 'gh pr view 123' no-skill)"
run_gate pass "エラー出力の捨て先だけ指定" "$(bash_payload 'ls -la /etc 2>/dev/null' no-skill)"
run_gate pass "ファイル記述子の複製だけ" "$(bash_payload 'ls -la /etc 2>&1' no-skill)"
run_gate pass "python3 -c の割り算（クォートの中の > 無し）" "$(bash_payload 'python3 -c "print(1698.69 / 1.5)"' no-skill)"
run_gate pass "python3 -c の中の比較演算子" "$(bash_payload 'python3 -c "print(849 if 1698 > 100 else 0)"' no-skill)"
run_gate pass "python3 -c の中の書式指定" "$(bash_payload "python3 -c \"print(f'{1698.69:>12,.2f}')\"" no-skill)"

# --- 引数値に渡した自然文の中のコマンド名 → 素通し（実行されない文字列で止めない） ---
run_gate pass "--text の自然文に rm が含まれる" "$(bash_payload "orca terminal send --text 'orca worktree rm の挙動を調べろ'" no-skill)"
run_gate pass "--text の自然文に git commit が含まれる" "$(bash_payload "orca terminal send --text \"git commit の前に止まる hook を調べろ\"" no-skill)"
run_gate pass "検索語に mkdir が含まれる" "$(bash_payload "grep -rn 'mkdir -p' ./plugins" no-skill)"
run_gate deny "自然文に見せかけてクォートの外で rm する" "$(bash_payload "orca terminal send --text '調べろ' && rm -rf /home/user/project/out" no-skill)"
run_gate deny "クォートの中に git commit がある sh -c" "$(bash_payload "sh -c \"git commit -m x\"" no-skill)"
run_gate deny "クォートの中に rm があるコマンド置換" "$(bash_payload 'echo $(rm -rf /home/user/project/out)' no-skill)"
run_gate deny "クォートの中に rm がある xargs" "$(bash_payload "find . -name '*.log' | xargs -I{} bash -c 'rm -f {}'" no-skill)"

bash_payload_in() {
  local cmd=$1 session=$2 cwd=$3
  jq -cn --arg c "$cmd" --arg s "$session" --arg t "$EMPTY_TRANSCRIPT" --arg cwd "$cwd" \
    '{tool_name: "Bash", tool_input: {command: $c}, session_id: $s, transcript_path: $t, agent_type: "worker", cwd: $cwd}'
}

# --- ワークツリーの中では plan だけでは通さない ---
run_gate deny "worktree で plan だけ起動済みの Write" "$(file_payload Write "$WORKTREE/plugins/a.sh" called-via-log)"
run_gate deny "worktree で plan だけ起動済みの Edit" "$(file_payload Edit "$WORKTREE/plugins/a.sh" short-name)"
run_gate deny "worktree で plan だけ起動済みの git commit" "$(bash_payload_in 'git commit -m x' called-via-log "$WORKTREE")"
run_gate pass "worktree で implement 起動済みの Write" "$(file_payload Write "$WORKTREE/plugins/a.sh" implement)"
run_gate pass "worktree で review 起動済みの Write" "$(file_payload Write "$WORKTREE/plugins/a.sh" review)"
run_gate pass "worktree で pr-comment 起動済みの gh pr review" "$(bash_payload_in 'gh pr review 301 --approve' pr-comment "$WORKTREE")"
run_gate pass "worktree で pr-followup 起動済みの Write" "$(file_payload Write "$WORKTREE/plugins/a.sh" pr-followup)"
run_gate deny "worktree で skill 未起動の Write" "$(file_payload Write "$WORKTREE/plugins/a.sh" no-skill)"

# --- auto-review-* worktree では skill 未起動でも通す ---
run_gate pass "auto-review-* worktree で skill 未起動の Bash" "$(bash_payload_in 'mkdir -p /home/user/project/out' no-skill "$AUTO_REVIEW_WORKTREE")"
run_gate pass "auto-review-* worktree で skill 未起動の Write" "$(file_payload Write "$AUTO_REVIEW_WORKTREE/plugins/a.sh" no-skill)"

# --- 本体では plan だけで通る（計画セッションを止めない） ---
run_gate pass "本体で plan だけ起動済みの Write" "$(file_payload Write "$MAIN_TREE/plans/x.md" called-via-log)"
run_gate pass "本体で plan だけ起動済みの git commit" "$(bash_payload_in 'git commit -m x' called-via-log "$MAIN_TREE")"

# --- サブエージェント配下も同じ判定にかける ---
run_gate deny "skill 未起動のサブエージェントからの Write" "$(subagent_payload Write "$CODE_PATH")"
run_gate pass "親が implement 起動済みのサブエージェントからの Write" "$(subagent_payload Write "$CODE_PATH" implement)"

# --- 対象外ツール → 素通し ---
run_gate pass "対象外ツール（Read）" "$(file_payload Read "$CODE_PATH" no-skill)"

if [[ "$failures" -gt 0 ]]; then
  printf '\nplan-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'plan-gate: %d 件すべて期待どおり\n' "$total"
