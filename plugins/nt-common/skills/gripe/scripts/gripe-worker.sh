#!/usr/bin/env bash
# **エラーの文言に変数を埋めるときは必ず ${var} と波括弧で囲め。** 日本語の閉じ括弧が直後に続くと、bash が「）」まで変数名の一部として読んで unbound variable で落ちる。

set -euo pipefail

export TZ=Asia/Tokyo
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

CONFIG_FILE="$HOME/.claude/gripe-config.json"
REQUEST_DIR="$HOME/.claude/state/gripe/requests"

# 作者の環境ではここに clone してあるので、設定ファイルが無くても当たる。
DEFAULT_REPO="$HOME/pj/nt-tools"

SCRIPT_PATH="$(cd "${BASH_SOURCE[0]%/*}" && pwd)/${BASH_SOURCE[0]##*/}"
PROMPT_TEMPLATE="${SCRIPT_PATH%/scripts/*}/prompts/gripe-prompt.md"

# --- 修正先の解決 -----------------------------------------------------------

resolve_repo() {
    local configured=""
    if [[ -f "$CONFIG_FILE" ]]; then
        configured="$(jq -r '.repo // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    fi
    if [[ -n "$configured" && -d "$configured/.git" ]]; then
        printf '%s\n' "$configured"
        return 0
    fi
    if [[ -d "$DEFAULT_REPO/.git" ]]; then
        printf '%s\n' "$DEFAULT_REPO"
        return 0
    fi
    printf 'NOT_CONFIGURED\n'
    return 0
}

save_repo() {
    local path="$1"
    if [[ -z "$path" ]]; then
        echo "保存するパスが空だ" >&2
        return 1
    fi
    # チルダで渡されたときのために展開する
    path="${path/#\~/$HOME}"
    if [[ ! -d "$path/.git" ]]; then
        echo "git リポジトリが見つからない: ${path}" >&2
        return 1
    fi
    mkdir -p "${CONFIG_FILE%/*}"
    jq -n --arg repo "$path" '{repo: $repo}' > "$CONFIG_FILE.tmp"
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    echo "保存した: ${path}"
}

# --- 起動 -------------------------------------------------------------------

launch_request() {
    local src="$1"
    if [[ ! -f "$src" ]]; then
        echo "依頼ファイルが見つからない: ${src}" >&2
        return 1
    fi

    local repo
    repo="$(resolve_repo)"
    if [[ "$repo" == "NOT_CONFIGURED" ]]; then
        echo "修正先リポジトリが未設定だ。--save-repo で設定しろ" >&2
        return 1
    fi

    if [[ ! -f "$PROMPT_TEMPLATE" ]]; then
        echo "指示文のテンプレートが見つからない: ${PROMPT_TEMPLATE}" >&2
        return 1
    fi

    mkdir -p "$REQUEST_DIR"

    # 投げる時点では Issue 番号がまだ無い（起動先の Claude が起票する）ので、日時で衝突を避ける。
    local name prompt_file request_body prompt
    name="gripe-$(date '+%Y%m%d-%H%M%S')"
    prompt_file="$REQUEST_DIR/${name}.md"
    request_body="$(cat "$src")"
    prompt="$(cat "$PROMPT_TEMPLATE")"
    prompt="${prompt//__REQUEST__/$request_body}"
    printf '%s\n' "$prompt" > "$prompt_file"

    local create_json worktree_path
    create_json="$(orca worktree create --repo "path:${repo}" --name "$name" --no-parent --json 2>&1)" || true
    worktree_path="$(printf '%s' "$create_json" | jq -r '.result.worktree.path // empty' 2>/dev/null || true)"
    if [[ -z "$worktree_path" ]]; then
        echo "ワークツリーの作成に失敗した。出力:" >&2
        printf '%s\n' "$create_json" >&2
        return 1
    fi

    local startup_handles
    startup_handles="$(orca terminal list --worktree "path:${worktree_path}" --json 2>/dev/null | jq -r '.result.terminals[]?.handle // empty' || true)"

    # 指示文はシェルの引数長の上限に触れうるので、起動するコマンドの中でファイルから読ませる。
    # OTEL_RESOURCE_ATTRIBUTES は /setup-otel 導入時に、どのリポジトリのどの自動処理かを記録に載せる。

    # Orca のターミナルは対話 zsh なので、claude が関数・エイリアスに置き換えられていても実行ファイルを直接呼ぶ。
    local term_json handle
    term_json="$(orca terminal create --worktree "path:${worktree_path}" --title "$name" \
        --command "OTEL_RESOURCE_ATTRIBUTES='project=$(basename "$repo"),job=gripe' command claude --model claude-opus-5 --effort medium --dangerously-skip-permissions \"\$(cat '${prompt_file}')\"" \
        --json 2>&1)" || true
    handle="$(printf '%s' "$term_json" | jq -r '.result.terminal.handle // empty' 2>/dev/null || true)"
    if [[ -z "$handle" ]]; then
        orca worktree rm --worktree "path:${worktree_path}" --force --run-hooks --json >/dev/null 2>&1 || true
        echo "Claude の起動に失敗した。出力:" >&2
        printf '%s\n' "$term_json" >&2
        return 1
    fi

    # orca worktree create は空のターミナルを1つ作る。Claude のタブだけ残す。
    local startup
    while IFS= read -r startup; do
        [[ -n "$startup" ]] || continue
        orca terminal close --terminal "$startup" --tab --json >/dev/null 2>&1 || true
    done <<< "$startup_handles"

    echo "投げた: ${name}"
    echo "ワークツリー: ${worktree_path}"
    echo "指示文: ${prompt_file}"
}

# --- 入口 -------------------------------------------------------------------

case "${1:-}" in
    --resolve-repo)
        resolve_repo
        ;;
    --save-repo)
        save_repo "${2:-}"
        ;;
    --run)
        launch_request "${2:-}"
        ;;
    *)
        echo "使い方: gripe-worker.sh --resolve-repo | --save-repo <path> | --run <依頼ファイル>" >&2
        exit 1
        ;;
esac
