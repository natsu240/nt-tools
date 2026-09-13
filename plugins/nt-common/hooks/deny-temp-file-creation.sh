#!/usr/bin/env bash
# Write ツールでの「一時的」を示唆するファイル名作成を block する PreToolUse hook。
# プレフィックス test- / tmp- / temp- / scratch- / sandbox- / debug- / tryout- で始まるbasename、および先頭がアンダースコアの basename（例: _W3LayoutCheckTest.php のような「正式なテストスイートに組み込む意図のない使い捨て検証ファイル」の命名慣習）を block する。

input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')

if [ -z "$file_path" ]; then
  exit 0
fi

basename=$(basename "$file_path")

if printf '%s' "$basename" | grep -qE '^(test|tmp|temp|scratch|sandbox|debug|tryout|tmpfile|scratchfile|throwaway|wip|delme|dummy|sample)[-_.]|^_'; then
  reason=$(cat <<EOF
🚫 「一時的」を示唆するファイル名の作成は禁止です: $basename

理由: 「test-...」「tmp-...」「temp-...」「scratch-...」「sandbox-...」「debug-...」、
または先頭アンダースコア（「_...」）のようなファイル名は、ほぼ常に「あとで消すつもりの
ゴミ」を作る兆候。機械的に止める方針。

代替:
  - そもそも一時スクリプトを作らずに済む方法を検討（jq one-liner、既存ツール利用）
  - 本当に永続化すべきなら、用途を表す正式な名前を付ける
  - どうしても一時的な実験が必要なら、ユーザーに「これ作っていい？」と確認してから命名
EOF
)
  jq -n --arg msg "$reason" '
    {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $msg
      },
      systemMessage: $msg
    }
  '
fi

exit 0
