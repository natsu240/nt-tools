#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/gate-risky-bash.sh"
[[ -f "$HOOK" ]] || { echo "gate-risky-bash.sh が見つかりません: $HOOK"; exit 1; }

failures=0
total=0

# permissionDecision が deny なら "block"、それ以外は "pass"。読み取り専用の自動許可も "pass" に含める。
run_case() {
  local expected=$1 label=$2 cmd=$3
  local out rc actual
  total=$((total + 1))
  out="$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$HOOK" 2>&1)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    actual="rc=$rc"
  elif grep -qE '"permissionDecision":[[:space:]]*"deny"' <<<"$out"; then
    actual="block"
  else
    actual="pass"
  fi
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-5s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    printf '    コマンド: %s\n' "$cmd"
    printf '    出力: %s\n' "$out"
  fi
}

# --- 実行される位置にある → block ---
run_case block "ヒアドキュメントでファイル作成" 'cat > /home/user/note.md <<EOF
本文
EOF'
run_case block "tee のヒアドキュメント" 'tee > /home/user/note.md <<EOF
本文
EOF'
run_case block "/tmp へのリダイレクト" 'echo hello > /tmp/scratch.txt'
run_case block "/tmp への追記" 'ls -la >> /tmp/out.log'

# --- /tmp 書き込み拒否のメッセージが Write ツール経由の scratchpad を案内すること ---
run_case_tmp_message() {
  local label=$1 cmd=$2
  local out rc
  total=$((total + 1))
  out="$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$HOOK" 2>&1)"
  rc=$?
  if [[ "$rc" -eq 0 ]] && grep -qF 'Write ツールで scratchpad' <<<"$out"; then
    return
  fi
  failures=$((failures + 1))
  printf 'NG  期待=scratchpad案内メッセージ %s\n' "$label"
  printf '    コマンド: %s\n' "$cmd"
  printf '    出力: %s\n' "$out"
}
run_case_tmp_message "/tmp へのリダイレクトは Write ツールでの scratchpad 作成を案内する" 'echo hello > /tmp/scratch.txt'

# --- このセッションの scratchpad 配下へのリダイレクトは対象外 ---
SCRATCHPAD_SESSION_ID="test-scratchpad-$$"
scratchpad_json() {
  local cmd=$1
  jq -n --arg c "$cmd" --arg s "$SCRATCHPAD_SESSION_ID" '{tool_name: "Bash", tool_input: {command: $c}, session_id: $s}'
}
run_case_scratchpad() {
  local expected=$1 label=$2 cmd=$3
  local out rc actual
  total=$((total + 1))
  out="$(scratchpad_json "$cmd" | bash "$HOOK" 2>&1)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    actual="rc=$rc"
  elif grep -qE '"permissionDecision":[[:space:]]*"deny"' <<<"$out"; then
    actual="block"
  else
    actual="pass"
  fi
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-5s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    printf '    コマンド: %s\n' "$cmd"
    printf '    出力: %s\n' "$out"
  fi
}
run_case_scratchpad pass "自分の scratchpad へのリダイレクトは通す" \
  "gh issue view 1 --json body --jq .body > /private/tmp/claude-501/proj/${SCRATCHPAD_SESSION_ID}/scratchpad/x.md"
run_case_scratchpad block "他セッションの scratchpad へのリダイレクトは止める" \
  'gh issue view 1 --json body --jq .body > /private/tmp/claude-501/proj/other-session/scratchpad/x.md'
run_case_scratchpad block "scratchpad 以外の /tmp 直下へのリダイレクトは止める" \
  "echo hi > /private/tmp/claude-501/proj/${SCRATCHPAD_SESSION_ID}/note.md"
run_case_scratchpad pass "Linux の scratchpad へのリダイレクトは通す" \
  "gh issue view 1 --json body --jq .body > /tmp/claude-1001/proj/${SCRATCHPAD_SESSION_ID}/scratchpad/x.md"
