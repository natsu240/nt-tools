#!/usr/bin/env bash
# コマンド文字列からのカテゴリ判定。記録側と判定側の hook が source して共有する。
#
# 両者で判定の仕方がズレると、記録したカテゴリと照合するカテゴリが噛み合わず使い切り式が静かに壊れる。そのため各スクリプトへ重複定義せずここに置く。

# コマンドとして実行され得る位置（行頭 / `;` `&` `|` `(` の直後 /コマンド置換の直後）に限定する。空白の直後まで許すと、単に文中へ現れただけの語（`grep -E "gh pr review"` の中身等）にマッチする。
GIT_CMD_HEAD='(^|[;&|(]|\$\()[[:space:]]*([A-Za-z0-9_.-]*/)*'
GIT_COMMIT_RE="${GIT_CMD_HEAD}git[[:space:]]+commit([[:space:]]|\$)"
GIT_PR_RE="${GIT_CMD_HEAD}gh[[:space:]]+pr[[:space:]]+(create|edit)([[:space:]]|\$)"
GIT_PR_REVIEW_COMMENT_RE="${GIT_CMD_HEAD}gh[[:space:]]+pr[[:space:]]+(review|comment)([[:space:]]|\$)"
GIT_API_MUTATE_RE="${GIT_CMD_HEAD}gh[[:space:]]+api([[:space:]]|\$)"
GIT_API_METHOD_MUTATE_RE='(-X[[:space:]]*(POST|PUT|PATCH|DELETE)\b|--method[[:space:]]+(POST|PUT|PATCH|DELETE)\b)'
GIT_API_PR_PATH_RE='(pulls/[0-9]+/reviews|issues/[0-9]+/comments|pulls/[0-9]+/comments)'

# shellcheck source=lib-strip-quoted.sh
source "${BASH_SOURCE[0]%/*}/lib-strip-quoted.sh"

# コマンド文字列からカテゴリ（commit / pr / pr-review）を1つ出力する。
# どれにも当てはまらなければ何も出力しない。
git_command_category() {
  local command="$1" stripped
  stripped="$(strip_quoted "$command")"

  if printf '%s' "$stripped" | grep -qE "$GIT_COMMIT_RE"; then
    printf 'commit'
  elif printf '%s' "$stripped" | grep -qE "$GIT_PR_RE"; then
    printf 'pr'
  elif printf '%s' "$stripped" | grep -qE "$GIT_PR_REVIEW_COMMENT_RE"; then
    printf 'pr-review'
  elif printf '%s' "$stripped" | grep -qE "$GIT_API_MUTATE_RE" \
    && printf '%s' "$command" | grep -qiE "$GIT_API_METHOD_MUTATE_RE" \
    && printf '%s' "$command" | grep -qE "$GIT_API_PR_PATH_RE"; then
    printf 'pr-review'
  fi
}

# カテゴリに対応する skill 名を1行ずつ出力する。短縮名とプラグイン名付きの両方を出すのは、どちらの書き方で起動されても認可するため。
git_category_skills() {
  case "$1" in
    commit) printf '%s\n' commit nt-developer:commit ;;
    pr) printf '%s\n' pr nt-developer:pr ;;
    pr-review) printf '%s\n' pr-comment nt-developer:pr-comment ;;
  esac
}

# 会話ログ側にフォールバックしたときに「消費」を数えるための正規表現。
# pr-review は `gh pr review` と `gh api` の投稿系を1つのカテゴリとして扱うため、消費の判定でも両方を数える（同じ skill 1回の起動で両方を通せてしまうのを防ぐ）。
git_category_consume_regex() {
  case "$1" in
    commit) printf '%s' "$GIT_COMMIT_RE" ;;
    pr) printf '%s' "$GIT_PR_RE" ;;
    pr-review) printf '%s' "($GIT_PR_REVIEW_COMMENT_RE|$GIT_API_MUTATE_RE)" ;;
  esac
}
