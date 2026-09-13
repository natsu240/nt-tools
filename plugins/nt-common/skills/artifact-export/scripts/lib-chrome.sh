#!/usr/bin/env bash
# svg-to-png.sh と svg-to-pdf.sh から source される共有部分。

CHROME_CANDIDATES=(
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
    "google-chrome"
    "chromium"
)

find_chrome() {
    local candidate
    for candidate in "${CHROME_CANDIDATES[@]}"; do
        if [[ "$candidate" == /* ]]; then
            [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
        elif command -v "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

require_chrome() {
    find_chrome || { echo "headless Chromeが見つからない（Google Chrome / Chromiumを確認しろ）" >&2; return 1; }
}

# pipefail 下でパイプの途中に head を置くと、上流の grep が SIGPIPE で死んで読み取り成功時でも失敗扱いになる。
read_svg_size() {
    local svg_path="$1"
    local opening
    opening="$(grep -m1 -o '<svg[^>]*>' "$svg_path")" || opening=''
    SVG_WIDTH=''
    SVG_HEIGHT=''
    if [[ "$opening" =~ width=\"([0-9.]+)\" ]]; then
        SVG_WIDTH="${BASH_REMATCH[1]}"
    fi
    if [[ "$opening" =~ height=\"([0-9.]+)\" ]]; then
        SVG_HEIGHT="${BASH_REMATCH[1]}"
    fi
    [[ -n "$SVG_WIDTH" && -n "$SVG_HEIGHT" ]] || { echo "SVGからwidth/heightを読み取れない（extract-svg.pyの出力を渡しているか確認しろ）" >&2; return 1; }
}

file_url_of() {
    local path="$1"
    printf 'file://%s/%s\n' "$(cd "$(dirname "$path")" && pwd)" "$(basename "$path")"
}
