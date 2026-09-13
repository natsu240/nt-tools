#!/usr/bin/env bash
# gh pr merge の Bash PostToolUse hook（ツールが成功したときだけ発火する）。
#
# 番号を省略した `gh pr merge` は PreToolUse が deny しているので、実行時点で PR 番号は必ずコマンド文字列にある。だから実行前に番号を控える状態ファイルは要らない。
#
# 計画書の紐付けに `<!-- PR: #<番号> -->` を使っているのは、ブランチ名からのチケット ID 抽出ではID を含まないブランチ運用や plans/other/ 配下に使えないため。
#
# **0件・複数件ヒット時に推測で1件選ぶな。** 何もせず通知だけ出す。

set -euo pipefail

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

command="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -z "$command" ]] && exit 0

# shellcheck source=lib-strip-quoted.sh
source "${BASH_SOURCE[0]%/*}/lib-strip-quoted.sh"
# shellcheck source=lib-plans-root.sh
source "${BASH_SOURCE[0]%/*}/lib-plans-root.sh"
stripped="$(strip_quoted "$command")"

CMD_HEAD='(^|[;&|(]|\$\()[[:space:]]*([A-Za-z0-9_.-]*/)*'
PR_MERGE_RE="${CMD_HEAD}gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+"

grep -qE "$PR_MERGE_RE" <<<"$stripped" || exit 0

pr_number="$(grep -oE "$PR_MERGE_RE" <<<"$stripped" | grep -oE '[0-9]+$' | head -1 || true)"
[[ -z "$pr_number" ]] && exit 0

HOOK_CWD="$(jq -r '.cwd // empty' <<<"$INPUT_JSON")"
[[ -z "$HOOK_CWD" ]] && exit 0

plans_dir="$(plans_root "$HOOK_CWD" || true)"
[[ -n "$plans_dir" ]] || exit 0
[[ -d "$plans_dir/レビュー中" ]] || exit 0
plans_base="$(dirname "$plans_dir")"

respond_message() {
  jq -n --arg msg "$1" '{systemMessage: $msg}'
  exit 0
}

matches=()
while IFS= read -r -d '' f; do
  if grep -qF "<!-- PR: #${pr_number} -->" "$f" 2>/dev/null; then
    matches+=("$f")
  fi
done < <(find "$plans_dir/レビュー中" -type f -name '*.md' -print0 2>/dev/null)

[[ "${#matches[@]}" -eq 0 ]] && exit 0

if [[ "${#matches[@]}" -gt 1 ]]; then
  respond_message "⚠️ PR #${pr_number} に対応する計画書が plans/レビュー中/ 配下で複数件見つかったため、完了への移動を見送りました。手動で mv してください: ${matches[*]}"
fi

src="${matches[0]}"
kanri="$(basename "$(dirname "$src")")"
dest_dir="$plans_dir/完了/$kanri"
mkdir -p "$dest_dir" 2>/dev/null
dest="$dest_dir/$(basename "$src")"
mv "$src" "$dest"

rel_dest="${dest#"$plans_base"/}"
respond_message "📦 PR #${pr_number} のマージに伴い、計画書を完了へ移動しました: ${rel_dest}"
