#!/usr/bin/env bash
# Bash PreToolUse hook。危険パターンを block し、読み取り専用コマンドは自動許可する。
#
# hook の allow は settings の deny ルールを override しない（deny が常に優先）。

# shellcheck source=lib-emit-decision.sh
source "${BASH_SOURCE[0]%/*}/lib-emit-decision.sh"

input=$(cat)
command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
[ -z "$command" ] && exit 0

deny() {
  emit_pretooluse_decision deny "$1"
  exit 0
}

# クォートの中身を落とした文字列。ヒアドキュメント / /tmp への書き込み / 他 ref からのファイル展開の判定に使う。これらは判定に使う部分がクォートの外にあるので、落としても本来の検出は壊れず、文字列リテラルとして書かれただけの誤検知だけが消える。
#
# 長文インラインスクリプトと小ファイルへの部分読みには使うな。前者は判定したい中身がクォートの中にあり（`python3 -c "長い..."`）、落とすと検出そのものが成立しない。
# 後者はファイル名の抽出に単語分割を使っており、落とすと引数ごと消える。
# shellcheck source=lib-strip-quoted.sh
source "${BASH_SOURCE[0]%/*}/lib-strip-quoted.sh"
unquoted=$(strip_quoted "$command")

# ============ HARD DENY（ディスク破壊・fork bomb） ============permission プロンプト(ask)にすら流さず問答無用で止める。チャット経由で頼む場面が原理的に無い「マシン/ディスク破壊系」だけに限定。rm -rf 系・curl|bash は対象外(従来の ask 維持)。
# 解除したいときは本セクションを編集するか、自分のターミナルで直接実行しろ。

# fork bomb
if printf '%s' "$command" | grep -qE ':[[:space:]]*\(\)[[:space:]]*\{[^}]*:[[:space:]]*\|[[:space:]]*:[^}]*\}[[:space:]]*;[[:space:]]*:'; then
  deny "🚫 [HARD DENY] fork bomb を検出。実行を拒否した。"
fi

# dd で生デバイスへ書き込み（dd of=file は対象外）
if printf '%s' "$command" | grep -qE '(^|[[:space:]/;&|])dd[[:space:]][^|;&]*of=/dev/(r?disk|sd|nvme|hd|vd)'; then
  deny "🚫 [HARD DENY] dd で生デバイス(/dev/...)へ書き込もうとしている。ディスク破壊のため拒否。必要なら自分のターミナルで実行しろ。"
fi

# mkfs（ローカル不在だが docker exec 等のコンテナ用保険）
if printf '%s' "$command" | grep -qE '(^|[[:space:]/;&|])mkfs(\.[a-z0-9]+)?([[:space:]]|$)'; then
  deny "🚫 [HARD DENY] mkfs によるフォーマットは拒否。"
fi

# fdisk 編集/初期化（-e/-i/-u/-y）。fdisk -l 等の参照は対象外
if printf '%s' "$command" | grep -qE '(^|[[:space:]/;&|])fdisk[[:space:]]+-[a-zA-Z]*[eiuy]'; then
  deny "🚫 [HARD DENY] fdisk のパーティション編集/初期化は拒否。"
fi

# diskutil の破壊 verb（list/info/mount 等は対象外）
if printf '%s' "$command" | grep -qE '(^|[[:space:]/;&|])diskutil[[:space:]][^|;&]*(eraseDisk|eraseVolume|reformat|partitionDisk|zeroDisk|randomDisk|secureErase|eraseOptical|destroyDisk|deleteContainer|deleteVolume|resetFusion|enableFusion)'; then
  deny "🚫 [HARD DENY] diskutil のディスク消去/再パーティションは拒否。必要なら自分のターミナルで実行しろ。"
fi

# newfs_*（macOS フォーマット本体）
if printf '%s' "$command" | grep -qE '(^|[[:space:]/;&|])newfs_(apfs|hfs|msdos|exfat|udf)([[:space:]]|$)'; then
  deny "🚫 [HARD DENY] newfs_* によるフォーマットは拒否。"
fi

# asr のディスク復元/消去
if printf '%s' "$command" | grep -qE '(^|[[:space:]/;&|])asr[[:space:]][^|;&]*(restore|--erase)'; then
  deny "🚫 [HARD DENY] asr によるディスク復元/消去は拒否。"
fi

