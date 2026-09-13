#!/usr/bin/env bash
# ワークツリー運用の強制対象リポジトリと、本体／切り出した側の判定。複数の hook が source して使う。
#
# 判定を各スクリプトへ書き写すな。片方だけ直すと、一方は止めるのに一方は素通しする。
#
# **ここへリポジトリを足す前に、Orca のセットアップスクリプトを登録しろ。** worktree には Git 管理外のファイル（node_modules / vendor / .env）が引き継がれず、登録前に足すと作るたびに手で再構築することになる。登録手順は git-rules skill の「Orca のセットアップスクリプトを登録する」節にある。
#
# **依存パッケージがコンテナの中にあるリポジトリは、セットアップスクリプトを登録しても解決しない。** 匿名ボリューム／名前付きボリュームに置かれた node_modules / vendor はホスト側から作れない。
# **container_name・ポート・ボリューム名がワークスペースごとに分かれていることを確認してから足せ。** 固定のままだとワークツリーで2つ目のコンテナを立てられず、動作確認ができない。

WORKTREE_ENFORCED_REPOS=(nt-tools)

nearest_existing_dir() {
  local dir
  dir="$(dirname "$1")"
  while [[ ! -d "$dir" && "$dir" != "/" && "$dir" != "." ]]; do
    dir="$(dirname "$dir")"
  done
  printf '%s' "$dir"
}

# `.git` 共通ディレクトリの絶対パスを1行返す。git 管理外なら何も出さない。
# worktree で切り出した側でも本体と同じ値を返すため、リポジトリの同一性判定に使える。
worktree_common_dir() {
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true
}

# 強制対象のリポジトリならリポジトリ名を1行返す。対象外・git 管理外なら何も出さない。
worktree_enforced_repo_name() {
  local dir="$1" common_dir repo_name repo
  common_dir="$(worktree_common_dir "$dir")"
  [[ -n "$common_dir" ]] || return 0
  repo_name="$(basename "$(dirname "$common_dir")")"
  for repo in "${WORKTREE_ENFORCED_REPOS[@]}"; do
    if [[ "$repo_name" == "$repo" ]]; then
      printf '%s' "$repo_name"
      return 0
    fi
  done
}

# 本体のチェックアウトなら 0 を返す。
# 切り出した側は --git-dir が .git/worktrees/<名前> を指し、共通ディレクトリと一致しない。
is_main_checkout() {
  local dir="$1" common_dir git_dir
  common_dir="$(worktree_common_dir "$dir")"
  [[ -n "$common_dir" ]] || return 1
  git_dir="$(git -C "$dir" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  [[ -n "$git_dir" ]] || return 1
  [[ "$git_dir" == "$common_dir" ]]
}

# git worktree で切り出した側なら 0 を返す。git 管理外は 1。
is_linked_worktree() {
  local dir="$1"
  [[ -n "$(worktree_common_dir "$dir")" ]] || return 1
  ! is_main_checkout "$dir"
}
