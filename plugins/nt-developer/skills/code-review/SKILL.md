---
name: code-review
description: 超高精度コードレビューをしたい時のみ起動しろ。
argument-hint: "PR番号 or Issue番号 or ブランチ名（省略時は develop との差分）"
effort: low
---

コード差分を **観点別の並列レビュー + 重複統合 + 正誤検証 + 一件ずつ採否決定** でレビューするスキル。**このスキルはコードを一切書き換えるな**（Edit は呼ぶな）。全 finding を 1 行サマリで一覧表示した後、1 件ずつ自動でユーザーに説明し、採用するか取り下げるかをその場で決めてもらい、最後に採用された一覧をまとめて見せて終了する。修正が必要な指摘は、ユーザーが別途 Edit を依頼するか、採用一覧を元に PR コメント文面を作って著者に投げる（後述）。規模は 4 観点 × Claude = **4 並列レビュー** + 1 正誤検証 = 主要 5 agent だ。

4 観点は Security / Bug/Logic / Spec/Range / Consistency。Spec/Range は仕様・ガイドライン準拠に加えて「仕様解釈が一次ソースの原文どおりか、その原文が今回の対象を名指ししているか」の照合と移行元照合を担う。Consistency は Code Quality・Performance・UX エッジケース・Cross-file 整合性・Altitude・Reuse に加えて、対称性（対になる画面・層・項目の欠け）・変更対象を説明している既存記述との照合・変更履歴との整合を担う（観点を増やすより 1 観点の中で広く拾って正誤検証で削るほうが効率が良い）。

本体のチェックアウト直下に `project_notes/legacy-source.md` があるリポジトリでは、移行元コードが **Spec/Range 観点の Claude 側にだけ**渡る（観点は増えないので並列数は 4 のまま）。リプレイス先のリポジトリで、差分が移行元システムの挙動から意図せず外れていないかを見るためだ。設定ファイルには移行元リポジトリのローカル絶対パスと構造の説明を書く。

並列レビューの後、別エージェントが「同じ問題を指してる複数 finding」を意味的にグルーピング（重複統合）し、その後に正誤検証 → スコアリングへ進む。

メインモデルの責務は **冒頭の方針確認 → Workflow 起動 → 結果表示 + 一件ずつ採否決定** だけに絞っている。PR 本文・コメントの取得、URL 抽出、仕様ソースの読み込みはすべて Workflow 側（plugin 内 `workflows/review-orchestrator.js`）で行う。これによりメインモデルが args の中身を全文書き起こす必要がなくなり、Workflow 起動までの時間を大幅に短縮している。

> Workflow tool を使う理由: 子エージェントの完了通知は Workflow 内で Promise の await として直接受領され、`task-notification` キューを経由しないため、Claude Code 2.1.172 以降の通知ルーティングバグ（親が rest 状態のとき子の通知が main にリダイレクトされる症状）の影響を受けない。

## Workflow script の絶対パス

Workflow tool 起動時に渡す `scriptPath`:

!`echo "${CLAUDE_SKILL_DIR}/../../workflows/review-orchestrator.js"`

## cache-io.sh の絶対パス（Workflow の args に渡す）

review-orchestrator.js は CACHE_DIR（`$HOME/.claude/cache/code-review/<run-id>/`）配下への mkdir / write / append / touch / rm / rmdir / chmod を、下記の固定スクリプト経由でしか行わない（個別コマンドだと CACHE_DIR の絶対パス表記が実行ごとに揺れて Bash 許可パターンが確実にマッチしないため）。この絶対パスを `args.CACHE_IO_SCRIPT` として渡せ:

!`echo "${CLAUDE_SKILL_DIR}/../../scripts/cache-io.sh"`

> ⚠️ **初回 permission 追加が必要**: 各自の `~/.claude/settings.json` の `permissions.allow` に `"Bash(bash *cache-io.sh*)"` を追加しないと、CACHE_DIR への書き込み・削除のたびに個別承認を求められる。追加後 Claude Code を完全終了 → 再起動で反映される。詳細は README.md の `/code-review（nt-developer）` 節を参照。

## trim-bulk-data-diffs.sh の絶対パス（Workflow の args に渡す）

