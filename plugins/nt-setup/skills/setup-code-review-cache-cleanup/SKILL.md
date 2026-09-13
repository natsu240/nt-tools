---
name: setup-code-review-cache-cleanup
description: code-review のキャッシュ自動掃除をセットアップするときに起動しろ。
effort: low
---

# code-review キャッシュ掃除 自動セットアップ

`/code-review` は実行中に `$HOME/.claude/cache/code-review/<run-id>/` 配下に一時ファイル（差分・プロンプト・ログ等）を作る。**正常終了時**は review-orchestrator.js の「後始末」フェーズが自分の実行が作ったディレクトリを名指しで削除するので問題ない。

しかし **異常終了時**（Claude Code 自体の強制終了・workflow の手動停止・マシンクラッシュ等）は「後始末」フェーズが走らず、ディレクトリが残り続ける。これを orchestrator 内のサブエージェントに `find ... -mtime +1 -exec rm -rf` で掃除させると、「年齢・パターンでの一括削除をユーザーが個別に名指ししていない対象に対して行う」という挙動が Claude Code 本体の安全確認の仕組み（behavior safety classifier）に引っかかり、レビュー実行のたびに失敗する（コマンドの書き方を変えても解消しない）。

そのため、この掃除は Claude Code のエージェント経由ではなく、**OS レベルの定期実行（launchd（macOS）/ systemd timer（Linux））**に切り替える。このスキルはその一度きりのセットアップを行う。

**定期実行はマシンごとの仕組みなので、セットアップしたマシンでしか掃除は動かない。**

## 前提条件の確認

`nt-setup` の `references/common-setup-conventions.md`「前提条件の確認」に従え。

## セットアップ手順

### 既存セットアップの確認

`nt-setup` の `references/common-setup-conventions.md`「既存セットアップの確認（共通の型）」に従え。識別子は `nt-code-review-cache-cleanup`、生成ファイルは `~/.claude/scripts/nt-code-review-cache-cleanup.sh` だ。

### ディレクトリの作成

```bash
mkdir -p ~/.claude/scripts
```

### スクリプトの生成

`${CLAUDE_SKILL_DIR}/templates/nt-code-review-cache-cleanup.sh` を読み、そのまま（プレースホルダー置換なし）`~/.claude/scripts/nt-code-review-cache-cleanup.sh` に書き込め。

書き込み後、実行権限を付与しろ:

```bash
chmod +x ~/.claude/scripts/nt-code-review-cache-cleanup.sh
```

### 登録ファイルの生成

`nt-setup` の `references/common-setup-conventions.md`「登録ファイルの生成（共通の型）」に従え。識別子は `nt-code-review-cache-cleanup` だ。`__HOME__` 以外のプレースホルダーは無い。

### 定期実行の登録

**登録前に必ずユーザーに「起動していいですか？」と確認しろ。**

`nt-setup` の `references/common-setup-conventions.md`「定期実行の登録（共通の型）」に従え。登録直後に1回、以降は1日ごと（86400 秒）に実行される。

### テスト実行

```bash
~/.claude/scripts/nt-code-review-cache-cleanup.sh
```

正常終了すれば `~/.claude/scripts/nt-code-review-cache-cleanup.log` に実行結果（削除対象の有無）が記録される。

## 厳守事項

`nt-setup` の `references/common-setup-conventions.md`「厳守事項」に従え。

## アンインストール手順（ユーザーに聞かれた場合のみ案内）

`nt-setup` の `references/common-setup-conventions.md`「アンインストール手順（共通の型）」を識別子 `nt-code-review-cache-cleanup` で案内しろ。
