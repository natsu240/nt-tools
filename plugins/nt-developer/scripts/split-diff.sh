#!/usr/bin/env bash
# code-review の差分ファイルを、Read ツール 1 回の読み取り上限に収まらないときだけファイル単位に分割し、目次（分割ファイルのパス + 対象ファイル + 行数）を書き出す固定処理。
#
# **行数だけで判定するな。** Read の上限は行数と読み込み量の両方で決まり、1 行あたりが長い差分は行数の閾値内に収まったまま失敗する。日本語が大半なので文字数でも代用できず、awk は LC_ALL=C で呼んで length() をバイト単位にしている。
set -u

DIFF_PATH="${1:?diff path required}"
OUT_DIR="${2:?output dir required}"
MAX_LINES="${3:-1500}"
MAX_BYTES="${4:-20000}"

if [ ! -f "$DIFF_PATH" ]; then
  echo "NOSPLIT 0 0"
  exit 0
fi

TOTAL_LINES=$(wc -l < "$DIFF_PATH" | tr -d ' ')
TOTAL_BYTES=$(wc -c < "$DIFF_PATH" | tr -d ' ')

if [ "$TOTAL_LINES" -le "$MAX_LINES" ] && [ "$TOTAL_BYTES" -le "$MAX_BYTES" ]; then
  echo "NOSPLIT ${TOTAL_LINES} ${TOTAL_BYTES}"
  exit 0
fi

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/diff-*.diff "$OUT_DIR/diff-index.txt"

# ファイル記述子を使い切らないよう、境界ごとに前のファイルを close する。
awk -v out="$OUT_DIR" '
/^diff --git / {
  if (fname != "") close(fname)
  n++
  fname = sprintf("%s/diff-%03d.diff", out, n)
}
fname != "" { print > fname }
END { if (fname != "") close(fname) }
' "$DIFF_PATH"

# 1 行が単体で上限バイト数を超える場合はその行だけで 1 ファイルになる（行を途中で割ると差分の 1 行が分断されて読めなくなるため、閾値超過を許して行の境界を守る）。
for f in "$OUT_DIR"/diff-*.diff; do
  [ -f "$f" ] || continue
  lines=$(wc -l < "$f" | tr -d ' ')
  bytes=$(wc -c < "$f" | tr -d ' ')
  if [ "$lines" -le "$MAX_LINES" ] && [ "$bytes" -le "$MAX_BYTES" ]; then
    continue
  fi
  LC_ALL=C awk -v prefix="${f%.diff}" -v maxl="$MAX_LINES" -v maxb="$MAX_BYTES" '
  {
    len = length($0) + 1
    if (fname == "" || (nlines > 0 && (nlines >= maxl || size + len > maxb))) {
      if (fname != "") close(fname)
      n++
      fname = sprintf("%s-part%03d.diff", prefix, n)
      size = 0
      nlines = 0
    }
    print > fname
    size += len
    nlines++
  }
  END { if (fname != "") close(fname) }
  ' "$f"
  rm -f "$f"
done

{
  echo "# 差分の目次"
  echo "# 元の差分は全 ${TOTAL_LINES} 行 / ${TOTAL_BYTES} バイトで、Read ツール 1 回の上限に収まらないためファイル単位に分割した。"
  echo "# 下記の全ファイルを Read ツールで読め。1 つも飛ばすな。"
  echo ""
  for f in "$OUT_DIR"/diff-*.diff; do
    [ -f "$f" ] || continue
    target=$(grep -m 1 '^diff --git ' "$f" | sed 's|^diff --git a/||; s| b/.*$||')
    [ -n "$target" ] || target="(直前のファイルの続き)"
    lines=$(wc -l < "$f" | tr -d ' ')
    echo "- ${f} : ${target} (${lines} 行)"
  done
} > "$OUT_DIR/diff-index.txt"

COUNT=$(find "$OUT_DIR" -maxdepth 1 -name 'diff-*.diff' | wc -l | tr -d ' ')
echo "SPLIT ${COUNT} ${TOTAL_LINES} ${TOTAL_BYTES}"
find "$OUT_DIR" -maxdepth 1 -name 'diff-*.diff' | sort
