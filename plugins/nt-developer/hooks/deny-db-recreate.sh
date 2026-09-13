#!/usr/bin/env bash
# Bash PreToolUse hook。
# ローカルのデータベースを丸ごと作り直す操作を deny する。
#
# **SQL の検査を strip_quoted だけで済ませるな。** SQL は `mysql -e "TRUNCATE ..."` のようにクォートの中へ書くので、落とすと本体ごと消えて検出できない。かといって中身をそのまま見ると `grep 'TRUNCATE'` のような読み取りまで止まる。そのため「データベースのクライアントを呼んでいること」を条件に足し、成り立つときだけ中身を見る。

set -euo pipefail

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

command="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -z "$command" ]] && exit 0

# shellcheck source=lib-strip-quoted.sh
source "${BASH_SOURCE[0]%/*}/lib-strip-quoted.sh"

stripped="$(strip_quoted "$command")"

# grep はパイプの終端に置くな。set -o pipefail 下では grep -q がマッチした瞬間に終了して上流が SIGPIPE で死に、その終了ステータスがパイプライン全体の結果になる。here-string で渡す。
if grep -qF -- 'test_db' <<<"$command"; then
  exit 0
fi

ARTISAN_RECREATE_RE='artisan[[:space:]]+(migrate:fresh|migrate:refresh|db:wipe)([[:space:]]|$)'
DB_CLIENT_RE='(\bmysql\b|\bmariadb\b|\bpsql\b|\bmysqldump\b|artisan[[:space:]]+db([[:space:]]|$))'
DESTRUCTIVE_SQL_RE='(TRUNCATE[[:space:]]+|DROP[[:space:]]+(TABLE|DATABASE|SCHEMA)[[:space:]]+)'

respond_deny() {
  local reason="$1"
  jq -n --arg reason "$reason" '
    {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      },
      systemMessage: $reason
    }
  '
  exit 0
}

if grep -qE "$ARTISAN_RECREATE_RE" <<<"$stripped"; then
  respond_deny "🚫 ローカルのデータベースを作り直すコマンドです（migrate:fresh / migrate:refresh / db:wipe）。実行するな、ユーザーに提案するな、「消せば戻せる」と案内するな。検証データを作る・壊す作業は test_db でやれ。今のデータベースを触らずに済ませる方法を探し、どうしても必要ならユーザーに理由を説明して判断を仰げ。"
fi

if grep -qE "$DB_CLIENT_RE" <<<"$stripped" && grep -qiE "$DESTRUCTIVE_SQL_RE" <<<"$command"; then
  respond_deny "🚫 データベースの中身を消す SQL です（TRUNCATE / DROP TABLE / DROP DATABASE / DROP SCHEMA）。実行するな、ユーザーに提案するな、「消せば戻せる」と案内するな。検証データを作る・壊す作業は test_db でやれ。"
fi

exit 0
