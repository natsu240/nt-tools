#!/usr/bin/env bash
# gh pr create の Bash PostToolUse hook（ツールが成功したときだけ発火する）。
#
# 計画書を plans/進行中/ から plans/レビュー中/ へ移し、1行目に `<!-- PR: #<番号> -->` を書く。
# この目印がマージ時に plans/完了/ へ移すための紐付けになるので、消すと取り残される。
#
# **チケット ID を持たない計画書まで自動で移すな。** パスが重なるだけの別作業を巻き込むと、マージ時にそれが 完了 まで動いてしまう。候補として通知するだけにして判断は呼び出し側に残す。
#
# **PR 番号が取れないときは何も移すな。** 番号なしでは目印の行を書けず、マージ時の移動から取り残されて今より状況が悪くなる。

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
PR_CREATE_RE="${CMD_HEAD}gh[[:space:]]+pr[[:space:]]+create([[:space:]]|\$)"

grep -qE "$PR_CREATE_RE" <<<"$stripped" || exit 0

HOOK_CWD="$(jq -r '.cwd // empty' <<<"$INPUT_JSON")"
[[ -z "$HOOK_CWD" ]] && exit 0

repo_root="$(git -C "$HOOK_CWD" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$repo_root" ]] && exit 0

plans_dir="$(plans_root "$HOOK_CWD" || true)"
[[ -n "$plans_dir" ]] || exit 0
[[ -d "$plans_dir/進行中" ]] || exit 0
plans_base="$(dirname "$plans_dir")"

MESSAGES=()

respond() {
  [[ "${#MESSAGES[@]}" -eq 0 ]] && exit 0
  local joined
  joined="$(printf '%s\n\n' "${MESSAGES[@]}")"
  jq -n --arg msg "${joined%$'\n\n'}" '{systemMessage: $msg}'
  exit 0
}

# --- PR 番号・タイトル・base ブランチの特定 -------------------------------

