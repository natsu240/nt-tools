#!/usr/bin/env bash
# 止める条件に合致しないときは何も出力せず exit 0 で終わる。permissionDecision は任意で、値が無ければ通常の許可の流れに戻る。

set -euo pipefail

INPUT_JSON="$(cat)"

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
case "$TOOL_NAME" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT_JSON")"
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# 一時ディレクトリ配下は対象外。使い捨ての調査スクリプトにコード規約を要求する意味が無い。
case "$FILE_PATH" in
  /tmp/*|/private/tmp/*) exit 0 ;;
esac
if [[ -n "${TMPDIR:-}" && "$FILE_PATH" == "${TMPDIR%/}"/* ]]; then
  exit 0
fi

# 拡張子ごとのコメント開始記号。Markdown は入れない（`#` 見出しが全部コメント行として拾われる）。
case "$FILE_PATH" in
  *.php|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.vue|*.scss|*.css|*.java|*.go|*.rs|*.kt|*.swift)
    COMMENT_HEAD='(//|/\*|\*)'
    ;;
  *.sh|*.bash|*.zsh|*.py|*.rb|*.yml|*.yaml)
    COMMENT_HEAD='#'
    ;;
  *.sql)
    COMMENT_HEAD='(--|/\*|\*)'
    ;;
  *)
    exit 0
    ;;
esac

NEW_TEXT="$(
  jq -r '
    [.tool_input.new_string?, .tool_input.content?, (.tool_input.edits[]?.new_string?)]
    | map(select(. != null))
    | join("\n")
  ' <<<"$INPUT_JSON"
)"
if [[ -z "$NEW_TEXT" ]]; then
  exit 0
fi

# 編集対象ファイルのリポジトリルート。新規作成では親ディレクトリがまだ無いことがあるため、実在する祖先まで遡ってから git に聞く。
SEARCH_DIR="$(dirname "$FILE_PATH")"
while [[ ! -d "$SEARCH_DIR" && "$SEARCH_DIR" != "/" && "$SEARCH_DIR" != "." ]]; do
  SEARCH_DIR="$(dirname "$SEARCH_DIR")"
done
REPO_ROOT="$(git -C "$SEARCH_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
# project_notes/ は本体にしか置かれないため、ワークツリーからも共通の .git を持つ本体のディレクトリを見る。
COMMON_DIR="$(git -C "$SEARCH_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
NOTES_ROOT="${COMMON_DIR:+$(dirname "$COMMON_DIR")}"

REL_PATH="$FILE_PATH"
if [[ -n "$REPO_ROOT" && "$FILE_PATH" == "$REPO_ROOT"/* ]]; then
  REL_PATH="${FILE_PATH#"$REPO_ROOT"/}"
fi

EXCLUDE_PATHS=()
EXTRA_PATTERNS=()
CONFIG_PATH=""
if [[ -n "$NOTES_ROOT" && -f "$NOTES_ROOT/project_notes/comment-guard.json" ]]; then
  CONFIG_PATH="$NOTES_ROOT/project_notes/comment-guard.json"
  # 壊れた設定ファイルで編集を止めない。読めなければ検査ごと諦める。
  if ! jq -e . "$CONFIG_PATH" >/dev/null 2>&1; then
    exit 0
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] && EXCLUDE_PATHS+=("$line")
  done < <(jq -r '.excludePaths[]? // empty' "$CONFIG_PATH")
  while IFS= read -r line; do
    [[ -n "$line" ]] && EXTRA_PATTERNS+=("$line")
  done < <(jq -r '.extraPatterns[]? // empty' "$CONFIG_PATH")
fi

# 除外パスの照合。`*` はディレクトリの区切りもまたぐ。
# 先頭の `**/` は「どの階層でも」の意味なので、リポジトリ直下のファイルにも当たるようにする。
path_matches() {
  local rel="$1" pat="$2"
  # shellcheck disable=SC2053
  [[ "$rel" == $pat ]] && return 0
  if [[ "$pat" == '**/'* ]]; then
    # shellcheck disable=SC2053
    [[ "$rel" == ${pat#'**/'} ]] && return 0
  fi
  return 1
}

for pat in ${EXCLUDE_PATHS+"${EXCLUDE_PATHS[@]}"}; do
  if path_matches "$REL_PATH" "$pat"; then
    exit 0
  fi
done

SPEC_URL_PATTERN='(atlassian\.net|docs\.google\.com/spreadsheets|github\.com/[^[:space:]]+/(issues|pull)/)'
QA_PATTERN='QA[[:space:]]*#?[0-9]+'
DB_VALUE_PATTERN='(\bvarchar\b|\bmax:[0-9]+)'

# 過去の状態を断定する形だけを載せる。「〜だった」「〜していた」は技術根拠の説明でも使い、「以前の」「元々」は「3日以前のファイル」のような日付・順序の説明で使うため、載せると正当なコメントまで止まる。
# 全角文字は文字クラスに入れるとバイト単位に分解されて壊れるので、リテラルの交替で書く。
HISTORY_PATTERN='(以前は|かつては|当初は|旧実装|旧仕様|旧:|旧：|将来課題)'

HIT_KIND=""
HIT_TOKEN=""
HIT_LINE=""

# **awk へ正規表現を渡す前にバックスラッシュを二重にしろ。** `-v` の代入で `\*` のエスケープが解け、`(//|/*|*)` という不正な正規表現になる。
AWK_COMMENT_HEAD="${COMMENT_HEAD//\\/\\\\}"
RULE_PATTERN='^[-=*#_~][-=*#_~]'
WRAP_MIN_BYTES=60
WRAPPED_LINE="$(
  LC_ALL=C awk -v head="$AWK_COMMENT_HEAD" -v minlen="$WRAP_MIN_BYTES" -v rule="$RULE_PATTERN" '
    function is_skippable(body) {
      return body ~ /^[[:space:]]*$/ || body ~ /^[[:space:]]/ \
        || body ~ /^[-*+][[:space:]]/ || body ~ /^[0-9]+[.)][[:space:]]/ \
        || body ~ rule || body ~ /^shellcheck/ \
        || body == "/" \
        || body ~ /^@?(shellcheck|eslint|stylelint|prettier|ts-|phpstan|psalm|phpcs|noinspection|noqa|pylint|rubocop|nolint|type:|param|return|var|template(-covariant)?|throws)/
    }
    {
      if ($0 !~ ("^[[:space:]]*" head)) { prev = ""; next }
      body = $0
      sub("^[[:space:]]*" head "[[:space:]]?", "", body)
      if (prev != "" && length(prev) >= minlen && !is_skippable(prev) && !is_skippable(body) \
          && prev !~ /[。：:][[:space:]]*$/) {
        print prev
        exit
      }
      prev = body
    }
  ' <<<"$NEW_TEXT" 2>/dev/null || true
)"
if [[ -n "$WRAPPED_LINE" ]]; then
  if [[ "${#WRAPPED_LINE}" -gt 120 ]]; then
    WRAPPED_LINE="${WRAPPED_LINE:0:120}…"
  fi
  REASON="$(jq -n -r --arg file "$FILE_PATH" --arg line "$WRAPPED_LINE" '
    "🚫 " + $file + " のコメントで1文を途中で折り返しています。\n"
    + "  該当行: " + $line + "\n"
    + "code-style の「複数行にする場合、改行は文（句点）の切れ目でだけ入れる」に反します。"
    + "1行の見た目の長さより文の意味的なまとまりを優先しろ。1文が長くなっても句点以外の位置で折り返すな。"
    + "句点で終わる位置まで1行にまとめてから再試行してください。"
  ')"
  emit_pretooluse_decision deny "$REASON"
  exit 0
