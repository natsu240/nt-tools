#!/usr/bin/env bash
# そのセッションで起動された skill 名を集める処理。
#
# 集める先は3つある。
# - PostToolUse が残した記録: 会話ログへの書き込みはこの hook が走る時点で間に合っていないことがあり、直前に起動した skill が会話ログ側にまだ現れない。
# - 会話ログの Skill ツール呼び出し: 記録役が動いていない環境ではこちらだけが頼りになる。
# - 会話ログの <command-name>: スラッシュコマンド（`/nt-common:research`）での起動は Skill ツールの tool_use にならないため、上の2つのどちらにも現れない。

# 起動済み skill 名を改行区切りで標準出力へ返す。
# 引数: $1=session_id $2=transcript_path（どちらも空でよい）
collect_called_skills() {
  local session_id="$1" transcript_path="$2"
  local skill_log="$HOME/.claude/hook-state/${session_id}_skills.log"

  if [[ -n "$session_id" && -f "$skill_log" ]]; then
    cat "$skill_log" 2>/dev/null
  fi

  if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
    return 0
  fi

  jq -r '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Skill")
    | .input.skill // empty
  ' <"$transcript_path" 2>/dev/null

  # <command-message> で始まる本文だけを対象にする。Claude Code がスラッシュコマンド起動時に生成する定型がこの形で、利用者が会話本文に <command-name> と書いただけのものを拾わないため。
  jq -r '
    select(.type == "user")
    | .message.content
    | select(type == "string" and startswith("<command-message>"))
    | [scan("<command-name>([^<]*)</command-name>")]
    | .[][0]
    | sub("^\\s*/?"; "")
    | sub("\\s+$"; "")
    | select(. != "")
  ' <"$transcript_path" 2>/dev/null
}
