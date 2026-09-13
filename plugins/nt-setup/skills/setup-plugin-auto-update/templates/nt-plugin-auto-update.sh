#!/usr/bin/env bash
# `claude plugin update` は "restart required to apply" 仕様なので、起動中のセッションには反映されない。
#
# launchd / systemd は最小限の PATH で実行するので、claude / jq が見つからないまま毎回何もせず終了する。エラー出力は /dev/null に捨てているので気付けない。インストール先を並べておく。
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

claude plugin marketplace update nt-tools >/dev/null 2>&1

if command -v jq >/dev/null 2>&1; then
  claude plugin list --json 2>/dev/null \
    | jq -r '.[] | select(.id | endswith("@nt-tools")) | "\(.id)\t\(.scope)"' \
    | while IFS=$'\t' read -r plugin_id scope; do
        claude plugin update "$plugin_id" -s "$scope" >/dev/null 2>&1
      done

  # 更新で置き換わった旧バージョンのキャッシュディレクトリを削除する。
  # Claude Code は旧バージョンを orphan として印を付け、およそ14日後の掃除で消す。その待ち時間を埋めるため自分で消す。
  # 稼働中セッションが握っているバージョンは、.in_use に残る生存 pid マーカーで判定して除外する。
  CACHE_DIR="$HOME/.claude/plugins/cache/nt-tools"
  INSTALLED_JSON="$HOME/.claude/plugins/installed_plugins.json"

  if [ -d "$CACHE_DIR" ] && [ -f "$INSTALLED_JSON" ]; then
    # installed_plugins.json は {"version": N, "plugins": {"<id>": [{"installPath": ...}]}} の形。
    # トップレベルを配列とみなす書き方（.[].installPath）は jq がエラーで終わり、使用中パスが1件も取れないまま「全部が削除対象」になる。
    ACTIVE_PATHS=$(jq -r '.plugins[][].installPath // empty' "$INSTALLED_JSON" 2>/dev/null)

    # 取得できなかったときは削除自体をやめる。空のまま先へ進むと現役バージョンまで消える。
    if [ -z "$ACTIVE_PATHS" ]; then
      exit 0
    fi

    LIVE_PIDS=$(ps -eo pid,command | grep '[c]laude' | awk '{print $1}' | sort -un | paste -sd'|' - || true)
    for plugin_dir in "$CACHE_DIR"/*/; do
      [ -d "$plugin_dir" ] || continue
      for version_dir in "$plugin_dir"*/; do
        [ -d "$version_dir" ] || continue
        version_dir="${version_dir%/}"
        if grep -qxF -- "$version_dir" <<<"$ACTIVE_PATHS"; then
          continue
        fi
        if [ -n "$LIVE_PIDS" ] && [ -d "$version_dir/.in_use" ]; then
          in_use_files=$(find "$version_dir/.in_use" -type f 2>/dev/null)
          if [ -n "$in_use_files" ] && grep -qE "/($LIVE_PIDS)(\.tmp\.[0-9a-f]+)?\$" <<<"$in_use_files"; then
            continue
          fi
        fi
        rm -rf "$version_dir"
      done
    done
  fi
fi