review-orchestrator.js は差分取得直後、.csv / .tsv / DDL を含まない .sql の差分本体を要約1行に差し替える固定フィルタを必ず1つ挟む（巨大なマスタデータの中身がそのままレビュー担当に渡ってコンテキストウィンドウ〈一度に読み込める文章量の上限〉を使い切り、並列レビューが全滅するのを防ぐため）。この絶対パスを `args.TRIM_DIFF_SCRIPT` として渡せ:

!`echo "${CLAUDE_SKILL_DIR}/../../scripts/trim-bulk-data-diffs.sh"`

> ⚠️ **初回 permission 追加が必要**: 各自の `~/.claude/settings.json` の `permissions.allow` に `"Bash(bash *trim-bulk-data-diffs.sh*)"` を追加しないと、差分取得のたびに個別承認を求められる。追加後 Claude Code を完全終了 → 再起動で反映される。

## split-diff.sh の絶対パス（Workflow の args に渡す）

レビュー担当（Claude 側）には差分の全文 Read を指示しているが、Read には 1 回の読み取り上限があり、これを超える差分は読めずに失敗する。これを防ぐため、差分が上限を超えるときだけファイル単位に分割して目次を渡す。上限は行数と読み込み量の両方で決まるので、どちらか一方でも超えたら分割する（行数だけで判定すると、1 行あたりが長い差分が閾値内に収まったまま Read に失敗する）。**このスクリプトは差分が空かどうかの判定も兼ねている**（行数・バイト数がどちらも 0 なら、差分の取得自体が失敗したものとしてレビューを中止する）。この絶対パスを `args.SPLIT_DIFF_SCRIPT` として渡せ:

!`echo "${CLAUDE_SKILL_DIR}/../../scripts/split-diff.sh"`

> ⚠️ **初回 permission 追加が必要**: 各自の `~/.claude/settings.json` の `permissions.allow` に `"Bash(bash *split-diff.sh*)"` を追加しないと、差分の分割判定のたびに個別承認を求められる。追加後 Claude Code を完全終了 → 再起動で反映される。

## split-guidelines.sh の絶対パス（Workflow の args に渡す）

ガイドライン（`AGENTS.md` / `docs/*.md` / `CLAUDE.md` の連結）も、Read の上限を超えると規約を読めずに失敗する。差分は行数で判定しているが、こちらはバイト数で判定して行の境界を保ったまま分ける。この絶対パスを `args.SPLIT_GUIDELINES_SCRIPT` として渡せ:

!`echo "${CLAUDE_SKILL_DIR}/../../scripts/split-guidelines.sh"`

> ⚠️ **初回 permission 追加が必要**: 各自の `~/.claude/settings.json` の `permissions.allow` に `"Bash(bash *split-guidelines.sh*)"` を追加しないと、ガイドラインの分割判定のたびに個別承認を求められる。追加後 Claude Code を完全終了 → 再起動で反映される。

## 対象特定（メイン会話）

### 1. 対象の特定

- `$ARGUMENTS` が数字のみ → **まず PR として存在するか確認しろ**。`gh pr view $ARGUMENTS --json number` を実行し:
  - 存在する → `TARGET` = PR 番号（既存動作のまま次の手順へ）
  - 存在しない → **Issue として存在するか確認しろ**。`gh issue view $ARGUMENTS --json number` を実行し:
    - 存在する → **GitHub Issue を実装計画書（仕様書）として渡された**という意味だ。この時点では Workflow をまだ起動していないため run-id 付きの CACHE_DIR は存在しない。**`gh issue view $ARGUMENTS --json body --jq .body` の出力を `<スクラッチパッド>` や `/tmp` へリダイレクトするな**（ユーザー環境のグローバル hook が `/tmp` 配下への書き込みを禁止していることがある）。代わりに `cache-io.sh`（冒頭で取得した絶対パス）経由で run-id 無関係の固定サブディレクトリ `$HOME/.claude/cache/code-review/_issue-docs/` に書け:
      ```
      bash "<cache-io.sh の絶対パス>" mkdir "$HOME/.claude/cache/code-review/_issue-docs"
      gh issue view $ARGUMENTS --json body --jq .body | bash "<cache-io.sh の絶対パス>" write "$HOME/.claude/cache/code-review/_issue-docs/issue-$ARGUMENTS.md"
      ```
      書き出したファイルの絶対パスを `PLAN_DOC_PATH` とせよ（`_issue-docs/` は run-id ディレクトリの外なので、後述の Workflow 側の後始末処理〈CACHE_DIR を丸ごと削除〉には巻き込まれない）。`TARGET` は空文字列にせよ（下記の「実装計画を渡された場合」と同じ扱いに合流させる）
    - 存在しない → `$ARGUMENTS` は PR にも Issue にも該当しないという意味だ。その旨をエラーとして報告し、Workflow を起動せず中止せよ
  - **GitHub は PR と Issue で番号の連番を共有している**（同じリポジトリで PR #123 と Issue #123 が同時に存在することは無い）。そのためこの2段階の存在確認だけで一意に判定できる
