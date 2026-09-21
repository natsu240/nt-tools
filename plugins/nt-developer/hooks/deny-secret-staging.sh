#!/usr/bin/env bash
# git add でシークレットファイル誤コミットを block する PreToolUse hook。
#
# **ヒアドキュメントの本体を除去する処理を消すな。** コミットメッセージ本文に書かれたファイル名まで拾って誤検知する。

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

input=$(cat)
command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
[ -z "$command" ] && exit 0

# ヒアドキュメント本体を除去したコマンド文字列を作る（<<EOF ... EOF / <<'EOF' ... EOF 等に対応）
strip_heredocs() {
  local delim="" in_here=0 line trimmed
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_here" = 0 ]; then
      printf '%s\n' "$line"
      if [[ "$line" =~ \<\<-?[[:space:]]*[\'\"]?([A-Za-z_][A-Za-z0-9_]*) ]]; then
        delim="${BASH_REMATCH[1]}"
        in_here=1
      fi
    else
      read -r trimmed <<< "$line"
      if [ "$trimmed" = "$delim" ]; then
        in_here=0
      fi
    fi
  done <<< "$1"
}
command_for_detection=$(strip_heredocs "$command")

# -m / --title / --body / --notes / --message に続く1行の引用符付き文字列はcommit message / PR タイトル・本文等の人間向けテキストであり実行対象のコマンドではないため、git add / シークレットファイル名のパターンを誤検知しないよう内容を空にする
command_for_detection=$(printf '%s' "$command_for_detection" | sed -E 's/(^|[[:space:]])(-m|--title|--body|--notes|--message)([[:space:]]+)"[^"]*"/\1\2\3""/g')

# git add コマンドが含まれない → 素通し
if ! printf '%s' "$command_for_detection" | grep -qE '(^|[[:space:]/;&|])git[[:space:]]+add[[:space:]]'; then
  exit 0
fi

# シークレットファイル名パターン（境界には引用符 ' " も含める。git add ".env" のように囲まれた場合も検知する）
secret_re="(\.env(\.[a-z][a-z0-9_-]*)?([[:space:]/'\"]|\$)|credentials\.(json|yml|yaml)|\.pem([[:space:]/'\"]|\$)|(^|[[:space:]/'\"])(id_rsa|id_dsa|id_ecdsa|id_ed25519)([[:space:]/'\"]|\$)|\.pgpass|secrets\.(yml|yaml))"

# git 追跡済み（HEAD に既に存在する）パスは対象から外す。git add には複数ファイル・ディレクトリを同時に渡せるため、コマンド全体の文字列一致では追跡済み/未追跡を区別できない。git add の引数から抜き出したパス候補ごとに、追跡済みかどうかを個別に判定する。
hook_cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')

is_tracked() {
  [ -n "$hook_cwd" ] || return 1
  (cd "$hook_cwd" 2>/dev/null && git ls-files --error-unmatch -- "$1" >/dev/null 2>&1)
}

NL=$(printf '\001')
detection_flat=$(printf '%s' "$command_for_detection" | tr '\n' "$NL")

untracked_secret_paths=""
set -f
while IFS= read -r add_segment; do
  [ -z "$add_segment" ] && continue
  add_args=$(printf '%s' "$add_segment" | sed -E 's/.*git[[:space:]]+add[[:space:]]+//')
  for tok in $add_args; do
    tok="${tok#\'}"; tok="${tok%\'}"; tok="${tok#\"}"; tok="${tok%\"}"
    case "$tok" in -*) continue ;; esac
    tok_for_match=$(printf '%s' "$tok" | sed -E 's/\.env\.example//g')
    [ -z "$tok_for_match" ] && continue
    if printf '%s' "$tok_for_match" | grep -qE "$secret_re" && ! is_tracked "$tok"; then
      untracked_secret_paths="${untracked_secret_paths}${untracked_secret_paths:+, }${tok}"
    fi
  done
done <<< "$(printf '%s' "$detection_flat" | grep -oE "(^|[[:space:]/;&|])git[[:space:]]+add[[:space:]]+[^;&|${NL}]*")"
set +f

if [ -n "$untracked_secret_paths" ]; then
  reason=$(printf '%s\n' \
    "🚫 シークレットファイルを git add しようとしている: ${untracked_secret_paths}" \
    "   対象パターン: .env / .env.<env> / credentials.{json,yml,yaml} / *.pem / id_rsa / id_dsa / id_ecdsa / id_ed25519 / .pgpass / secrets.{yml,yaml}" \
    "   .env.example と git 追跡済みファイルは除外対象。本当に必要なら自分のターミナルで git add してください。")
  emit_pretooluse_decision deny "$reason"
  exit 0
fi

# git add -A / --all は、対象パスが明示指定されていれば確認不要（-A path1 path2 / -A -- path1 path2 どちらの書式も対象）
if printf '%s' "$command_for_detection" | grep -qE 'git[[:space:]]+add[[:space:]]+(-A|--all)([[:space:]]|$)'; then
  if printf '%s' "$command_for_detection" | grep -qE '(-A|--all)[[:space:]]+(--[[:space:]]+)?[A-Za-z0-9_./][^[:space:]]*'; then
    exit 0
  fi
  emit_pretooluse_decision deny "🚫 対象パス無指定の git add -A / --all は禁止。意図しないシークレット・作業中のファイルまで巻き込む。git status で対象を確認し、git add <パス> のようにステージするファイルを明示しろ。"
  exit 0
fi

# git add . / * は常に確認プロンプト（対象がリポジトリ全体・カレントディレクトリ全体を指すため、明示指定の余地がない）
if printf '%s' "$command_for_detection" | grep -qE 'git[[:space:]]+add[[:space:]]+(\.|\*)([[:space:]]|$)'; then
  emit_pretooluse_decision deny "🚫 git add . / * は禁止。カレントディレクトリ配下を丸ごと巻き込むため、意図しないシークレット・作業中のファイルが混ざる。git status で対象を確認し、git add <パス> のようにステージするファイルを明示しろ。"
  exit 0
fi

exit 0
