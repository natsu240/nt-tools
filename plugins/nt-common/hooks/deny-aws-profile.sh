#!/usr/bin/env bash
# Bash PreToolUse hook。profile 指定の無い / default を指定した / 本番へ変更を加える`aws` の実行を deny する。
#
# **ask（確認）に変えるな。** 本番エラー監視は launchd から `claude -p` で無人実行され、確認を返しても答える人がいないまま処理が止まる。
#
# `default` を対象にしているのは `~/.aws/config` の [default] に認証情報を置いていないため。

set -euo pipefail

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

INPUT_JSON="$(cat)"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

command="$(jq -r '.tool_input.command // empty' <<<"$INPUT_JSON")"
[[ -z "$command" ]] && exit 0

# クォートの中身を落としてから判定する。コミットメッセージ本文に aws と書いただけで deny されるのを防ぐため。
# shellcheck source=lib-strip-quoted.sh
source "${BASH_SOURCE[0]%/*}/lib-strip-quoted.sh"

# コマンドとして実行される位置にある aws だけを拾う。`AWS_PROFILE=xxx aws ...`のように環境変数の代入が前置きされる形も認める（この形を認めないと、profile を環境変数で渡したときに本番への変更系を検出できない）。
CMD_HEAD='(^|[;&|(]|\$\()[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([A-Za-z0-9_.-]*/)*'
AWS_RE="${CMD_HEAD}aws[[:space:]]"

stripped="$(strip_quoted "$command")"

# grep へは here-string で渡す。`printf | grep -q` の形にすると、grep がマッチして即終了した瞬間に上流が SIGPIPE で死に、pipefail のせいで「マッチしなかった」と判定される。
grep -qE "$AWS_RE" <<<"$stripped" || exit 0

# profile を要求しない呼び出し
if grep -qE 'aws[[:space:]]+(--version|help|configure)([[:space:]]|$)' <<<"$stripped"; then
  exit 0
fi

deny() {
  emit_pretooluse_decision deny "$1"
  exit 0
}

if ! grep -qE '(--profile[[:space:]=]|AWS_PROFILE=)' <<<"$command"; then
  deny '🚫 aws コマンドに profile 指定がありません。`aws --profile <profile 名> ...` の形で実行してください。profile 名はプロジェクトの `project_notes/aws-sources.md` に書いてあります。既定の資格情報のまま実行すると、狙った環境とは別の環境の値を見たまま断定する事故になります。'
fi

# profile 名はクォートで囲まれていることがある（`--profile "xxx-prd"`）。
# strip_quoted はクォートの中身を落とすため、名前の取り出しだけは元の文字列から行う。
PROFILE_PREFIX='(--profile[[:space:]]+|--profile=|AWS_PROFILE=|AWS_DEFAULT_PROFILE=)'
profiles="$(grep -oE "${PROFILE_PREFIX}[\"']?[A-Za-z0-9_.:@/-]+" <<<"$command" \
  | sed -E "s/^${PROFILE_PREFIX}[\"']?//" || true)"

if grep -qx 'default' <<<"$profiles"; then
  deny '🚫 `default` プロファイルには認証情報を置いていないため、この実行は必ず失敗します。環境に合った profile 名（プロジェクトの `project_notes/aws-sources.md` 参照）を指定してください。'
fi

# 読み取り専用と見なす操作。接頭辞で拾えるものと、接頭辞では拾えないものに分ける。
READONLY_PREFIX_RE='^(describe|get|list|batch-get|lookup|filter|search)'
READONLY_EXACT=' help ls tail wait start-query stop-query get-query-results test-metric-filter start-live-tail stop-live-tail generate-query list-profiles '

is_readonly_operation() {
  local op
  op="$(tr '[:upper:]' '[:lower:]' <<<"$1")"
  [[ "$READONLY_EXACT" == *" ${op} "* ]] && return 0
  grep -qE "$READONLY_PREFIX_RE" <<<"$op"
}

# 次の語を値として取るグローバルオプション。サービス名・操作名より前に置けるのはグローバルオプションだけなので、この一覧で足りる（未知のフラグは値を取らないものとして扱う。サービス名を読み飛ばして誤判定するのを避けるため）。
VALUE_FLAGS=' --profile --region --output --endpoint-url --query --color --ca-bundle --cli-read-timeout --cli-connect-timeout --cli-binary-format '

# 1つのコマンド文字列に aws 呼び出しが複数並ぶことがあるため、区切り記号で分けてセグメントごとに操作名を取り出す。
mutating_operations=""
while IFS= read -r segment; do
  grep -qE '(^|[[:space:]])([A-Za-z0-9_.-]*/)*aws[[:space:]]' <<<"$segment" || continue

  in_aws=0
  want=""
  service=""
  operation=""
  read -ra tokens <<<"$segment"
  for token in "${tokens[@]}"; do
    if [[ -n "$want" ]]; then
      want=""
      continue
    fi
    if (( in_aws == 0 )); then
      [[ "$token" == "aws" || "$token" == */aws ]] && in_aws=1
      continue
    fi
    case "$token" in
      -*)
        # `--profile=xxx` のように値が同じ語に入っている場合は次の語を飛ばさない
        if [[ "$token" != *=* && "$VALUE_FLAGS" == *" ${token} "* ]]; then
          want="skip"
        fi
        ;;
      *)
        if [[ -z "$service" ]]; then
          service="$token"
        elif [[ -z "$operation" ]]; then
          operation="$token"
        fi
        ;;
    esac
  done

  [[ -z "$operation" ]] && continue
  is_readonly_operation "$operation" && continue
  mutating_operations="${mutating_operations}${service} ${operation} / "
done < <(tr ';|&()' '\n' <<<"$stripped")

[[ -z "$mutating_operations" ]] && exit 0

prod_profile="$(grep -iE '(prd|prod)' <<<"$profiles" | head -1 || true)"
[[ -z "$prod_profile" ]] && exit 0

deny "🚫 本番プロファイル（${prod_profile}）に対する変更系の aws コマンドです: ${mutating_operations% / }。本番は読み取り専用で使う運用にしています。変更が必要なら人が意図的に実行してください（読み取り系のコマンドはそのまま実行できます）。"
