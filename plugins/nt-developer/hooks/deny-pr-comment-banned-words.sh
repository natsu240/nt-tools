#!/usr/bin/env bash
# Bash PreToolUse hook。
# PR へのレビュー投稿（gh pr review / gh pr comment / gh api の投稿系）の本文にpr-comment の禁止語が入っていたら deny する。
#
# **禁止語をこのファイルに直書きするな。** SKILL.md の表を実行時に読んで正本にしている。
#
# 抽出は表の左列（使うな側）に限る。右列にも鍵括弧付きの引用が現れ、行全体から拾うと説明のための引用まで禁止語に混ざる。左列にもパターンの説明が混ざるので、鍵括弧で囲まれた実文言だけを取り、波ダッシュを含むものは機械照合できない説明として除く。
#
# 鍵括弧を `tr -d` で消すな（GNU tr はバイト単位で削るため、同じバイトを含む他の日本語まで壊れる）。

set -euo pipefail

INPUT_JSON="$(cat)"

# shellcheck source=lib-gh-pr-post-detect.sh
source "${BASH_SOURCE[0]%/*}/lib-gh-pr-post-detect.sh"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

command="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -z "$command" ]] && exit 0

if ! is_gh_pr_post_command "$command"; then
  exit 0
fi

SKILL_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/pr-comment" 2>/dev/null && pwd)/SKILL.md"
[[ ! -f "$SKILL_PATH" ]] && exit 0

BANNED_WORDS="$(
  awk '
    /^### 禁止語/ { in_section = 1; next }
    in_section && /^#/ { in_section = 0 }
    in_section && /^\|/ {
      line = $0
      sub(/^\|[[:space:]]*/, "", line)
      sub(/[[:space:]]*\|.*/, "", line)
      print line
    }
  ' "$SKILL_PATH" \
    | grep -oE '「[^」]+」' \
    | sed -e 's/「//g' -e 's/」//g' \
    | grep -v '〜' \
    | sort -u
)"

[[ -z "$BANNED_WORDS" ]] && exit 0

HITS=""
while IFS= read -r word; do
  [[ -z "$word" ]] && continue
  if grep -qF -- "$word" <<<"$command"; then
    HITS="${HITS}
  - ${word}"
  fi
done <<<"$BANNED_WORDS"

[[ -z "$HITS" ]] && exit 0

REASON="🚫 投稿しようとしている本文に pr-comment の禁止語が入っています:${HITS}

いずれも実際に差し戻された決まり文句です。指摘の分類は見出し（\`## 🔴 必須対応\` / \`## 🟢 任意対応\`）で伝え、本文では言い直さないでください。免責が必要なら該当する指摘の直後に、その指摘だけを指す形で書き下ろしてください。"

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
