#!/usr/bin/env bash
# Orca がワークツリーを作った直後に走らせるセットアップスクリプトの雛形。
# 各リポジトリの `scripts/orca-worktree-setup.sh` としてコミットし、Orca の設定欄にはそのパス1行だけを入れる。
#
# Orca は作成したワークツリーをカレントディレクトリにして実行する。
# 本体のチェックアウトは Git 管理外のファイル（.env）の写し元として使う。

set -euo pipefail

WORKTREE_DIR="$PWD"
MAIN_CHECKOUT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"

# 本体からコピーする Git 管理外のファイル。リポジトリの実態に合わせて書き換えろ。
COPY_FROM_MAIN=(
  .env
)

# 依存パッケージを入れるディレクトリと、そこで走らせるコマンド。リポジトリの実態に合わせて書き換えろ。
INSTALL_TARGETS=(
  "html:composer install --no-interaction"
  "html:npm ci"
  "cdk:npm ci"
)

for rel in "${COPY_FROM_MAIN[@]}"; do
  src="$MAIN_CHECKOUT/$rel"
  dest="$WORKTREE_DIR/$rel"
  if [[ ! -f "$src" ]]; then
    echo "スキップ: 本体に $rel が無い" >&2
    continue
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  echo "コピー: $rel"
done

for entry in "${INSTALL_TARGETS[@]}"; do
  dir="${entry%%:*}"
  cmd="${entry#*:}"
  if [[ ! -d "$WORKTREE_DIR/$dir" ]]; then
    echo "スキップ: $dir が無い" >&2
    continue
  fi
  echo "実行: $dir で $cmd"
  (cd "$WORKTREE_DIR/$dir" && eval "$cmd")
done

echo "セットアップ完了: $WORKTREE_DIR"
