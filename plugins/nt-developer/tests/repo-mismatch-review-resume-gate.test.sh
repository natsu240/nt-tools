#!/usr/bin/env bash

set -uo pipefail
unset GIT_DIR GIT_WORK_TREE

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-repo-mismatch-review-resume.sh"
[[ -f "$HOOK" ]] || { echo "deny-repo-mismatch-review-resume.sh が見つかりません: $HOOK"; exit 1; }

WORK_DIR="$(mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

APP_REPO="$WORK_DIR/sample-app"
mkdir -p "$APP_REPO"
git -C "$APP_REPO" init -q -b main
git -C "$APP_REPO" remote add origin https://github.com/natsu240/sample-app.git

DB_REPO="$WORK_DIR/sample-db-project"
mkdir -p "$DB_REPO"
git -C "$DB_REPO" init -q -b main
git -C "$DB_REPO" remote add origin git@github.com:natsu240/sample-db-project.git

AUTO_RESULTS="$WORK_DIR/_auto-results"
mkdir -p "$AUTO_RESULTS"
APP_RESULT="$AUTO_RESULTS/natsu240_sample-app-292.json"
echo '{}' > "$APP_RESULT"

failures=0
total=0

run_case() {
  local expected=$1 label=$2 skill=$3 args=$4 cwd=$5
  local out actual json
  total=$((total + 1))
  json="$(jq -n --arg s "$skill" --arg a "$args" --arg cwd "$cwd" '{tool_name: "Skill", tool_input: {skill: $s, args: $a}, cwd: $cwd}')"
  out="$(printf '%s' "$json" | bash "$HOOK" 2>&1)"
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
    printf '    出力: %s\n' "$out"
  fi
}

# --- リポジトリ違いのセッションで再開 → 拒否 ---
run_case deny "sample-app の保存結果を sample-db-project のセッションで再開" "code-review" "$APP_RESULT" "$DB_REPO"
run_case deny "プラグイン名付きの skill 名でも同様に拒否" "nt-developer:code-review" "$APP_RESULT" "$DB_REPO"

# --- 正しいリポジトリのセッションで再開 → 素通し ---
run_case pass "sample-app の保存結果を sample-app のセッションで再開" "code-review" "$APP_RESULT" "$APP_REPO"

# --- _auto-results 以外の引数 → 素通し ---
run_case pass "手動レビューのキャッシュパス" "code-review" "$WORK_DIR/manual-cache/run-1/result.json" "$DB_REPO"
run_case pass "PR 番号だけの引数" "code-review" "292" "$DB_REPO"
run_case pass "引数なし" "code-review" "" "$DB_REPO"

# --- 対象外の skill → 素通し ---
run_case pass "別の skill 名" "commit" "$APP_RESULT" "$DB_REPO"

if [[ "$failures" -gt 0 ]]; then
  printf '\nrepo-mismatch-review-resume-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'repo-mismatch-review-resume-gate: %d 件すべて期待どおり\n' "$total"
