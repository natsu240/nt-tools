#!/usr/bin/env bash
# Artifact ツールの PreToolUse hook。
# インフラ構成図らしい SVG を持つのに公式アイコンの埋め込み（<symbol id="..."> と <use href="#..."> の組）が1つも無い publish を deny する。
#
# AWS のサービス名は SVG の中に限って数える。本文の表でサービス名に触れているだけのレポートを止めないため。

set -euo pipefail

INPUT_JSON="$(cat)"

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT_JSON")"
if [[ "$TOOL_NAME" != "Artifact" ]]; then
  exit 0
fi

ACTION="$(jq -r '.tool_input.action // "publish"' <<<"$INPUT_JSON")"
if [[ "$ACTION" != "publish" ]]; then
  exit 0
fi

# 判定にトランスクリプトのパスを使うな。共通フィールドの agent_id / agent_type で判定する（メインは agent_type="worker" かつ agent_id 未設定）。
AGENT_ID="$(jq -r '.agent_id // empty' <<<"$INPUT_JSON")"
AGENT_TYPE="$(jq -r '.agent_type // empty' <<<"$INPUT_JSON")"
if [[ -n "$AGENT_ID" || ( -n "$AGENT_TYPE" && "$AGENT_TYPE" != "worker" ) ]]; then
  exit 0
fi

FILE_PATH="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT_JSON")"
if [[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]]; then
  exit 0
fi

CONTENT="$(cat -- "$FILE_PATH")"
if ! grep -qF -- '<svg' <<<"$CONTENT"; then
  exit 0
fi

SVG_MARKUP="$(sed -n '/<svg/,/<\/svg>/p' <<<"$CONTENT")"

AWS_SERVICE_PATTERN='EC2|VPC|Amazon S3|Aurora|RDS|Lambda|CloudFront|Route 53|Route53|ALB|NLB|ECS|Fargate|EKS|DynamoDB|CloudWatch|API Gateway|Secrets Manager|CodeBuild|CodePipeline|SQS|SNS|ElastiCache|NAT Gateway|Internet Gateway|Availability Zone'
SERVICE_HITS="$(grep -oE -- "$AWS_SERVICE_PATTERN" <<<"$SVG_MARKUP" | sort -u | wc -l | tr -d ' ')"
if [[ "$SERVICE_HITS" -lt 2 ]]; then
  exit 0
fi

if grep -qE -- '<symbol[^>]+id=' <<<"$CONTENT" && grep -qE -- '<use[^>]+(xlink:)?href="#' <<<"$CONTENT"; then
  exit 0
fi

REASON="$(jq -n -r --arg path "$FILE_PATH" '
  "🚫 " + $path + " は AWS のインフラ構成図なのに、公式 Architecture Icons の埋め込みが1つも見つかりません（<symbol id=\"...\"> と <use href=\"#...\"> の組が無い）。自作の箱・自前で描いた図形でサービスを表すのは nt-common:artifact-architecture の禁止事項です。\n\nhttps://aws.amazon.com/architecture/icons/ の英語版ページから Icon-package を取得し、必要なアイコンの SVG を <symbol id=\"...\"> としてページ内に1箇所まとめて置き、各図から <use href=\"#...\"> で参照しろ。path のデータと fill 色は一切変更するな。\n\n手順は nt-common:artifact-architecture の「アイコンは公式配布から直接取得する」節にある。"
')"
emit_pretooluse_decision deny "$REASON"

exit 0