fi

while IFS= read -r line; do
  if ! LC_ALL=C grep -qE "^[[:space:]]*${COMMENT_HEAD}" <<<"$line"; then
    continue
  fi

  if token="$(LC_ALL=C grep -oE "$SPEC_URL_PATTERN" <<<"$line" | head -1)" && [[ -n "$token" ]]; then
    HIT_KIND="仕様ツールの URL"
    HIT_TOKEN="$token"
  elif token="$(LC_ALL=C grep -oE "$QA_PATTERN" <<<"$line" | head -1)" && [[ -n "$token" ]]; then
    HIT_KIND="QA 番号"
    HIT_TOKEN="$token"
  elif token="$(LC_ALL=C grep -oiE "$DB_VALUE_PATTERN" <<<"$line" | head -1)" && [[ -n "$token" ]]; then
    HIT_KIND="データベース定義・バリデーション値の転記"
    HIT_TOKEN="$token"
  elif token="$(grep -oE "$HISTORY_PATTERN" <<<"$line" | head -1)" && [[ -n "$token" ]]; then
    HIT_KIND="過去の経緯・背景の記述"
    HIT_TOKEN="$token"
  else
    for pat in ${EXTRA_PATTERNS+"${EXTRA_PATTERNS[@]}"}; do
      token="$(LC_ALL=C grep -oE "$pat" <<<"$line" 2>/dev/null | head -1 || true)"
      if [[ -n "$token" ]]; then
        HIT_KIND="このプロジェクトで追加した検出パターン"
        HIT_TOKEN="$token"
        break
      fi
    done
  fi

  if [[ -n "$HIT_KIND" ]]; then
    HIT_LINE="$line"
    break
  fi
