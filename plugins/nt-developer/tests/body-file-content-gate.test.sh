#!/usr/bin/env bash
# 本文を --body-file / -F でファイル経由に渡しても、本文の中身を見る hook が検知し続けるかの検査。

set -uo pipefail

HOOKS_DIR="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0
total=0

# $1=期待 pass/deny $2=見出し $3=hook のファイル名 $4=command $5=cwd
run_case() {
  local expected=$1 label=$2 hook=$3 cmd=$4 cwd=${5:-}
  local out actual
  total=$((total + 1))
  out="$(jq -nc --arg c "$cmd" --arg w "$cwd" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $w}' | bash "$HOOKS_DIR/$hook" 2>&1)"
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

printf '%s\n' 'レビュー対応です' 'Co-Authored-By: Claude <noreply@anthropic.com>' >"$WORK_DIR/coauthor.txt"
printf '%s\n' 'レビュー対応です' >"$WORK_DIR/clean.txt"
printf '%s\n' '詳しくは owner/other-repo#42 を見てください' >"$WORK_DIR/cross-repo.md"
printf '%s\n' '詳しくは #42 を見てください' >"$WORK_DIR/same-repo.md"
printf '%s\n' '🟢 任意対応です。今すぐの対応は不要です' >"$WORK_DIR/banned.md"
printf '%s\n' '🟢 任意対応です。ご確認 please' >"$WORK_DIR/allowed.md"

# --- Co-Authored-By ---
run_case deny "-F 経由の Co-Authored-By" deny-coauthor-in-commit.sh "git commit -F $WORK_DIR/coauthor.txt"
run_case pass "-F 経由だが Co-Authored-By 無し" deny-coauthor-in-commit.sh "git commit -F $WORK_DIR/clean.txt"
run_case deny "インラインの Co-Authored-By" deny-coauthor-in-commit.sh "git commit -m 'Co-Authored-By: Claude <x@y>'"
run_case pass "存在しないファイルを指す -F" deny-coauthor-in-commit.sh "git commit -F $WORK_DIR/missing.txt"
run_case pass "cwd 起点の相対パスで Co-Authored-By 無し" deny-coauthor-in-commit.sh "git commit -F clean.txt" "$WORK_DIR"
run_case deny "cwd 起点の相対パスで Co-Authored-By 有り" deny-coauthor-in-commit.sh "git commit -F coauthor.txt" "$WORK_DIR"

# --- 他リポジトリへの参照 ---
run_case deny "--body-file 経由の他リポジトリ参照" deny-cross-repo-mention-in-pr.sh "gh pr create --title x --body-file $WORK_DIR/cross-repo.md"
run_case pass "--body-file 経由で同リポジトリの #N だけ" deny-cross-repo-mention-in-pr.sh "gh pr create --title x --body-file $WORK_DIR/same-repo.md"
run_case deny "--body-file= の等号つき形式" deny-cross-repo-mention-in-pr.sh "gh pr create --title x --body-file=$WORK_DIR/cross-repo.md"

# --- pr-comment の禁止語 ---
run_case deny "--body-file 経由の禁止語" deny-pr-comment-banned-words.sh "gh pr review 123 --comment --body-file $WORK_DIR/banned.md"
run_case pass "--body-file 経由で禁止語なし" deny-pr-comment-banned-words.sh "gh pr review 123 --comment --body-file $WORK_DIR/allowed.md"

if [[ "$failures" -gt 0 ]]; then
  printf '\nbody-file-content-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'body-file-content-gate: %d 件すべて期待どおり\n' "$total"
