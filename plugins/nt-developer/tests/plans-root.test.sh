#!/usr/bin/env bash

set -uo pipefail
unset GIT_DIR GIT_WORK_TREE

HOOKS="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)"
REVIEW_HOOK="$HOOKS/move-plan-to-review-on-pr-create.sh"
MERGE_HOOK="$HOOKS/move-plan-to-complete-on-merge.sh"
for f in "$REVIEW_HOOK" "$MERGE_HOOK"; do
  [[ -f "$f" ]] || { echo "hook が見つかりません: $f"; exit 1; }
done

failures=0
total=0

check() {
  local label=$1 expected=$2 actual=$3
  total=$((total + 1))
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-8s 実際=%-8s %s\n' "$expected" "$actual" "$label"
  fi
}

# 本体のチェックアウトと、そこから切り出したワークツリーを作る。計画書は本体側にだけ置く。
setup_repo() {
  local root=$1 main="$root/main" wt="$root/wt"

  git init --quiet -b main "$main"
  git -C "$main" config user.email test@example.com
  git -C "$main" config user.name test
  git -C "$main" commit --quiet --allow-empty -m init
  git -C "$main" worktree add --quiet -b feature-ABC-1 "$wt" >/dev/null 2>&1
}

exists() {
  [[ -f "$1" ]] && echo present || echo absent
}

# --- gh pr create をワークツリーで実行: 本体側の計画書が レビュー中 へ移ること ---
root="$(mktemp -d)"
setup_repo "$root"
mkdir -p "$root/main/plans/進行中/github"
printf '# 計画\n' >"$root/main/plans/進行中/github/テスト-ABC-1.md"

out="$(jq -n --arg cwd "$root/wt" \
  '{tool_name: "Bash", cwd: $cwd, tool_input: {command: "gh pr create --fill"}, tool_response: {stdout: "https://github.com/o/r/pull/42", stderr: ""}}' \
  | bash "$REVIEW_HOOK" 2>&1)"

check "ワークツリーからでも本体の 進行中 から消える" "absent" "$(exists "$root/main/plans/進行中/github/テスト-ABC-1.md")"
check "ワークツリーからでも本体の レビュー中 に置かれる" "present" "$(exists "$root/main/plans/レビュー中/github/テスト-ABC-1.md")"
check "ワークツリー側に plans を作らない" "absent" "$([[ -d "$root/wt/plans" ]] && echo present || echo absent)"
check "PR 番号の目印が書かれる" "present" \
  "$(grep -qF '<!-- PR: #42 -->' "$root/main/plans/レビュー中/github/テスト-ABC-1.md" 2>/dev/null && echo present || echo absent)"
check "移動を通知する" "notified" "$(grep -q 'レビュー中' <<<"$out" && echo notified || echo silent)"
rm -rf "$root"

# --- gh pr merge をワークツリーで実行: 本体側の計画書が 完了 へ移ること ---
root="$(mktemp -d)"
setup_repo "$root"
mkdir -p "$root/main/plans/レビュー中/github"
printf '<!-- PR: #42 -->\n# 計画\n' >"$root/main/plans/レビュー中/github/テスト-ABC-1.md"

out="$(jq -n --arg cwd "$root/wt" \
  '{tool_name: "Bash", cwd: $cwd, tool_input: {command: "gh pr merge 42 --merge"}, tool_response: {stdout: "", stderr: ""}}' \
  | bash "$MERGE_HOOK" 2>&1)"

check "ワークツリーからでも本体の レビュー中 から消える" "absent" "$(exists "$root/main/plans/レビュー中/github/テスト-ABC-1.md")"
check "ワークツリーからでも本体の 完了 に置かれる" "present" "$(exists "$root/main/plans/完了/github/テスト-ABC-1.md")"
check "完了への移動を通知する" "notified" "$(grep -q '完了' <<<"$out" && echo notified || echo silent)"
rm -rf "$root"

# --- 止めてはいけない例: plans を持たないリポジトリでは何もしない ---
root="$(mktemp -d)"
setup_repo "$root"
out="$(jq -n --arg cwd "$root/wt" \
  '{tool_name: "Bash", cwd: $cwd, tool_input: {command: "gh pr create --fill"}, tool_response: {stdout: "https://github.com/o/r/pull/42", stderr: ""}}' \
  | bash "$REVIEW_HOOK" 2>&1)"
check "plans が無ければ黙って終わる" "" "$out"
check "plans が無ければ作らない" "absent" "$([[ -d "$root/main/plans" ]] && echo present || echo absent)"
rm -rf "$root"

if [[ "$failures" -gt 0 ]]; then
  printf '\nplans-root: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'plans-root: %d 件すべて期待どおり\n' "$total"