- `$ARGUMENTS` が実在するファイルパスで拡張子が `.md`→ **実装計画を渡された**という意味だ。**`plans/` 配下のパスに限らない**（GitHub Issue で実装計画を管理しているリポジトリでは、`nt-developer:plan` が description を `.md` に書き出してそのパスを渡す運用も引き続き使える）。`test -f "$ARGUMENTS" && realpath "$ARGUMENTS"` 等で絶対パスを確定し `PLAN_DOC_PATH` とせよ。`TARGET` は空文字列にせよ（実装計画書をもとにした、コミット前の作業ツリーそのもののレビュー。「実装計画書をローカル md に書く→実装する→コミット前にレビューしてほしい」という使い方に対応するための分岐だ）
- `$ARGUMENTS` が実在するファイルパスで拡張子が `.json`（例: 無人実行スクリプトが保存した `$HOME/.claude/cache/code-review/_auto-results/<repo>-<PR番号>.json`）→ **無人実行済みの保存結果**を渡されたという意味だ。`test -f "$ARGUMENTS" && realpath "$ARGUMENTS"` 等で絶対パスを確定し `RESULT_JSON_PATH` とせよ。`SKIP_WORKFLOW` = true とせよ。この分岐が成立したら、以降の「base ブランチの検出」「PR author の判定」「IS_OWN_CHANGE の確定」は全てスキップし、そのまま「Workflow tool 起動（メイン会話）」節の「保存済み結果から再開する場合」へ進め（Workflow は起動しない）
- `$ARGUMENTS` がブランチ名 → `TARGET` = ブランチ名
- `$ARGUMENTS` が空 → `TARGET` = 空文字列（Workflow が base ブランチとの差分として扱う。base ブランチの決定は次の手順を見ろ）

`PLAN_DOC_PATH` に該当しなかった場合は空文字列のまま扱え。数字のみの `$ARGUMENTS` が Issue として解決された場合に書き出した一時ファイルは、レビューが完走・中止のどちらであっても結果表示後に `bash "<cache-io.sh の絶対パス>" rm "$HOME/.claude/cache/code-review/_issue-docs/issue-$ARGUMENTS.md"` で削除しろ（下記「スキル全体のルール」参照）。

### 2. base ブランチの検出（TARGET が PR 番号でない場合のみ）

`TARGET` が数字（PR 番号）なら、この手順は丸ごとスキップして次に進め（PR の base は `gh` 側が自動で解決する）。

!`git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true`

上記はリモート origin のデフォルトブランチを `origin/<branch>` 形式で返す（例: `origin/master`）。`origin/` を除いた部分を default ブランチとする。空（origin/HEAD 未設定）ならローカルに実在する `main` / `master` / `develop` のうち1つを default とする。

**プロジェクトごとにブランチ運用が異なる**。default ブランチを機械的に決め打ちするな。以下の手順で判定しろ（`nt-developer:pr` の base ブランチ検出と同じロジックだ）:

- `TARGET` がブランチ名として明示指定されている場合、そのブランチ自体が比較対象なのでこの検出は不要。そのブランチ名をそのまま `BASE_BRANCH` とせよ
- `TARGET` が空文字列（develop 差分 or 実装計画書経由のケース）の場合、`git branch -r` で default 以外に長期運用されていそうな統合ブランチ（`develop` / `staging` / `release/*` 等。`feature/*` や個人名ブランチのような一時的なものは除く）が存在するか確認しろ
- default 以外の統合ブランチが1つでも見つかったら、**AskUserQuestion で「このレビューの比較元ブランチはどれか」を必ず確認しろ**（推測で決め打つな）。選択肢には default ブランチと検出した統合ブランチ全部を含めろ。決まったブランチ名を `BASE_BRANCH` とせよ
- default 以外に統合ブランチが無ければ確認不要、そのまま default を `BASE_BRANCH` とせよ