done <<<"$NEW_TEXT"

# 連続するコメント本体を「行数 → タブ → \034 で連結した本文」の形で、1まとまりにつき1行ずつ出す。罫線のセクション区切り（罫線に挟まれた見出しを含む）とツールが読む指示行は分量の規約の対象外なので落とし、そこでまとまりを切る。
comment_blocks() {
  LC_ALL=C awk -v head="$AWK_COMMENT_HEAD" -v rule="$RULE_PATTERN" '
    function body_of(line,   body) {
      body = line
      sub("^[[:space:]]*" head "[[:space:]]*", "", body)
      return body
    }
    function is_rule_line(line) {
      return line ~ ("^[[:space:]]*" head) && body_of(line) ~ rule
    }
    function flush() {
      if (n > 0) print n "\t" block
      n = 0
      block = ""
    }
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (lines[i] !~ ("^[[:space:]]*" head)) { flush(); continue }
        body = body_of(lines[i])
        if (body ~ /^[[:space:]]*$/) { flush(); continue }
        if (body ~ /^[*\/][[:space:]]*$/) { flush(); continue }
        if (body ~ /^!/) { flush(); continue }
        if (body ~ rule) { flush(); continue }
        if (body ~ /^@?(shellcheck|eslint|stylelint|prettier|ts-|phpstan|psalm|phpcs|noinspection|noqa|pylint|rubocop|nolint|type:|param|return|var|template(-covariant)?|throws)/) { flush(); continue }
        if (i > 1 && i < NR && is_rule_line(lines[i - 1]) && is_rule_line(lines[i + 1])) { flush(); continue }
        n++
        block = (n == 1 ? body : block "\034" body)
      }
      flush()
    }
  ' 2>/dev/null || true
}

