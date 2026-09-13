#!/usr/bin/env bash
# deny-pr-state-before-push.sh の検査。

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-pr-state-before-push.sh"
[[ -f "$HOOK" ]] || { echo "deny-pr-state-before-push.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

user_message() {
  jq -cn --arg m "$1" '{type: "user", message: {content: $m}}'
}

bash_call() {
  jq -cn --arg c "$1" '{type: "assistant", message: {content: [{type: "tool_use", id: "x", name: "Bash", input: {command: $c}}]}}'
}

CHECKED="$TMP_ROOT/checked.jsonl"
{
  user_message 'push しといて'
  bash_call 'gh pr view 289 --json state --jq .state'
} >"$CHECKED"

UNCHECKED="$TMP_ROOT/unchecked.jsonl"
{
  user_message 'push しといて'
  bash_call 'gh pr list --head dev-user --state open'
} >"$UNCHECKED"

PREVIOUS_TURN="$TMP_ROOT/previous-turn.jsonl"
{
  user_message '状況を見て'
  bash_call 'gh pr view 289 --json state --jq .state'
  user_message 'じゃあ push しといて'
} >"$PREVIOUS_TURN"

FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/gh" <<'FAKE'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" == "no-pr-branch" ]] && { echo 0; exit 0; }
done
echo 1
FAKE
chmod +x "$FAKE_BIN/gh"

NO_PR_REPO="$TMP_ROOT/no-pr-repo"
git init --quiet --initial-branch=no-pr-branch "$NO_PR_REPO"

HAS_PR_REPO="$TMP_ROOT/has-pr-repo"
git init --quiet --initial-branch=dev-user "$HAS_PR_REPO"

failures=0
total=0

run_case() {
  local expected=$1 label=$2 cmd=$3 transcript=$4 cwd=${5-}
  local out actual
  total=$((total + 1))
  out="$(jq -cn --arg c "$cmd" --arg t "$transcript" --arg w "$cwd" '{tool_name: "Bash", tool_input: {command: $c}, transcript_path: $t} + (if $w == "" then {} else {cwd: $w} end)' | PATH="$FAKE_BIN:$PATH" bash "$HOOK" 2>&1)"
  if [[ -z "$out" ]]; then
    actual="pass"
  elif grep -qE '"permissionDecision":[[:space:]]*"deny"' <<<"$out"; then
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

# --- state を確認せずに push → 拒否 ---
run_case deny "一覧検索だけで push" 'git push origin dev-user' "$UNCHECKED"
run_case deny "確認したのは前のターン" 'git push origin dev-user' "$PREVIOUS_TURN"
run_case deny "PR がある1ブランチでの push" 'git push origin dev-user' "$UNCHECKED" "$HAS_PR_REPO"

# --- 止めてはいけない例 ---
run_case pass "同じターンで state を確認済み" 'git push origin dev-user' "$CHECKED"
run_case pass "新規ブランチの初回 push" 'git push -u origin issue-601' "$UNCHECKED"
run_case pass "--set-upstream 付きの初回 push" 'git push --set-upstream origin issue-601' "$UNCHECKED"
run_case pass "push 以外のコマンド" 'git status --porcelain' "$UNCHECKED"
run_case pass "本文に git push と書くだけ" "gh pr comment 1 --body 'git push の前に state を見ろ'" "$UNCHECKED"
run_case pass "会話ログが無い" 'git push origin dev-user' "$TMP_ROOT/missing.jsonl"
run_case pass "PR が1本も無いブランチの push" 'git push origin no-pr-branch' "$UNCHECKED" "$NO_PR_REPO"

if [[ "$failures" -gt 0 ]]; then
  printf '\npr-state-before-push-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'pr-state-before-push-gate: %d 件すべて期待どおり\n' "$total"
