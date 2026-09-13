#!/usr/bin/env bash
# Edit / Write / MultiEdit / 状態を変える Bash の PreToolUse hook が共有する、一時領域判定・検査対象ディレクトリの解決。
#
# deny-plan-skill-gate.sh と deny-plan-decision-gate.sh が共有する。各スクリプトに書き写すな。片方だけ直すと、一方は止めるのに一方は素通しする。
#
# サブエージェント配下からの呼び出しを免除する判定をここに足すな。免除すると、拒否された処理をサブエージェントへ投げ直せば通る抜け道になる。

# shellcheck source=lib-state-change-command.sh
source "${BASH_SOURCE[0]%/*}/lib-state-change-command.sh"
# shellcheck source=lib-effective-cwd.sh
source "${BASH_SOURCE[0]%/*}/lib-effective-cwd.sh"
# shellcheck source=lib-worktree-enforcement.sh
source "${BASH_SOURCE[0]%/*}/lib-worktree-enforcement.sh"

# 一時ディレクトリ配下のパスなら 0 を返す。
is_scratch_path() {
  local path="$1"
  case "$path" in
    /tmp/*|/private/tmp/*) return 0 ;;
  esac
  is_tool_output_path "$path" && return 0
  is_review_cache_path "$path" && return 0
  [[ -n "${TMPDIR:-}" && "$path" == "${TMPDIR%/}"/* ]]
}

# Bash の command が判定対象（状態を変える かつ 一時領域限定でない）なら 0 を返す。
# TARGET_DIR の解決（cwd 無しだと空になり得る）とは別の判定にする。cwd 無しを「対象外」と混同すると、cwd を持たないテスト入力等で全件素通しになる。
bash_command_in_scope() {
  local command="$1"
  is_state_change_command "$command" || return 1
  ! is_scratch_path_only_command "$command"
}
