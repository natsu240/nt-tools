#!/usr/bin/env bash
# Edit/Write/MultiEdit の PreToolUse hook。
# 対象ファイルの拡張子・パスから必要な code-style 系 skill を判定し、このターンのトランスクリプト内でまだ Skill ツール経由で呼ばれていなければ deny する。
# メインスレッド・サブエージェントの両方が対象。
# skill は namespace 無し（personal skill 由来）・`nt-developer:` 付き（plugin 由来）のどちらで呼ばれても許可する。

set -euo pipefail

INPUT_JSON="$(cat)"

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"
# shellcheck source=lib-called-skills.sh
source "${BASH_SOURCE[0]%/*}/lib-called-skills.sh"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
case "$TOOL_NAME" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT_JSON")"
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# 一時ディレクトリ・code-review の CACHE_DIR 配下は対象外にする。調査用の使い捨てスクリプト（構文チェッカ・集計器 等）や実行のたびに作られレビュー終了後に消える作業ファイルにプロジェクトのコード規約を要求する意味が無いうえ、regex や字句解析の実験のように規約と噛み合わない書き方が要る場面で、退路を塞ぐだけになる。
case "$FILE_PATH" in
  /tmp/*|/private/tmp/*|"$HOME/.claude/cache/code-review/"*) exit 0 ;;
esac
if [[ -n "${TMPDIR:-}" && "$FILE_PATH" == "${TMPDIR%/}"/* ]]; then
  exit 0
fi

REQUIRED_SKILLS=()
case "$FILE_PATH" in
  *.php)
    REQUIRED_SKILLS=("code-style|nt-developer:code-style" "code-style-laravel|nt-developer:code-style-laravel")
    ;;
  *.vue|*.scss)
    REQUIRED_SKILLS=("code-style|nt-developer:code-style" "code-style-vue|nt-developer:code-style-vue")
    ;;
  */infra/*.ts|*/infra/*.tsx|*/infra/*.js|*/infra/*.jsx|*/cdk/*.ts|*/cdk/*.tsx|*/cdk/*.js|*/cdk/*.jsx)
    REQUIRED_SKILLS=("code-style|nt-developer:code-style" "code-style-cdk|nt-developer:code-style-cdk" "code-style-ts|nt-developer:code-style-ts")
    ;;
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs)
    REQUIRED_SKILLS=("code-style|nt-developer:code-style" "code-style-ts|nt-developer:code-style-ts")
    ;;
  */.github/workflows/*.yml|*/.github/workflows/*.yaml)
    REQUIRED_SKILLS=("code-style|nt-developer:code-style" "code-style-cicd|nt-developer:code-style-cicd")
    ;;
  *.sh|*.bash|*.zsh)
    REQUIRED_SKILLS=("code-style|nt-developer:code-style")
    ;;
  *)
    exit 0
    ;;
esac

TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$INPUT_JSON")"
if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT_JSON")"
CALLED_SKILLS="$(collect_called_skills "$SESSION_ID" "$TRANSCRIPT_PATH")"

# grep はパイプの終端に置くな。set -o pipefail 下では grep -q がマッチした瞬間に終了して上流が SIGPIPE で死に、その終了ステータスがパイプライン全体の結果になる（マッチしているのにマッチしなかったと判定される）。here-string で渡す。
MISSING=()
for pattern in "${REQUIRED_SKILLS[@]}"; do
  if ! grep -qE "^(${pattern})\$" <<<"$CALLED_SKILLS"; then
    MISSING+=("${pattern%%|*}")
  fi
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
  exit 0
fi

MISSING_LIST="$(printf '%s, ' "${MISSING[@]}")"
MISSING_LIST="${MISSING_LIST%, }"

REASON="$(jq -n -r --arg file "$FILE_PATH" --arg missing "$MISSING_LIST" '
  "🚫 " + $file + " を編集する前に、対象言語の code-style 系 skill が未起動です。先に Skill ツールで次を起動してから再試行してください: " + $missing
')"
emit_pretooluse_decision deny "$REASON"

exit 0
