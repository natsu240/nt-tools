---
name: setup-version-upgrade-notify
description: 新バージョンのDiscord通知をセットアップするときに起動しろ。
effort: low
---

# Claude Code バージョンアップ通知 セットアップ

Claude Code（`@anthropic-ai/claude-code`）の新バージョンを CHANGELOG.md で定期的に見に行き、**前回と違うバージョンが出ていたときだけ** その内容を要約して Discord へ通知する仕組みを、launchd（macOS）または systemd timer（Linux）に登録する。

## 前提として理解しておくこと

- **新着が無いときはトークンを消費しない。** CHANGELOG.md 先頭の見出しを1回取って、記録済みのバージョンと同じなら claude を起動せずに終わる
- **監視対象は npm registry のバージョン番号ではなく CHANGELOG.md にしている。** npm 公開のほうが CHANGELOG.md への追記より早く、npm registry のバージョン番号を監視対象にすると CHANGELOG が未追記のまま通知してしまう問題があったため
- **Discord 側は Bot を作らない。** Discord Developer Portal に「Webhooks... do not require a bot user or authentication to use」と明記されている（`https://docs.discord.com/developers/resources/webhook`、2026-08-14 確認）。サーバー設定の「連携サービス」画面から Webhook を1個発行するだけで済む
- **他のリポジトリのリリースを直接受け取る仕組みと同様、npm の新バージョンを push で受け取る仕組みも無い。** こちらから定期的に見に行くしかない
- **初回セットアップ時（登録直後に1回動く）も通知する。** 過去のバージョンを遡って全部送るのではなく、その時点の最新バージョン1件だけを要約して送る（セットアップの動作確認を兼ねる）
- **Discord への送信はシェルスクリプトが1回だけ行う。** claude の仕事は要約を `~/.claude/state/version-upgrade-notify/summary.md` へ書き出すところまでだ。送信を claude に任せると同じ内容が複数回届きうるため任せない。Webhook URL も claude へ渡らない
- **要約は日本語で届く。** 機能名・フラグ名・設定キーだけ原文のまま残す
- **要約に3回続けて失敗したら、そのバージョンは諦めて「本文を送れなかった」旨だけを Discord へ送る。** 要約は claude を起動して作るため認証切れ等で失敗しうるが、この通知は curl だけで送るので claude が起動できない状態でも届く

## 前提条件の確認

`nt-setup` の `references/common-setup-conventions.md`「前提条件の確認」に加え、実行前に以下を確認しろ。1つでも欠けていたらユーザーに案内して中断しろ。

- **`jq`** — `which jq`。無ければ導入を案内しろ（macOS は `brew install jq`、Linux は `sudo apt install jq` 等）
- **`curl`** — `which curl`

## ユーザーから設定情報を聞け

`AskUserQuestion` で以下を聞け。**推測で埋めるな。**

- **Discord の Webhook URL**。まだ発行していない場合は、以下の手順を案内しろ（Bot 作成は不要だと明示しろ）:
  1. 通知したい Discord サーバーの通知先チャンネルを開く
  2. チャンネル設定（歯車アイコン）→「連携サービス」タブ →「ウェブフックを作成」
  3. 名前を付けて「ウェブフック URL をコピー」
- **確認する間隔（秒）**。既定の提案は `300`（5分）。新着が無ければトークンを消費しないので、短くしても実害は無い

## 既存セットアップの確認

`nt-setup` の `references/common-setup-conventions.md`「既存セットアップの確認（共通の型）」に従え。識別子は `version-upgrade-notify`、生成ファイルは以下だ。

- `~/.claude/scripts/version-upgrade-notify.sh`
- `~/.claude/scripts/version-upgrade-notify-prompt.md`
- `~/.claude/version-upgrade-notify.json`

## セットアップ手順

### ディレクトリの作成

```bash
mkdir -p ~/.claude/scripts ~/.claude/state/version-upgrade-notify
```

### スクリプトと指示文の配置

`${CLAUDE_SKILL_DIR}/templates/version-upgrade-notify.sh` を `~/.claude/scripts/version-upgrade-notify.sh` へ、`${CLAUDE_SKILL_DIR}/templates/version-upgrade-notify-prompt.md` を `~/.claude/scripts/version-upgrade-notify-prompt.md` へコピーし、スクリプトに実行権限を付けろ。

```bash
chmod +x ~/.claude/scripts/version-upgrade-notify.sh
```

どちらもプレースホルダーの置換は不要だ（設定値は次の設定ファイルから読む）。**プラグインの配置場所から直接実行させるな。** プラグインを更新するとバージョンのディレクトリが変わり、定期実行の参照先が壊れる。

### 設定ファイルの生成

聞き取った Webhook URL で `~/.claude/version-upgrade-notify.json` を作れ。

```json
{
  "discord_webhook_url": "<聞き取った Webhook URL>"
}
```

このファイルが無い環境ではスクリプトは何もせず終了する。**Webhook URL は機密情報なので、会話に貼り出す以外の場所（コミット・ログ等）に書くな。**

### 登録ファイルの生成

`nt-setup` の `references/common-setup-conventions.md`「登録ファイルの生成（共通の型）」に従え。識別子は `version-upgrade-notify` だ。`__INTERVAL_SECONDS__` はユーザーが指定した間隔（秒）で置換しろ。

### 動作確認（定期実行を登録する前にやれ）

claude を起動しない試し実行で、設定の読み込みから指示文の組み立てまでが通ることを確かめろ。

```bash
VERSION_NOTIFY_DRY_RUN=1 bash ~/.claude/scripts/version-upgrade-notify.sh
ls -t ~/.claude/state/version-upgrade-notify/logs/ | head -1
```

ログに「新着を検知した」と「試し実行のため claude は起動しない」が出ていれば組み立ては通っている。**試し実行では記録を進めないので、この後の本番実行でもう一度同じバージョンが処理される。**

### 定期実行の登録

**登録する前にユーザーへ確認を取れ。** 登録した時点で即座に1回動き、その時点の最新バージョンの要約が実際に Discord へ送られる。

`nt-setup` の `references/common-setup-conventions.md`「定期実行の登録（共通の型）」に従え。

登録後、指定したチャンネルにメッセージが届いたか確認するようユーザーに伝えろ。

## 動いているかの確認方法（ユーザーに伝えろ）

| 見る場所 | 内容 |
|---|---|
| `~/.claude/state/version-upgrade-notify/state.json` | 最後に見たバージョン・確認時刻・連続失敗の回数 |
| `~/.claude/state/version-upgrade-notify/logs/` | 実際に処理したときだけ1ファイル残る。新着が無かった回はログを作らない（30日で消える） |
| `~/.claude/scripts/version-upgrade-notify-stderr.log` | launchd / systemd 側のエラー |

## 厳守事項

`nt-setup` の `references/common-setup-conventions.md`「厳守事項」に加え、以下を守れ（登録の確認では、登録直後に1回動き実際に Discord へメッセージが送られる点も併せて伝えろ）。

- **Discord Webhook URL を推測で決めるな。** 必ず聞け
- **Webhook URL をログ・コミット・会話以外の場所に書き残すな**

## アンインストール手順（ユーザーに聞かれた場合のみ案内）

`nt-setup` の `references/common-setup-conventions.md`「アンインストール手順（共通の型）」を識別子 `version-upgrade-notify` で案内し、加えて以下も案内しろ。

```bash
rm ~/.claude/version-upgrade-notify.json
rm -rf ~/.claude/state/version-upgrade-notify
```