### 4. PR author の判定（PR 番号の場合のみ）

`gh pr view $ARGUMENTS --json author --jq '.author.login'` で PR の author を取得し、自分の GitHub アカウントと一致するか判定しろ。**ここで取得するのは author だけだ。** PR description / コメント / 関連 URL の取得は Workflow 側で行うので、メイン側でこれらの gh コマンドを叩くな（速度低下と args 肥大化の原因になる）。

### 5. IS_OWN_CHANGE の確定（質問はしない）

- **他人の PR** → `IS_OWN_CHANGE` = false
- **自分の変更**（自分の PR / ブランチ名 / 空 / 実装計画書経由）→ `IS_OWN_CHANGE` = true

`MODE` は常に固定値 `"review-only"` を渡せ（Workflow はレビュー・スコアリングまでしか行わないので分岐不要。**このスキルはどのケースでもコードを修正しない**）。`IS_OWN_CHANGE` は個人の review-rules（`~/.claude/review-rules/*.md`）由来の指摘を「必須対応/任意対応」に混ぜるか、独立した「🔵 個人観点」に分離するかの判定にだけ使う（他人の変更では分離、自分の変更では従来どおり混ぜる）。修正するかどうかの方針確認はしない（後述のとおり全件を一件ずつ採否決定するフローに固定されている）。

---

## Workflow tool 起動（メイン会話）

### 保存済み結果から再開する場合（`SKIP_WORKFLOW` = true）

Workflow tool は呼ぶな。代わりに `Read` で `RESULT_JSON_PATH` の中身を読み、その JSON オブジェクトをそのまま以降の `result` として扱え（キー構成は下記の Workflow 戻り値と同一で、`PROJECT_ROOT` フィールドも含む）。

`result.PROJECT_ROOT` を、以降の「結果処理」で finding の妥当性検証のために該当ファイルを Read する際の基準パスとして使え。**現在の cwd（`pwd`）とは無関係に、常にこの `PROJECT_ROOT` を基準にパスを解決しろ**（無人実行で保存された結果は、ユーザーがどのディレクトリでこのセッションを開いていても続きから始められる必要がある）。

読み込みが終わったら、そのまま下記「結果処理（メイン会話）」へ進め。`fail_fast` 判定・初回一覧表示・一件ずつ採否決定・採用一覧の最終表示は、Workflow が完了した通常のケースと全く同じ手順を使う。

### 通常起動（`SKIP_WORKFLOW` でない場合）

Workflow tool を **1 回だけ**呼べ。`scriptPath` には冒頭で取得した絶対パスを渡せ。**`args` には以下 10 フィールドだけを渡せ**（PR 本文・コメントは orchestrator が自分で取得するので、メイン側で詰めるな）:

```json
{
  "TARGET": "<上で確定した TARGET>",
  "MODE": "review-only",
  "PROJECT_ROOT": "<現在の cwd（pwd で取得）>",
  "IS_OWN_CHANGE": "<true | false>",
  "CACHE_IO_SCRIPT": "<上で取得した cache-io.sh の絶対パス>",
  "TRIM_DIFF_SCRIPT": "<上で取得した trim-bulk-data-diffs.sh の絶対パス>",
  "SPLIT_DIFF_SCRIPT": "<上で取得した split-diff.sh の絶対パス>",
  "SPLIT_GUIDELINES_SCRIPT": "<上で取得した split-guidelines.sh の絶対パス>",
  "BASE_BRANCH": "<上で確定した base ブランチ名>",
  "PLAN_DOC_PATH": "<実装計画書の絶対パス。該当なしなら空文字列>"
}
```

