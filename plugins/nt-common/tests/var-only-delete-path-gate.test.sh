#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-var-only-delete-path.sh"
[[ -f "$HOOK" ]] || { echo "deny-var-only-delete-path.sh が見つかりません: $HOOK"; exit 1; }

failures=0
total=0

run_case() {
  local expected=$1 label=$2 cmd=$3
  local out actual
  total=$((total + 1))
  out="$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$HOOK" 2>&1)"
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

# --- 変数展開だけで組んだ削除対象パス → 拒否 ---
run_case deny "クォート内の変数展開" 'rm -f "$DIR/file.txt"'
run_case deny "クォート無しの変数展開" 'rm $FILE'
run_case deny "波括弧付きの変数展開" 'rm -rf "${TARGET}/sub"'
run_case deny "unlink でも同様" 'unlink "$LOGFILE"'

# --- 絶対パスを直書き → 素通し ---
run_case pass "絶対パス直書き" 'rm -f /home/user/.claude/hook-state/verify_state.log'

# --- HOME / TMPDIR 始まりは空にならない前提で除外 → 素通し ---
run_case pass "HOME 始まり" 'rm -f "$HOME/tmp/x"'
run_case pass "波括弧 HOME 始まり" 'rm -f "${HOME}/tmp/x"'
run_case pass "TMPDIR 始まり" 'rm -f "$TMPDIR/x"'

# --- 削除コマンドでない → 素通し ---
run_case pass "削除コマンドではない" 'ls -la $DIR'

# --- 読み取り・文字列として現れるだけ → 素通し ---
run_case pass "クォート内の文字列として rm が現れるだけ" 'echo "rm -f $VAR"'
run_case pass "コミットメッセージに rm と書く" "git commit -m 'rm -f \$VAR を直した'"

# --- チェーンの区切りを越えて後続コマンドの引数を拾わない → 素通し ---
run_case pass "rm の後の別コマンドの引数は無視" 'rm -f /abs/path && echo $VAR'

if [[ "$failures" -gt 0 ]]; then
  printf '\nvar-only-delete-path-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'var-only-delete-path-gate: %d 件すべて期待どおり\n' "$total"
