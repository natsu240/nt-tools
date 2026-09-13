#!/usr/bin/env bash
# このリポジトリ専用の hook。<リポジトリルート>/.claude/settings.json に登録してある。
#
# gh pr merge が成功したら、plugin.json の version が上がっているプラグインのタグ + GitHub Release を作る。version を上げていないマージでは何もしない。
#
# **プラグイン側へ移すな。** このリポジトリだけの運用を全ユーザーへ配ることになり、「どのリポジトリでのマージか」を hook 自身で判定する必要が出る。
#
# タグを打つ先は origin の default ブランチの先頭コミットにする。同じ `gh pr merge` の成功時には他の hook も発火し、ローカルが最新化されている保証が無いため HEAD は見ない。
# `claude plugin tag` は打つ先を指定できず HEAD 固定になるので使わず、`gh release create --target <SHA>` でタグと Release をまとめて作る。

set -euo pipefail

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

command="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -z "$command" ]] && exit 0

# クォートの中身を落としてから判定する（コミットメッセージ本文に gh pr merge と書いただけで発火するのを防ぐため）。実装はプラグイン側にあるものを使い回す。
# 環境変数ではなくこのスクリプトの位置からリポジトリルートを求める。
REPO_ROOT_DIR="$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)"
# shellcheck source=../../plugins/nt-developer/hooks/lib-strip-quoted.sh
source "$REPO_ROOT_DIR/plugins/nt-developer/hooks/lib-strip-quoted.sh"
stripped="$(strip_quoted "$command")"

CMD_HEAD='(^|[;&|(]|\$\()[[:space:]]*([A-Za-z0-9_.-]*/)*'
PR_MERGE_RE="${CMD_HEAD}gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+"

grep -qE "$PR_MERGE_RE" <<<"$stripped" || exit 0

pr_number="$(grep -oE "$PR_MERGE_RE" <<<"$stripped" | grep -oE '[0-9]+$' | head -1 || true)"
[[ -z "$pr_number" ]] && exit 0

HOOK_CWD="$(jq -r '.cwd // empty' <<<"$INPUT_JSON")"
[[ -z "$HOOK_CWD" ]] && exit 0

repo_root="$(git -C "$HOOK_CWD" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$repo_root" ]] && exit 0

respond_message() {
  jq -n --arg msg "$1" '{systemMessage: $msg}'
  exit 0
}

# タグの一覧と default ブランチの先頭を最新化する
if ! git -C "$repo_root" fetch origin --tags --quiet 2>/dev/null; then
  respond_message "⚠️ PR #${pr_number} のマージ後、git fetch に失敗したためタグと Release を作れませんでした。手動で作成してください。"
fi

default_ref="$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo 'origin/main')"
target_sha="$(git -C "$repo_root" rev-parse "$default_ref" 2>/dev/null || true)"
if [[ -z "$target_sha" ]]; then
  respond_message "⚠️ PR #${pr_number} のマージ後、${default_ref} の先頭コミットを特定できなかったためタグと Release を作れませんでした。手動で作成してください。"
fi

# Release のノートに使う PR のタイトル・URL（取れなければタグ名だけにする）
pr_title="$(gh pr view "$pr_number" --json title -q .title 2>/dev/null || true)"
pr_url="$(gh pr view "$pr_number" --json url -q .url 2>/dev/null || true)"

created=""
failed=""
while IFS= read -r manifest; do
  [[ -z "$manifest" ]] && continue
  content="$(git -C "$repo_root" show "${default_ref}:${manifest}" 2>/dev/null || true)"
  [[ -z "$content" ]] && continue

  name="$(jq -r '.name // empty' <<<"$content" 2>/dev/null || true)"
  version="$(jq -r '.version // empty' <<<"$content" 2>/dev/null || true)"
  [[ -z "$name" || -z "$version" ]] && continue

  tag="${name}--v${version}"
  # 既にタグがある = この PR では version が上がっていない
  if git -C "$repo_root" rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
    continue
  fi

  notes="$tag"
  if [[ -n "$pr_title" ]]; then
    notes="${pr_title} (#${pr_number})"
    [[ -n "$pr_url" ]] && notes="${notes} ${pr_url}"
  fi

  if (cd "$repo_root" && gh release create "$tag" --target "$target_sha" --title "$tag" --notes "$notes") >/dev/null 2>&1; then
    created="${created} ${tag}"
  else
    failed="${failed} ${tag}"
  fi
done < <(git -C "$repo_root" ls-tree -r --name-only "$default_ref" 2>/dev/null \
  | grep -E '^plugins/[^/]+/\.claude-plugin/plugin\.json$' || true)

if [[ -n "$failed" ]]; then
  msg="⚠️ PR #${pr_number} のマージ後、タグと Release の作成に失敗しました:${failed}。手動で作成してください。"
  [[ -n "$created" ]] && msg="${msg} 作成できたもの:${created}"
  respond_message "$msg"
fi

if [[ -n "$created" ]]; then
  respond_message "🏷️ PR #${pr_number} のマージに伴い、タグと GitHub Release を作成しました:${created}"
fi

exit 0
