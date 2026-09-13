#!/bin/bash
# Claude Code ステータスライン。
#
# 計画・チケットの検出をブランチ名に頼っているのは、stdin の JSON しか渡らず会話内容には原理的にアクセスできないため。
#
# **5h/7d の「予測%」は Claude Code が提供する値ではない。** 現在の使用率とリセットまでの残り時間から線形外挿した自前の見積もりで、7d の未来分は平日ペースのみで外挿している。
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name')
DIR=$(echo "$input" | jq -r '.workspace.current_dir')
PCT_RAW=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
PCT=$(jq -nr "($PCT_RAW * 10 | round) / 10")
PCT_INT=$(jq -nr "$PCT_RAW | floor")
TOKENS=$(echo "$input" | jq -r '(.context_window.total_input_tokens // 0) | tostring | [scan("\\d{1,3}(?=(?:\\d{3})*$)")] | join(",")')
WINDOW_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 1000000')
WINDOW_STR=$(jq -nr --argjson w "$WINDOW_SIZE" 'if ($w % 10000) == 0 then (($w/10000)|tostring) + "万" else ($w | tostring) end')
VERSION=$(echo "$input" | jq -r '.version // empty')
EFFORT=$(echo "$input" | jq -r '.effort.level // empty')
SESSION_ID=$(echo "$input" | jq -r '.session_id')

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'

# このキャッシュ先だけセッションで分けない。npm の最新版は全セッション共通の値で、分けると新しいセッションを開くたびに npm view が走り直す。
CACHE_FILE="/tmp/statusline-latest-version"
CACHE_MAX_AGE=3600
cache_is_stale() {
    [ ! -f "$CACHE_FILE" ] || \
    [ $(($(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0))) -gt $CACHE_MAX_AGE ]
}
if cache_is_stale; then
    CACHE_TMP_FILE="$CACHE_FILE.$$.tmp"
    (
        # macOS の /tmp は /private/tmp へのシンボリックリンクで、-H が無いと find が先へ入らない。
        find -H /tmp -maxdepth 1 -name 'statusline-*' -type f -mtime +3 -delete
        npm view @anthropic-ai/claude-code version 2>/dev/null > "$CACHE_TMP_FILE" && mv "$CACHE_TMP_FILE" "$CACHE_FILE"
        rm -f "$CACHE_TMP_FILE"
    ) >/dev/null 2>&1 &
fi
LATEST=$(cat "$CACHE_FILE" 2>/dev/null | tr -d ' \n')

VERSION_STR=""
if [ -n "$VERSION" ] && [ -n "$LATEST" ]; then
    if [ "$VERSION" = "$LATEST" ]; then
        VERSION_STR="  v$VERSION (latest)"
    else
        VERSION_STR="  v$VERSION → $LATEST"
    fi
elif [ -n "$VERSION" ]; then
    VERSION_STR="  v$VERSION"
fi

EFFORT_STR=""
[ -n "$EFFORT" ] && EFFORT_STR="  ⚡$EFFORT"

if [ "$PCT_INT" -ge 90 ]; then BAR_COLOR="$RED"
elif [ "$PCT_INT" -ge 70 ]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

# 20セル × 8段階の部分ブロックで 0.625% 刻み（160ステップ）
TOTAL_STEPS=$(jq -nr "($PCT_RAW * 1.6) | round")
[ "$TOTAL_STEPS" -gt 160 ] && TOTAL_STEPS=160
[ "$TOTAL_STEPS" -lt 0 ] && TOTAL_STEPS=0
FILLED=$((TOTAL_STEPS / 8))
PART=$((TOTAL_STEPS % 8))
PARTS=("" "▏" "▎" "▍" "▌" "▋" "▊" "▉")
PARTIAL="${PARTS[$PART]}"
EMPTY=$((20 - FILLED - (PART > 0 ? 1 : 0)))
[ "$EMPTY" -lt 0 ] && EMPTY=0
printf -v FILL_STR "%${FILLED}s"; printf -v PAD "%${EMPTY}s"
BAR="${FILL_STR// /█}${PARTIAL}${PAD// /░}"

fmt_jp_duration() {
    local s=$1
    [ "$s" -lt 0 ] && s=0
    local d=$((s / 86400))
    local h=$(((s % 86400) / 3600))
    local m=$(((s % 3600) / 60))
    local sec=$((s % 60))
    if [ "$d" -gt 0 ]; then
        printf '%d日%02d時間%02d分%02d秒\n' "$d" "$h" "$m" "$sec"
    elif [ "$h" -gt 0 ]; then
        printf '%d時間%02d分%02d秒\n' "$h" "$m" "$sec"
    elif [ "$m" -gt 0 ]; then
        printf '%d分%02d秒\n' "$m" "$sec"
    else
        printf '%d秒\n' "$sec"
    fi
}

CUR_USAGE=$(echo "$input" | jq -c '.context_window.current_usage // empty')

