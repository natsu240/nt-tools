#!/usr/bin/env bash
# そのセッションで AskUserQuestion に渡した質問文を集める処理。
#
# 集める先は2つある。
# - PostToolUse が残した記録: 会話ログへの書き込みはこの hook が走る時点で間に合っていないことがあり、直前に投げた質問が会話ログ側にまだ現れない。
# - 会話ログの AskUserQuestion ツール呼び出し: 記録役が動いていない環境ではこちらだけが頼りになる。

# 質問文を1件1行で標準出力へ返す。
# 引数: $1=session_id $2=transcript_path（どちらも空でよい）
collect_ask_questions() {
  local session_id="$1" transcript_path="$2"
  local ask_log="$HOME/.claude/hook-state/${session_id}_ask-questions.log"

  if [[ -n "$session_id" && -f "$ask_log" ]]; then
    cat "$ask_log" 2>/dev/null
  fi

  if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
    return 0
  fi

  jq -r '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and .name == "AskUserQuestion")
    | .input.questions[]?
    | .question // empty
    | gsub("[\\n\\r\\t]"; " ")
    | select(. != "")
  ' <"$transcript_path" 2>/dev/null
}

# 突き合わせの前に両側へ必ず適用する。見出し記号・リンク記法まで落とすな（別の断定文どうしが同一と見なされ、提示していない文が素通しする）。
normalize_for_match() {
  printf '%s' "$1" | tr -d ' \t\r\n`*_' | sed 's/　//g'
}
