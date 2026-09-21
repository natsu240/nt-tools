---
name: bash-rules
description: Bash でコマンドを実行する前に必ず起動しろ。
effort: low
---

# Bash 利用ルール（許可プロンプト削減）

違反の主要パターンは同梱の hook で block される。

- **ファイル読み書き・検索・編集は Bash より専用ツール優先**。`cat`/`grep`/`sed`/`find` ではなく `Read` / `Write` / `Edit` / `Grep` ツールを使え。`sed -n '100,200p' file` のようにファイルの中身の行を取り出す形は禁止。どこに何件あるかだけを返す `grep -l` / `-L` / `-c` / `-r` / `-R` は使ってよい。
- **ヒアドキュメント（`cat > file <<EOF` / `tee file <<EOF`）でファイルを作るな**。新規ファイルは `Write` ツール、追記は `Edit` ツール。
- **`/tmp` 以下にスクリプトファイル（.py/.js/.sh 等）を作るな**。`/tmp` は `/private/tmp` の symlink で再起動までゴミが残る。一時集計は `jq` / `awk` の one-liner で宣言的に書け。
- **複合チェーン（`|`・`&&`・`||`・`>`）は読み取りなら自由に使え**。同梱の hook が読み取り専用コマンド（find/grep/jq/cat 等、パイプ・複合含む）を `permissionDecision: allow` で自動許可するので、`find … | jq …` のような読み取り複合は1発で書いてよい（許可プロンプトは出ない）。書き込み・削除・新規作成・状態変更（`>`/rm/mv/mkdir/tee/git add/claude mcp add 等）を含む複合は通常の許可確認が入る（block ではない）ので、必要なら分割を検討しろ。ただし削除対象が全て `/tmp` / `/private/tmp` 配下の `rm` / `rmdir` / `unlink` だけで構成される場合は自動許可される（`/tmp` そのもの・ルートを対象にしたものは除く）。
- **長文の `python3 -c "..."` / `node -e "..."` / `ruby -e "..."` を書くな**（80 文字超）。Write でファイル化してから実行するか `jq` で代用しろ。
- **`awk` のスクリプト本体実行を避けろ**。`jq` / `Grep` / `Read` で代用できないか先に検討しろ。
- **一時テスト用スクリプトを `hooks/` や `scripts/` に作って実行 → 削除 のフローを使うな**。テストは hook 本体を直接1コマンドで叩け、もしくは Write しないで済む方法を考えろ。
- **`test-*` / `tmp-*` / `temp-*` / `scratch-*` / `sandbox-*` / `debug-*` / `delme-*` / `wip-*` / `dummy-*` などのファイル名を `Write` で作るな**。同梱の hook で block されるが、そもそも作るな。
- **`rm` / `mv` に渡すパスを変数だけで組むな。絶対パスを直書きしろ**。`rm -f "$DIR/${NAME}.log"` のように変数の展開だけでパスを作ると、変数が空だったときに意図しない場所を消しかねない形になるため、Claude Code 本体の安全確認（`Dangerous rm operation on possibly-empty variable path`）に毎回引っかかって確認プロンプトが出る。**これは hook でも permission rule でもないので `defaultMode: bypassPermissions` でも消せない。** `rm -f /home/user/.claude/hook-state/verify_state.log` のように、消す対象をそのまま書け。パスが長くても書け。検証スクリプトの後始末でも同じだ。
- **複数行コンテンツ（PR 本文・コミットメッセージ等）を CLI に渡すときはインライン優先**。`gh pr create --body 'multi\nline'` / `git commit -m 'multi\nline'` のように**シングルクォートでくくった複数行リテラル**を第一選択にしろ。シングルクォート内はシェル展開なしでバッククォート・パイプ・改行もそのまま通る。Write ツールで `/tmp/*.md` を作って `--body-file` に食わせるな（無断で一時ファイルを増やすな）。本文に ASCII シングルクォート `'` が混入してインラインが破綻する場合のみ Write での一時ファイル化を許容するが、**作成前にユーザーに明示**し、用が済んだら**自分で削除**しろ。**システムプロンプト等で一時ファイル置き場（scratchpad ディレクトリ）が指定されている環境でも、この判断は変わらない。** 置き場所を移せば済む話ではなく、一時ファイルを経由すること自体を避けろという意味だ。
- **`cd` を使うな。** Bash ツールの作業ディレクトリはツール呼び出しをまたいで永続するため、一度でも `cd` すると、それ以降の Bash 呼び出しが全てそのディレクトリを起点に実行され続ける（`git branch` 等のリポジトリ操作がそのまま壊れる）。同梱の hook が、サブシェルへ閉じ込めた形（`(cd dir && command)`）も含めて deny する。対象を絶対パスで書け（git なら `git -C <パス>`）。