TURN_CACHE_STR=""
if [ -n "$CUR_USAGE" ]; then
    INPUT_TOK=$(echo "$CUR_USAGE" | jq -r '.input_tokens // 0')
    CCREATE=$(echo "$CUR_USAGE" | jq -r '.cache_creation_input_tokens // 0')
    CREAD=$(echo "$CUR_USAGE" | jq -r '.cache_read_input_tokens // 0')
    TOTAL_TURN=$((INPUT_TOK + CCREATE + CREAD))

    if [ "$TOTAL_TURN" -gt 0 ]; then
        HIT_PCT=$(jq -nr "(${CREAD} / ${TOTAL_TURN} * 10000 | round) / 100")
        HIT_PCT_INT=$(jq -nr "$HIT_PCT | floor")
        if [ "$HIT_PCT_INT" -ge 80 ]; then TC_COLOR="$GREEN"
        elif [ "$HIT_PCT_INT" -ge 40 ]; then TC_COLOR="$YELLOW"
        else TC_COLOR="$RED"; fi
        TURN_CACHE_STR="  ${TC_COLOR}🎯 $(printf '%5s' "$HIT_PCT")%ヒット${RESET}"
    fi
fi

PROMPT_CACHE=$(echo "$input" | jq -c '.prompt_cache // empty')

miss_cause_label() {
    case "$1" in
        system_prompt_changed) echo "システムプロンプト変更" ;;
        tools_changed) echo "ツール定義変更" ;;
        model_changed) echo "モデル変更" ;;
        fast_mode_changed) echo "高速モード切替" ;;
        cache_scope_or_ttl_changed) echo "キャッシュ範囲/TTL変更" ;;
        betas_changed) echo "ベータヘッダー変更" ;;
        effort_changed) echo "思考量変更" ;;
        auto_mode_changed) echo "自動モード切替" ;;
        overage_changed) echo "利用枠超過状態の変化" ;;
        extra_body_changed) echo "追加リクエスト項目変更" ;;
        defer_loading_changed) echo "ツール遅延読込の変更" ;;
        messages_rewritten) echo "過去メッセージ書換" ;;
        ttl_expired_5m) echo "5分TTL超過で放置" ;;
        ttl_expired_1h) echo "1時間TTL超過で放置" ;;
        likely_server_side) echo "プロンプト不変（サーバー側と推定）" ;;
        unknown) echo "不明" ;;
        *) echo "$1" ;;
    esac
}

SESSION_CACHE_STR=""
MISS_CAUSE_LINE=""
if [ -n "$PROMPT_CACHE" ]; then
    PC_HIT_RATIO=$(echo "$PROMPT_CACHE" | jq -r '.hit_ratio // empty')
    PC_MISSES=$(echo "$PROMPT_CACHE" | jq -r '.misses // 0')
    PC_CAUSES=$(echo "$PROMPT_CACHE" | jq -r '.last_miss_cause.causes // [] | .[]')

    if [ -n "$PC_CAUSES" ]; then
        PC_TOOLS_ADDED=$(echo "$PROMPT_CACHE" | jq -r '.last_miss_cause.tools_added // empty')
        PC_TOOLS_REMOVED=$(echo "$PROMPT_CACHE" | jq -r '.last_miss_cause.tools_removed // 0')
        PC_CHAR_DELTA=$(echo "$PROMPT_CACHE" | jq -r '.last_miss_cause.system_char_delta // empty')
        PC_LAST_MISS_AT=$(echo "$PROMPT_CACHE" | jq -r '.last_miss_at // empty')

        CAUSE_TEXT=""
        while IFS= read -r cause; do
            [ -z "$cause" ] && continue
            label=$(miss_cause_label "$cause")
            case "$cause" in
                tools_changed)
                    [ -n "$PC_TOOLS_ADDED" ] && label="${label} (+${PC_TOOLS_ADDED}/-${PC_TOOLS_REMOVED})"
                    ;;
                system_prompt_changed)
                    if [ -n "$PC_CHAR_DELTA" ] && [ "$PC_CHAR_DELTA" -ne 0 ] 2>/dev/null; then
                        DELTA_STR=$(jq -nr --argjson d "$PC_CHAR_DELTA" '($d | fabs | tostring | [scan("\\d{1,3}(?=(?:\\d{3})*$)")] | join(",")) as $n | (if $d > 0 then "+" else "-" end) + $n')
                        label="${label} (${DELTA_STR}文字)"
                    fi
                    ;;
            esac
            if [ -z "$CAUSE_TEXT" ]; then CAUSE_TEXT="$label"; else CAUSE_TEXT="${CAUSE_TEXT}、${label}"; fi
        done <<< "$PC_CAUSES"

        if [ -n "$CAUSE_TEXT" ]; then
            MISS_CAUSE_LINE="🧊 直近のミス: ${CAUSE_TEXT}"
            if [ -n "$PC_LAST_MISS_AT" ]; then
                MISS_CAUSE_LINE="${MISS_CAUSE_LINE} / $(fmt_jp_duration $(($(date +%s) - PC_LAST_MISS_AT)))前"
            fi
        fi
    fi

    if [ -n "$PC_HIT_RATIO" ]; then
        SC_HIT_PCT=$(jq -nr "(${PC_HIT_RATIO} * 10000 | round) / 100")
        SC_HIT_PCT_INT=$(jq -nr "$SC_HIT_PCT | floor")
        if [ "$SC_HIT_PCT_INT" -ge 80 ]; then SC_COLOR="$GREEN"
        elif [ "$SC_HIT_PCT_INT" -ge 40 ]; then SC_COLOR="$YELLOW"
        else SC_COLOR="$RED"; fi
        SESSION_CACHE_STR="  ${SC_COLOR}🗄️ セッション: $(printf '%5s' "$SC_HIT_PCT")%ヒット${RESET}"
        [ "$PC_MISSES" -gt 0 ] && SESSION_CACHE_STR="${SESSION_CACHE_STR} (ミス${PC_MISSES}回)"
    fi