Workflow は CACHE_DIR 準備 → PR コンテキスト取得 → レビュールール読み込み → 移行元コード読み込み（`project_notes/legacy-source.md` の有無を判定し、あれば Spec/Range 観点の Claude 側へ移行元コードを渡す）→ 外部連携 MCP 検出（Laravel 公式の laravel-boost が接続済みなら Bug/Logic 観点の Claude 側だけ実データベース参照版〈`nt-developer:reviewer-db`〉に、AWS 公式の aws-iac-mcp-server が接続済みなら Bug/Logic・Security 観点の Claude 側だけ CDK 検証版〈`nt-developer:reviewer-cdk`〉に切替）→ 収集（差分 + ガイドライン + lint + git history）→ 並列レビュー（4）→ 重複統合 → 正誤検証 → スコアリング（finding が 0 件のときはスキップ）→ 後始末（レビューが最後まで通ったときだけ CACHE_DIR を削除する。中止したときは残す）を一気通貫で実行し、最終的に以下の形の JSON を返す:

```json
{
  "fail_fast": null | { "stage": "...", "rows": [...] },
  "target": "...",
  "mode": "review-only",
  "changed_files": ["..."],
  "lint_executed": true | false,
  "lint_method": "Pint / PHPStan ...",
  "spec_failures": [],
  "degraded_engine_failures": [
    { "id": "X-security", "stage": "並列レビュー", "dimension": "Security", "status": "失敗 (JSON parse)", "excerpt": "...", "error": "..." }
  ],
  "findings": [
    {
      "file": "...",
      "line": 12,
      "category": "bug | security | spec | convention | refactor",
      "severity": "MUST | SHOULD",
      "confidence": 0-100,
      "description": "...",
      "evidence": "...",
      "source_agents": ["C-security"],
      "engines": ["claude"],
      "dimension": "security",
      "severity_label": "必須対応"
    }
  ],
  "optional_findings": [
    { "...同じ形だが severity_label は '任意対応' のみ..." }
  ],
  "personal_preference_findings": [
    { "...同じ形だが severity_label は '個人観点' のみ。IS_OWN_CHANGE=false のときだけ入る..." }
  ],
  "agent_summary": { "r1_agents": "4", "r2_agents": "1", "r2_new_findings": 0 }
}
```

`findings` には 🔴 必須対応 だけ入る。🟢 任意対応 は `optional_findings` に、🔵 個人観点（`IS_OWN_CHANGE=false` のとき、個人の review-rules 由来の指摘だけを分離したもの）は `personal_preference_findings` に分離されている（後述の結果処理で常に一覧表示する）。

---

## 結果処理（メイン会話）

### 共通: Workflow から fail_fast が返ったとき（最優先）

`result.fail_fast` が `null` でない場合、観点エージェント・バリデータ・仕様収集のいずれかが deny / hang / 空応答 / JSON parse 不能で失敗したという意味だ。**残りエージェントの結果でレポートを作り直すな。一件ずつ説明して採否を決めるフェーズにも進むな**。

**重要: 推測の原因リストを並べるな**。以下の手順で実態を抜き出して報告しろ。

#### A. 仕様取得段階の失敗（`result.fail_fast.stage` が `'仕様取得'` または `'Google Sheets 事前取得'`）

`result.fail_fast.spec_failures` または `result.spec_failures` に各失敗ソースの `{source, reason}` が入っている。**全件をそのまま中止レポートに転記しろ**（要約するな・件数省略するな）。

加えて、各 `reason` のキーワードから**修復ガイド**を推定して併記しろ:

| reason に含まれるキーワード | 推定原因 | 修復ガイド |
|---|---|---|
| `401` / `unauthorized` / `authentication required` / `not authenticated` | MCP 認証切れ | claude.ai のコネクタ設定で対象 MCP を再認証してください |
| `403` / `forbidden` / `permission denied` | 権限不足 | 対象リソースのアクセス権限を確認してください（共有設定・スペースの参加権限など） |
| `404` / `not found` | リソース不在 | 参照先の URL / ID が古い可能性。最新の URL に更新してください |
| `429` / `rate_limit` / `too many requests` | レート制限 | 3 回リトライしても駄目だったので、数分待ってから再実行してください |
| `timeout` / `connection reset` / `socket hangup` | 一時的不能 | MCP サーバーの一時的不能。少し待って再実行してください |
| `資格情報が無い` / `アクセストークンを更新できなかった` | Google の認証が切れている | google-workspace MCP の `start_google_auth` で一度認証してください（Google Sheets は MCP ではなくこの資格情報を使って直接読みます） |
| `listed_sources に含まれているが touched_sources に記録がない` | 仕様取得エージェントの打ち切り | 仕様取得エージェントが該当ソースを開かずに終わった。再実行で改善する可能性あり |

