#!/usr/bin/env bash

set -uo pipefail

HOOKS="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)"

failures=0
total=0

judge() {
  local rc=$1 out=$2
  if [[ "$rc" -ne 0 ]]; then
    printf 'rc=%s' "$rc"
  elif grep -qE '"permissionDecision":[[:space:]]*"deny"' <<<"$out"; then
    printf 'deny'
  elif grep -qE '"permissionDecision":[[:space:]]*"ask"' <<<"$out"; then
    printf 'ask'
  else
    printf 'pass'
  fi
}

run_case() {
  local expected=$1 hook=$2 label=$3 payload=$4
  local out rc actual
  total=$((total + 1))
  out="$(printf '%s' "$payload" | bash "$HOOKS/$hook" 2>&1)"
  rc=$?
  actual="$(judge "$rc" "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-6s %s（%s）\n' "$expected" "$actual" "$label" "$hook"
    printf '    出力: %s\n' "$out"
    return
  fi
  if [[ "$expected" == "deny" ]] && ! jq -e '.systemMessage == .hookSpecificOutput.permissionDecisionReason and (.systemMessage | length > 0)' >/dev/null 2>&1 <<<"$out"; then
    failures=$((failures + 1))
    printf 'NG  理由が systemMessage に入っていない %s（%s）\n' "$label" "$hook"
    printf '    出力: %s\n' "$out"
  fi
}

bash_payload() {
  jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'
}

write_payload() {
  jq -nc --arg f "$1" '{tool_name: "Write", tool_input: {file_path: $f, content: "x"}}'
}

# --- deny-coauthor-in-commit.sh ---
run_case deny deny-coauthor-in-commit.sh "Co-Authored-By 付きのコミット" \
  "$(bash_payload 'git commit -m "修正" -m "Co-Authored-By: Claude <noreply@anthropic.com>"')"
run_case pass deny-coauthor-in-commit.sh "普通のコミット" \
  "$(bash_payload 'git commit -m "コメント規約の穴を塞ぐ"')"
run_case pass deny-coauthor-in-commit.sh "コミット以外で語に触れるだけ" \
  "$(bash_payload 'grep -r Co-Authored-By .githooks/pre-push')"

# --- deny-cross-repo-mention-in-pr.sh ---
run_case deny deny-cross-repo-mention-in-pr.sh "他リポジトリの番号参照" \
  "$(bash_payload 'gh pr create --title x --body "natsu240/sample-app#221 と同じ対応"')"
run_case deny deny-cross-repo-mention-in-pr.sh "他リポジトリの PR URL" \
  "$(bash_payload 'gh issue comment 1 --body "https://github.com/natsu240/sample-app/pull/221 を見て"')"
run_case pass deny-cross-repo-mention-in-pr.sh "同リポジトリ内の番号参照" \
  "$(bash_payload 'gh pr create --title x --body "Closes #400"')"
run_case pass deny-cross-repo-mention-in-pr.sh "gh pr / gh issue 以外のコマンド" \
  "$(bash_payload 'git commit -m "natsu240/sample-app#221 の件"')"

# --- deny-dbdocs-public.sh ---
run_case deny deny-dbdocs-public.sh "--private の無い dbdocs build" \
  "$(bash_payload 'dbdocs build docs/schema.dbml --project ws/name')"
run_case pass deny-dbdocs-public.sh "--private 付きの dbdocs build" \
  "$(bash_payload 'dbdocs build docs/schema.dbml --project ws/name --private')"
run_case pass deny-dbdocs-public.sh "build 以外の dbdocs" \
  "$(bash_payload 'dbdocs ls')"

# --- deny-laravel-migration-write.sh ---
run_case deny deny-laravel-migration-write.sh "migration を Write で作る" \
  "$(write_payload '/home/user/app/database/migrations/2026_08_14_000001_create_users_table.php')"
run_case pass deny-laravel-migration-write.sh "seeder を Write で作る" \
  "$(write_payload '/home/user/app/database/seeders/UserSeeder.php')"
run_case pass deny-laravel-migration-write.sh "通常のクラスを Write で作る" \
  "$(write_payload '/home/user/app/Models/User.php')"

# --- deny-reviewer-outside-orchestrator.sh ---
run_case deny deny-reviewer-outside-orchestrator.sh "メインループから reviewer を起動" \
  "$(jq -nc '{tool_name: "Agent", tool_input: {subagent_type: "nt-developer:reviewer"}, agent_type: ""}')"
run_case pass deny-reviewer-outside-orchestrator.sh "orchestrator から reviewer を起動" \
  "$(jq -nc '{tool_name: "Agent", tool_input: {subagent_type: "nt-developer:reviewer"}, agent_type: "nt-developer:review-orchestrator"}')"
run_case pass deny-reviewer-outside-orchestrator.sh "別のサブエージェントを起動" \
  "$(jq -nc '{tool_name: "Agent", tool_input: {subagent_type: "nt-common:explorer"}, agent_type: ""}')"

# --- deny-secret-staging.sh ---
run_case deny deny-secret-staging.sh ".env を git add" \
  "$(bash_payload 'git add .env')"
run_case deny deny-secret-staging.sh "秘密鍵を git add" \
  "$(bash_payload 'git add config/id_rsa')"
run_case pass deny-secret-staging.sh ".env.example を git add" \
  "$(bash_payload 'git add .env.example')"
run_case pass deny-secret-staging.sh "通常のファイルを git add" \
  "$(bash_payload 'git add README.md')"
run_case deny deny-secret-staging.sh "パス無指定の git add -A" \
  "$(bash_payload 'git add -A')"
run_case deny deny-secret-staging.sh "git add ." \
  "$(bash_payload 'git add .')"
run_case pass deny-secret-staging.sh "対象パスを明示した git add -A" \
  "$(bash_payload 'git add -A plugins/nt-developer/hooks')"

# --- deny-write-outside-allowed.sh ---
run_case deny deny-write-outside-allowed.sh "作業ディレクトリへの隠し dump" \
  "$(write_payload '/home/user/app/.r1-findings.php')"
run_case deny deny-write-outside-allowed.sh "Bash リダイレクトでの隠し dump" \
  "$(bash_payload 'jq . input.json > /home/user/app/.dump.diff')"
run_case pass deny-write-outside-allowed.sh "一時ディレクトリ配下への隠し dump" \
  "$(write_payload '/tmp/.r1-findings.php')"
run_case pass deny-write-outside-allowed.sh "通常のソースファイル" \
  "$(write_payload '/home/user/app/src/Validator.php')"
run_case pass deny-write-outside-allowed.sh "拡張子が対象外の隠しファイル" \
  "$(write_payload '/home/user/app/.gitignore')"

if [[ "$failures" -gt 0 ]]; then
  printf '\ndeny-decision-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'deny-decision-gate: %d 件すべて期待どおり\n' "$total"
