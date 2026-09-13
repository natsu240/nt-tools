#!/usr/bin/env bash
# plugins/*/skills/*/SKILL.md と plugins/*/agents/*.md の frontmatter・本文が参照するファイルパスを機械的に検査する構造バリデーター。
#
# 検査項目: SKILL.md の name/description 欠落、description 内のコロン+スペースのクォート漏れ（YAML の plain scalar は ": "（コロン+半角スペース）を含むとネストしたマッピングと誤認されてパースが崩れる）、templates/ references/ 配下の参照切れ（ファイル名変更時の書き忘れ）、hooks.json が直接パス実行している hook の実在と実行権限（権限が無いと実行時に Permission denied で一度も動かない）、gh の --jq に raw 出力フラグを付けた誤用（gh では unknown command になる）、~/.claude/review-rules/ からこのリポジトリへ張ったシンボリックリンクの切れ（切れても画面に何も出ないままレビュー規約が渡らなくなる）、複数のプラグインへ複製している同名 lib-*.sh の食い違い（片方だけ直すと一方は止めるのに一方は素通しする）。
# AI を使わない純粋なテキスト検査のため、実行コストはゼロ（トークン消費なし）。
#
# 使い方: bash scripts/validate-skills.sh exit 0: 全件合格 / exit 1: 検査エラーあり

set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

errors=0
checked=0

# 数値順を仮定しない: find の出力順は環境依存だが、全件検査するので順序自体は無関係
skill_files=$(find plugins -type f -path "*/skills/*/SKILL.md" | sort)
agent_files=$(find plugins -type f -path "*/agents/*.md" | sort)

extract_top_level_value() {
  # frontmatter 内でインデント無し（ネストしたリスト項目を除外）の "key: value" を1件抜く
  local frontmatter="$1"
  local key="$2"
  printf '%s\n' "$frontmatter" | grep -E "^${key}:" | head -n1 | sed -E "s/^${key}:[[:space:]]*//"
}

check_description_quoting() {
  local value="$1"
  local file="$2"

  case "$value" in
    \"*\"|\'*\')
      # ダブル/シングルクォートで囲まれている前提で通す（対応するクォートの厳密なバランス検査まではしない。過剰検出よりも既存の正しい記法を壊さない方を優先する）
      return 0
      ;;
  esac

  case "$value" in
    *": "*|*"："*)
      echo "❌ $file: description にクォート無しでコロン+スペースを含む（YAML パース事故のリスク）: ${value}"
      errors=$((errors + 1))
      ;;
  esac
}

check_frontmatter_file() {
  local file="$1"
  local expected_name="$2"
  checked=$((checked + 1))

  local first_line
  first_line=$(awk 'NR==1{print; exit}' "$file")
  if [ "$first_line" != "---" ]; then
    echo "❌ $file: frontmatter が --- で始まっていない"
    errors=$((errors + 1))
    return
  fi

  local frontmatter
  frontmatter=$(awk '/^---$/{c++; next} c==1{print} c==2{exit}' "$file")

  local name_value
  name_value=$(extract_top_level_value "$frontmatter" "name")
  if [ -z "$name_value" ]; then
    echo "❌ $file: name フィールドが無い"
    errors=$((errors + 1))
  elif [ "$name_value" != "$expected_name" ]; then
    echo "❌ $file: name(\"$name_value\") がディレクトリ/ファイル名(\"$expected_name\")と一致しない"
    errors=$((errors + 1))
  fi

  local description_value
  description_value=$(extract_top_level_value "$frontmatter" "description")
  if [ -z "$description_value" ]; then
    echo "❌ $file: description フィールドが無い、または空"
    errors=$((errors + 1))
  else
    check_description_quoting "$description_value" "$file"
  fi
}

