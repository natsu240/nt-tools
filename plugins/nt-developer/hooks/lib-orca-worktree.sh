#!/usr/bin/env bash
# git worktree remove で畳むと Orca のメタデータが残り、サイドバーに実体の無いカードが残る。

ORCA_TIMEOUT=${ORCA_TIMEOUT:-20}
ORCA_BIN=${ORCA_BIN:-orca}

orca_timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then
    printf 'timeout'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout'
  fi
}

# orca が応答しない環境で hook が固まらないよう、timeout があれば挟む。
orca_json() {
  local bin
  bin=$(orca_timeout_bin)

  if [ -n "$bin" ]; then
    "$bin" "$ORCA_TIMEOUT" "$ORCA_BIN" "$@" 2>/dev/null || true
  else
    "$ORCA_BIN" "$@" 2>/dev/null || true
  fi
}

# orca CLI は selector が見つからない等の失敗でも終了コード 0 を返すため、JSON の "ok" で判定する。
orca_ok() {
  grep -qE '"ok"[[:space:]]*:[[:space:]]*true' <<<"$1"
}

orca_worktree_managed() {
  local path=$1

  command -v "$ORCA_BIN" >/dev/null 2>&1 || return 1
  orca_ok "$(orca_json worktree show --worktree "path:$path" --json)"
}

worktree_has_local_changes() {
  local path=$1

  [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]
}

remote_branch_gone() {
  local repo_dir=$1 branch=$2
  local bin listing
  bin=$(orca_timeout_bin)

  if [ -n "$bin" ]; then
    listing=$("$bin" "$ORCA_TIMEOUT" git -C "$repo_dir" ls-remote --heads origin "refs/heads/$branch" 2>/dev/null) || return 1
  else
    listing=$(git -C "$repo_dir" ls-remote --heads origin "refs/heads/$branch" 2>/dev/null) || return 1
  fi

  [ -z "$listing" ]
}

# 本体の作業ツリーも Orca に登録されている。git worktree remove は本体を拒否するが orca worktree rm は消してしまう。
remove_worktree() {
  local path=$1 main_worktree=$2

  [ "$path" = "$main_worktree" ] && return 1
  worktree_has_local_changes "$path" && return 1

  if orca_worktree_managed "$path"; then
    # --run-hooks を付けないとリポジトリ側の archive フックがスキップされる。
    if orca_ok "$(orca_json worktree rm --worktree "path:$path" --run-hooks --json)"; then
      return 0
    fi
  fi

  git -C "$main_worktree" worktree remove "$path" >/dev/null 2>&1
}