if [[ -z "$HIT_KIND" ]]; then
  BASELINE_TEXT=""
  HAS_BASELINE=0
  case "$TOOL_NAME" in
    Edit|MultiEdit)
      if jq -e '(.tool_input | has("old_string")) or ((.tool_input.edits? // []) | map(has("old_string")) | any)' <<<"$INPUT_JSON" >/dev/null 2>&1; then
        HAS_BASELINE=1
        BASELINE_TEXT="$(
          jq -r '
            [.tool_input.old_string?, (.tool_input.edits[]?.old_string?)]
            | map(select(. != null))
            | join("\n")
          ' <<<"$INPUT_JSON"
        )"
      fi
      ;;
    Write)
      # 新規作成は対象外。0 行からの増加になり、コメントを持つファイルを1つも作れなくなる。
      if [[ -f "$FILE_PATH" ]]; then
        HAS_BASELINE=1
        BASELINE_TEXT="$(cat "$FILE_PATH")"
      fi
      ;;
  esac

  OFFENDING_BLOCK=""
  if [[ "$HAS_BASELINE" -eq 1 ]]; then
    BASELINE_BLOCKS="$(comment_blocks <<<"$BASELINE_TEXT")"
    NEW_BLOCKS="$(comment_blocks <<<"$NEW_TEXT")"
    while IFS= read -r block; do
      if [[ -z "$block" ]]; then
        continue
      fi
      if [[ "${block%%$'\t'*}" -lt 2 ]]; then
        continue
      fi
      if [[ -n "$BASELINE_BLOCKS" ]] && LC_ALL=C grep -qxF -- "$block" <<<"$BASELINE_BLOCKS"; then
        continue
      fi
      OFFENDING_BLOCK="$block"
      break
    done <<<"$NEW_BLOCKS"
  fi

  if [[ -n "$OFFENDING_BLOCK" ]]; then
    BLOCK_COUNT="${OFFENDING_BLOCK%%$'\t'*}"
    BLOCK_BODY="${OFFENDING_BLOCK#*$'\t'}"
    SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT_JSON")"
    ASKED_KEY="$(printf '%s\n%s' "$FILE_PATH" "$BLOCK_BODY" | shasum -a 256 | cut -d' ' -f1)"
    ASKED_LOG=""
    if [[ -n "$SESSION_ID" ]]; then
      ASKED_LOG="$HOME/.claude/hook-state/${SESSION_ID}_comment-additions.log"
    fi

    if [[ -n "$ASKED_LOG" && -f "$ASKED_LOG" ]] && grep -qxF -- "$ASKED_KEY" "$ASKED_LOG"; then
      exit 0
    fi

    if [[ -n "$ASKED_LOG" ]]; then
      mkdir -p "$(dirname "$ASKED_LOG")" 2>/dev/null
      printf '%s\n' "$ASKED_KEY" >>"$ASKED_LOG" 2>/dev/null
    fi

    BLOCK_DISPLAY="${BLOCK_BODY//$'\034'/ ⏎ }"
    if [[ "${#BLOCK_DISPLAY}" -gt 160 ]]; then
      BLOCK_DISPLAY="${BLOCK_DISPLAY:0:160}…"
    fi

    REASON="$(jq -n -r \
      --arg file "$FILE_PATH" \
      --arg n "$BLOCK_COUNT" \
      --arg line "$BLOCK_DISPLAY" '
      "🚫 " + $file + " に " + $n + " 行続くコメントを書こうとしています。\n"
      + "  該当: " + $line + "\n"
      + "code-style の「1行なら書いてよい。2行目以降だけ『コードの外側にある事実か』を問え」に反します。"
      + "2行目以降を1行ずつ「これはコードの外側にある事実か（ツール・言語・環境の仕様、このファイルに現れない別プロセスの存在）」と問い直し、答えられない行を消して1行に収めてから再試行してください。\n"
      + "ただしコードから読み取れない実装契約・技術根拠は消す対象ではありません。code-style の「純粋な経緯は消せ。実装契約・技術根拠だけ残せ」で判定してください。\n"
      + "書く価値があると考える場合は自分の判断で残さず、その行をユーザーに提示して要否を仰いでください。\n"
      + "**ユーザーの承認が得られたら、その編集をそのまま再実行しろ。同じコメントの2度目は通す。** 承認を得ないまま再実行するな。"
    ')"
    emit_pretooluse_decision deny "$REASON"
  fi
  exit 0
fi

# 長い行をそのまま返すと拒否理由が読みにくいので切り詰める。
if [[ "${#HIT_LINE}" -gt 160 ]]; then
  HIT_LINE="${HIT_LINE:0:160}…"
fi

CONFIG_HINT="$CONFIG_PATH"
if [[ -z "$CONFIG_HINT" ]]; then
  CONFIG_HINT="${NOTES_ROOT:-<リポジトリルート>}/project_notes/comment-guard.json"
fi

REASON="$(jq -n -r \
  --arg file "$FILE_PATH" \
  --arg kind "$HIT_KIND" \
  --arg token "$HIT_TOKEN" \
  --arg line "$HIT_LINE" \
  --arg config "$CONFIG_HINT" '
  "🚫 " + $file + " のコメントに出典・相互参照が入っています（" + $kind + ": " + $token + "）。\n"
  + "  該当行: " + $line + "\n"
  + "code-style の「docblock / コメントに出典・経緯・チケット番号・他ファイル参照を書くな」に反します。"
  + "該当の記載をコメントから削ってから再試行してください（経緯・出典は実装計画や PR の説明に書きます）。\n"
  + "そのファイルではその記載が正しい場合は、自分で判断して設定を書き換えず、"
  + $config + " の excludePaths への追加をユーザーに提案してください。"
')"
emit_pretooluse_decision deny "$REASON"

exit 0
