# CLAUDE.md

README は人間向けの地図（インストール手順）だ。作業のために読む必要はない。

## 運用

- **`plugins/` を触る変更は main 直 push 禁止。** PR にして `gh pr merge <PR番号> --merge` でマージしろ。**self-approve でいい**
- **マージが終わったら必ず本体（`~/pj/nt-tools`）で `git pull origin main` を実行しろ。** マージした本人がその場でやれ（ワークツリーの中にいるなら `git -C ~/pj/nt-tools pull origin main`）。
- **README.md / CLAUDE.md だけの更新は PR を立てず main へ直 push でいい**（version も tag も不要）。**worktree は main をチェックアウトできない**ので、`git worktree add --detach ../nt-tools-docs` で切り出して編集・コミットし、`git push origin HEAD:main` で送れ
- **`plugins/` を触ったら `plugin.json` の version を上げろ。上げる桁は変更の種類で決めろ。** 判断できないときは低い桁（patch）に倒せ。**実装と同じコミットに入れろ。** タグと GitHub Release はマージ時に hook が自動で作る。作られなかったときだけ手動で作れ。
  - **patch**（`x.y.Z`）: 既存の skill / hook / agent の挙動が変わらない変更。文言・誤字・規約の追記、テストの追加、リファクタ
  - **minor**（`x.Y.0`）: skill / hook / agent / workflow の新規追加、既存 skill への引数・分岐の追加、hook の検知範囲の拡大
  - **major**（`X.0.0`）: skill / hook の削除・改名、起動方法や引数の互換を壊す変更、プラグイン間の依存関係の変更
  - **1つの PR で複数の種類が混ざるときは、最も高い桁を1回だけ上げろ。** 桁を2つ同時に動かすな
- **実装計画は GitHub Issue の description で管理する。`plans/` は使わない。** ブランチ名は `issue-<番号>`
- **このプラグインは macOS と Linux / WSL の両方で動くように書け。片方だけで動く書き方をするな。** `stat` は `stat -c ... || stat -f ...` の順でフォールバックさせ、`date` は `date --version` の成否で GNU と BSD を分岐させろ。定期実行は launchd の plist と systemd の unit を両方置け。スクラッチパッドのパスは `/tmp/claude-$(id -u)` のように uid から組み立て、`/private/tmp/claude-501` のような決め打ちを書くな。**鍵括弧を含む日本語から文字を落とすのに `tr` を使うな**（GNU の `tr` はバイト単位で削るため Linux で日本語が壊れる。`sed` を使え）。
- スキル・hook の指示文は**必ず強制命令形**（「必ず〜しろ」「絶対〜するな」）で書け。
- **skill / agent / hook の指示文に実例（過去の失敗談・事故の経緯）を絶対に書くな。規則だけ書け。**
- **オーバードキュメンテーションをするな。** 規則と結論を書け。**理由を添えるなら1文に収めろ。** それで足りないのは、理由が無いと適用範囲・例外・回避策を判断できない規則だけだ。判断が変わらない経緯・背景・失敗談は書くな。同じ内容を言い換えて重ねるな。skill / agent / hook / README / CLAUDE.md の全てに適用しろ。
- **ファイルを変更する作業は必ずワークツリーに切り出してやれ。作りかたは `/nt-developer:git-rules` にある**（このリポジトリで渡す値は `--repo id:<nt-tools の id>` / `--base-branch main` / `--name issue-<番号>` だ）。**本体のフォルダ（`~/pj/nt-tools`）は main の更新・PR のマージ・掃除にだけ使う。** 本体での編集・コミットは hook が自動で止める。
- **例外: `git check-ignore` で無視されるファイルは、本体のフォルダで直接編集していい。**

## 一気通貫で進めろ

着手を承認されたら、**ブランチ作成 → 実装 → コミット → PR → マージ まで確認を取らずに進めろ**（`/commit` のコミット前確認だけは毎回止まる）。**このリポジトリは `/nt-developer:plan` → `implement` → `review` を1セッションで通せ。** **`/code-review` は使うな**（代わりにやることは `/nt-developer:review` の「レビュー skill を使わない運用のリポジトリの場合」節にある）。ブランチ削除は GitHub 側の設定で自動的に行われるので気にするな。

止まって確認を取るのは、ユーザーが範囲を明示したとき・破壊的変更を含むとき・hook や conflict で止まったとき・**作業を複数の Issue / PR に分けようとするとき**だけだ。

**独立した Issue は並行して進めろ。1本ずつ順番に片付けるな。** それぞれ別のワークツリーに切り出せ。**先にマージされたぶんで競合しても rebase するな。後からマージする側が競合を直してマージコミットで解決しろ。**

