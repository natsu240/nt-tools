#!/usr/bin/env bash
# Write / Edit / MultiEdit / gh の --repo 指定操作に対する PreToolUse hook。セッションを開いたプロジェクト以外への副作用を deny する。
#
# 同一性は `git rev-parse --git-common-dir` で見る。フォルダ名の一致で見ると、同じリポジトリから切り出した worktree を別プロジェクトと誤判定する。
# **Read / Grep / Glob を対象に足すな。** 他プロジェクトを参考にする調査まで塞ぐ。

set -euo pipefail

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"
# shellcheck source=lib-strip-quoted.sh
source "${BASH_SOURCE[0]%/*}/lib-strip-quoted.sh"
# shellcheck source=lib-repo-identity.sh
source "${BASH_SOURCE[0]%/*}/lib-repo-identity.sh"

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
CWD="$(jq -r '.cwd // empty' <<<"$INPUT_JSON")"
[[ -z "$CWD" ]] && exit 0

git_common_dir() {
  env -u GIT_DIR -u GIT_WORK_TREE git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true
}

# スクラッチパッドと ~/.claude/ と各プロジェクトの project_notes/（個人メモ）は常に許可する。
is_always_allowed_path() {
  local path="$1"
  case "$path" in
    /tmp/*|/private/tmp/*) return 0 ;;
    "$HOME/.claude/"*) return 0 ;;
    */project_notes/*) return 0 ;;
  esac
  if [[ -n "${TMPDIR:-}" && "$path" == "${TMPDIR%/}"/* ]]; then
    return 0
  fi
  return 1
}

deny_file_write() {
  local target_path="$1" current_common_dir="$2" target_common_dir="$3"
  local current_repo target_repo reason
  current_repo="$(basename "$(dirname "$current_common_dir")")"
  target_repo="$(basename "$(dirname "$target_common_dir")")"
  reason="🚫 このセッションが開いているのは ${current_repo} だ。別プロジェクト（${target_repo}）のファイルを書き換えようとしている: ${target_path}。今どのリポジトリの話なのかをユーザーに確認しろ。そのプロジェクトを触るなら、そのフォルダで別のセッションを開いてやれ（読み取りは止めていない）。"
  emit_pretooluse_decision deny "$reason"
}

check_file_write() {
  local target_path
  target_path="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT_JSON")"
  [[ -z "$target_path" ]] && return 0
  is_always_allowed_path "$target_path" && return 0

  # 新規作成では対象もその親も未作成のことがあるので、実在する祖先まで遡ってから判定する。
  local target_dir="$target_path"
  target_dir="$(dirname "$target_dir")"
  while [[ ! -d "$target_dir" && "$target_dir" != "/" && "$target_dir" != "." ]]; do
    target_dir="$(dirname "$target_dir")"
  done

  local current_common_dir target_common_dir
  current_common_dir="$(git_common_dir "$CWD")"
  target_common_dir="$(git_common_dir "$target_dir")"
  # どちらかが git 管理外なら比較できない。誤検知で止めるより素通しする。
  [[ -n "$current_common_dir" && -n "$target_common_dir" ]] || return 0
  [[ "$current_common_dir" == "$target_common_dir" ]] && return 0

  deny_file_write "$target_path" "$current_common_dir" "$target_common_dir"
}

# gh で状態を変える操作だけを拾う。`gh issue view --repo` のような読み取りは対象外。
GH_MUTATE_RE='(^|[;&|(]|\$\()[[:space:]]*gh[[:space:]]+(issue|pr|release|repo|api|label|milestone|project|secret|variable|workflow|run|gist)[[:space:]]+[^|;&]*(create|edit|comment|close|reopen|merge|delete|review|ready|develop|transfer|pin|unpin|lock|unlock|rename|sync|upload)([[:space:]]|$)'
GH_REPO_ARG_RE='(--repo[=[:space:]]+|[[:space:]]-R[[:space:]]+)[^[:space:];&|]+'

check_gh_repo_arg() {
  local command stripped repo_arg current_owner_repo reason
  command="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
  [[ -z "$command" ]] && return 0
  stripped="$(strip_quoted "$command")"
  grep -qE "$GH_MUTATE_RE" <<<"$stripped" || return 0

  repo_arg="$(grep -oE "$GH_REPO_ARG_RE" <<<"$stripped" | head -n1 || true)"
  repo_arg="${repo_arg##*[[:space:]=]}"
  [[ -z "$repo_arg" ]] && return 0

  current_owner_repo="$(git_remote_owner_repo "$CWD")"
  [[ -z "$current_owner_repo" ]] && return 0

  # owner を省いた `--repo <repo>` の書き方もあるため、その場合はリポジトリ名だけを比べる。
  case "$repo_arg" in
    */*) [[ "$repo_arg" == "$current_owner_repo" ]] && return 0 ;;
    *) [[ "$repo_arg" == "${current_owner_repo##*/}" ]] && return 0 ;;
  esac

  reason="🚫 このセッションが開いているのは ${current_owner_repo} だ。別リポジトリ（${repo_arg}）へ副作用のある gh 操作をしようとしている。今どのリポジトリの話なのかをユーザーに確認しろ。そのリポジトリで作業するなら、そのフォルダで別のセッションを開いてやれ（--repo 付きの読み取りは止めていない）。"
  emit_pretooluse_decision deny "$reason"
}

case "$TOOL_NAME" in
  Write|Edit|MultiEdit) check_file_write ;;
  Bash) check_gh_repo_arg ;;
esac

exit 0
