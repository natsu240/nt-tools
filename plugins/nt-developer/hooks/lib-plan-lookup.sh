#!/usr/bin/env bash
# 計画（GitHub Issue の description または plans 配下の計画書）の本文を取る処理。
#
# deny-plan-decision-gate.sh と deny-session-split.sh が共有する。各スクリプトに書き写すな。片方だけ直すと、一方は止めるのに一方は素通しする。

# 計画の本文を標準出力へ返す。特定できなければ何も出さない。
# 引数: $1=対象ディレクトリ
lookup_plan_body() {
  local target_dir="$1"
  [[ -n "$target_dir" ]] || return 0

  local branch
  branch="$(git -C "$target_dir" symbolic-ref --short HEAD 2>/dev/null || true)"

  if [[ "$branch" =~ ^issue-([0-9]+)$ ]]; then
    gh issue view "${BASH_REMATCH[1]}" --json body --jq .body 2>/dev/null || true
    return 0
  fi

  local main_common_dir main_checkout state_file plan_path
  main_common_dir="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$target_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [[ -n "$main_common_dir" ]] || return 0

  main_checkout="$(dirname "$main_common_dir")"
  state_file="$HOME/.claude/state/plan-current$(printf '%s' "$main_checkout" | tr '/' '_').json"
  [[ -f "$state_file" ]] || return 0

  plan_path="$(jq -r '.plan // empty' "$state_file" 2>/dev/null || true)"
  [[ -n "$plan_path" && -f "$plan_path" ]] || return 0

  cat "$plan_path"
}
