#!/usr/bin/env bash
# Bash PreToolUse hook。
# rm / rmdir / unlink / shred に渡すパスを変数の展開だけで組んでいたら deny する。
#
# この形は Claude Code 本体の安全確認（`Dangerous rm operation on possibly-empty variable path`）が確認プロンプトを出す。本体の確認は hook でも permission rule でもないため `defaultMode: bypassPermissions` でも消せない。手前で止めて書き直させる。
#
# **判定に strip_quoted を通したコマンドを使うな。** `"$DIR/x"` のようにクォートの中に変数がある形を見る必要がある。

set -euo pipefail

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

command="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -z "$command" ]] && exit 0

# shellcheck source=lib-strip-quoted.sh
source "${BASH_SOURCE[0]%/*}/lib-strip-quoted.sh"

CMD_HEAD='(^|[;&|(]|\$\()[[:space:]]*([A-Za-z0-9_.-]*/)*'
DELETE_RE="${CMD_HEAD}(rm|rmdir|unlink|shred)([[:space:]]|\$)"

# 削除コマンドが実行位置にあるかだけを、クォートを落とした文字列で確認する。
grep -qE "$DELETE_RE" <<<"$(strip_quoted "$command")" || exit 0

# 引数はクォートを落とす前のコマンドから集める。区切り（&& / || / ; / |）で対象外に戻し、チェーンに並んだ別コマンドの引数を拾わない。
bad=""
in_delete=0
set -f
for word in $command; do
  case "$word" in
    '&&'|'||'|';'|'|'|'\;')
      in_delete=0
      continue
      ;;
  esac

  base="${word##*/}"
  base="${base#\'}"; base="${base%\'}"
  base="${base#\"}"; base="${base%\"}"

  case "$base" in
    rm|rmdir|unlink|shred)
      in_delete=1
      continue
      ;;
  esac

  [[ "$in_delete" -eq 0 ]] && continue

  case "$word" in
    -*) continue ;;
  esac

  # 前後のクォートだけ剥がす（中身の変数はそのまま見る）
  path="${word#\'}"; path="${path%\'}"
  path="${path#\"}"; path="${path%\"}"

  # 変数展開で始まるものだけが対象。$HOME / $TMPDIR は空にならない前提で除外する。
  case "$path" in
    '$HOME'/*|'${HOME}'/*|'$TMPDIR'/*|'${TMPDIR}'/*) continue ;;
    '$'*) bad="$path"; break ;;
  esac
done
set +f

[[ -z "$bad" ]] && exit 0

REASON="🚫 削除対象のパス（${bad}）を変数の展開だけで組んでいます。変数が空だったときに意図しない場所を消しかねない形なので、Claude Code 本体の安全確認が確認プロンプトを出します（hook でも permission rule でもないため bypassPermissions でも消せません）。消す対象を絶対パスでそのまま書いてください（例: rm -f /home/user/.claude/hook-state/verify_state.log）。パスが長くても書いてください。"

jq -n --arg reason "$REASON" '
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
