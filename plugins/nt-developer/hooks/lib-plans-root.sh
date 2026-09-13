#!/usr/bin/env bash
# plans/ の置き場所の解決。計画書を移す2つの hook が source して共有する。
#
# plans/ は Git 管理外なのでワークツリーには引き継がれず、`orca worktree rm` でワークツリーごと消える。そのため本体のチェックアウト直下だけを置き場所にする。

# 引数のディレクトリが属するリポジトリの、本体のチェックアウト直下の plans ディレクトリを出力する。
plans_root() {
  local common
  common="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ -n "$common" ]] || return 1
  printf '%s/plans' "$(dirname "$common")"
}
