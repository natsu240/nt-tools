#!/usr/bin/env bash
# Bash の PreToolUse hook。cd でのディレクトリ移動を deny する。
#
# Bash ツールの作業ディレクトリはツール呼び出しをまたいで持ち越される。移動したまま戻さないと、以降のコマンド・ステータスライン・別ペインの起動先まで巻き込んで狂う。hook は別プロセスなので、移動してしまった cwd を後から書き戻すことはできない。

set -euo pipefail

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"
# shellcheck source=lib-strip-quoted.sh
source "${BASH_SOURCE[0]%/*}/lib-strip-quoted.sh"

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

COMMAND="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -z "$COMMAND" ]] && exit 0

# 文中に語として現れただけのもの（`echo cd /tmp` / `find . -name cd`）を拾わないよう、コマンドとして実行され得る位置に限定する。
CD_RE='(^|[;&|(]|\$\()[[:space:]]*cd([[:space:]]|;|$)'
grep -qE "$CD_RE" <<<"$(strip_quoted "$COMMAND")" || exit 0

REASON="🚫 Bash で cd を使うな。移動したディレクトリは次のコマンド以降もそのまま残る。対象パスを絶対パスで書き直せ（git なら \`git -C <パス>\`、その他は \`ls /abs/path\` のようにコマンドの引数で指定しろ）。"
emit_pretooluse_decision deny "$REASON"

exit 0
