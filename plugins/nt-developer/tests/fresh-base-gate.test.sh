#!/usr/bin/env bash

set -uo pipefail
unset GIT_DIR GIT_WORK_TREE

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-fresh-base.sh"
[[ -f "$HOOK" ]] || { echo "deny-fresh-base.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

GIT_QUIET=(git -c user.name=test -c user.email=test@example.com -c init.defaultBranch=main -c advice.detachedHead=false)

ORIGIN="$TMP_ROOT/origin.git"
SEED="$TMP_ROOT/seed"
WORK="$TMP_ROOT/work"
OUTSIDE="$TMP_ROOT/outside"

"${GIT_QUIET[@]}" init --quiet --bare "$ORIGIN"
"${GIT_QUIET[@]}" init --quiet "$SEED"
printf 'seed\n' >"$SEED/README.md"
"${GIT_QUIET[@]}" -C "$SEED" add README.md
"${GIT_QUIET[@]}" -C "$SEED" commit --quiet -m "初期コミット"
"${GIT_QUIET[@]}" -C "$SEED" remote add origin "$ORIGIN"
"${GIT_QUIET[@]}" -C "$SEED" push --quiet -u origin main
"${GIT_QUIET[@]}" clone --quiet "$ORIGIN" "$WORK"
"${GIT_QUIET[@]}" -C "$WORK" fetch --quiet origin
mkdir -p "$OUTSIDE"

failures=0
total=0

run_case() {
  local expected=$1 label=$2 dir=$3 cmd=$4
  local out actual
  total=$((total + 1))
  out="$(jq -n --arg c "$cmd" --arg d "$dir" '{tool_name: "Bash", cwd: $d, tool_input: {command: $c}}' | bash "$HOOK" 2>&1)"
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

# --- fetch 直後・origin と同じ内容 → 素通し ---
run_case pass "最新の main から switch -c" "$WORK" 'git switch -c issue-1'
run_case pass "最新の main から checkout -b" "$WORK" 'git checkout -b issue-1'
run_case pass "ブランチを切らない switch" "$WORK" 'git switch main'
run_case pass "ブランチを切らない checkout" "$WORK" 'git checkout main'
run_case pass "コミットメッセージに switch -c と書く" "$WORK" "git commit -m 'git switch -c の順番を直した'"
run_case pass "git 以外のコマンド" "$WORK" 'ls -la'

# --- git 管理外 → 素通し ---
run_case pass "git 管理外のディレクトリ" "$OUTSIDE" 'git switch -c issue-1'

# --- feature ブランチからの枝分かれ → 素通し（base ブランチ上でないため） ---
"${GIT_QUIET[@]}" -C "$WORK" switch --quiet -c feature-x
run_case pass "feature ブランチから switch -c" "$WORK" 'git switch -c issue-1'
run_case pass "feature ブランチから checkout -b" "$WORK" 'git checkout -b issue-1'
"${GIT_QUIET[@]}" -C "$WORK" switch --quiet main

# --- fetch が古い → 拒否 ---
touch -t 202601010000 "$WORK/.git/FETCH_HEAD"
run_case deny "fetch が古い状態で switch -c" "$WORK" 'git switch -c issue-1'
run_case deny "fetch が古い状態で checkout -b" "$WORK" 'git checkout -b issue-1'
run_case pass "fetch が古くてもブランチを切らないなら素通し" "$WORK" 'git switch main'

# --- FETCH_HEAD が無い → 拒否 ---
rm -f "$WORK/.git/FETCH_HEAD"
run_case deny "一度も fetch していない状態で switch -c" "$WORK" 'git switch -c issue-1'

# --- fetch 済みだが origin より遅れている → 拒否 ---
printf 'updated\n' >>"$SEED/README.md"
"${GIT_QUIET[@]}" -C "$SEED" commit --quiet -am "追加コミット"
"${GIT_QUIET[@]}" -C "$SEED" push --quiet origin main
"${GIT_QUIET[@]}" -C "$WORK" fetch --quiet origin
run_case deny "ローカルの main が遅れている状態で switch -c" "$WORK" 'git switch -c issue-1'

# --- 遅れを解消したら素通し ---
"${GIT_QUIET[@]}" -C "$WORK" merge --quiet --ff-only origin/main
run_case pass "pull 後の main から switch -c" "$WORK" 'git switch -c issue-1'

if [[ "$failures" -gt 0 ]]; then
  printf '\nfresh-base-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'fresh-base-gate: %d 件すべて期待どおり\n' "$total"
