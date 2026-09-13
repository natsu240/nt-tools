#!/usr/bin/env bash
# PreToolUse hook（Write / Edit / MultiEdit / Bash）。
# 常駐して動き続けるものの設定への書き込みを permissionDecision: ask に落とす。
#
# **deny に変えるな。** 編集そのものは正当な作業だ。書き換えた瞬間から本人の操作なしで動き続けて変更に気づく機会が無いので、確認だけ挟む。

set -euo pipefail

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ -z "$TOOL_NAME" ]] && exit 0

# 常駐設定に該当するなら 0 を返す
is_daemon_config() {
  local path="$1"
  [[ -z "$path" ]] && return 1
  case "$path" in
    \~/*) path="${HOME}${path#\~}" ;;
    \$HOME/*) path="${HOME}${path#\$HOME}" ;;
  esac
  case "$path" in
    "$HOME/Library/LaunchAgents/"*.plist) return 0 ;;
    "$HOME/Library/LaunchDaemons/"*.plist) return 0 ;;
    "$HOME/.config/systemd/user/"*) return 0 ;;
    "$HOME/.claude/settings.json") return 0 ;;
    "$HOME/.zshrc"|"$HOME/.zprofile"|"$HOME/.zshenv") return 0 ;;
    "$HOME/.bashrc"|"$HOME/.bash_profile") return 0 ;;
    "$HOME/.claude/"*monitor*) return 0 ;;
    "$HOME/.claude/"*start-*) return 0 ;;
    "$HOME/.claude/"*-update*) return 0 ;;
  esac
  return 1
}

ask_for_approval() {
  local path="$1"
  local reason="⏰ ${path} は起動し続ける仕組みの設定です。書き換えると本人が操作しなくても新しい内容で動き続けます。変更してよいか、どこをどう変えるかをユーザーに提示して確認してください。"
  jq -n --arg reason "$reason" '
    {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "ask",
        permissionDecisionReason: $reason
      },
      systemMessage: $reason
    }
  '
  exit 0
}

case "$TOOL_NAME" in
  Write|Edit|MultiEdit)
    file_path="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT_JSON")"
    if is_daemon_config "$file_path"; then
      ask_for_approval "$file_path"
    fi
    ;;
  Bash)
    command="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
    [[ -z "$command" ]] && exit 0
    while IFS= read -r target; do
      [[ -z "$target" ]] && continue
      target="${target//\"/}"
      target="${target//\'/}"
      if is_daemon_config "$target"; then
        ask_for_approval "$target"
      fi
    done < <(printf '%s\n' "$command" \
      | grep -oE '(>>?[[:space:]]*|tee([[:space:]]+-[a-zA-Z]+)*[[:space:]]+)[^ |&;<>()]+' \
      | grep -vE '^>>?[[:space:]]*&' \
      | sed -E 's/^(>>?[[:space:]]*|tee([[:space:]]+-[a-zA-Z]+)*[[:space:]]+)//')
    ;;
esac

exit 0