fi

# 先頭の区切り2スペースは行頭に残ると字下げに見えるので落とす。
CACHE_LINE="${TURN_CACHE_STR}${SESSION_CACHE_STR}"
CACHE_LINE="${CACHE_LINE#  }"

# refreshInterval=1 で毎秒描画されるため、git プロセスの起動を5秒キャッシュで抑える。
BRANCH_CACHE_FILE="/tmp/statusline-branch-$SESSION_ID"
BRANCH_CACHE_MAX_AGE=5
branch_cache_is_stale() {
    [ ! -f "$BRANCH_CACHE_FILE" ] || \
    [ $(($(date +%s) - $(stat -c %Y "$BRANCH_CACHE_FILE" 2>/dev/null || stat -f %m "$BRANCH_CACHE_FILE" 2>/dev/null || echo 0))) -gt $BRANCH_CACHE_MAX_AGE ]
}
if branch_cache_is_stale; then
    if git rev-parse --git-dir > /dev/null 2>&1; then
        git branch --show-current 2>/dev/null > "$BRANCH_CACHE_FILE"
    else
        : > "$BRANCH_CACHE_FILE"
    fi
fi
BRANCH_NAME=$(cat "$BRANCH_CACHE_FILE" 2>/dev/null)
BRANCH=""
[ -n "$BRANCH_NAME" ] && BRANCH="  🌿 $BRANCH_NAME"

file_cache_is_stale() {
    local f=$1 max_age=$2
    [ ! -f "$f" ] || \
    [ $(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0) )) -gt "$max_age" ]
}

# ターミナルのハイパーリンク（OSC 8）でクリック可能にする。
osc8_link() {
    local url=$1 label=$2
    printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$url" "$label"
}

STATE_DIR="$HOME/.claude/state"
mkdir -p "$STATE_DIR" 2>/dev/null

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)

ISSUE_NUM=""
[[ "$BRANCH_NAME" =~ ^issue-([0-9]+)$ ]] && ISSUE_NUM="${BASH_REMATCH[1]}"

PLAN_FILE=""
PLAN_PR_NUM=""