run_case_scratchpad block "Linux でも他セッションの scratchpad へのリダイレクトは止める" \
  'gh issue view 1 --json body --jq .body > /tmp/claude-1001/proj/other-session/scratchpad/x.md'

# --- パイプ後段のコマンドが、前段の引数ファイルを部分読みしたと誤検知しない ---
run_case pass "パイプ後段の tail が前段の実行対象ファイルを拾わない" \
  'bash scripts/validate-skills.sh | tail -8'
run_case block "実際に grep が対象にしているファイルは同じ区間なので止める" \
  "grep -n foo $HOOK"
run_case pass "クォート内の tail という語だけでは反応しない" \
  "gh issue create --title 'パイプ後段の tail を直す' --body x"

run_case block "他ブランチからのファイル展開" 'git checkout develop -- src/foo.php'
run_case block "git restore --source" 'git restore --source origin/main src/foo.php'

# --- 文字列リテラルとして現れただけ → 素通し ---
run_case pass "PR 本文にファイル展開の実例" "gh pr create --title x --body 'git checkout main -- docs/plan.md は素通しします'"
run_case pass "コミットメッセージにファイル展開の実例" "git commit -m 'git checkout develop -- src/foo.php の扱いを変えた'"
run_case pass "PR 本文にヒアドキュメントの実例" "gh pr create --title x --body 'cat > file.txt <<EOF の形は禁止です'"
run_case pass "PR 本文に /tmp 書き込みの実例" "gh pr create --title x --body '中間出力を > /tmp/out.log に逃がすのは禁止です'"
run_case pass "ダブルクォートの中の実例" 'gh issue comment 1 --body "git checkout main -- README.md を書いても止まりません"'

# --- HEAD 系のファイル展開はもともと対象外 → 素通し ---
run_case pass "HEAD からのファイル復元" 'git checkout HEAD -- src/foo.php'
run_case pass "HEAD~1 からのファイル復元" 'git checkout HEAD~1 -- src/foo.php'

# --- 長文インラインスクリプトは中身がクォート内なので、クォート内でも止まる（対象外にした判断） ---
run_case block "長文の python3 -c" 'python3 -c "import json, sys, os, re, collections; print(json.dumps(collections.Counter(sys.argv)))"'
run_case block "PR 本文に書いた長文の python3 -c も止まる" "gh pr create --title x --body 'python3 -c \"import json, sys, os, re, collections; print(json.dumps(collections.Counter(sys.argv)))\" は禁止です'"

# --- 通常のコマンド → 素通し ---
run_case pass "読み取りのみ" 'git status --porcelain'
run_case pass "短いインラインスクリプト" 'python3 -c "print(1)"'
run_case pass "ブランチの移動" 'git switch main'
run_case pass "scratchpad への書き出しではない普通の実行" 'bash .githooks/pre-push'

# --- claude CLI を子プロセスとして起動する行為 → block ---
run_case block "claude -p での無人実行" "claude -p 'hello'"
run_case block "claude --debug でのデバッグ起動" "claude -p --model sonnet --debug 'hello'"
run_case block "claude --dangerously-skip-permissions" "claude -p --dangerously-skip-permissions 'hello'"
run_case block "claude remote-control の起動" 'claude remote-control'
run_case block "cd を挟んだ claude -p" "cd /tmp && claude -p --model sonnet --debug --dangerously-skip-permissions 'hello'"

# --- claude CLI の既存許可コマンド・文字列リテラル → 素通し ---
run_case pass "claude mcp add" 'claude mcp add foo'
run_case pass "claude plugin tag" 'claude plugin tag --push plugins/nt-common'
run_case pass "gripe-worker.sh の起動(claudeという単語を含まない)" 'bash gripe/scripts/gripe-worker.sh --run req.md'
run_case pass "PR 本文に claude -p の実例" "gh pr create --title x --body 'claude -p の実行は禁止です'"