# 生デバイスへのリダイレクト（> /dev/disk0 等。/dev/null 等は対象外）
if printf '%s' "$command" | grep -qE '>[[:space:]]*/dev/(r?disk[0-9]|sd[a-z]|nvme[0-9]|hd[a-z]|vd[a-z])'; then
  deny "🚫 [HARD DENY] 生デバイス(/dev/...)へのリダイレクトは拒否。"
fi

# ============ block 系 ============

# A: ヒアドキュメント書き込み（cat > file <<... / tee file <<...）
if printf '%s' "$unquoted" | grep -qE '(cat|tee)[[:space:]]*>[[:space:]]*[^[:space:]]+[[:space:]]*<<'; then
  deny "🚫 ヒアドキュメントによる一時ファイル書き込みは禁止。新規は Write、追記は Edit ツールを使え。"
fi

# B: /tmp 以下へのファイル書き込み禁止（スクリプトも grep 等の中間出力も）Bash 経由の /tmp 書き込みだけを禁止する。Write ツール経由の scratchpad（$TMPDIR / /tmp / /private/tmp 配下）は許可されており対象外（ルール C 参照）。このセッションの scratchpad（/tmp/claude-<uid>/<project>/<session_id>/scratchpad。macOS は /private/tmp 配下）への Bash からのリダイレクトも、コマンド出力の保存は Write ツールで代替できないため対象外にする。
if printf '%s' "$unquoted" | grep -qE '>>?[[:space:]]*[^[:space:]|&;<]*/tmp/[^[:space:]|&;<>]+'; then
  session_id=$(printf '%s' "$input" | jq -r '.session_id // ""')
  non_scratchpad_target=0
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    if [ -n "$session_id" ] && printf '%s' "$target" | grep -qE "/tmp/claude-[0-9]+/[^/]+/${session_id}/scratchpad(/|\$)"; then
      continue
    fi
    non_scratchpad_target=1
  done < <(printf '%s' "$unquoted" | grep -oE '>>?[[:space:]]*[^[:space:]|&;<]*/tmp/[^[:space:]|&;<>]+' | sed -E 's/^>>?[[:space:]]*//')
  if [ "$non_scratchpad_target" -eq 1 ]; then
    deny "🚫 Bash から /tmp へ書くな（このセッションの scratchpad 配下を除く）。使い捨てのクエリ・スクリプトは Write ツールで scratchpad（\$TMPDIR / /tmp / /private/tmp 配下）に作れ。grep/awk 等の中間出力は \`| head -c N\` でそのまま出すか Read ツールで offset 指定して読め。"
  fi
fi

# C: 長文インラインスクリプト（80 字超）
if printf '%s' "$command" | grep -qE "(python3?|node|ruby|perl|php)[[:space:]]+-(c|e)[[:space:]]+.{80,}"; then
  deny "🚫 長文の -c/-e インラインスクリプト実行は禁止。Write でファイル化するか jq で代用しろ。使い捨ての調査スクリプトなら scratchpad（\$TMPDIR / /tmp / /private/tmp 配下）に Write しろ。この置き場は code-style 系 skill の起動チェックの対象外なので、そちらで止まることはない。"
fi

# D: 他 ref からワークツリーへのファイル展開（git checkout <ref> -- / git restore --source）
explode_ref=""
if printf '%s' "$unquoted" | grep -qE 'git[[:space:]]+checkout[[:space:]]+[^[:space:]]+[[:space:]]+--([[:space:]]|$)'; then
  explode_ref=$(printf '%s' "$unquoted" | sed -E 's/.*git[[:space:]]+checkout[[:space:]]+([^[:space:]]+)[[:space:]]+--.*/\1/')
elif printf '%s' "$unquoted" | grep -qE 'git[[:space:]]+restore[[:space:]]+.*--source'; then
  explode_ref=$(printf '%s' "$unquoted" | sed -E 's/.*--source[= ]+([^[:space:]]+).*/\1/')
fi
if [ -n "$explode_ref" ]; then
  case "$explode_ref" in
    HEAD|HEAD~*|HEAD^*|@) ;;
    *)
      deny "🚫 他ブランチ/コミットからワークツリーへのファイル展開は禁止。gh pr diff / git show <ref>:<path> / git worktree を使え。"
      ;;
  esac
fi

if printf '%s' "$unquoted" | grep -qE '(^|[[:space:]/;&|])claude[[:space:]]+-p([[:space:]]|$)' \
   && ! printf '%s' "$command" | grep -qF '/goal'; then
  deny "🚫 Bash から claude CLI を子プロセスとして起動する行為(-p)は禁止。動作確認が必要なら既存のコード・ドキュメント調査で済ませろ。/goal を伴う起動だけ例外で許可される。claude mcp / claude plugin 等の既存許可コマンドは対象外。"