check_referenced_paths() {
  local file="$1"
  local skill_dir
  skill_dir="$(dirname "$file")"

  # "plugin 内 `workflows/review-orchestrator.js` に委譲" のような本文中での概念的な言及まで拾うと過剰検出になる。実行時に Claude Code が実際に解決する${CLAUDE_SKILL_DIR}/ 起点の参照だけに絞る（それ以外は壊れてもスキルが機能不全にならないため対象外）`../` の直後にプラグイン名が入る形（他プラグイン同梱スクリプトの参照）も拾う。
  # 拾えないと、参照先をリネーム・移動したときに参照側だけ無言で腐る。
  local matches
  matches=$(grep -oE '\$\{CLAUDE_SKILL_DIR\}/(\.\./){0,3}([A-Za-z0-9_-]+/)?(references|templates|prompts|scripts|workflows)/[A-Za-z0-9_.-]+\.[A-Za-z0-9]+' "$file" | sed -E 's/^\$\{CLAUDE_SKILL_DIR\}\///' | sort -u)

  [ -z "$matches" ] && return

  local rel
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    local resolved
    resolved="$(cd "$skill_dir" 2>/dev/null && cd "$(dirname "$rel")" 2>/dev/null && pwd)"
    if [ -z "$resolved" ] || [ ! -f "$resolved/$(basename "$rel")" ]; then
      echo "❌ $file: 本文が参照するファイルが存在しない: $rel"
      errors=$((errors + 1))
    fi
  done <<< "$matches"
}

check_mcp_tool_namespace() {
  # プラグイン同梱の .mcp.json で定義した MCP サーバーは実行時にplugin:<プラグイン名>:<サーバー名> という名前空間に変換され、ツール名もmcp__plugin_<プラグイン名>_<サーバー名>__<ツール名> になる。
  # agent の tools: や hook の matcher がプラグイン名を省いた生のサーバー名（mcp__<サーバー名>__*）のまま残っていると、実際の接続名と一致せず該当ツールが一切バインドされない。
  local plugin_dir="$1"
  local plugin_name
  plugin_name="$(basename "$plugin_dir")"
  local mcp_json="$plugin_dir/.mcp.json"
  [ -f "$mcp_json" ] || return
  command -v jq >/dev/null 2>&1 || return

  local server_names
  server_names=$(jq -r '.mcpServers // {} | keys[]' "$mcp_json" 2>/dev/null)
  [ -z "$server_names" ] && return

  local server
  while IFS= read -r server; do
    [ -z "$server" ] && continue
    local hit
    hit=$(grep -rEn "mcp__${server}(__|,|\"| )" "$plugin_dir" --include="*.md" --include="*.json" --include="*.sh" --exclude-dir=tests 2>/dev/null | grep -v "mcp__plugin_${plugin_name}_${server}__")
    if [ -n "$hit" ]; then
      echo "❌ ${plugin_dir}: MCP サーバー '${server}' がプラグイン名前空間プレフィックス無し（mcp__${server}__* 等）で参照されている。実際の接続名は mcp__plugin_${plugin_name}_${server}__* のはず:"
      echo "$hit" | sed 's/^/    /'
      errors=$((errors + 1))
    fi
  done <<< "$server_names"
}

