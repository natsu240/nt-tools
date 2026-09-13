#!/usr/bin/env bash
# deny-pr-comment-banned-words.sh の検査。
# lib-gh-pr-post-detect.sh への切り出し後も、投稿系コマンドの判定と禁止語検出が変わっていないか確認する。

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-pr-comment-banned-words.sh"
[[ -f "$HOOK" ]] || { echo "deny-pr-comment-banned-words.sh が見つかりません: $HOOK"; exit 1; }

failures=0
total=0

judge() {
  local out=$1
  if [[ -z "$out" ]]; then
    printf 'pass'
  elif grep -q '"permissionDecision": "deny"' <<<"$out"; then
    printf 'deny'
  else
    printf 'other'
  fi
}

run_raw_case() {
  local expected=$1 label=$2 payload=$3
  local out actual
  total=$((total + 1))
  out="$(printf '%s' "$payload" | bash "$HOOK" 2>&1)"
  actual="$(judge "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-4s %s\n' "$expected" "$actual" "$label"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- 投稿系コマンド + 禁止語 → deny ---
run_raw_case deny "gh pr comment の禁止語" "$(jq -nc '{tool_name: "Bash", tool_input: {command: "gh pr comment 123 --body \"気付いたら直す程度で対応します\""}}')"
run_raw_case deny "gh pr review の禁止語" "$(jq -nc '{tool_name: "Bash", tool_input: {command: "gh pr review 123 --comment --body \"今すぐの対応は不要です\""}}')"
run_raw_case deny "gh api レビュー投稿の禁止語" "$(jq -nc '{tool_name: "Bash", tool_input: {command: "gh api repos/x/y/pulls/123/reviews -f body=\"対応しなくても大丈夫です\""}}')"
run_raw_case deny "gh api issueコメント投稿の禁止語" "$(jq -nc '{tool_name: "Bash", tool_input: {command: "gh api repos/x/y/issues/123/comments -f body=\"お手数おかけし恐縮ですが、よろしくお願いいたします。\""}}')"
run_raw_case deny "gh pr review の禁止語(今回のPRには影響ありません)" "$(jq -nc '{tool_name: "Bash", tool_input: {command: "gh pr review 123 --comment --body \"今回のPRには影響ありません\""}}')"

# --- 投稿系コマンドだが禁止語なし → pass ---
run_raw_case pass "gh pr comment だが禁止語なし" "$(jq -nc '{tool_name: "Bash", tool_input: {command: "gh pr comment 123 --body \"承認いたします\""}}')"

# --- 投稿系コマンドではない → pass ---
run_raw_case pass "gh pr view は対象外" "$(jq -nc '{tool_name: "Bash", tool_input: {command: "gh pr view 123 --comments"}}')"
run_raw_case pass "git commit は対象外" "$(jq -nc '{tool_name: "Bash", tool_input: {command: "git commit -m \"今すぐの対応は不要です\""}}')"

# --- 対象外のツール ---
run_raw_case pass "対象外ツール(Read)" "$(jq -nc '{tool_name: "Read", tool_input: {file_path: "/repo/a.md"}}')"

if [[ "$failures" -gt 0 ]]; then
  printf '\npr-comment-banned-words-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'pr-comment-banned-words-gate: %d 件すべて期待どおり\n' "$total"
