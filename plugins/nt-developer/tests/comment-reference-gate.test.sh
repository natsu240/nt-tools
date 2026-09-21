#!/usr/bin/env bash
# **検査用のリポジトリを /tmp や $TMPDIR 配下（mktemp -d の既定）へ移すな。** hook がそこを対象外にしているため、何を書いても素通しになりテストが失敗せずに常に通る。

set -uo pipefail
unset GIT_DIR GIT_WORK_TREE

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/gate-comment-reference.sh"
[[ -f "$HOOK" ]] || { echo "gate-comment-reference.sh が見つかりません: $HOOK"; exit 1; }

mkdir -p "$HOME/.cache"
WORK="$(mktemp -d "$HOME/.cache/nt-comment-guard.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PLAIN="$WORK/plain"
CONFIGURED="$WORK/configured"
CONFIGURED_WT="$WORK/configured-issue-1"
mkdir -p "$PLAIN" "$CONFIGURED/project_notes"
git -C "$PLAIN" init -q
git -C "$CONFIGURED" init -q
git -C "$CONFIGURED" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$CONFIGURED" worktree add -q -b issue-1 "$CONFIGURED_WT" >/dev/null 2>&1
printf '%s\n' \
  '{' \
  '  "excludePaths": ["**/validationRules.ts", "docs/*.php"],' \
  '  "extraPatterns": ["V-[0-9]+"]' \
  '}' > "$CONFIGURED/project_notes/comment-guard.json"

failures=0
total=0

judge() {
  local out=$1
  if [[ -z "$out" ]]; then
    printf 'pass'
  elif grep -q '行続くコメントを書こうとしています' <<<"$out"; then
    printf 'deny-multi'
  elif grep -q '"permissionDecision": "deny"' <<<"$out"; then
    printf 'deny'
  else
    printf 'other'
  fi
}