**サブ Issue に切る判断は必ず承諾を得ろ。** 一気通貫で進めていいのは承認された1つの作業単位の中だけだ。**1つのサブ Issue は1セッションで扱い、次のサブ Issue へは絶対に進むな**（詳細は `/nt-developer:plan` の `references/issue-route.md`「Relationships / Sub-issues」節）。

## 参照している側の確認先

確認のやり方は `/nt-developer:review` の「レビュー skill を使わない運用のリポジトリの場合」節にある。**このリポジトリで見る先はこれだ。**

- **リポジトリの中**: README の一覧／`.claude-plugin/marketplace.json` と各 `plugin.json` の description／各 skill が参照している skill 名・節名／`hooks.json`／`scripts/` の検査が見ているパス／`.githooks/`
  - **skill を消すときは名前で grep しただけで終わるな。** README のプラグイン一覧の用途欄・marketplace.json・plugin.json の description は機能の言い換えで書いてあり、名前検索にかからない
- **リポジトリの外**: グローバルの `~/.claude/CLAUDE.md` と、下の「ローカルにだけ実体があるもの」全部。**見つかったらその場で直し、直したことを報告に書け**（このリポジトリの PR には含められない）

## ローカルにだけ実体があるもの

セットアップ用 skill は `~/.claude/` 配下にスクリプトを置いて launchd（macOS）/ systemd user unit（Linux）に登録する。**実体がリポジトリの中に無いので、変更したときに影響範囲として目に入らない。**

`plugins/nt-setup/` を直したら、下の写しと launchd の plist / systemd の unit を**自分で同じ内容に必ず直せ。**

- **写し**（`~/.claude/statusline.sh`／`~/.claude/scripts/` の `*.sh` と `*-prompt.md`／`~/.claude/otel/` 配下／`~/.claude/settings.json` の `permissions.allow` と `env`）: **テンプレートを直したら、対応する写しがローカルに存在するか必ず確認し、あれば同じ内容に必ず直せ**（報告に書くだけで終わらせるな）。launchd の plist（`~/Library/LaunchAgents/com.claude.*.plist`）と systemd の unit（`~/.config/systemd/user/claude-*.service` / `claude-*.timer`）が起動するコマンド・引数・時刻も同様だ。
- **実行時に読む**（`~/.claude/state/` と `~/.claude/hook-state/` 配下）: プラグインを更新した時点で効く。
- **`~/.claude/review-rules/*.md`**: このリポジトリの `code-style` 系 SKILL.md へのシンボリックリンク。切れると `/code-review` にレビュー規約が渡らないまま黙って動く。

何が登録されているかは、macOS は `ls ~/Library/LaunchAgents/com.claude.*.plist`、Linux は `systemctl --user list-unit-files 'claude-*'` で見ろ。

## agent を書くときの注意

- **MCP ツールの名前は `mcp__plugin_<プラグイン名>_<サーバー名>__<ツール名>` だ。** `mcp__<サーバー名>__*` のようにプラグイン名を省くと**該当ツールが1つもバインドされない**（`scripts/validate-skills.sh` が push 前に検出する）
- **MCP を使う agent の `tools:` には `ToolSearch` も必ず入れろ。** MCP ツールが遅延ロードの環境では、`ToolSearch` を持たない agent に MCP ツールが1つも渡らない
- **`tools:` にはそのタスクで実際に使うツールだけを書け。** 使わないツールを足すな。孫エージェントを起動させたくないなら `Agent` を渡すな。
- **共通の指示を複数の agent へコピーしているとき、片方だけ直すな**（`scripts/validate-skills.sh` が push 前に検査する）

## skill を書くときの注意

- **`claude -p` から無人実行される skill の完了・エラー報告は必ず stdout に出せ。** stderr へ出した内容はどこにも残らない。

## hook を書くときの注意

- **`grep -q` をパイプの終端に置くな。** `pipefail` 下では上流が SIGPIPE で死に、マッチしたのに「しなかった」と判定される。here-string（`grep -qF -- "$key" <<<"$haystack"`）を使え
- **クォートの中身を落とすのに `sed` を使うな。** 同梱の共通ライブラリを使え
- **拒否は終了コード2でなく JSON の `permissionDecision` で返せ。** 理由は `permissionDecisionReason` と `systemMessage` の両方に入れろ（前者だけだと画面に出ない）
- **拒否する hook のテストには「止めてはいけない例」も必ず入れろ。**
- **`lib-*.sh` の中身を各 hook に書き写すな。**
