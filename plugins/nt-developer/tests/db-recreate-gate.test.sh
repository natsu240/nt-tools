#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-db-recreate.sh"
[[ -f "$HOOK" ]] || { echo "deny-db-recreate.sh が見つかりません: $HOOK"; exit 1; }

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

# --- artisan の作り直し → 拒否 ---
run_case deny "migrate:fresh" 'php artisan migrate:fresh'
run_case deny "migrate:fresh --seed" 'php artisan migrate:fresh --seed'
run_case deny "migrate:refresh" 'php artisan migrate:refresh'
run_case deny "db:wipe" 'php artisan db:wipe'
run_case deny "コンテナ越しの migrate:fresh" 'docker compose exec app php artisan migrate:fresh --seed'
run_case deny "&& でつないだ2つ目が migrate:fresh" 'cd /app && php artisan migrate:fresh'

# --- SQL の破壊操作（データベースのクライアント呼び出しを伴う） → 拒否 ---
run_case deny "mysql で TRUNCATE" 'mysql -u root -e "TRUNCATE TABLE users"'
run_case deny "mysql で DROP TABLE" 'mysql -h db -u root -e "DROP TABLE properties"'
run_case deny "psql で DROP DATABASE" 'psql -U postgres -c "DROP DATABASE app"'
run_case deny "コンテナ越しの mysql で TRUNCATE" 'docker compose exec db mysql -uroot -e "TRUNCATE users;"'
run_case deny "小文字の drop table" 'mysql -u root -e "drop table users"'
run_case deny "artisan db での TRUNCATE" 'php artisan db --execute="TRUNCATE users"'

# --- test_db 相手 → 素通し（検証データを作る・壊す作業の行き先） ---
run_case pass "test_db への migrate:fresh" 'php artisan migrate:fresh --database=test_db'
run_case pass "test_db への TRUNCATE" 'mysql -u root test_db -e "TRUNCATE TABLE users"'
run_case pass "test_db への db:wipe" 'php artisan db:wipe --database=test_db'

# --- 通常の migration 操作 → 素通し ---
run_case pass "通常の migrate" 'php artisan migrate'
run_case pass "migrate --seed" 'php artisan migrate --seed'
run_case pass "migrate:status" 'php artisan migrate:status'
run_case pass "migrate:rollback" 'php artisan migrate:rollback --step=1'
run_case pass "make:migration" 'php artisan make:migration create_users_table'

# --- 読み取り・文字列として現れるだけ → 素通し ---
run_case pass "TRUNCATE を grep するだけ" "grep -rn 'TRUNCATE' ./database"
run_case pass "DROP TABLE を grep するだけ" "grep -rn 'DROP TABLE' ./database/migrations"
run_case pass "migrate:fresh を grep するだけ" "grep -rn 'migrate:fresh' ./docs"
run_case pass "コミットメッセージに DROP TABLE と書く" "git commit -m 'DROP TABLE を含む migration を削除した'"
run_case pass "コミットメッセージに migrate:fresh と書く" "git commit -m 'migrate:fresh を止める hook を追加'"
run_case pass "SELECT を流すだけ" 'mysql -u root -e "SELECT * FROM users LIMIT 10"'
run_case pass "バックアップの取得" 'mysqldump -u root app > /tmp/backup.sql'
run_case pass "データベースに触らないコマンド" 'ls -la /tmp'

if [[ "$failures" -gt 0 ]]; then
  printf '\ndb-recreate-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'db-recreate-gate: %d 件すべて期待どおり\n' "$total"