# --- /goal を伴う claude -p 起動 → 素通し（--debug 等の3フラグは対象外のまま block） ---
run_case pass "claude -p での /goal 起動" "claude -p '/goal 完了条件'"
run_case block "/goal を伴っても --debug は禁止" "claude -p --debug '/goal 完了条件'"
run_case block "/goal を伴っても --dangerously-skip-permissions は禁止" "claude -p --dangerously-skip-permissions '/goal 完了条件'"

# --- セッション内で Read 済みのファイルへの部分読みは「読み直すな」の文言になる ---
run_case_already_read() {
  local label=$1 cmd=$2 file=$3
  local session_id reads_log out rc actual
  total=$((total + 1))
  session_id="test-session-$$"
  reads_log="$HOME/.claude/hook-state/${session_id}_reads.log"
  printf '%s\n' "$file" >"$reads_log"
  out="$(jq -n --arg c "$cmd" --arg s "$session_id" '{tool_name: "Bash", tool_input: {command: $c}, session_id: $s}' | bash "$HOOK" 2>&1)"
  rc=$?
  rm -f "$reads_log"
  if [[ "$rc" -ne 0 ]]; then
    actual="rc=$rc"
  elif grep -qF 'Read 済みだ' <<<"$out"; then
    actual="already_read"
  elif grep -qE '"permissionDecision":[[:space:]]*"deny"' <<<"$out"; then
    actual="block"
  else
    actual="pass"
  fi
  if [[ "$actual" != "already_read" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=already_read 実際=%-5s %s\n' "$actual" "$label"
    printf '    コマンド: %s\n' "$cmd"
    printf '    出力: %s\n' "$out"
  fi
}
run_case_already_read "既読ファイルへの grep -n は読み直すな文言になる" "grep -n foo $HOOK" "$HOOK"

# --- /tmp 配下の後片付けは自動許可、それ以外の削除は通常の permission フローへ ---
run_case_delete() {
  local expected=$1 label=$2 cmd=$3
  local out rc actual
  total=$((total + 1))
  out="$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$HOOK" 2>&1)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    actual="rc=$rc"
  elif grep -qF '/tmp 配下の一時ファイル削除' <<<"$out"; then
    actual="allow"
  elif grep -qE '"permissionDecision":[[:space:]]*"deny"' <<<"$out"; then
    actual="block"
  else
    actual="prompt"
  fi
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-6s 実際=%-6s %s\n' "$expected" "$actual" "$label"
    printf '    コマンド: %s\n' "$cmd"
    printf '    出力: %s\n' "$out"
  fi
}
run_case_delete allow "/tmp 配下のディレクトリ削除" 'rm -rf /tmp/research_hooks'
run_case_delete allow "/private/tmp 配下のファイル削除" 'rm -f /private/tmp/claude-501/proj/session/scratchpad/x.md'
run_case_delete allow "/tmp 配下を並べた削除" 'rm -f /tmp/a.json /tmp/b.json'
run_case_delete allow "/tmp 配下の削除を && でつなぐ" 'rm -rf /tmp/a && rm -rf /tmp/b'
run_case_delete prompt "/tmp そのものの削除" 'rm -rf /tmp'
run_case_delete prompt "ルート直下の削除" 'rm -rf /'
run_case_delete prompt "/tmp から親を辿る削除" 'rm -rf /tmp/../home/user'
run_case_delete prompt "プロジェクト配下の削除" 'rm -rf /home/user/app/storage'
run_case_delete prompt "/tmp 配下でも削除以外が混ざる" 'rm -f /tmp/a && mv /home/user/b /home/user/c'
run_case_delete prompt "変数で組んだ削除対象" 'rm -rf "$TMPDIR/x"'

if [[ "$failures" -gt 0 ]]; then
  printf '\nrisky-bash-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'risky-bash-gate: %d 件すべて期待どおり\n' "$total"
