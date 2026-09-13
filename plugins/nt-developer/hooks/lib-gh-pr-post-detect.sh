#!/usr/bin/env bash
# 「gh pr review/comment、gh api の PR コメント投稿系コマンドか」の判定。複数の hook が source して使う。
#
# 判定がズレると、一方は止めるのに一方は素通しするという分かりにくい状態になる。
# そのため各スクリプトへ重複定義せずここに置く。

GH_PR_POST_RE='gh[[:space:]]+pr[[:space:]]+(review|comment)([[:space:]]|$)'
GH_PR_API_POST_RE='gh[[:space:]]+api[^|;&]*(pulls/[0-9]+/reviews|issues/[0-9]+/comments|pulls/[0-9]+/comments)'

is_gh_pr_post_command() {
  local command="$1"
  # grep はパイプの終端に置くな。set -o pipefail 下では grep -q がマッチした瞬間に終了して上流が SIGPIPE で死に、その終了ステータスがパイプライン全体の結果になる。here-string で渡す。
  if grep -qE "$GH_PR_POST_RE" <<<"$command"; then
    return 0
  fi
  if grep -qE "$GH_PR_API_POST_RE" <<<"$command"; then
    return 0
  fi
  return 1
}