# 記録された「作業中の計画書」を読む。
# 記録されたパスが消えていても同じファイル名で探し直せるのは、状態のディレクトリだけが変わってファイル名は変えない運用だから。
if [ -z "$PLAN_FILE" ] && [ -n "$REPO_ROOT" ]; then
    CURRENT_PLAN_STATE="$STATE_DIR/plan-current${REPO_ROOT//\//_}.json"
    STATE_REPO=$(jq -r '.repo // empty' "$CURRENT_PLAN_STATE" 2>/dev/null)
    STATE_PLAN=$(jq -r '.plan // empty' "$CURRENT_PLAN_STATE" 2>/dev/null)
    if [ "$STATE_REPO" = "$REPO_ROOT" ] && [ -n "$STATE_PLAN" ]; then
        if [ -f "$STATE_PLAN" ]; then
            PLAN_FILE="$STATE_PLAN"
        else
            PLAN_RESOLVE_CACHE="/tmp/statusline-plan-resolve-$SESSION_ID"
            if file_cache_is_stale "$PLAN_RESOLVE_CACHE" 5; then
                find "$REPO_ROOT/plans" -type f -name "$(basename "$STATE_PLAN")" 2>/dev/null | sort | head -1 > "$PLAN_RESOLVE_CACHE.tmp" 2>/dev/null \
                    && mv "$PLAN_RESOLVE_CACHE.tmp" "$PLAN_RESOLVE_CACHE" 2>/dev/null
            fi
            RESOLVED_PLAN=$(cat "$PLAN_RESOLVE_CACHE" 2>/dev/null)
            # 探索キャッシュはセッション単位なので、同じセッションで別リポジトリへ移った直後は前のリポジトリの結果が残る。今のリポジトリ配下のものだけ採用する。
            if [ -n "$RESOLVED_PLAN" ] && [ -f "$RESOLVED_PLAN" ] && [[ "$RESOLVED_PLAN" == "$REPO_ROOT"/* ]]; then
                PLAN_FILE="$RESOLVED_PLAN"
                jq -cn --arg repo "$REPO_ROOT" --arg plan "$RESOLVED_PLAN" '{repo: $repo, plan: $plan}' > "$CURRENT_PLAN_STATE.tmp" 2>/dev/null \
                    && mv "$CURRENT_PLAN_STATE.tmp" "$CURRENT_PLAN_STATE" 2>/dev/null
            fi
        fi
    fi
    if [ -n "$PLAN_FILE" ] && [[ "$PLAN_FILE" == */plans/完了/* ]]; then
        rm -f "$CURRENT_PLAN_STATE"
        PLAN_FILE=""
    fi
fi

if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
    FIRST_LINE=$(head -1 "$PLAN_FILE")
    [[ "$FIRST_LINE" =~ PR:\ #([0-9]+) ]] && PLAN_PR_NUM="${BASH_REMATCH[1]}"

fi

# 計画書が特定できない場合、「変更したファイルのパスが計画書の『触るファイル』節に重なるか」を見て plans/進行中/ 配下の候補を探す。ただし内容の照合（変更後・対応内容が実際の差分に含まれているか）まではしないため、確定ではなく候補として扱う。
PLAN_CANDIDATE=""
if [ -z "$PLAN_FILE" ] && [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT/plans/進行中" ]; then
    # 変更ファイルは千件規模になりうるので、1件ずつ grep を起動せずパターンファイルにまとめて計画書1件あたり grep 1回で照合する。
    # 探索自体も gh CLI 呼び出しと同じくバックグラウンドに逃がす（同期実行だと毎秒描画がこの処理の完了を待たされ、ステータスラインが出なくなる）。
    # 起動前にキャッシュファイルを touch するのは、探索中の毎秒描画が同じ探索を何重にも起動するのを防ぐため。
    CANDIDATE_CACHE_FILE="/tmp/statusline-plan-candidate-$SESSION_ID"
    if file_cache_is_stale "$CANDIDATE_CACHE_FILE" 10; then
        touch "$CANDIDATE_CACHE_FILE" 2>/dev/null
        (
            BASE_REF=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
            if [ -n "$BASE_REF" ]; then
                CHANGED_FILES=$( { git diff --name-only "${BASE_REF}...HEAD" 2>/dev/null; git diff --name-only HEAD 2>/dev/null; } | sort -u)
            else
                CHANGED_FILES=$(git diff --name-only HEAD 2>/dev/null | sort -u)
            fi
            CHANGED_PATTERN_FILE="$CANDIDATE_CACHE_FILE.$$.changed"
            printf '%s\n' "$CHANGED_FILES" | grep -v '^$' > "$CHANGED_PATTERN_FILE" 2>/dev/null
            if [ -s "$CHANGED_PATTERN_FILE" ]; then
                find "$REPO_ROOT/plans/進行中" -type f -name '*.md' 2>/dev/null | sort | while IFS= read -r plan; do
                    SECTION=$(awk '/^## /{on=($0 ~ /触るファイル/)} on' "$plan" 2>/dev/null)
                    [ -z "$SECTION" ] && continue
                    grep -qF -f "$CHANGED_PATTERN_FILE" <<< "$SECTION" && echo "$plan"
                done
            fi
            rm -f "$CHANGED_PATTERN_FILE"
        ) > "$CANDIDATE_CACHE_FILE.tmp" 2>/dev/null && mv "$CANDIDATE_CACHE_FILE.tmp" "$CANDIDATE_CACHE_FILE" 2>/dev/null &
    fi
    CANDIDATE_LIST=$(cat "$CANDIDATE_CACHE_FILE" 2>/dev/null)
    [ -n "$CANDIDATE_LIST" ] && PLAN_CANDIDATE=$(echo "$CANDIDATE_LIST" | head -1)
fi

# GitHub Issue / PR はネットワーク越しの gh CLI 呼び出しになるため60秒キャッシュする（branch と同じ5秒キャッシュだと refreshInterval=1 の毎秒描画で API を叩き続ける）。
#
# キャッシュの置き場所はリポジトリごとに分ける。ファイル名がブランチ名・Issue 番号だけだと、別リポジトリで同じブランチ名（issue-359 等）や同じ Issue 番号を使ったときに中身を共有してしまい、別リポジトリの PR / Issue が表示される。
#
# 取得に失敗したときは空の JSON を書いて古い中身を捨てる。`&& mv` だけだと、PR がまだ無い・マージ済みでブランチが消えた等で gh が失敗したときに置き換えが起きず、以前の中身がそのまま残り続ける（マージ済みの PR が画面に居座る）。
REPO_KEY=$(echo "${REPO_ROOT:-none}" | tr -c 'A-Za-z0-9_-' '_')
ISSUE_TITLE=""
ISSUE_URL=""
PR_NUM="$PLAN_PR_NUM"
PR_TITLE=""
PR_URL=""
if command -v gh > /dev/null 2>&1; then
    if [ -n "$ISSUE_NUM" ]; then
        ISSUE_CACHE_FILE="/tmp/statusline-issue-${REPO_KEY}-${ISSUE_NUM}.json"
        if file_cache_is_stale "$ISSUE_CACHE_FILE" 60; then
            (gh issue view "$ISSUE_NUM" --json title,url,state 2>/dev/null > "$ISSUE_CACHE_FILE.tmp" \
                || echo '{}' > "$ISSUE_CACHE_FILE.tmp"
             mv "$ISSUE_CACHE_FILE.tmp" "$ISSUE_CACHE_FILE") >/dev/null 2>&1 &
        fi
        if [ "$(jq -r '.state // empty' "$ISSUE_CACHE_FILE" 2>/dev/null)" = "OPEN" ]; then
            ISSUE_TITLE=$(jq -r '.title // empty' "$ISSUE_CACHE_FILE" 2>/dev/null)
            ISSUE_URL=$(jq -r '.url // empty' "$ISSUE_CACHE_FILE" 2>/dev/null)
        fi
    fi

    BRANCH_SAFE=$(echo "${BRANCH_NAME:-none}" | tr -c 'A-Za-z0-9_-' '_')
    PR_CACHE_FILE="/tmp/statusline-pr-${REPO_KEY}-${BRANCH_SAFE}.json"
    if file_cache_is_stale "$PR_CACHE_FILE" 60; then
        if [ -n "$PR_NUM" ]; then
            (gh pr view "$PR_NUM" --json number,url,title,state 2>/dev/null > "$PR_CACHE_FILE.tmp" \
                || echo '{}' > "$PR_CACHE_FILE.tmp"
             mv "$PR_CACHE_FILE.tmp" "$PR_CACHE_FILE") >/dev/null 2>&1 &
        else
            (gh pr view --json number,url,title,state 2>/dev/null > "$PR_CACHE_FILE.tmp" \
                || echo '{}' > "$PR_CACHE_FILE.tmp"
             mv "$PR_CACHE_FILE.tmp" "$PR_CACHE_FILE") >/dev/null 2>&1 &
        fi
    fi
    if [ "$(jq -r '.state // empty' "$PR_CACHE_FILE" 2>/dev/null)" = "OPEN" ]; then
        PR_NUM=$(jq -r '.number // empty' "$PR_CACHE_FILE" 2>/dev/null)
        PR_TITLE=$(jq -r '.title // empty' "$PR_CACHE_FILE" 2>/dev/null)
        PR_URL=$(jq -r '.url // empty' "$PR_CACHE_FILE" 2>/dev/null)
    fi
fi

# plans/<状態>/<管理表>/... というパス構造から状態部分だけを取り出す
plan_state_from_path() {
    echo "$1" | sed -n 's#^plans/\([^/]*\)/.*#\1#p'
}

PLAN_LINE=""
if [ -n "$PLAN_FILE" ]; then
    PLAN_REL="${PLAN_FILE#"$REPO_ROOT"/}"
    PLAN_STATE=$(plan_state_from_path "$PLAN_REL")
    if [ -n "$PLAN_STATE" ]; then
        PLAN_LABEL="[${PLAN_STATE}] ${PLAN_REL}"
    else
        PLAN_LABEL="${PLAN_REL}"
    fi
    PLAN_LINE="📋 $(osc8_link "vscode://file${PLAN_FILE}" "$PLAN_LABEL")"
elif [ -n "$PLAN_CANDIDATE" ]; then
    PLAN_CANDIDATE_REL="${PLAN_CANDIDATE#"$REPO_ROOT"/}"
    PLAN_STATE=$(plan_state_from_path "$PLAN_CANDIDATE_REL")
    if [ -n "$PLAN_STATE" ]; then
        PLAN_LABEL="[${PLAN_STATE}・候補] ${PLAN_CANDIDATE_REL}"
    else
        PLAN_LABEL="${PLAN_CANDIDATE_REL}"
    fi
    PLAN_LINE="📋? $(osc8_link "vscode://file${PLAN_CANDIDATE}" "$PLAN_LABEL")"
fi

ISSUE_LINE=""
[ -n "$ISSUE_TITLE" ] && ISSUE_LINE="📌 Issue #${ISSUE_NUM}: $(osc8_link "$ISSUE_URL" "$ISSUE_TITLE")"

PR_LINE=""
[ -n "$PR_TITLE" ] && PR_LINE="🔀 PR #${PR_NUM}: $(osc8_link "$PR_URL" "$PR_TITLE")"

FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
FIVE_H_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
WEEK=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
WEEK_RESET=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
NOW=$(date +%s)

# epoch 秒の整形と日付文字列の解釈は、GNU と BSD（macOS）の date でオプションが違う。
if date --version >/dev/null 2>&1; then
    fmt_epoch() { date -d "@$1" "$2"; }
    fmt_epoch_utc() { date -u -d "@$1" "$2"; }
    midnight_epoch() { date -d "$1 00:00:00" '+%s'; }
    ymd_dow() { date -d "$1" '+%u'; }
else
    fmt_epoch() { date -r "$1" "$2"; }
    fmt_epoch_utc() { date -u -r "$1" "$2"; }
    midnight_epoch() { date -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" '+%s'; }
    ymd_dow() { date -j -f '%Y-%m-%d' "$1" '+%u'; }
fi

project_pct() {
    local pct=$1 elapsed=$2 window=$3
    [ "$elapsed" -lt 60 ] && return 0
    jq -n "$pct * $window / $elapsed | round" 2>/dev/null
}

weekday_seconds() {
    local start=$1 end=$2
    if [ "$end" -le "$start" ]; then echo 0; return; fi
    local total=0
    local sy sm sd cursor
    sy=$(fmt_epoch "$start" '+%Y')
    sm=$(fmt_epoch "$start" '+%m')
    sd=$(fmt_epoch "$start" '+%d')
    cursor=$(midnight_epoch "$sy-$sm-$sd" 2>/dev/null)
    while [ "$cursor" -lt "$end" ]; do
        local next_ts=$((cursor + 86400))
        local dow
        dow=$(fmt_epoch "$cursor" '+%u')
        if [ "$dow" -ge 1 ] && [ "$dow" -le 5 ]; then
            local seg_s=$cursor seg_e=$next_ts
            [ "$seg_s" -lt "$start" ] && seg_s=$start
            [ "$seg_e" -gt "$end" ] && seg_e=$end
            total=$((total + seg_e - seg_s))
        fi
        cursor=$next_ts
    done
    echo "$total"
}

# /setup-otel 導入済みなら、平日/週末の消費内訳は OTel の Elasticsearch (logs-generic.otel-default の attributes.cost_usd)から直接集計する。
# 「描画された瞬間の曜日に消費をまるごと計上する」差分の積み上げ方式だと、描画が飛んだ区間(リモート経由のセッション等)の消費が誤った曜日に計上される。
# そのため実測データそのものを見に行く。
ES_URL="http://localhost:9200"
ES_INDEX="logs-generic.otel-default"
# 空にすると利用枠の記録だけを止められる（画面表示はそのまま残る）
RATE_LIMIT_INDEX="claude-rate-limits"

es_query_weekday_weekend_cost() {
    local start_ts=$1 end_ts=$2
    local start_iso end_iso query result
    start_iso=$(fmt_epoch_utc "$start_ts" '+%Y-%m-%dT%H:%M:%SZ')
    end_iso=$(fmt_epoch_utc "$end_ts" '+%Y-%m-%dT%H:%M:%SZ')
    query=$(jq -n --arg s "$start_iso" --arg e "$end_iso" '{
        size: 0,
        query: {bool: {filter: [
            {term: {event_name: "api_request"}},
            {range: {"@timestamp": {gte: $s, lt: $e}}}
        ]}},
        aggs: {by_day: {date_histogram: {
            field: "@timestamp", calendar_interval: "day",
            time_zone: "Asia/Tokyo", format: "yyyy-MM-dd"
        }, aggs: {total_cost: {sum: {field: "attributes.cost_usd"}}}}}
    }')
    result=$(curl -s --max-time 2 -H 'Content-Type: application/json' -d "$query" "$ES_URL/$ES_INDEX/_search" 2>/dev/null)
    echo "$result" | jq -e '.aggregations.by_day.buckets' >/dev/null 2>&1 || return 1

    local wd_cost=0 we_cost=0 d cost dow
    while IFS=$'\t' read -r d cost; do
        [ -z "$d" ] && continue
        dow=$(ymd_dow "$d" 2>/dev/null) || continue
        if [ "$dow" -ge 1 ] && [ "$dow" -le 5 ]; then
            wd_cost=$(jq -n --argjson a "$wd_cost" --argjson b "${cost:-0}" '$a + $b')
        else
            we_cost=$(jq -n --argjson a "$we_cost" --argjson b "${cost:-0}" '$a + $b')
        fi
    done < <(echo "$result" | jq -r '.aggregations.by_day.buckets[] | "\(.key_as_string)\t\(.total_cost.value)"')

    jq -cn --argjson wd "$wd_cost" --argjson we "$we_cost" '{weekday: $wd, weekend: $we}'
}

# ES問い合わせは毎秒の描画には重いので30秒キャッシュする
es_split_cache_is_stale() {
    local f=$1
    [ ! -f "$f" ] || \
    [ $(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0) )) -gt 30 ]
}

# 7d 用: 平日レートで未来分のみ外挿（現在%には土日消費も既に含まれる）
project_pct_weekday() {
    local current_pct=$1 reset=$2
    [ -z "$current_pct" ] || [ -z "$reset" ] && return 0
    local week_start=$((reset - 604800))
    local trace_file="$STATE_DIR/week-trace-$reset.json"
    local es_split_file="$STATE_DIR/es-weekday-split-$reset.json"

    # WEEK_RESET が変わったら古い trace / ES キャッシュを消す
    find "$STATE_DIR" -maxdepth 1 -name 'week-trace-*.json' ! -name "week-trace-$reset.json" -delete 2>/dev/null
    find "$STATE_DIR" -maxdepth 1 -name 'es-weekday-split-*.json' ! -name "es-weekday-split-$reset.json" -delete 2>/dev/null

    local elapsed_wd remaining_wd elapsed_total
    elapsed_wd=$(weekday_seconds "$week_start" "$NOW")
    remaining_wd=$(weekday_seconds "$NOW" "$reset")
    elapsed_total=$((NOW - week_start))

    # ES キャッシュが古ければ実測を取り直す
    if es_split_cache_is_stale "$es_split_file"; then
        local es_result
        es_result=$(es_query_weekday_weekend_cost "$week_start" "$NOW")
        [ -n "$es_result" ] && echo "$es_result" > "$es_split_file.tmp" 2>/dev/null && mv "$es_split_file.tmp" "$es_split_file" 2>/dev/null
    fi

    local wd_used wend_used es_wd es_we es_total
    if [ -f "$es_split_file" ]; then
        es_wd=$(jq -r '.weekday // 0' "$es_split_file" 2>/dev/null)
        es_we=$(jq -r '.weekend // 0' "$es_split_file" 2>/dev/null)
        es_total=$(jq -n --argjson a "${es_wd:-0}" --argjson b "${es_we:-0}" '$a + $b' 2>/dev/null)
    fi

    if [ -n "$es_total" ] && [ "$(jq -n --argjson t "$es_total" '$t > 0')" = "true" ]; then
        # ground truth: 現在%を ES 実測の weekday/weekend 費用比で按分する
        wd_used=$(jq -n --argjson cur "$current_pct" --argjson wd "$es_wd" --argjson t "$es_total" '$cur * $wd / $t' 2>/dev/null)
        wend_used=$(jq -n --argjson cur "$current_pct" --argjson u "$wd_used" '$cur - $u' 2>/dev/null)
    else
        # ES 未導入・未接続・この週まだ実測ゼロ: 差分の積み上げ方式にフォールバックNOW が平日（月〜金）かどうか
        local now_dow is_weekday
        now_dow=$(date '+%u')
        if [ "$now_dow" -ge 1 ] && [ "$now_dow" -le 5 ]; then is_weekday=1; else is_weekday=0; fi

        # y = ax + b モデル: a = wd_used/ew, b = wend_used, cur = wd_used + wend_used delta は NOW の曜日で全額 wd_used または wend_used に振り分ける
        if [ -f "$trace_file" ]; then
            local last_ts last_pct prev_wd prev_we
            last_ts=$(jq -r '.last_ts // empty' "$trace_file" 2>/dev/null)
            last_pct=$(jq -r '.last_pct // empty' "$trace_file" 2>/dev/null)
            prev_wd=$(jq -r '.weekday_used // empty' "$trace_file" 2>/dev/null)
            prev_we=$(jq -r '.weekend_used // empty' "$trace_file" 2>/dev/null)
            if [ -z "$prev_we" ] && [ -n "$prev_wd" ]; then
                prev_we=$(jq -n --argjson cur "$current_pct" --argjson wd "$prev_wd" 'if ($cur - $wd) > 0 then ($cur - $wd) else 0 end' 2>/dev/null)
            fi
            if [ -n "$last_ts" ] && [ -n "$last_pct" ] && [ -n "$prev_wd" ] && [ -n "$prev_we" ] && [ "$NOW" -gt "$last_ts" ]; then
                wd_used=$(jq -n --argjson cur "$current_pct" --argjson last "$last_pct" --argjson used "$prev_wd" --argjson wd "$is_weekday" '
                    ($cur - $last) as $delta
                    | if $delta <= 0 then $used
                      elif $wd == 1 then $used + $delta
                      else $used end
                ' 2>/dev/null)
                wend_used=$(jq -n --argjson cur "$current_pct" --argjson last "$last_pct" --argjson used "$prev_we" --argjson wd "$is_weekday" '
                    ($cur - $last) as $delta
                    | if $delta <= 0 then $used
                      elif $wd == 0 then $used + $delta
                      else $used end
                ' 2>/dev/null)
            else
                wd_used="$prev_wd"
                wend_used="$prev_we"
            fi
        fi

        if [ -z "$wd_used" ]; then
            # ブートストラップ: 現在%を経過全体に対する平日比率で按分（土日比率も同様）
            if [ "$elapsed_total" -gt 0 ]; then
                wd_used=$(jq -n --argjson cur "$current_pct" --argjson ew "$elapsed_wd" --argjson et "$elapsed_total" '$cur * $ew / $et' 2>/dev/null)
                wend_used=$(jq -n --argjson cur "$current_pct" --argjson wd "$wd_used" 'if ($cur - $wd) > 0 then ($cur - $wd) else 0 end' 2>/dev/null)
            else
                wd_used=0
                wend_used=0
            fi
        fi

        # cur が下がった等で wd_used > cur になったら丸める（wend_used も同様）
        wd_used=$(jq -n --argjson cur "$current_pct" --argjson u "${wd_used:-0}" 'if $u > $cur then $cur else $u end' 2>/dev/null)
        wend_used=$(jq -n --argjson cur "$current_pct" --argjson wd "$wd_used" --argjson u "${wend_used:-0}" '
            ($cur - $wd) as $cap
            | if $u > $cap then (if $cap < 0 then 0 else $cap end) else $u end
        ' 2>/dev/null)

        # 状態保存(次回描画時の差分計算用。ES が使えない環境向けのフォールバック専用)
        jq -n --argjson ts "$NOW" --argjson pct "$current_pct" --argjson wd "$wd_used" --argjson we "$wend_used" \
            '{last_ts: $ts, last_pct: $pct, weekday_used: $wd, weekend_used: $we}' > "$trace_file" 2>/dev/null
    fi

    # 平日経過が短すぎる場合は予測を出さない
    [ "$elapsed_wd" -lt 60 ] && return 0

    jq -n --argjson cur "$current_pct" --argjson used "$wd_used" --argjson ew "$elapsed_wd" --argjson rw "$remaining_wd" \
        '($cur + ($used / $ew) * $rw) | round' 2>/dev/null
}

# 利用枠の使用率は stdin の JSON でしか手に入らない。OTel のメトリクス・ログイベント・hook の入力のどれにも項目が無いため、ここで Elasticsearch へ残している。
record_rate_limits() {
    [ -z "$RATE_LIMIT_INDEX" ] && return 0
    [ -z "$FIVE_H" ] && [ -z "$WEEK" ] && return 0

    local sent_file="$STATE_DIR/rate-limit-sent.json"
    local snapshot prev
    snapshot="${FIVE_H:-}/${WEEK:-}"
    prev=$(jq -r '.snapshot // empty' "$sent_file" 2>/dev/null)
    [ "$snapshot" = "$prev" ] && return 0

    local repo project
    repo=$(git rev-parse --show-toplevel 2>/dev/null)
    project="${repo##*/}"
    [ -z "$project" ] && project="${DIR##*/}"

    local doc
    doc=$(jq -cn \
        --arg ts "$(fmt_epoch_utc "$NOW" '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg project "$project" \
        --arg session "$SESSION_ID" \
        --arg model "$MODEL" \
        --arg version "$VERSION" \
        --arg five "$FIVE_H" --arg five_reset "$FIVE_H_RESET" \
        --arg week "$WEEK" --arg week_reset "$WEEK_RESET" \
        '{"@timestamp": $ts, project: $project, session_id: $session, model: $model}
         | if $version != "" then .version = $version else . end
         | if $five != "" then .five_hour = {used_percentage: ($five | tonumber)} else . end
         | if $five_reset != "" then .five_hour.resets_at = ($five_reset | tonumber) else . end
         | if $week != "" then .seven_day = {used_percentage: ($week | tonumber)} else . end
         | if $week_reset != "" then .seven_day.resets_at = ($week_reset | tonumber) else . end' 2>/dev/null)
    [ -z "$doc" ] && return 0

    # 送信できたときだけ記録を更新する（ES 停止中に snapshot だけ進めると、次に復帰しても値が変わるまで1件も書かれない穴になる）。
    (curl -s --max-time 2 -o /dev/null -f -H 'Content-Type: application/json' \
        -d "$doc" "$ES_URL/$RATE_LIMIT_INDEX/_doc" \
        && jq -cn --arg s "$snapshot" '{snapshot: $s}' > "$sent_file.tmp" \
        && mv "$sent_file.tmp" "$sent_file") >/dev/null 2>&1 &
}

FIVE_H_LINE=""
if [ -n "$FIVE_H" ]; then
    FIVE_H_LINE="5h: $(printf '%2.0f' "$FIVE_H")%"
    if [ -n "$FIVE_H_RESET" ]; then
        FIVE_H_PROJ=$(project_pct "$FIVE_H" $((NOW - (FIVE_H_RESET - 18000))) 18000)
        [ -n "$FIVE_H_PROJ" ] && FIVE_H_LINE="$FIVE_H_LINE → $(printf '%2d' "$FIVE_H_PROJ")%"
        FIVE_H_LINE="$FIVE_H_LINE  ⏳ $(fmt_jp_duration $((FIVE_H_RESET - NOW))) ($(fmt_epoch "$FIVE_H_RESET" '+%H:%M'))"
    fi
fi
WEEK_LINE=""
if [ -n "$WEEK" ]; then
    WEEK_LINE="7d: $(printf '%2.0f' "$WEEK")%"
    if [ -n "$WEEK_RESET" ]; then
        WEEK_PROJ=$(project_pct_weekday "$WEEK" "$WEEK_RESET")
        [ -n "$WEEK_PROJ" ] && WEEK_LINE="$WEEK_LINE → $(printf '%2d' "$WEEK_PROJ")%"
        case $(fmt_epoch "$WEEK_RESET" '+%u') in
            1) DOW=月;; 2) DOW=火;; 3) DOW=水;; 4) DOW=木;;
            5) DOW=金;; 6) DOW=土;; 7) DOW=日;;
        esac
        WEEK_LINE="$WEEK_LINE  ⏳ $(fmt_jp_duration $((WEEK_RESET - NOW))) ($(fmt_epoch "$WEEK_RESET" '+%m/%d')(${DOW}) $(fmt_epoch "$WEEK_RESET" '+%H:%M'))"
    fi
fi

echo -e "${CYAN}🤖 $MODEL${RESET}${VERSION_STR}${EFFORT_STR}  📁 ${DIR##*/}$BRANCH"
echo -e "${BAR_COLOR}${BAR}${RESET}  $(printf '%4s' "$PCT")% (${TOKENS} / ${WINDOW_STR})"
if [ -n "$CACHE_LINE" ]; then echo -e "$CACHE_LINE"; fi
if [ -n "$MISS_CAUSE_LINE" ]; then printf '%s\n' "$MISS_CAUSE_LINE"; fi
if [ -n "$FIVE_H_LINE" ]; then echo "📊 $FIVE_H_LINE"; fi
if [ -n "$WEEK_LINE" ]; then echo "📊 $WEEK_LINE"; fi
if [ -n "$PLAN_LINE" ]; then printf '%s\n' "$PLAN_LINE"; fi
if [ -n "$ISSUE_LINE" ]; then printf '%s\n' "$ISSUE_LINE"; fi
if [ -n "$PR_LINE" ]; then printf '%s\n' "$PR_LINE"; fi

record_rate_limits
exit 0
