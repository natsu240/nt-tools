#!/usr/bin/env bash
# SessionStart(resume) フック: 古いセッションの再開で発生する再キャッシュコストを警告する。
#
# prompt_cache_likely_expired / estimated_cache_write_usd はドキュメント未記載のフィールドのため、将来のアップデートで改名・削除される可能性がある。動かなくなったら実機検証をやり直せ。
#
# **失敗してもセッション再開は絶対に止めるな。** すべて stderr 飲み + exit 0 で抜ける。

set +e

INPUT_JSON="$(cat 2>/dev/null || true)"

LIKELY_EXPIRED="$(printf '%s' "$INPUT_JSON" | jq -r '.prompt_cache_likely_expired // empty' 2>/dev/null)"
[ "$LIKELY_EXPIRED" != "true" ] && exit 0

ESTIMATED_USD="$(printf '%s' "$INPUT_JSON" | jq -r '.estimated_cache_write_usd // empty' 2>/dev/null)"
[ -z "$ESTIMATED_USD" ] && exit 0

USD_FMT="$(jq -nr --argjson v "$ESTIMATED_USD" '$v | (. * 100 | round) / 100' 2>/dev/null)"
[ -z "$USD_FMT" ] && exit 0

jq -cn --arg usd "$USD_FMT" \
  '{systemMessage: ("⚠️ セッションが古く、プロンプトキャッシュが失効している可能性があります。再開により約$" + $usd + "の再キャッシュコストが発生する見込みです。")}'

exit 0
