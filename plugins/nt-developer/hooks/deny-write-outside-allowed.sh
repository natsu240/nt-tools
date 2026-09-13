#!/usr/bin/env bash
# code-review の subagent が作業ディレクトリ（PROJECT_ROOT）配下に隠しファイルとして一時 dump を書き出すのを block する。
#
# **対象を拡張子で絞っている範囲を広げるな。** .gitignore / .env / .claude/* のような通常運用のドットファイルを巻き込む。

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')

# 許可された格納先に該当するなら 0 を返す
is_allowed_destination() {
  local path="$1"
  # 先頭の ~ / $HOME 展開
  case "$path" in
    \~/*) path="${HOME}${path#~}" ;;
    \$HOME/*) path="${HOME}${path#\$HOME}" ;;
  esac
  case "$path" in
    "$HOME/.claude/cache/code-review/"*) return 0 ;;
    /tmp/*|/private/tmp/*) return 0 ;;
    /dev/null|/dev/stdout|/dev/stderr) return 0 ;;
    *)
      if [ -n "${TMPDIR:-}" ]; then
        local tmpdir="${TMPDIR%/}"
        case "$path" in
          "$tmpdir"/*) return 0 ;;
        esac
      fi
      return 1
      ;;
  esac
}

# basename が「ドット始まり + コード系拡張子」に該当するなら 0 を返す
is_suspicious_temp_file() {
  local path="$1"
  local base
  base=$(basename "$path")
  # ドット始まり判定
  case "$base" in
    .*) ;;
    *) return 1 ;;
  esac
  # コード系拡張子判定
  case "$base" in
    *.vue|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs) return 0 ;;
    *.php|*.py|*.rb|*.go|*.java|*.kt|*.swift|*.rs|*.c|*.cpp|*.h|*.hpp) return 0 ;;
    *.diff|*.patch|*.sql) return 0 ;;
    *.html|*.css|*.scss|*.sass) return 0 ;;
  esac
  return 1
}

block_path() {
  local path="$1"
  local reason="$2"
  local message
  message=$(printf '%s\n' \
    "🚫 作業ディレクトリ汚染防止: $reason" \
    "   対象パス: $path" \
    "   許可された一時ファイルの格納先:" \
    "     - \$HOME/.claude/cache/code-review/<run-id>/ 配下" \
    "     - \$TMPDIR / /tmp / /private/tmp 配下" \
    "   ドット隠しファイル + コード系拡張子のパターンが project root 配下の" \
    "   一時 dump として頻発するため block している。")
  jq -n --arg msg "$message" '
    {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $msg
      },
      systemMessage: $msg
    }
  '
  exit 0
}

check_path() {
  local path="$1"
  local reason="$2"
  # 空パスは無視
  [ -z "$path" ] && return 0
  # 許可された格納先ならスキップ
  if is_allowed_destination "$path"; then
    return 0
  fi
  # 怪しい一時ファイルパターンなら block
  if is_suspicious_temp_file "$path"; then
    block_path "$path" "$reason"
  fi
  return 0
}

case "$tool_name" in
  Bash)
    command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
    [ -z "$command" ] && exit 0

    # `>` / `>>` リダイレクト先の抽出`2>&1` / `&>` / `>(...)` のような特殊形式は対象外（grep -v で除外）
    while IFS= read -r target; do
      [ -z "$target" ] && continue
      # 引用符の除去
      target=${target//\"/}
      target=${target//\'/}
      check_path "$target" "Bash リダイレクト > / >>"
    done < <(printf '%s\n' "$command" \
      | grep -oE '>>?[[:space:]]*[^ |&;<>()]+' \
      | grep -vE '^>>?[[:space:]]*&' \
      | sed -E 's/^>>?[[:space:]]*//')

    # `tee` の書き出し先の抽出
    while IFS= read -r target; do
      [ -z "$target" ] && continue
      target=${target//\"/}
      target=${target//\'/}
      check_path "$target" "tee による書き出し"
    done < <(printf '%s\n' "$command" \
      | grep -oE '(^|[|;&[:space:]])tee([[:space:]]+-[a-zA-Z]+)*[[:space:]]+[^ |&;<>()]+' \
      | sed -E 's/^.*tee([[:space:]]+-[a-zA-Z]+)*[[:space:]]+//')
    ;;

  Write)
    file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')
    check_path "$file_path" "Write tool による作成"
    ;;
esac

exit 0
