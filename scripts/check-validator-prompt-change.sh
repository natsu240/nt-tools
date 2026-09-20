#!/usr/bin/env bash
# review-orchestrator.js の PROMPTS.validator が base ブランチとの差分で変わっていれば注意喚起する（push は止めない）。
#
# 使い方: bash scripts/check-validator-prompt-change.sh <base_ref> <head_ref>

set -euo pipefail

BASE_REF="$1"
HEAD_REF="$2"
TARGET="plugins/nt-developer/workflows/review-orchestrator.js"

START_MARKER='// ==VALIDATOR_PROMPT_START=='
END_MARKER='// ==VALIDATOR_PROMPT_END=='

# 目印が片方でも欠けていれば空文字列を返す。
extract_guarded() {
  local ref="$1"
  local content
  content="$(git show "${ref}:${TARGET}" 2>/dev/null || true)"

  if [[ "$content" != *"$START_MARKER"* ]] || [[ "$content" != *"$END_MARKER"* ]]; then
    printf ''
    return
  fi

  local guarded="${content#*"$START_MARKER"}"
  guarded="${guarded%%"$END_MARKER"*}"
  printf '%s' "$guarded"
}

BASE_GUARDED="$(extract_guarded "$BASE_REF")"
HEAD_GUARDED="$(extract_guarded "$HEAD_REF")"

if [[ "$BASE_GUARDED" != "$HEAD_GUARDED" ]]; then
  echo "警告: ${TARGET} の正誤検証（validator）への指示文が変更されています。plugins/nt-developer/tests/validator-fixtures/ の見本で判定が壊れていないか手動確認し、同ディレクトリの README.md の最終確認日を更新してください。"
else
  echo "validatorへの指示文に変更はありません。"
fi

exit 0
