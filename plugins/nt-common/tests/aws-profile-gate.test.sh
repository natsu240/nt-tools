#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/deny-aws-profile.sh"
[[ -f "$HOOK" ]] || { echo "deny-aws-profile.sh が見つかりません: $HOOK"; exit 1; }

failures=0
total=0

run_case() {
  local expected=$1 label=$2 cmd=$3
  local out actual
  total=$((total + 1))
  out="$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$HOOK" 2>&1)"
  if [[ -z "$out" ]]; then
    actual="pass"
  elif grep -q '"permissionDecision": "deny"' <<<"$out"; then
    actual="deny"
  else
    actual="other"
  fi
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-4s 実際=%-5s %s\n' "$expected" "$actual" "$label"
    printf '    コマンド: %s\n' "$cmd"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- 本番プロファイルへの変更系 → 拒否 ---
run_case deny "本番への update-service" 'aws --profile sample-app-prd ecs update-service --cluster c --service s'
run_case deny "本番への s3 cp（profile がコマンド末尾）" 'aws s3 cp ./a.txt s3://bucket/ --profile sample-app-prd'
run_case deny "本番への delete-object" 'aws --profile sample-app-prd s3api delete-object --bucket b --key k'
run_case deny "本番への put-parameter（--profile= 形式）" 'aws --profile=sample-app-prd ssm put-parameter --name n --value v'
run_case deny "本番への変更系（AWS_PROFILE= 前置き）" 'AWS_PROFILE=sample-app-prd aws ecs update-service --cluster c --service s'
run_case deny "本番への変更系（profile 名がクォート内）" 'aws --profile "sample-app-prd" ecs update-service --cluster c'
run_case deny "prod 表記の本番" 'aws --profile some-prod-account lambda update-function-code --function-name f'
run_case deny "本番読み取りと検証変更の混在（安全側に倒す）" 'aws --profile sample-app-prd logs tail /ecs/x && aws --profile sample-app-dev ecs update-service --cluster c'

# --- default の明示 → 拒否 ---
run_case deny "default を明示" 'aws --profile default s3 ls'
run_case deny "default を明示（読み取りでも）" 'aws --profile default sts get-caller-identity'

# --- profile 指定なし → 拒否 ---
run_case deny "profile 指定なし" 'aws s3 ls'
run_case deny "profile 指定なし（読み取り）" 'aws logs describe-log-groups'

# --- 本番への読み取り → 素通し（エラー監視の無人実行がここを通る） ---
run_case pass "本番の logs filter-log-events" 'aws --profile sample-app-prd logs filter-log-events --log-group-name /ecs/x --filter-pattern ERROR'
run_case pass "本番の describe-alarms" 'aws --profile sample-app-prd cloudwatch describe-alarms --state-value ALARM'
run_case pass "本番の describe-alarm-history" 'aws --profile sample-app-prd cloudwatch describe-alarm-history --history-item-type StateUpdate'
run_case pass "本番の sts get-caller-identity" 'aws --profile sample-app-prd sts get-caller-identity'
run_case pass "本番の s3 ls" 'aws --profile sample-app-prd s3 ls s3://bucket/'
run_case pass "本番の logs tail" 'aws --profile sample-app-prd logs tail /ecs/x --since 10m'
run_case pass "本番の get-secret-value（読み取り扱い）" 'aws --profile sample-app-prd secretsmanager get-secret-value --secret-id s'
run_case pass "本番の list-clusters（--region を挟む）" 'aws --profile sample-app-prd --region ap-northeast-1 ecs list-clusters'

# --- 本番以外への変更系 → 素通し ---
run_case pass "検証環境への update-service" 'aws --profile sample-app-dev ecs update-service --cluster c --service s'
run_case pass "研究用アカウント（prd/prod を含まない）への変更系" 'aws --profile research-lab-aws s3 cp ./a.txt s3://bucket/'
run_case pass "監視用プロファイル（prd/prod を含まない）" 'aws --profile sample-app-error-monitor logs filter-log-events --log-group-name /ecs/x'

# --- 対象外 ---
run_case pass "profile を要求しない --version" 'aws --version'
run_case pass "コミットメッセージに aws と書いただけ" "git commit -m 'aws の設定を修正した'"
run_case pass "文字列として aws が出るだけ" 'grep -r "aws --profile" ./docs'
run_case pass "aws を含まないコマンド" 'ls -la /tmp'

if [[ "$failures" -gt 0 ]]; then
  printf '\naws-profile-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'aws-profile-gate: %d 件すべて期待どおり\n' "$total"
