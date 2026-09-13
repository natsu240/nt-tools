#!/usr/bin/env bash
# deny-artifact-official-icons.sh の検査。

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-artifact-official-icons.sh"
[[ -f "$HOOK" ]] || { echo "deny-artifact-official-icons.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

HANDMADE="$TMP_ROOT/handmade.html"
cat >"$HANDMADE" <<'HTML'
<html><body>
<svg viewBox="0 0 200 200">
  <rect x="0" y="0" width="200" height="200" fill="none" stroke="#888"/>
  <text x="10" y="20">VPC パブリックサブネット</text>
  <rect x="40" y="60" width="80" height="40"/>
  <text x="50" y="80">EC2 インスタンス</text>
</svg>
</body></html>
HTML

OFFICIAL="$TMP_ROOT/official.html"
cat >"$OFFICIAL" <<'HTML'
<html><body>
<svg><symbol id="icon-ec2" viewBox="0 0 48 48"><path d="M0 0h48v48H0z"/></symbol></svg>
<svg viewBox="0 0 200 200">
  <text x="10" y="20">VPC パブリックサブネット</text>
  <use href="#icon-ec2" x="40" y="60"/>
  <text x="50" y="120">EC2 インスタンス</text>
</svg>
</body></html>
HTML

SINGLE_SERVICE="$TMP_ROOT/single.html"
cat >"$SINGLE_SERVICE" <<'HTML'
<html><body>
<svg viewBox="0 0 200 200">
  <rect x="0" y="0" width="100" height="40"/>
  <text x="10" y="20">Lambda の実行回数</text>
</svg>
</body></html>
HTML

REPORT="$TMP_ROOT/report.html"
cat >"$REPORT" <<'HTML'
<html><body>
<table><tr><td>EC2</td><td>VPC</td><td>Aurora</td></tr></table>
<svg viewBox="0 0 100 100"><rect width="100" height="100"/><text x="5" y="20">月次の推移</text></svg>
</body></html>
HTML

NO_SVG="$TMP_ROOT/no-svg.html"
printf '<html><body><p>EC2 と VPC と Aurora の話</p></body></html>' >"$NO_SVG"

failures=0
total=0

judge() {
  local out=$1
  if [[ -z "$out" ]]; then
    printf 'pass'
  elif grep -q '"permissionDecision": "deny"' <<<"$out"; then
    printf 'deny'
  else
    printf 'other'
  fi
}

run_raw_case() {
  local expected=$1 label=$2 payload=$3
  local out actual
  total=$((total + 1))
  out="$(printf '%s' "$payload" | bash "$HOOK" 2>&1)"
  actual="$(judge "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-4s %s\n' "$expected" "$actual" "$label"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- 止める例 ---
run_raw_case deny "自作の箱で描いた AWS 構成図" "$(jq -nc --arg p "$HANDMADE" '{tool_name: "Artifact", tool_input: {file_path: $p}}')"
run_raw_case deny "action: publish を明示した場合も同じ" "$(jq -nc --arg p "$HANDMADE" '{tool_name: "Artifact", tool_input: {action: "publish", file_path: $p}}')"

# --- 止めてはいけない例 ---
run_raw_case pass "公式アイコンを symbol/use で埋め込んでいる構成図" "$(jq -nc --arg p "$OFFICIAL" '{tool_name: "Artifact", tool_input: {file_path: $p}}')"
run_raw_case pass "AWS のサービス名が1種類だけの図" "$(jq -nc --arg p "$SINGLE_SERVICE" '{tool_name: "Artifact", tool_input: {file_path: $p}}')"
run_raw_case pass "サービス名が本文の表にあるだけのレポート" "$(jq -nc --arg p "$REPORT" '{tool_name: "Artifact", tool_input: {file_path: $p}}')"
run_raw_case pass "SVG を持たないページ" "$(jq -nc --arg p "$NO_SVG" '{tool_name: "Artifact", tool_input: {file_path: $p}}')"
run_raw_case pass "file_path のファイルが存在しない" "$(jq -nc '{tool_name: "Artifact", tool_input: {file_path: "/nonexistent/diagram.html"}}')"
run_raw_case pass "read は対象外" "$(jq -nc --arg p "$HANDMADE" '{tool_name: "Artifact", tool_input: {action: "read", url: "https://x", file_path: $p}}')"
run_raw_case pass "upload_asset は対象外" "$(jq -nc --arg p "$HANDMADE" '{tool_name: "Artifact", tool_input: {action: "upload_asset", file_path: $p}}')"
run_raw_case pass "サブエージェントからの呼び出しは対象外" "$(jq -nc --arg p "$HANDMADE" '{tool_name: "Artifact", tool_input: {file_path: $p}, agent_id: "sub-1", agent_type: "explorer"}')"
run_raw_case pass "対象外ツール(Read)" "$(jq -nc --arg p "$HANDMADE" '{tool_name: "Read", tool_input: {file_path: $p}}')"

if [[ "$failures" -gt 0 ]]; then
  printf '\nartifact-official-icons-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'artifact-official-icons-gate: %d 件すべて期待どおり\n' "$total"