# tool_response は Bash では {stdout, stderr, ...} のオブジェクトで来る想定だが、文字列で来る場合も落ちないようにしておく。
response_text="$(
  jq -r '
    (.tool_response // empty)
    | if type == "object" then ((.stdout // "") + "\n" + (.stderr // "")) else tostring end
  ' <<<"$INPUT_JSON" 2>/dev/null || true
)"

pr_number="$(grep -oE 'https?://[^[:space:]]+/pull/[0-9]+' <<<"$response_text" 2>/dev/null | tail -n 1 | grep -oE '[0-9]+$' || true)"
number_from_fallback=0

pr_json=""
if command -v gh >/dev/null 2>&1; then
  pr_json="$(cd "$repo_root" && gh pr view --json number,title,baseRefName 2>/dev/null || true)"
fi

if [[ -z "$pr_number" && -n "$pr_json" ]]; then
  pr_number="$(jq -r '.number // empty' <<<"$pr_json" 2>/dev/null || true)"
  [[ -n "$pr_number" ]] && number_from_fallback=1
fi

if [[ -z "$pr_number" ]]; then
  MESSAGES+=("⚠️ PR を作成しましたが、PR 番号を特定できなかったため plans/進行中/ の計画書は移動していません。手動で plans/レビュー中/ へ移し、1行目に \`<!-- PR: #<番号> -->\` を書いてください（この行が無いとマージ時に plans/完了/ へ移りません）。")
  respond
fi

pr_title=""
base_branch=""
if [[ -n "$pr_json" ]]; then
  pr_title="$(jq -r '.title // empty' <<<"$pr_json" 2>/dev/null || true)"
  base_branch="$(jq -r '.baseRefName // empty' <<<"$pr_json" 2>/dev/null || true)"
fi

# --- チケット ID の収集 ---------------------------------------------------

branch_name="$(git -C "$repo_root" symbolic-ref --short HEAD 2>/dev/null || true)"

commit_subjects=""
if [[ -n "$base_branch" ]]; then
  commit_subjects="$(git -C "$repo_root" log --format='%s%n%b' "origin/${base_branch}..HEAD" 2>/dev/null || true)"
  if [[ -z "$commit_subjects" ]]; then
    commit_subjects="$(git -C "$repo_root" log --format='%s%n%b' "${base_branch}..HEAD" 2>/dev/null || true)"
  fi
fi

id_source="$(printf '%s\n%s\n%s\n' "$branch_name" "$pr_title" "$commit_subjects")"
# issue-<番号> は GitHub Issue 経路のブランチ命名に使う固定パターンで、チケット ID ではない。
# 除外しないとチケット ID と誤認識し、無関係な plans/*.md を一致と誤判定する。
ticket_ids="$(grep -oE '[A-Za-z]{2,10}-[0-9]+' <<<"$id_source" 2>/dev/null | tr '[:lower:]' '[:upper:]' | grep -vE '^ISSUE-[0-9]+$' | sort -u || true)"

# --- ファイル名がチケット ID に一致する計画書を移す ------------------------

moved=()
remaining=()

while IFS= read -r -d '' plan; do
  matched=0
  plan_name="$(basename "$plan" | tr '[:lower:]' '[:upper:]')"
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if grep -qF -- "$id" <<<"$plan_name"; then
      matched=1
      break
    fi
  done <<<"$ticket_ids"

  if [[ "$matched" -eq 1 ]]; then
    moved+=("$plan")
  else
    remaining+=("$plan")
  fi
done < <(find "$plans_dir/進行中" -type f -name '*.md' -print0 2>/dev/null)

moved_rel=()
for src in "${moved[@]:-}"; do
  [[ -z "$src" ]] && continue
  rel="${src#"$plans_dir"/進行中/}"
  dest="$plans_dir/レビュー中/$rel"
  mkdir -p "$(dirname "$dest")" 2>/dev/null
  mv "$src" "$dest"

  first_line="$(head -n 1 "$dest" 2>/dev/null || true)"
  tmp="${dest}.stamp.$$"
  if grep -qE '^<!-- PR: #[0-9]+ -->[[:space:]]*$' <<<"$first_line"; then
    { printf '<!-- PR: #%s -->\n' "$pr_number"; tail -n +2 "$dest"; } >"$tmp"
  else
    { printf '<!-- PR: #%s -->\n' "$pr_number"; cat "$dest"; } >"$tmp"
  fi
  mv "$tmp" "$dest"

  moved_rel+=("${dest#"$plans_base"/}")
done

# --- 移していない計画書のうち、今回の差分に触れているものを候補として通知 ----

changed_files=""
if [[ -n "$base_branch" ]]; then
  changed_files="$(git -C "$repo_root" diff --name-only "origin/${base_branch}...HEAD" 2>/dev/null || true)"
  if [[ -z "$changed_files" ]]; then
    changed_files="$(git -C "$repo_root" diff --name-only "${base_branch}...HEAD" 2>/dev/null || true)"
  fi
fi

candidates_rel=()
if [[ -n "$changed_files" ]]; then
  for plan in "${remaining[@]:-}"; do
    [[ -z "$plan" ]] && continue
    while IFS= read -r changed; do
      [[ -z "$changed" ]] && continue
      if grep -qF -- "$changed" "$plan" 2>/dev/null; then
        candidates_rel+=("${plan#"$plans_base"/}")
        break
      fi
    done <<<"$changed_files"
  done
fi

# --- 通知の組み立て -------------------------------------------------------

if [[ "${#moved_rel[@]}" -gt 0 ]]; then
  MESSAGES+=("📦 PR #${pr_number} 用に、チケット ID が一致した計画書 ${#moved_rel[@]} 件を plans/レビュー中/ へ移し、1行目に \`<!-- PR: #${pr_number} -->\` を書きました: ${moved_rel[*]}")
fi

if [[ "${#candidates_rel[@]}" -gt 0 ]]; then
  MESSAGES+=("⚠️ 次の計画書は今回の差分で変更したファイルに触れていますが、ファイル名にチケット ID が無いため自動では移していません: ${candidates_rel[*]}
今回の PR のものなら、同じ管理表のディレクトリを保ったまま plans/レビュー中/ へ移し、1行目に \`<!-- PR: #${pr_number} -->\` を書いてください（この行が無いとマージ時に plans/完了/ へ移りません）。パスが重なっただけの別作業のものなら何もしないでください。")
fi

if [[ "$number_from_fallback" -eq 1 && "${#MESSAGES[@]}" -gt 0 ]]; then
  MESSAGES+=("（PR 番号は標準出力に URL が見つからなかったため gh pr view で引き直しました）")
fi

respond
