#!/usr/bin/env bash
# 「ブランチを新しく作る形のコマンドか」の判定。複数の hook が source して使う。
#
# 判定がズレると、一方は止めるのに一方は素通しするという分かりにくい状態になる。
# そのため各スクリプトへ重複定義せずここに置く。
#
# **ブランチを新しく作る形だけを拾う。** `git switch main`（移動）・`git checkout <ファイル>`（ファイルの復元）は日常的に打つコマンドなので、ここで拾うと毎回止まって作業にならない。

# コマンドとして実行され得る位置（行頭 / `;` `&` `|` `(` の直後 / コマンド置換の直後）に限定する。
BRANCH_CMD_HEAD='(^|[;&|(]|\$\()[[:space:]]*([A-Za-z0-9_.-]*/)*'
GIT_WITH_DIR="git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?"
# `-c` / `-C` / `--create` / `--force-create`。`-t` 等と組み合わせた `-tc` の形も拾う。
BRANCH_SWITCH_CREATE_RE="${BRANCH_CMD_HEAD}${GIT_WITH_DIR}switch[[:space:]]+(-[[:alnum:]]*[cC]|--create|--force-create)([[:space:]]|\$)"
# `git checkout` は他の引数が先に来ることがある（`git checkout --track -b foo`）ので、`-b` / `-B` がどの位置にあっても拾う。ただしパイプ・コマンド区切りは越えない。
BRANCH_CHECKOUT_CREATE_RE="${BRANCH_CMD_HEAD}${GIT_WITH_DIR}checkout[[:space:]]+([^|;&]*[[:space:]])?-[[:alnum:]]*[bB]([[:space:]]|\$)"

# クォートを落とした後のコマンド文字列が「ブランチを新しく作る形」なら 0 を返す。
# 引数には strip_quoted 済みの文字列を渡すこと。
is_branch_create_command() {
  local stripped="$1"
  # grep はパイプの終端に置くな。set -o pipefail 下では grep -q がマッチした瞬間に終了して上流が SIGPIPE で死に、その終了ステータスがパイプライン全体の結果になる。here-string で渡す。
  if grep -qE "$BRANCH_SWITCH_CREATE_RE" <<<"$stripped"; then
    return 0
  fi
  if grep -qE "$BRANCH_CHECKOUT_CREATE_RE" <<<"$stripped"; then
    return 0
  fi
  return 1
}
