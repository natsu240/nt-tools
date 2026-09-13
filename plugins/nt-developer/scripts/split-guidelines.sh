#!/usr/bin/env bash
# code-review のガイドライン連結ファイル（AGENTS.md / docs/*.md / CLAUDE.md を cat したもの）を、Read ツール 1 回で読める大きさに収まらないときだけ分割し、目次（分割ファイルのパス +バイト数）を書き出す固定処理。
#
# **行数で判定するな。** Read の上限はバイト数で決まり、日本語が大半なので文字数でも代用できない。awk は LC_ALL=C で呼んで length() をバイト単位にしている。
set -u

GUIDELINES_PATH="${1:?guidelines path required}"
OUT_DIR="${2:?output dir required}"
MAX_BYTES="${3:-20000}"

if [ ! -f "$GUIDELINES_PATH" ]; then
  echo "NOSPLIT 0"
  exit 0
fi

TOTAL_BYTES=$(wc -c < "$GUIDELINES_PATH" | tr -d ' ')

if [ "$TOTAL_BYTES" -le "$MAX_BYTES" ]; then
  echo "NOSPLIT ${TOTAL_BYTES}"
  exit 0
fi

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/guidelines-[0-9]*.txt "$OUT_DIR/guidelines-index.txt"

# 1 行が単体で閾値を超える場合はその行だけで 1 ファイルになる（行を途中で割ると規約の 1 文が分断されて読めなくなるため、閾値超過を許して行の境界を守る）。
LC_ALL=C awk -v out="$OUT_DIR" -v max="$MAX_BYTES" '
{
  len = length($0) + 1
  if (fname == "" || (size > 0 && size + len > max)) {
    if (fname != "") close(fname)
    n++
    fname = sprintf("%s/guidelines-%03d.txt", out, n)
    size = 0
  }
  print > fname
  size += len
}
END { if (fname != "") close(fname) }
' "$GUIDELINES_PATH"

{
  echo "# ガイドラインの目次"
  echo "# 元のガイドラインは全 ${TOTAL_BYTES} バイトで、Read ツール 1 回の上限に収まらないため分割した。"
  echo "# 下記の全ファイルを Read ツールで読め。1 つも飛ばすな。"
  echo ""
  # 目次ファイル自身は上のリダイレクトで既に作られているので、番号付きの分割ファイルだけを拾う glob にする（`guidelines-*.txt` だと目次が目次に載る）。
  for f in "$OUT_DIR"/guidelines-[0-9]*.txt; do
    [ -f "$f" ] || continue
    bytes=$(wc -c < "$f" | tr -d ' ')
    echo "- ${f} : ${bytes} バイト"
  done
} > "$OUT_DIR/guidelines-index.txt"

COUNT=$(find "$OUT_DIR" -maxdepth 1 -name 'guidelines-[0-9]*.txt' | wc -l | tr -d ' ')
echo "SPLIT ${COUNT} ${TOTAL_BYTES}"
find "$OUT_DIR" -maxdepth 1 -name 'guidelines-[0-9]*.txt' | sort