run_case() {
  local expected=$1 label=$2 file=$3 text=$4
  local out actual
  total=$((total + 1))
  out="$(jq -n --arg f "$file" --arg s "$text" '{tool_name: "Edit", tool_input: {file_path: $f, new_string: $s}}' | bash "$HOOK" 2>&1)"
  actual="$(judge "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-8s 実際=%-8s %s\n' "$expected" "$actual" "$label"
    printf '    ファイル: %s\n' "$file"
    printf '    本文: %s\n' "$text"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

run_edit_case() {
  local expected=$1 label=$2 file=$3 old=$4 new=$5
  local out actual
  total=$((total + 1))
  out="$(jq -n --arg f "$file" --arg o "$old" --arg s "$new" '{tool_name: "Edit", tool_input: {file_path: $f, old_string: $o, new_string: $s}}' | bash "$HOOK" 2>&1)"
  actual="$(judge "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-8s 実際=%-8s %s\n' "$expected" "$actual" "$label"
    printf '    変更前: %s\n' "$old"
    printf '    変更後: %s\n' "$new"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

run_approval_case() {
  local expected=$1 label=$2 payload=$3
  local out actual
  total=$((total + 1))
  out="$(printf '%s' "$payload" | HOME="$WORK/home" bash "$HOOK" 2>&1)"
  actual="$(judge "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-8s 実際=%-8s %s\n' "$expected" "$actual" "$label"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

run_raw_case() {
  local expected=$1 label=$2 payload=$3
  local out actual
  total=$((total + 1))
  out="$(printf '%s' "$payload" | bash "$HOOK" 2>&1)"
  actual="$(judge "$out")"
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-8s 実際=%-8s %s\n' "$expected" "$actual" "$label"
    [[ "$actual" == "other" ]] && printf '    出力: %s\n' "$out"
  fi
}

# --- コメントに出典・相互参照 → 拒否 ---
run_case deny "チケット番号" "$PLAIN/src/a.ts" '// DEMO-101 の対応'
run_case deny "チケット番号（docblock の途中行）" "$PLAIN/src/a.php" '/**
 * 入力モーダルの入力値
 *
 * DEMO-101 / DEMO-102。
 */'
run_case deny "GitHub Issue の URL" "$PLAIN/src/a.vue" '// 見た目は https://github.com/natsu240/sample-app/issues/12 に合わせる'
run_case deny "Google Sheets の URL" "$PLAIN/src/a.ts" '// 詳細は https://docs.google.com/spreadsheets/d/abc/edit を見ろ'
run_case deny "GitHub PR の URL" "$PLAIN/src/a.scss" '/* https://github.com/natsu240/sample-app/pull/34 */'
run_case deny "QA 番号" "$PLAIN/src/a.py" '# QA #12 で報告された挙動に合わせる'
run_case deny "バリデーション値の転記" "$PLAIN/src/a.php" '// バックエンドの max:255 に合わせる'
run_case deny "データベース定義の転記" "$PLAIN/src/a.ts" '// カラムは varchar なので長さに注意'
run_case deny "SQL の行コメント" "$PLAIN/db/a.sql" '-- varchar(255) で作ってある'
run_case deny "シェルスクリプトのコメント" "$PLAIN/bin/a.sh" '# varchar(255) に合わせて切り詰める'

# --- 過去の経緯・背景の記述 → 拒否 ---
run_case deny "以前の実装との対比" "$PLAIN/bin/a.sh" '# 以前は sed で落としていたが、入れ子のクォートで境界がずれる'
run_case deny "過去の運用判断" "$PLAIN/bin/a.sh" '# 当初は ask にしていたが、実運用上不要と分かったので deny にした'
run_case deny "かつての挙動" "$PLAIN/src/a.ts" '// かつては同期処理だったので待ち合わせが要らなかった'
run_case deny "旧実装への言及" "$PLAIN/src/a.php" '// 旧実装のロジックをそのまま移した'
run_case deny "旧仕様への言及" "$PLAIN/src/a.vue" '// 旧仕様では1画面に詰め込んでいた'
run_case deny "旧: の形" "$PLAIN/src/a.scss" '/* 旧: padding 40px のせいでバーが押し込まれていた */'
run_case deny "旧: の形（全角コロン）" "$PLAIN/src/a.scss" '/* 旧：padding 40px */'
run_case deny "将来課題" "$PLAIN/src/a.php" '// マスタ未整備のため兼用する（将来課題）'
run_case deny "docblock の途中行に経緯" "$PLAIN/src/a.php" '/**
 * その他条件本文を PDF 用 HTML に整形する。
 * 以前は Blade 側で処理していた。
 */'

# --- 止めてはいけないもの → 素通し ---
run_case pass "日数の比較（以前の）" "$PLAIN/bin/b.sh" '# 更新が3日以前のファイルをまとめて掃除する'
run_case pass "順序の説明（以前に）" "$PLAIN/src/b.ts" '// この行以前に初期化が終わっている前提'
run_case pass "元データの意味" "$PLAIN/bin/b.sh" '# 元々のパスへ戻してから再実行する'
run_case pass "技術根拠（過去形を含むが経緯ではない）" "$PLAIN/bin/b.sh" '# 相対パスのリンクは、切れていると本来どこを指していたか判定できないため対象から外す'
run_case pass "技術根拠（ライブラリの挙動）" "$PLAIN/bin/b.sh" '# grep をパイプの終端に置くと pipefail 下で上流が SIGPIPE で死ぬため here-string で渡す'
run_case pass "現在の制約を語る説明" "$PLAIN/src/b.php" '// Blade の {{ }} は改行が消えるため nl2br で <br> 化してから流し込む'
run_case pass "将来の可能性（課題ではない）" "$PLAIN/src/b.ts" '// 将来的に件数が増えてもページングで対応できる'
run_case pass "規格名（SHA-256）" "$PLAIN/src/a.ts" '// SHA-256 でハッシュ化する'
run_case pass "規格名（RFC-7231）" "$PLAIN/src/a.ts" '// RFC-7231 の定義に従う'
run_case pass "規格名（ISO-8601）" "$PLAIN/src/a.php" '// ISO-8601 形式で保存する'
run_case pass "脆弱性番号（CVE-2024-1234）" "$PLAIN/src/a.ts" '// CVE-2024-1234 の対策で追加'
run_case pass "文字コード（UTF-8）" "$PLAIN/src/a.php" '// UTF-8 で読み込む'
run_case pass "コメントのない普通のコード" "$PLAIN/src/a.ts" 'const limit = 255;'
run_case pass "コメント以外の行にチケット番号が出るだけ" "$PLAIN/src/a.ts" 'const ticketUrl = "DEMO-101";'
run_case pass "実装契約を書いた普通のコメント" "$PLAIN/src/a.ts" '// link.click() が例外を投げても revokeObjectURL がスキップされないよう try/finally で保護'
run_case pass "Markdown（見出しをコメントとして拾わない）" "$PLAIN/docs/a.md" '# 以前は別の実装だった'
run_case pass "対象外の拡張子" "$PLAIN/docs/a.txt" '# 以前は別の実装だった'
run_case pass "一時ディレクトリ配下" "/tmp/scratch/a.ts" '// 以前は別の実装だった'

# --- Write / MultiEdit も対象 ---
run_raw_case deny "Write の content" "$(jq -nc --arg f "$PLAIN/src/b.ts" '{tool_name: "Write", tool_input: {file_path: $f, content: "// 以前は別の実装だった\nconst a = 1;"}}')"
run_raw_case deny "MultiEdit の2つ目の edits" "$(jq -nc --arg f "$PLAIN/src/b.ts" '{tool_name: "MultiEdit", tool_input: {file_path: $f, edits: [{new_string: "const a = 1;"}, {new_string: "// 以前は別の実装だった"}]}}')"
run_raw_case pass "対象外のツール" "$(jq -nc --arg f "$PLAIN/src/b.ts" '{tool_name: "Read", tool_input: {file_path: $f, new_string: "// 以前は別の実装だった"}}')"

# --- プロジェクト側の設定 ---
run_case pass "追加パターンを設定していないリポジトリでは V-1 を止めない" "$PLAIN/src/c.ts" '// V-1 の検証ルール'
run_case deny "extraPatterns に足した V-1 を止める" "$CONFIGURED/src/c.ts" '// V-1 の検証ルール'
run_case pass "excludePaths のファイルは検査しない" "$CONFIGURED/src/common/validationRules.ts" '// V-1 の検証ルール'
run_case pass "excludePaths のファイルは既定パターンも検査しない" "$CONFIGURED/src/common/validationRules.ts" '// 以前は別の実装だった'
run_case pass "excludePaths（階層を固定した書き方）" "$CONFIGURED/docs/a.php" '// 以前は別の実装だった'
run_case deny "excludePaths に合致しないファイルは止める" "$CONFIGURED/src/other.ts" '// 以前は別の実装だった'
run_case deny "ワークツリーでも本体の extraPatterns を使う" "$CONFIGURED_WT/src/c.ts" '// V-1 の検証ルール'
run_case pass "ワークツリーでも本体の excludePaths を使う" "$CONFIGURED_WT/src/common/validationRules.ts" '// V-1 の検証ルール'

# --- 1文を途中で折り返したら拒否する ---
run_case deny "1文が2行に折り返されている" "$PLAIN/bin/wrap.sh" '# 変数が空だったときに意図しない場所を消しかねない形になるため、
# 本体の確認に到達する前にここで止める。'
run_case deny "3行に折り返されている" "$PLAIN/src/wrap.ts" '// Read の上限はバイト数で決まり、
// 日本語が大半なので文字数でも代用できず、
// awk は LC_ALL=C で呼んでいる。'

# --- 折り返しに見えるが止めてはいけないもの ---
run_case pass "句点で終わる行が続くだけ" "$PLAIN/bin/ok.sh" '# 1文目はここで終わる。
# 2文目もここで終わる。'
run_case pass "コロンで終わる導入行に続く箇条書き" "$PLAIN/bin/list.sh" '# 検出できないもの:
# - eval に押し込まれたコマンド
# - 変数で渡された名前'
run_case pass "インデントされた例示コード" "$PLAIN/bin/example.sh" '# 次の形では境界がずれる:
#
#   echo "1) 結果: $(req "git add x")"'
run_case pass "shellcheck ディレクティブ" "$PLAIN/bin/sc.sh" '# クォートの中身を落としてから判定する。
# shellcheck source=lib-strip-quoted.sh'
run_case pass "空コメント行で区切られている" "$PLAIN/bin/blank.sh" '# 1文目はここで終わる。
#
# 2文目もここで終わる。'
run_case pass "コメントが1行だけ" "$PLAIN/bin/single.sh" '# 折り返す相手がいない'
run_case pass "句点無しの3行docblock（説明が1行に収まっている）" "$PLAIN/src/wrap2.php" '/**
 * 入力モーダルの入力値を対象レコード単位で1行に保存し初回表示に使う
 */'
run_case pass "型注釈だけのparamタグが連続する" "$PLAIN/src/wrap3.php" '/**
 * @param  list<array{fee: int, billing_cycle_code: int|null}>  $otherFees
 * @param  int  $itemId
 */'
run_case pass "罫線が長いセクション区切り" "$PLAIN/bin/section.sh" $'a=1\n# ------------------------------------------------------------\n# まとまりの見出し\n# ------------------------------------------------------------\nb=2'
run_case pass "コメント以外の行が続く" "$PLAIN/bin/code2.sh" '# 折り返す相手がいない
a=1'

# --- 禁止語を含むコメントは行数に関わらず拒否する ---
run_case deny "長いうえに禁止語を含むなら deny を優先する" "$PLAIN/bin/both.sh" '# 1行目
# 2行目3行目以前は sed でやっていた5行目6行目'

# --- 2行以上続くコメントのまとまりを足す編集は拒否する ---
run_edit_case deny-multi "if 文をそのまま日本語にした2行" "$PLAIN/bin/add1.sh" 'rc=$?' '# permissionDecision が deny なら "block"、それ以外は "pass"。
# 終了コードが 0 以外なら "rc=N" を返して落とす。拒否を JSON で返す方式では、非ゼロ終了はスクリプトの異常終了だけを意味する。
rc=$?'
run_edit_case deny-multi "既存1行に1行足す" "$PLAIN/bin/add3.sh" '# 既存の説明。
a=1' '# 既存の説明。
# 足した説明。
a=1'
run_edit_case deny-multi "docblock に1行足す" "$PLAIN/src/add.php" '/**
 * 入力モーダルの入力値
 */' '/**
 * 入力モーダルの入力値
 * 対象レコードごとに1行だけ持つ
 */'
run_edit_case deny-multi "セクション見出しの下に2行足す" "$PLAIN/bin/section2.sh" $'# --------\n# まとまりの見出し\n# --------\na=1' $'# --------\n# まとまりの見出し\n# --------\n# 足した説明。\n# もう1行の説明。\na=1'
run_raw_case deny-multi "MultiEdit の2つ目の edits で2行足す" "$(jq -nc --arg f "$PLAIN/bin/add4.sh" '{tool_name: "MultiEdit", tool_input: {file_path: $f, edits: [{old_string: "a=1", new_string: "a=1"}, {old_string: "b=2", new_string: "# 足した説明。\n# もう1行の説明。\nb=2"}]}}')"

# --- 1行のコメントは足しても止めない ---
run_edit_case pass "何も無いところに1行足す" "$PLAIN/bin/add2.sh" 'set -euo pipefail' '# 拒否を permissionDecision: deny の JSON で返す hook 群の検査。
set -euo pipefail'
run_edit_case pass "離れた2箇所に1行ずつ足す" "$PLAIN/bin/add5.sh" $'a=1\nb=2' $'# 1つ目の説明。\na=1\n# 2つ目の説明。\nb=2'
run_edit_case pass "セクション見出しの下に1行足す" "$PLAIN/bin/section2.sh" $'# --------\n# まとまりの見出し\n# --------\na=1' $'# --------\n# まとまりの見出し\n# --------\n# 足した説明。\na=1'
run_edit_case pass "罫線の下に1行足す" "$PLAIN/bin/section3.sh" $'a=1' $'# --------\n# 足した説明。\na=1'
run_edit_case pass "説明1行とタグだけの docblock を足す" "$PLAIN/src/add2.php" 'private function values(): array
{' '/**
 * 表示用の値を組み立てる。
 *
 * @return list<string>
 */
private function values(): array
{'
run_edit_case pass "既にある2行のまとまりを含んだまま編集する" "$PLAIN/bin/keep9.sh" '# 1文目。
# 2文目。
a=1' '# 1文目。
# 2文目。
a=1
b=2'
run_edit_case pass "PHPStan の型情報 docblock を1行足す" "$PLAIN/src/add.php" 'private function values(): array
{' '/**
 * @return list<string>
 */
private function values(): array
{'

# --- まとまりが2行に達しない編集は止めない ---
run_edit_case pass "罫線のセクション区切りだけ増やす" "$PLAIN/bin/keep1.sh" '# 既存の説明。
a=1' '# 既存の説明。

# --- 区切り ---
a=1'
run_edit_case pass "セクション区切りを2つに分ける" "$PLAIN/bin/section1.sh" $'# --------\n# 既存のまとまり\n# --------\na=1\n# 説明。\nb=2' $'# --------\n# 既存のまとまり\n# --------\na=1\n\n# --------\n# 足したまとまり\n# --------\n# 説明。\nb=2'
run_edit_case pass "ツール向けディレクティブだけ増やす" "$PLAIN/bin/keep2.sh" '# 既存の説明。
a=1' '# 既存の説明。
# shellcheck disable=SC2053
a=1'
run_edit_case pass "空コメント行だけ増やす" "$PLAIN/bin/keep3.sh" '# 1文目。
# 2文目。' '# 1文目。
#
# 2文目。'
run_edit_case pass "コメントを減らす" "$PLAIN/bin/keep4.sh" '# 1文目。
# 2文目。
a=1' '# 1文目。
a=1'
run_edit_case pass "コメントの本文だけ書き換える" "$PLAIN/bin/keep5.sh" '# 古い説明。
a=1' '# 新しい説明。
a=1'
run_edit_case pass "コードだけ増やす" "$PLAIN/bin/keep6.sh" 'a=1' 'a=1
b=2'
run_edit_case pass "ヒアドキュメントで書き出すスクリプトの shebang" "$PLAIN/bin/keep8.sh" 'a=1' $'cat >"$FAKE" <<\'F\'\n#!/usr/bin/env bash\necho 0\nF\na=1'
run_edit_case pass "コメントを1行足して2行消す" "$PLAIN/bin/keep7.sh" '# 1文目。
# 2文目。
# 3文目。
a=1' '# 別の説明。
a=1'

# --- ユーザーへ要否を確認したコメントは2度目に通す ---
APPROVAL_SID="approval-test"
APPROVAL_PAYLOAD="$(jq -nc --arg f "$PLAIN/bin/approve.sh" --arg sid "$APPROVAL_SID" '{session_id: $sid, tool_name: "Edit", tool_input: {file_path: $f, old_string: "a=1", new_string: "# 足した説明。\n# もう1行の説明。\na=1"}}')"
run_approval_case deny-multi "1度目は止める" "$APPROVAL_PAYLOAD"
run_approval_case pass "同じコメントの2度目は通す" "$APPROVAL_PAYLOAD"
run_approval_case deny-multi "別のコメントは改めて止める" "$(jq -nc --arg f "$PLAIN/bin/approve.sh" --arg sid "$APPROVAL_SID" '{session_id: $sid, tool_name: "Edit", tool_input: {file_path: $f, old_string: "a=1", new_string: "# 別の説明。\n# さらに別の説明。\na=1"}}')"
run_approval_case deny-multi "同じコメントでも別ファイルなら止める" "$(jq -nc --arg f "$PLAIN/bin/approve2.sh" --arg sid "$APPROVAL_SID" '{session_id: $sid, tool_name: "Edit", tool_input: {file_path: $f, old_string: "a=1", new_string: "# 足した説明。\n# もう1行の説明。\na=1"}}')"
run_approval_case deny-multi "別セッションでは通さない" "$(jq -nc --arg f "$PLAIN/bin/approve.sh" '{session_id: "approval-test-other", tool_name: "Edit", tool_input: {file_path: $f, old_string: "a=1", new_string: "# 足した説明。\n# もう1行の説明。\na=1"}}')"
run_raw_case deny-multi "session_id が無ければ2度目も止める" "$(jq -nc --arg f "$PLAIN/bin/approve3.sh" '{tool_name: "Edit", tool_input: {file_path: $f, old_string: "a=1", new_string: "# 足した説明。\n# もう1行の説明。\na=1"}}')"
run_raw_case deny-multi "session_id が無ければ何度でも止める" "$(jq -nc --arg f "$PLAIN/bin/approve3.sh" '{tool_name: "Edit", tool_input: {file_path: $f, old_string: "a=1", new_string: "# 足した説明。\n# もう1行の説明。\na=1"}}')"

# --- Write は新規作成も対象にする ---
mkdir -p "$PLAIN/bin"
printf '%s\n' '# 既存の説明。' 'a=1' > "$PLAIN/bin/overwrite.sh"
run_raw_case deny-multi "既存ファイルの上書きで2行になる" "$(jq -nc --arg f "$PLAIN/bin/overwrite.sh" '{tool_name: "Write", tool_input: {file_path: $f, content: "# 既存の説明。\n# 足した説明。\na=1\n"}}')"
run_raw_case pass "既存ファイルの上書きで増えない" "$(jq -nc --arg f "$PLAIN/bin/overwrite.sh" '{tool_name: "Write", tool_input: {file_path: $f, content: "# 書き換えた説明。\na=1\nb=2\n"}}')"
run_raw_case deny-multi "新規作成の2行コメントも止める" "$(jq -nc --arg f "$PLAIN/bin/brand-new.sh" '{tool_name: "Write", tool_input: {file_path: $f, content: "# 新規ファイルの説明。\n# もう1行の説明。\na=1\n"}}')"
run_raw_case pass "新規作成の1行コメントは通す" "$(jq -nc --arg f "$PLAIN/bin/brand-new2.sh" '{tool_name: "Write", tool_input: {file_path: $f, content: "# 新規ファイルの説明。\na=1\n"}}')"

# --- 設定ファイルが壊れていたら検査ごと諦める（編集を止めない） ---
printf '%s\n' '{ こわれた JSON' > "$CONFIGURED/project_notes/comment-guard.json"
run_case pass "設定ファイルが読めないときは止めない" "$CONFIGURED/src/other.ts" '// 以前は別の実装だった'

if [[ "$failures" -gt 0 ]]; then
  printf '\ncomment-reference-gate: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'comment-reference-gate: %d 件すべて期待どおり\n' "$total"
