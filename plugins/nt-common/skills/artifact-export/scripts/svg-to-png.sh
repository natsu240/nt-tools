#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "使い方: svg-to-png.sh <入力svg> <出力png> [倍率(既定2)] [背景色(既定 FFFFFFFF)]" >&2
    exit 1
}

SVG_PATH="${1:-}"
PNG_PATH="${2:-}"
SCALE="${3:-2}"
BACKGROUND="${4:-FFFFFFFF}"

[[ -n "$SVG_PATH" && -n "$PNG_PATH" ]] || usage
[[ -f "$SVG_PATH" ]] || { echo "入力SVGが見つからない: $SVG_PATH" >&2; exit 1; }

source "$(dirname "${BASH_SOURCE[0]}")/lib-chrome.sh"

CHROME_BIN="$(require_chrome)" || exit 1
read_svg_size "$SVG_PATH" || exit 1

# --window-sizeは整数のみ受け付ける
WINDOW_WIDTH=$(( ${SVG_WIDTH%.*} > 0 ? ${SVG_WIDTH%.*} : 1 ))
WINDOW_HEIGHT=$(( ${SVG_HEIGHT%.*} > 0 ? ${SVG_HEIGHT%.*} : 1 ))

mkdir -p "$(dirname "$PNG_PATH")"

"$CHROME_BIN" \
    --headless --disable-gpu --no-sandbox \
    --screenshot="$PNG_PATH" \
    --window-size="${WINDOW_WIDTH},${WINDOW_HEIGHT}" \
    --force-device-scale-factor="$SCALE" \
    --default-background-color="$BACKGROUND" \
    "$(file_url_of "$SVG_PATH")"

[[ -f "$PNG_PATH" ]] || { echo "PNGが生成されなかった" >&2; exit 1; }
echo "$PNG_PATH"