fi

if printf '%s' "$unquoted" | grep -qE '(^|[[:space:]/;&|])claude([[:space:]]|$)' \
   && printf '%s' "$unquoted" | grep -qE '(^|[[:space:]])(--debug|--dangerously-skip-permissions|--remote-control|remote-control)([[:space:]]|$)'; then
  deny "🚫 Bash から claude CLI を子プロセスとして起動する行為(--debug / --dangerously-skip-permissions / remote-control)は禁止。/goal を伴う -p 起動でもこの3フラグは対象外。claude mcp / claude plugin 等の既存許可コマンドは対象外。"
fi

# ============ 書き込み・状態変更の検出 ============クォート内・コマンド置換・fd リダイレクトを除外してからファイル書き込みリダイレクトを判定する。
NL=$(printf '\001')
s=$(printf '%s' "$command" | tr '\n' "$NL")
s=$(printf '%s' "$s" | sed -E 's/\$\([^()]*\)//g')      # $(...) 除去
s=$(printf '%s' "$s" | sed -E 's/`[^`]*`//g')           # `...` 除去
s=$(printf '%s' "$s" | sed -E "s/'[^']*'//g")           # '...' 除去
s=$(printf '%s' "$s" | sed -E 's/"[^"]*"//g')           # "..." 除去
s=$(printf '%s' "$s" | sed -E 's/[0-9]+>&[0-9-]+//g')   # 2>&1 等
s=$(printf '%s' "$s" | sed -E 's/&>[[:space:]]*[^[:space:]|&;<>]+//g')   # &>file
s=$(printf '%s' "$s" | sed -E 's/[0-9]+>>?[[:space:]]*\/dev\/null//g')   # 2>/dev/null
s=$(printf '%s' "$s" | sed -E 's/[0-9]+>>?[[:space:]]*&[0-9-]+//g')      # 2>&-

write_detected=""

# ファイル書き込みリダイレクト（> / >>。fd リダイレクトは上で除外済み）
if printf '%s' "$s" | grep -qE '>'; then
  write_detected="redirect"
fi

# 書き込み・削除・新規作成・状態変更コマンド（sanitized で判定。クォート内のコマンド名を誤検出しない）
if printf '%s' "$s" | grep -qE '(\brm\b|\brmdir\b|\bunlink\b|\bshred\b|\bmv\b|\bcp\b|\bmkdir\b|\btouch\b|\btee\b|\bdd\b|\bln\b|\bchmod\b|\bchown\b|\bchgrp\b|\btruncate\b|\brsync\b|\bmktemp\b|(sed|perl)[[:space:]]+-i|git[[:space:]]+(add|commit|push|rm|mv|reset|restore|checkout|switch|merge|rebase|stash|clean|tag|branch|apply|cherry-pick|revert|am|init|clone|remote|config|gc|prune|fetch|pull)|(npm|pnpm|yarn|bun|pip3?|brew|apt|apt-get|gem|cargo|poetry|uv|uvx)[[:space:]]+(install|add|i|remove|rm|uninstall|update|upgrade|link|unlink)|go[[:space:]]+(install|get)|claude[[:space:]]+mcp[[:space:]]+(add|remove)|\bkill\b|\bpkill\b|\bkillall\b|\bsystemctl\b|\blaunchctl\b|\bcrontab\b|defaults[[:space:]]+write)'; then
  write_detected="command"
fi

# /tmp そのもの・ルート直下を対象にしたものは対象外
is_tmp_cleanup_only() {
  local stripped="$1" segment tok found_path segments
  printf '%s' "$stripped" | grep -qE '>' && return 1
  segments="$(printf '%s' "$stripped" | sed -E 's/&&/\n/g; s/\|\|/\n/g; s/;/\n/g')"

  while IFS= read -r segment; do
    [ -z "$(printf '%s' "$segment" | tr -d '[:space:]')" ] && continue
    printf '%s' "$segment" | grep -qE '^[[:space:]]*(rm|rmdir|unlink)([[:space:]]|$)' || return 1

    found_path=0
    set -f
    for tok in $segment; do
      case "$tok" in
        rm|rmdir|unlink|-*) continue ;;
      esac
      case "$tok" in
        */../*|*/..) set +f; return 1 ;;
        /tmp/?*|/private/tmp/?*) found_path=1 ;;
        *) set +f; return 1 ;;
      esac
    done
    set +f
    [ "$found_path" -eq 1 ] || return 1
  done <<<"$segments"
  return 0
}