#### B. それ以外の段階での失敗（CACHE_DIR 準備 / 収集 / 並列レビュー / 重複統合 / 正誤検証）

orchestrator が `fail_fast.rows` の各エントリに `excerpt`（subagent stdout 末尾の要点）を入れて返す。これをそのまま転記して報告しろ。

`stage` が `'収集'` で `id` が `diff` のときは、**差分が空だった**という意味だ（レビューする対象そのものが無い）。原因は2通りで、どちらかを断定するな:

- 比較対象との間に変更が1つも無い（`TARGET` / `BASE_BRANCH` の指定が意図と違う、コミットもファイルの変更も無い状態でレビューを叩いた 等）
- 差分の取得コマンドが失敗した（`git fetch` が通らない、ブランチ名を解決できない、`gh` の認証が切れている 等）

`error` の本文には実際に使われた `TARGET` / `BASE_BRANCH` が入っているので、それを転記した上で両方を確認するよう案内しろ。

**中止したときは作業ディレクトリを削除せず残す**（`result.cache_dir` にパスが入る）。差分・ガイドライン・仕様の保存内容がそこに残っているので、`excerpt` だけで原因が分からないときはこのディレクトリの中を見ろ。中止レポートにもこのパスを書いて、ユーザーが自分で確認できるようにしろ。残ったディレクトリは `nt-setup` の `/setup-code-review-cache-cleanup` で登録した定期実行（launchd / systemd timer）が 1 日ごとに掃除する。

#### 中止報告のフォーマット

仕様取得段階の場合:

```
🚫 {result.fail_fast.stage} 段階で失敗のためレビューを中止しました

## 取得失敗したソース（全 N 件）

| # | source | reason |
|---|---|---|
| 1 | （spec_failures[0].source をそのまま） | （spec_failures[0].reason をそのまま） |
| 2 | ... | ... |

## 修復ガイド

- {推定原因 1}: {修復ガイド 1}
- {推定原因 2}: {修復ガイド 2}

対応: 上記を修復したうえで `/code-review <TARGET>` を再実行してください。
仕様取得が 1 件でも欠けると Spec/Range 観点のレビュー精度が落ちるため部分実行は許可していません。
```

**`review-orchestrator.js` 自体の照合ロジックの不具合が疑われる場合**（reason が「実際には取得できていたはずなのに打ち切り扱いになっている」ように見える等）は、丸ごとの再実行以外に選択肢がある。仕様取得後の照合は Workflow スクリプト側の後処理なので、`review-orchestrator.js` を修正した上で `Workflow({scriptPath, resumeFromRunId: <直前実行の runId>})` を使えば、完了済みの仕様取得エージェントの結果はキャッシュから再利用され、仕様取得からやり直さずに続行できる。

それ以外の段階の場合:

```
🚫 {fail_fast.stage} で失敗のためレビューを中止しました

| ID | 状態 | 抜粋 / 詳細 |
|----|------|------------|
| ... | ... | ... |

対応: 原因を解消したうえで `/code-review <TARGET>` を再実行してください。
部分取得のままレポートを出しても正誤検証・見落とし補完が機能しないので無価値です。
```

「考えられる原因」のような推測リストを並べるな。**ログ・spec_failures を読まずに想像で原因を書くな**。「他のエージェントの結果は揃ったから報告だけは出す」「別バリデータが深く検証したから欠落リスクは限定的」のような正当化もするな。

### 仕様取得の軽微な未解決点（`result.fail_fast` が `null` でも `result.spec_failures` が空でない場合）

`result.spec_failures` は、仕様取得ソースへのアクセス自体は成功したが特定の記述・定義（参照コードの文言解決先等）が見つからなかった軽微なケースを表す。**これはレビューを中止する理由ではない**（アクセス不能な場合は `result.fail_fast` 経由で中止済み）。初回一覧表示の直前に「仕様取得で一部未解決点がありました」の 1 行と、各エントリの `source` / `reason` を短く添えろ。findings の一覧表示自体はそのまま続行しろ。

### 初回一覧表示（他人の PR のレビューも同じフローに従う）