check_hook_exec_permission() {
  # hooks.json は hook を "${CLAUDE_PLUGIN_ROOT}/hooks/<file>" の形で直接パス実行する。
  # 実行権限の無いファイルがコミットされていると実行時に /bin/sh: Permission denied になり、その hook はインストール以来一度も動かない。しかも記録だけを行う PostToolUse のhook は失敗しても作業が止まらないため、気付く機会が無い。
  # source されるだけのライブラリは hooks.json から参照されないため自然に対象外になる。
  local plugin_dir="$1"
  local hooks_json="$plugin_dir/hooks/hooks.json"
  [ -f "$hooks_json" ] || return

  local refs
  refs=$(grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/hooks/[A-Za-z0-9_.-]+' "$hooks_json" | sed -E 's|^\$\{CLAUDE_PLUGIN_ROOT\}/hooks/||' | sort -u)
  [ -z "$refs" ] && return

  local name
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    local path="$plugin_dir/hooks/$name"
    if [ ! -f "$path" ]; then
      echo "❌ $hooks_json: 参照している hook が存在しない: hooks/$name"
      errors=$((errors + 1))
      continue
    fi
    if [ ! -x "$path" ]; then
      echo "❌ $path: hooks.json が直接パス実行しているのに実行権限が無い（実行時に Permission denied になり hook が一度も動かない）。git update-index --chmod=+x で 100755 にしろ"
      errors=$((errors + 1))
    fi
  done <<< "$refs"
}

check_gh_jq_flag() {
  # gh の --jq は既定で jq -r 相当の raw 出力（文字列をクォート無しで出す）になるため、jq と同じつもりで raw 出力フラグを付けた形で書くと`unknown command ".[].name" for "gh label list"` で必ず失敗する。スキル本文のコマンド例に混ざっていると、その手順を実行した瞬間にコケる。
  # 検索パターンは変数で組む（このファイル自身も検索対象に入るため、検査コードが自分をヒットさせないようにする）。
  local bad_flag="-r"
  local hits
  hits=$(grep -rn -- "--jq ${bad_flag}" plugins scripts 2>/dev/null)
  [ -z "$hits" ] && return

  echo "❌ gh の --jq に ${bad_flag} を付けている箇所がある（gh では unknown command で失敗する。${bad_flag} 無しで書け）:"
  echo "$hits" | sed 's/^/    /'
  errors=$((errors + 1))
}

check_review_rules_symlinks() {
  # ~/.claude/review-rules/ には、このリポジトリの code-style 系 SKILL.md を指すシンボリックリンクを張って /code-review にレビュー規約を渡している。
  # skill を別プラグインへ移す・名前を変える・消すと全部まとめて切れるが、/code-review は `(review-rules なし)` とすら表示せず黙って動き続けるため気づく機会が無い。
  #
  # 対象はこのリポジトリの中を指しているリンクだけにする。他のリポジトリ・個人のファイルを指すリンクが切れていてもこのリポジトリの責任ではない。ディレクトリが無い環境（このリポジトリを使う全員が張っているものではない）も対象外。
  # リンク先が相対パスのものは、切れていると本来どこを指していたか判定できないため対象外になる（このリポジトリへのリンクは絶対パスで張る前提）。
  local dir="$HOME/.claude/review-rules"
  [ -d "$dir" ] || return

  local link target
  for link in "$dir"/*; do
    [ -L "$link" ] || continue
    target="$(readlink "$link")"
    case "$target" in
      "$repo_root"/*) ;;
      *) continue ;;
    esac
    if [ ! -e "$link" ]; then
      echo "❌ $link: リンク先がこのリポジトリ内に存在しない: $target"
      echo "    切れたままだと /code-review にレビュー規約が渡らない（画面には何も出ない）。移動先へ張り直せ"
      errors=$((errors + 1))
    fi
  done
}

check_reviewer_shared_instructions() {
  local dir="$repo_root/plugins/nt-developer/agents"
  [ -d "$dir" ] || return

  local required=(
    "修正は呼び出し元が判断する"
    "必ずスキーマの root object をそのまま tool input に渡せ"
    "のような迂回は絶対にやるな"
  )

  local file phrase path
  for file in reviewer.md reviewer-db.md reviewer-cdk.md; do
    path="$dir/$file"
    [ -f "$path" ] || continue
    for phrase in "${required[@]}"; do
      if ! grep -qF -- "$phrase" "$path"; then
        echo "❌ $path: reviewer 3種で共通の指示が落ちている: 「${phrase}」"
        errors=$((errors + 1))
      fi
    done
  done
}

check_duplicated_libs() {
  local -a duplicated=(
    "lib-called-skills.sh"
    "lib-emit-decision.sh"
  )

  local name base other
  for name in "${duplicated[@]}"; do
    base="$repo_root/plugins/nt-common/hooks/$name"
    other="$repo_root/plugins/nt-developer/hooks/$name"
    [ -f "$base" ] && [ -f "$other" ] || continue
    if ! cmp -s "$base" "$other"; then
      echo "❌ $name: nt-common 版と nt-developer 版の内容が食い違っている（片方だけ直すと判定がズレる）"
      errors=$((errors + 1))
    fi
  done
}

while IFS= read -r file; do
  [ -z "$file" ] && continue
  expected_name="$(basename "$(dirname "$file")")"
  check_frontmatter_file "$file" "$expected_name"
  check_referenced_paths "$file"
done <<< "$skill_files"

while IFS= read -r file; do
  [ -z "$file" ] && continue
  expected_name="$(basename "$file" .md)"
  check_frontmatter_file "$file" "$expected_name"
done <<< "$agent_files"

plugin_dirs=$(find plugins -mindepth 1 -maxdepth 1 -type d | sort)
while IFS= read -r pdir; do
  [ -z "$pdir" ] && continue
  check_mcp_tool_namespace "$pdir"
  check_hook_exec_permission "$pdir"
done <<< "$plugin_dirs"

check_gh_jq_flag
check_review_rules_symlinks
check_reviewer_shared_instructions
check_duplicated_libs

echo "---"
echo "検査対象: ${checked} ファイル / エラー: ${errors} 件"

if [ "$errors" -gt 0 ]; then
  exit 1
fi
exit 0
