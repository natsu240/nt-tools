#!/usr/bin/env bash
# git remote / auto-results ファイル名から owner・repo を取り出す処理。複数の hook が source して使う。
#
# 各スクリプトに書き写すな。片方だけ直すと、一方は判定できるのに一方は判定できない状態になる。

# 標準出力へ "owner/repo" を1行返す。取得できなければ何も出さない。
git_remote_owner_repo() {
  local cwd="$1" url
  url="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$cwd" remote get-url origin 2>/dev/null || true)"
  [[ -z "$url" ]] && return 0
  printf '%s' "$url" | grep -oE 'github\.com[:/][^/]+/[^/]+' \
    | sed -E 's#^github\.com[:/]##; s#\.git$##'
}

# `_auto-results/<org>_<repo>-<PR番号>.json` 形式のパスから owner/repo/PR番号を取り出す。
# org と repo の境界は最初の `_`、repo と PR番号の境界は最後の `-`（repo 名にハイフンを含む前提）。
# 標準出力へ "org repo pr" を1行返す。パターンに合わなければ何も出さない。
parse_auto_results_filename() {
  local path="$1" base name org rest repo pr
  base="$(basename "$path")"
  case "$base" in
    *.json) ;;
    *) return 0 ;;
  esac
  name="${base%.json}"
  case "$name" in
    *_*-*[0-9]) ;;
    *) return 0 ;;
  esac
  org="${name%%_*}"
  rest="${name#*_}"
  pr="${rest##*-}"
  repo="${rest%-*}"
  [[ -z "$org" || -z "$repo" || ! "$pr" =~ ^[0-9]+$ ]] && return 0
  printf '%s %s %s\n' "$org" "$repo" "$pr"
}