`result.findings`（必須対応）と `result.optional_findings`（任意対応）、`result.personal_preference_findings`（個人観点。`IS_OWN_CHANGE=false` のときだけ入る）が渡される。**初回表示から 🔴🟢🔵 の全件を 1 行サマリで表示しろ**（フォーマット）:

```
📋 レビュー結果

確定 findings: 必須 N 件 / 任意 K 件（+ 個人観点 J 件）

🔴 必須対応（N 件）
1. <file:line> — <description の 1 行サマリ>（信頼度 X）
2. ...

🟢 任意対応（K 件）
1. <file:line> — <description の 1 行サマリ>（信頼度 X）
2. ...

🔵 個人観点（J 件、レビュアー個人の好みとして。対応は任意）
1. <file:line> — <description の 1 行サマリ>（信頼度 X）
2. ...
```

`result.personal_preference_findings` が空の場合、確定 findings の行から「+ 個人観点」を省き、🔵 個人観点 セクション自体も出すな。

各 finding は **1 行サマリのみ**で表示しろ。詳細（evidence / 妥当性検証 / 引用コード）は次の「一件ずつ説明して採否を決める」で展開する。この時点で 1 件あたり 10〜20 行のブロックを一気に展開するな。

### 一件ずつ説明して採否を決める

**🔴🟢🔵 の全件が対象だ**（1 件も除外するな。「どれを見るか」をユーザーに選ばせるな）。番号順に **1 件ずつ**、以下を自動で繰り返せ:

1. **指摘の妥当性そのものを検証しろ**。finding の evidence をそのまま鵜呑みにするな。該当ファイルを Read して実際のコードを確認し、finding が主張する挙動が本当に起きるか裏取りしろ。**コードの裏取りだけで終わらせるな。** finding が「退行」「規約違反」「仕様との矛盾」を主張している場合、一次仕様（CACHE_DIR 配下の PR_CONTEXT）に矛盾しないかも必ず確認しろ。差分の前後比較だけでコードが「バグに見える」ことと、実際に仕様違反であることは別物だ。裏取りの結果「指摘が誤り・的外れ」と分かった場合は、読んだコードや仕様のどの部分がどう食い違うかを明記した上で「この指摘は誤りの可能性が高い」と一言添えろ。**それでも一覧から勝手に消すな。採用するか取り下げるかの最終判断はユーザーに委ねろ**
2. 噛み砕いた説明を書け:
   - 専門用語の羅列で説明を始めるな
   - 「今のコードはこう動く → こういう入力・操作が来るとこうなる → だからこういう問題が起きる → 直すとこう変わる」の順で書け
   - 必要な箇所は該当ファイルを Read して実際のコードを引用しろ
   - **「次の指摘に進みます」のような進行報告の1文だけで済ませて手順3に進むな。** 前の指摘で似た説明をしたから今回は省略してよい、という判断も禁止だ。指摘ごとに対象コードは変わるので、毎回この手順を書き切れ
3. 説明の直後、AskUserQuestion で**この 1 件について**「採用する / 取り下げる」の 2 択を聞け

全件の決定が揃うまで次のフェーズに進むな。

### 採用一覧の最終表示

全件の採否が決まったら、**採用された finding だけ**をまとめて 1 行サマリで再表示しろ（🔴🟢🔵 の内訳件数も添える）。

**ここでスキルを終了しろ。Edit による修正は一切行うな。** 修正が必要な場合は、ユーザーが別途修正を指示するか、下記「PR コメントのドラフトを生成する場合のルール」に従って採用一覧を元に文面を作れ。

## 採用後に実装を依頼された場合

ユーザーが採用一覧確定後に実装（Edit 等）を依頼してきた場合、`IS_OWN_CHANGE` の値でそのまま自動で分岐しろ。改めて聞き直すな。

- `IS_OWN_CHANGE = false`（他人の PR）: 自分がそのブランチへ直接 push / Edit する権限は無い前提で動け。デフォルトは「PR コメントのドラフトを生成する場合のルール」に従ってコメント文面を作成する一択とし、AskUserQuestion は呼ぶな
- `IS_OWN_CHANGE = true`（自分の PR / ブランチ）: デフォルトはそのまま Edit で実装に進める一択とし、AskUserQuestion は呼ぶな