if [ "$write_detected" = "command" ] && is_tmp_cleanup_only "$unquoted"; then
  emit_pretooluse_decision allow "/tmp 配下の一時ファイル削除 (auto-approved by gate-risky-bash)"
  exit 0
fi

if [ -n "$write_detected" ]; then
  # 書き込み・状態変更を含む → 通常の permission フローへ（settings の allow ルール or 確認）
  exit 0
fi

# ============ 小ファイルへの部分読み → block（Read 強制） ============明示パスの既存ファイル（すべて100KB未満）から grep/head/tail/sed/awk で内容の行を取り出すコマンドは拒否して Read ツールへ誘導する（CLAUDE.md「ファイルの読み方（強制）」と同基準）。
# どこに何件あるかだけを返す grep（-l/-L/-c/-r/-R 等）・100KB以上のファイルを含むもの・ファイル引数なしのパイプ処理は対象外。`;`/`&&`/`||`/`|` の区間ごとに判定し、クォート内の語は $unquoted で除外する。

# ファイルの中身ではなく、どこに何件あるかだけを返す grep なら 0 を返す
is_locate_only_grep() {
  local segment="$1"
  printf '%s' "$segment" | grep -qE '(^|[[:space:]/;&|])grep([[:space:]]|$)' || return 1
  printf '%s' "$segment" | grep -qE '(^|[[:space:]])(--recursive|--files-with-matches|--files-without-match|--count|-[a-zA-Z]*[rRlLc])'
}

if printf '%s' "$unquoted" | grep -qE '(^|[[:space:]/;&|])(grep|head|tail|sed|awk)([[:space:]]|$)'; then
  hook_cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
  [ -n "$hook_cwd" ] && cd "$hook_cwd" 2>/dev/null
  session_id=$(printf '%s' "$input" | jq -r '.session_id // ""')
  reads_log="$HOME/.claude/hook-state/${session_id}_reads.log"
  found_small=0
  found_big=0
  small_files=""
  already_read_files=""

  segments_raw="$(printf '%s' "$unquoted" \
    | sed -E 's/&&/\n/g; s/\|\|/\n/g; s/;/\n/g; s/\|/\n/g')"

  while IFS= read -r segment; do
    printf '%s' "$segment" | grep -qE '(^|[[:space:]/;&|])(grep|head|tail|sed|awk)([[:space:]]|$)' || continue
    is_locate_only_grep "$segment" && continue

    set -f
    for w in $segment; do
      w=${w#\'}; w=${w%\'}; w=${w#\"}; w=${w%\"}
      case "$w" in "~/"*) w="$HOME/${w#\~/}";; esac
      if [ -f "$w" ]; then
        sz=$(stat -c '%s' "$w" 2>/dev/null || stat -f '%z' "$w" 2>/dev/null || echo 0)
        if [ "$sz" -lt 102400 ]; then
          found_small=1
          if [ -n "$session_id" ] && [ -s "$reads_log" ] && grep -qxF -- "$w" "$reads_log" 2>/dev/null; then
            already_read_files="${already_read_files}${already_read_files:+, }${w}"
          else
            kb=$((sz / 1024))
            small_files="${small_files}${small_files:+, }${w}（約${kb}KB）"
          fi
        else
          found_big=1
        fi
      fi
    done
    set +f
  done <<<"$segments_raw"

  if [ "$found_small" -eq 1 ] && [ "$found_big" -eq 0 ]; then
    if [ -n "$already_read_files" ]; then
      deny "🚫 ${already_read_files} は既にこのセッションで Read 済みだ。行番号は直前の Read 出力に付いている。読み直すな。"
    else
      deny "🚫 ${small_files} から grep/head/tail/sed/awk で内容の行を取り出すな。Read ツールで全文読め（複数あるなら1つずつ Read しろ）。単一ファイル内の検索・行番号引き当ては Grep ツールでもできる。どこに何件あるかだけを知りたいなら grep の -l / -L / -c / -r / -R は許可される。100KB以上のログ/JSONL への grep も許可される。"
    fi
  fi
fi

# ============ 読み取り専用 → 自動許可（パイプ・複合含む、プロンプトなし） ============
emit_pretooluse_decision allow "read-only command (auto-approved by gate-risky-bash)"
exit 0
