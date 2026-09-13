#!/usr/bin/env bash
set -euo pipefail

# SVG を直接 --print-to-pdf に渡すと用紙サイズ（Letter）の紙に縮小配置されるため、@page でページ寸法を指定したラッパー HTML に中身を埋め込んでから印刷する。
# <img> 参照ではなくインラインで埋め込むのは、画像として扱われると extract-svg.py が持ち込む @import（フォント指定）が読み込まれないためだ。

usage() {
    echo "使い方: svg-to-pdf.sh <入力svg> <出力pdf> [背景色(既定 #ffffff)]" >&2
    exit 1
}

SVG_PATH="${1:-}"
PDF_PATH="${2:-}"
BACKGROUND="${3:-#ffffff}"

[[ -n "$SVG_PATH" && -n "$PDF_PATH" ]] || usage
[[ -f "$SVG_PATH" ]] || { echo "入力SVGが見つからない: $SVG_PATH" >&2; exit 1; }

source "$(dirname "${BASH_SOURCE[0]}")/lib-chrome.sh"

CHROME_BIN="$(require_chrome)" || exit 1
read_svg_size "$SVG_PATH" || exit 1

WRAPPER_DIR="$(mktemp -d)"
trap 'rm -rf "$WRAPPER_DIR"' EXIT
WRAPPER_PATH="$WRAPPER_DIR/print.html"

{
    printf '<!DOCTYPE html>\n<html><head><meta charset="utf-8"><style>\n'
    printf '@page { size: %spx %spx; margin: 0; }\n' "$SVG_WIDTH" "$SVG_HEIGHT"
    printf 'html, body { margin: 0; padding: 0; background: %s; }\n' "$BACKGROUND"
    printf 'svg { display: block; }\n'
    printf '</style></head><body>\n'
    grep -v '^<?xml' "$SVG_PATH"
    printf '</body></html>\n'
} > "$WRAPPER_PATH"

mkdir -p "$(dirname "$PDF_PATH")"

"$CHROME_BIN" \
    --headless --disable-gpu --no-sandbox \
    --print-to-pdf="$PDF_PATH" \
    --no-pdf-header-footer \
    "$(file_url_of "$WRAPPER_PATH")"

[[ -f "$PDF_PATH" ]] || { echo "PDFが生成されなかった" >&2; exit 1; }
echo "$PDF_PATH"
