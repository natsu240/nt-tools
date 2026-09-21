#!/usr/bin/env bash
# コマンド文字列と、そのコマンドが `--body-file` / `-F` で渡しているファイルの中身を連結して返す処理。
#
# 本文をファイル経由で渡すと、本文の中身を見る hook にはコマンド文字列だけが届き、検査対象そのものが手元に無い状態になる。

# $1=command の `--body-file` / `-F` の引数のパスを1件1行で返す。
extract_body_file_paths() {
  local command="$1" w take=0
  set -f
  for w in $command; do
    w="${w//\'/}"
    w="${w//\"/}"
    if [[ "$take" == 1 ]]; then
      take=0
      [[ -n "$w" ]] && printf '%s\n' "$w"
      continue
    fi
    case "$w" in
      --body-file=*) printf '%s\n' "${w#--body-file=}" ;;
      --body-file|-F) take=1 ;;
    esac
  done
  set +f
}

# $1=command と、そこから読めたファイルの中身を改行で連結して返す（$2=cwd は相対パスの起点。空でよい）。
command_with_body_files() {
  local command="$1" cwd="$2" path
  printf '%s' "$command"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ "$path" != /* && -n "$cwd" ]] && path="$cwd/$path"
    [[ -f "$path" ]] || continue
    printf '\n'
    cat "$path" 2>/dev/null
  done <<<"$(extract_body_file_paths "$command")"
}