AskUserQuestion を呼んでよいのは、上記のデフォルトだけでは判断できない真に曖昧なケース（複数ブランチ・複数リポジトリにまたがる、書き込み権限の有無が不明、等）に限定しろ。**既に確定・提示済みの事実（著者一致判定など）から自明に導ける分岐は、質問文にその事実を書くだけで終わらせず、そのまま断定して進めろ。事実を提示した上でなお選択肢を委ねるな。**

---

## PR コメントのドラフトを生成する場合のルール

レビュー結果を元に「PR コメント書いて」と頼まれた場合、以下を守れ:

### 冒頭

**労いの 1 行から始めろ。** 「実装ありがとうございます！」「対応ありがとうございます！」「レビューさせていただきました 🙏」のような自然な労い。いきなり指摘に入るな。

### 禁止語

- **評価語**: 「綺麗に統一されている」「読みやすい」「整理されている」「センスが良い」「丁寧な実装」等の評価表現は使うな。レビュアーが実装者を上から評価する構図になる。
- **英語スラング**: `nit` / `LGTM` / `FYI` / `IMO` / `WIP` / `TBD` / `AFAIK` 等を本文に混ぜるな。日本語で書け（「個人的には」等）。
- **読み飛ばしを誘う言い回し**: この PR の中で直さなくてよいことを、緊急度の言葉（「気付いたら直す程度で」「今すぐの対応は不要です」等）や免責の決まり文句にすり替えて表現するな。分類は `nt-developer:pr-comment` の2分類（この PR で直してほしい / この PR では直さなくてよい）に従え。禁止語の一覧も同スキルが正本だ

### 文面の作り方

- 🔴 必須対応 は理由と修正案を簡潔に書け。長い解説を貼るより「現状の挙動 → 問題 → 修正案」の順で 3〜5 行に収めろ
- セクション見出しは分類名をそのまま長文化せず、次の2つに固定しろ。**文言も絵文字も変えるな。**「対応しなくても大丈夫です」のように、読み手が見出しの時点で配下を読み飛ばしてよいと判断できる文言に言い換えるな:
  - `## 🔴 必須対応`
  - `## 🟢 任意対応`
- **見出しで分類を示している以上、各項目の末尾で分類を言い直すな**（「対応は任意です」「この PR で対応する必要はありません」等）。分類を伝える場所は見出しだけに絞れ
- 最後は「以上、ご確認よろしくお願いいたします。」で締めろ（絵文字は付けるな）

### 能動的に提案するとき

ユーザーが指示していないのに「PR コメントドラフト作りますか？」と提案する場合、**前提を 1 行説明してから AskUserQuestion を呼べ**。例:

❌ ダメ: 「コメント文面まとめますか？」（脈絡なし）
✅ OK: 「〇〇さんがレビュー依頼してきていたので、返信用の文面を整える？」（前提を明示）

## スキル全体のルール

- 指摘・レポートはすべて日本語で書け
- 変更差分に対してのみレビューしろ。変更外の既存コードには触れるな
- コードベースの網羅的な検索が必要になったら自分で grep するな。`nt-developer:reviewer`（`subagent_type: nt-developer:reviewer`）に依頼しろ（`general-purpose` / `Explore` は使うな）
- 確信のない断言をするな。Workflow の報告にない情報を足すな
- **このスキルはコードを一切修正するな。** Edit は呼ぶな。指摘の是非を検証する目的でコードは必ず Read しろ。ただし書き換えは行うな。修正が必要な場合はユーザーが別途指示する
- **作業ディレクトリ汚染の禁止**: メイン会話自身も、一件ずつ説明して採否を決める対話中に PROJECT_ROOT 配下にドット隠しファイル（`.foo.vue` / `.bar.diff` 等のコード系拡張子）を作るな。PreToolUse hook で block しているが、迂回もするな。一時ファイルが必要なら `cache-io.sh` 経由で `$HOME/.claude/cache/code-review/` 配下に書け（`$TMPDIR` / `/tmp` への直接書き込みはユーザー環境のグローバル hook で禁止されていることがあるので使うな）
- **Issue 番号から自動生成した一時ファイル**（`$HOME/.claude/cache/code-review/_issue-docs/issue-<番号>.md`）は、レビューが完走・中止のどちらであっても、結果表示（または中止レポート）を出した後に `cache-io.sh` の `rm` 操作で削除しろ
