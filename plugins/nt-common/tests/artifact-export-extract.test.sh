#!/usr/bin/env bash

set -uo pipefail

SCRIPT="$(cd "${BASH_SOURCE[0]%/*}/../skills/artifact-export/scripts" && pwd)/extract-svg.py"
[[ -f "$SCRIPT" ]] || { echo "extract-svg.py が見つかりません: $SCRIPT"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FIXTURE="$TMP_ROOT/fixture.html"
cat >"$FIXTURE" <<'HTML'
<!-- frame-runtime -->
<style>body{margin:0}img{max-width:100%}</style>
<html>
<head>
<style>
:root{--bg:#fff}
table{border-collapse:collapse}
.page{padding:8px}
svg .zone-vpc{fill:#eef;stroke:#99c}
svg .icon-box{fill:none}
svg #fake-id{fill:red}
@font-face{font-family:"X";src:url(x.woff)}
</style>
<script>
const css = "svg .zone-vpc{fill:red}";
</script>
</head>
<body>
<svg class="icon-sprite-no-viewbox">
  <symbol id="ic-orphan"><circle r="1"/></symbol>
</svg>
<svg viewBox="0 0 10 10" class="icon-sprite-defs-only">
  <symbol id="ic-server"><rect id="inner-rect" width="10" height="10"/></symbol>
  <symbol id="ic-unused"><circle r="5"/></symbol>
</svg>
<h2>構成図A</h2>
<figure>
<svg viewBox="0 0 100 100">
  <rect class="zone-vpc" x="0" y="0" width="100" height="100"/>
  <rect class="deco" data-id="fake-id" x="0" y="0" width="1" height="1"/>
  <use href="#ic-server" class="icon-box" x="10" y="10"/>
  <text x="5" y="5">&nbsp;サーバー&nbsp;</text>
</svg>
<figcaption>構成図Aの説明</figcaption>
</figure>
</body>
</html>
HTML

failures=0
total=0

check() {
  local label=$1 condition=$2
  total=$((total + 1))
  if ! eval "$condition"; then
    failures=$((failures + 1))
    echo "NG  $label"
  fi
}

LIST_JSON="$(python3 "$SCRIPT" list "$FIXTURE")"

check "list: 図を1枚検出する" \
  '[[ "$(jq "(.figures | length)" <<<"$LIST_JSON")" == "1" ]]'

check "list: sprite(viewBox無し)は candidates に混ぜない" \
  '[[ "$(jq -r ".skipped[] | select(.reason == \"viewBox が無い\") | length" <<<"$LIST_JSON" | wc -l | tr -d " ")" == "1" ]]'

check "list: sprite(定義置き場)は candidates に混ぜない" \
  '[[ "$(jq -r "[.skipped[] | select(.reason | startswith(\"定義置き場\"))] | length" <<<"$LIST_JSON")" == "1" ]]'

check "list: 見出し・キャプションが取れている" \
  '[[ "$(jq -r ".figures[0].heading" <<<"$LIST_JSON")" == "構成図A" && "$(jq -r ".figures[0].caption" <<<"$LIST_JSON")" == "構成図Aの説明" ]]'

OUT_SVG="$TMP_ROOT/out.svg"
EXTRACT_JSON="$(python3 "$SCRIPT" extract "$FIXTURE" --index 0 --out "$OUT_SVG")"

check "extract: xml_valid が true" \
  '[[ "$(jq -r ".xml_valid" <<<"$EXTRACT_JSON")" == "true" ]]'

check "extract: unresolved_ids が空" \
  '[[ "$(jq -r "(.unresolved_ids | length)" <<<"$EXTRACT_JSON")" == "0" ]]'

check "extract: xml.etree.ElementTree で実際にパースできる" \
  'python3 -c "import xml.etree.ElementTree as ET; ET.parse(\"$OUT_SVG\")"'

SVG_BODY="$(cat "$OUT_SVG")"

check "extract: 使われている symbol(ic-server)を含む" \
  '[[ "$SVG_BODY" == *'\''id="ic-server"'\''* ]]'

check "extract: 使われていない symbol(ic-unused)は含まない" \
  '[[ "$SVG_BODY" != *'\''id="ic-unused"'\''* ]]'

check "extract: 別 sprite の孤立 symbol(ic-orphan)は含まない" \
  '[[ "$SVG_BODY" != *'\''id="ic-orphan"'\''* ]]'

check "extract: 使用実績ベースで svg 配下の CSS ルールを残す" \
  '[[ "$SVG_BODY" == *'\''.zone-vpc'\''* && "$SVG_BODY" == *'\''.icon-box'\''* ]]'

check "extract: 使われていない body/table/.page の CSS ルールは落とす" \
  '[[ "$SVG_BODY" != *'\''body{margin:0}'\''* && "$SVG_BODY" != *"table {"* && "$SVG_BODY" != *".page {"* ]]'

check "extract: 絞り込み対象外の @font-face はそのまま残す" \
  '[[ "$SVG_BODY" == *"@font-face"* ]]'

check "extract: data-id を id 属性と誤認しない(#fake-id の CSS ルールは落ちる)" \
  '[[ "$SVG_BODY" != *"#fake-id"* ]]'

check "extract: script内の文字列はCSSとして拾わない" \
  '[[ "$SVG_BODY" != *"fill:red"* ]]'

check "extract: &nbsp; は数値文字参照に変換される" \
  '[[ "$SVG_BODY" == *"&#160;"* && "$SVG_BODY" != *"&nbsp;"* ]]'

if [[ "$failures" -gt 0 ]]; then
  printf '\nartifact-export-extract: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'artifact-export-extract: %d 件すべて期待どおり\n' "$total"
