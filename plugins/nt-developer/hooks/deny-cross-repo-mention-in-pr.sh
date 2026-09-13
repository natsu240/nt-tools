#!/usr/bin/env bash
# PR / Issue の本文に他リポジトリへの参照（`owner/repo#N`・GitHub URL）を書くのを block する。
#
# 相手リポジトリの timeline に cross-reference event が残り、本文を後から編集してもevent は消えない（GitHub の仕様。API でも削除不可）。

input=$(cat)
command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

if [ -z "$command" ]; then
  exit 0
fi

# 対象コマンド: gh pr create / edit / comment, gh issue create / edit / comment
if ! printf '%s' "$command" | grep -qE '\bgh (pr|issue) (create|edit|comment)\b'; then
  exit 0
fi

# パターン 1: owner/repo#N（例: natsu240/sample-app#221）
matched_slug=$(printf '%s' "$command" | grep -oE '[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+' | head -3)

# パターン 2: https://github.com/owner/repo/(pull|issues)/N
matched_url=$(printf '%s' "$command" | grep -oE 'github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/(pull|issues)/[0-9]+' | head -3)

if [ -z "$matched_slug" ] && [ -z "$matched_url" ]; then
  exit 0
fi

reason=$(cat <<EOF
🚫 gh pr / gh issue の create / edit / comment の引数に「他リポジトリへの番号参照」または「GitHub PR/issue URL」が含まれています。

検出パターン:
${matched_slug}
${matched_url}

これらを本文に書くと相手リポジトリの timeline に永続的な cross-reference event が残り、
本文を後で編集しても event は消えません（GitHub の仕様。API でも削除不可）。

書き方:
  ❌ owner/repo#N
  ❌ https://github.com/owner/repo/pull/N
  ✅ 同リポジトリ内なら #N のみ
  ✅ 他リポジトリの番号に触れる必要があるなら # を外して「PR 番号 N」「issue 番号 N」のように数字単独で書く

本当に cross-reference を残したい場合（双方の合意がある等の極めて稀なケース）は、
このメッセージをユーザーに提示し明示の許可を取ってから実行してください。
EOF
)
jq -n --arg msg "$reason" '
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
