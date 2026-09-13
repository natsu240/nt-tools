#!/usr/bin/env bash
# hook 入力の `.cwd` はツールを呼んだ時点の作業ディレクトリで、コマンドの中の `cd` や `git -C` を反映しない。判定対象のディレクトリを `.cwd` だけで決めると、worktree へ `cd` してから操作しているのに本体の作業ツリーだと誤判定する。
#
# クォートで囲まれたパス（`cd '/path with space'`）はクォート除去処理が中身を落とすため拾えない。拾えなければ `.cwd` を返すので、判定は従来どおりになる。

# shellcheck source=lib-strip-quoted.sh
source "${BASH_SOURCE[0]%/*}/lib-strip-quoted.sh"

# 文中に語として現れただけのもの（`echo cd /tmp`）を拾わないよう、GIT_CMD_HEAD と同じ考え方でコマンドとして実行され得る位置に限定する。
EFFECTIVE_CWD_RE='(^|[;&|(]|\$\()[[:space:]]*(cd|git[[:space:]]+-C)[[:space:]]+[^[:space:];&|)]+'

# `effective_cwd "<コマンド文字列>" "<.cwd の値>"` で呼び、判定に使うべきディレクトリの絶対パスを1つ標準出力へ返す（末尾に改行は付けない）。
effective_cwd() {
  local command="$1" fallback="$2" stripped matches candidate resolved
  stripped="$(strip_quoted "$command")"

  matches="$(grep -oE "$EFFECTIVE_CWD_RE" <<<"$stripped" || true)"
  # 複数あれば先に現れた1つを使う。2つ目以降の時点では、最初の移動先での操作はもう済んでいる。
  candidate="${matches%%$'\n'*}"
  candidate="${candidate##*[[:space:]]}"
  [[ -z "$candidate" ]] && { printf '%s' "$fallback"; return; }

  case "$candidate" in
    /*) resolved="$candidate" ;;
    *) resolved="$fallback/$candidate" ;;
  esac

  # 変数の展開結果・`cd -`・タイポは実在しないパスになる。
  [[ -d "$resolved" ]] || { printf '%s' "$fallback"; return; }

  (cd "$resolved" && pwd)
}
