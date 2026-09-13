#!/usr/bin/env bash
# コマンド文字列が「状態を変える操作」を含むかを判定する処理。複数の hook が source して使う。
#
# 各スクリプトに書き写すな。片方だけ直すと、一方は止めるのに一方は素通しする状態になる。

# shellcheck source=lib-strip-quoted.sh
source "${BASH_SOURCE[0]%/*}/lib-strip-quoted.sh"

# 状態を変えると見なすコマンド。読み取りだけの調べ物（find / grep / jq / cat 等）は含めない。リダイレクト（>）は下の is_state_change_command が別に判定する。
STATE_CHANGE_RE='(\brm\b|\brmdir\b|\bmv\b|\bcp\b|\bmkdir\b|\btouch\b|\btee\b|\bln\b|\bchmod\b|\bchown\b|\btruncate\b|\brsync\b|(sed|perl)[[:space:]]+-i|git[[:space:]]+(add|commit|push|rm|mv|reset|restore|checkout|switch|merge|rebase|stash|clean|tag|apply|cherry-pick|revert|init|clone|config)|git[[:space:]]+branch[[:space:]]+(-[dDmM]\b|--delete\b|--move\b|[^-[:space:]])|gh[[:space:]]+(pr|issue|release|repo|api)[[:space:]]+(create|edit|merge|review|delete|comment|close|reopen|ready|update)|(npm|pnpm|yarn|bun|pip3?|brew|apt|apt-get|gem|cargo|poetry|uv|uvx)[[:space:]]+(install|add|remove|uninstall|update|upgrade)|go[[:space:]]+(install|get)|claude[[:space:]]+(mcp|plugin)[[:space:]]+(add|remove|install|update)|\bkill\b|\bpkill\b|\bkillall\b|\blaunchctl\b|\bcrontab\b|defaults[[:space:]]+write|php[[:space:]]+artisan[[:space:]]+(migrate|db:seed))'

QUOTED_BODY_EXECUTED_RE='(^|[[:space:];&|(`])(sudo|doas|env|nohup|timeout|time|watch|xargs|ssh|eval|source|bash|sh|zsh|ksh|dash|fish|python[0-9.]*|perl|ruby|node|deno|bun|php|osascript|awk|sed|make|npm|pnpm|yarn|docker|kubectl|claude)([[:space:]]|$)|[[:space:]]-exec(dir)?[[:space:]]'

# /dev/null への書き捨てとファイル記述子の複製（2>&1 / >&2 等）はファイルを一切作らないので、リダイレクト判定の前に取り除く。残った > / >> だけを実ファイルへの書き込みとみなす。
# ERE には先読みが無く「> の直後が /dev/null でない」を1本のパターンで表せないため、判定対象の文字列側から先に落とす方式を採る。
STATE_CHANGE_REDIRECT_NOOP_RE='([0-9]*>>?[[:space:]]*&[0-9-]+|&?[0-9]*>>?[[:space:]]*/dev/null)'

# 状態を変える操作を含むなら 0、含まないなら 1 を返す。
is_state_change_command() {
  local command="$1"
  if [[ -z "$command" ]]; then
    return 1
  fi

  local stripped
  stripped="$(strip_quoted "$command")"

  # grep はパイプの終端に置くな。set -o pipefail 下では grep -q がマッチした瞬間に終了して上流が SIGPIPE で死に、その終了ステータスがパイプライン全体の結果になる。here-string で渡す。クォートの中身は QUOTED_BODY_EXECUTED_RE に当たるときだけ判定に載せろ（常に載せると引数値の自然文で誤検知し、一切載せないと `bash -c "rm -rf ..."` を素通しする）。
  if grep -qE "$STATE_CHANGE_RE" <<<"$stripped"; then
    return 0
  fi

  if grep -qE "$QUOTED_BODY_EXECUTED_RE" <<<"$stripped" && grep -qE "$STATE_CHANGE_RE" <<<"$command"; then
    return 0
  fi

  local redirect_target
  redirect_target="$(sed -E "s#${STATE_CHANGE_REDIRECT_NOOP_RE}##g" <<<"$stripped")"

  grep -qF '>' <<<"$redirect_target"
}

# ツールが自動生成する出力先ディレクトリ。現在は該当なし（該当が増えたらここに足す）。
is_tool_output_path() {
  return 1
}

is_review_cache_path() {
  local path="$1"
  [[ "$path" == *..* ]] && return 1
  [[ -n "${HOME:-}" && "$path" == "${HOME}/.claude/cache/code-review/"* ]]
}

is_scratch_path_only_command() {
  local command="$1"
  local stripped
  stripped="$(strip_quoted "$command")"

  local -a tokens
  read -ra tokens <<<"$stripped"

  local found_path=0
  local tok
  for tok in "${tokens[@]}"; do
    if is_tool_output_path "$tok"; then
      found_path=1
      continue
    fi

    case "$tok" in
      */*) ;;
      *) continue ;;
    esac
    found_path=1

    case "$tok" in
      /tmp/*|/private/tmp/*) continue ;;
      '$TMPDIR'/*|'${TMPDIR}'/*|'$HOME/.claude/state/'*|'${HOME}/.claude/state/'*|'$HOME/.claude/hook-state/'*|'${HOME}/.claude/hook-state/'*) continue ;;
      '$HOME/.claude/cache/code-review/'*|'${HOME}/.claude/cache/code-review/'*) continue ;;
      */cache-io.sh) continue ;;
    esac

    if [[ -n "${TMPDIR:-}" && "$tok" == "${TMPDIR%/}"/* ]]; then
      continue
    fi
    if is_review_cache_path "$tok"; then
      continue
    fi
    if [[ -n "${HOME:-}" ]] && { [[ "$tok" == "${HOME}/.claude/state/"* ]] || [[ "$tok" == "${HOME}/.claude/hook-state/"* ]]; }; then
      continue
    fi

    return 1
  done

  [[ "$found_path" == 1 ]]
}
