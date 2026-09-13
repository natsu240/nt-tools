#!/usr/bin/env bash
# review-orchestrator.js の subagent が CACHE_DIR ($HOME/.claude/cache/code-review/<run-id>/) 配下へ書き込み・削除する操作を1つのスクリプトに集約するヘルパー。
#
# **個別コマンドに分解するな。** CACHE_DIR の絶対パスは run-id 部分が実行ごとに変わるため、パスを対象にした Bash 許可パターンでは確実にマッチさせられない。書き込み・削除をこのスクリプト 1 つに集約し、固定ファイル名へのマッチだけで許可できる形にしている。
#
# 使う前に ~/.claude/settings.json の permissions.allow へ以下の 1 行が必要:
#   "Bash(bash *cache-io.sh*)"

set -u

allowed_prefix="$HOME/.claude/cache/code-review/"

op="${1:-}"
target="${2:-}"

if [ -z "$op" ] || [ -z "$target" ]; then
  echo "usage: cache-io.sh <mkdir|write|append|touch|rm|rmdir|chmod-exec> <path>" >&2
  exit 1
fi

case "$target" in
  *..*)
    echo "🚫 cache-io.sh はパス中に '..' を含む対象を拒否する: $target" >&2
    exit 1
    ;;
  "$allowed_prefix"*) ;;
  *)
    echo "🚫 cache-io.sh は $allowed_prefix 配下のパスのみ操作できる。指定された対象: $target" >&2
    exit 1
    ;;
esac

case "$op" in
  mkdir) mkdir -p "$target" ;;
  write) cat > "$target" ;;
  append) cat >> "$target" ;;
  touch) touch "$target" ;;
  rm) rm -f "$target" ;;
  rmdir) rm -rf "$target" ;;
  chmod-exec) chmod +x "$target" ;;
  *)
    echo "🚫 cache-io.sh 未知の操作: $op" >&2
    exit 1
    ;;
esac
