#!/usr/bin/env bash
# Laravel migration を Write で直接作るのを block し、php artisan make:migration を促す。
#
# Write で命名すると連番が固定され、他の開発者と作業日が被ったとき衝突する。
# artisan は microsecond 精度のタイムスタンプを生成するので衝突しない。

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')

if [ -z "$file_path" ]; then
  exit 0
fi

if printf '%s' "$file_path" | grep -qE 'database/migrations/.+\.php$'; then
  reason=$(cat <<EOF
🚫 Laravel migration ファイルを Write で直接作るのは禁止: $file_path

理由: Write で命名すると YYYY_MM_DD_000001_xxx.php のような連番が hardcode され、
他の開発者と作業日が被ったときに連番が衝突する。

代替: Bash で以下を実行して Laravel に生成させろ。
  php artisan make:migration <スネークケース名>

Laravel が microsecond 精度のタイムスタンプ付きで空ファイルを生成するので、
そのファイルを Edit ツールで開いて中身を埋めること。
EOF
)
  emit_pretooluse_decision deny "$reason"
fi

exit 0
