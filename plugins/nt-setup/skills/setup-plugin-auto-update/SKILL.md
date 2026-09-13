---
name: setup-plugin-auto-update
description: プラグインの自動更新をセットアップするときに起動しろ。
effort: low
---

# nt-tools プラグイン自動更新 セットアップ

このスキルは、**Claude Code を起動していない間も** nt-tools のインストール済みプラグイン本体を定期的に最新化する仕組みを、launchd（macOS）または systemd timer（Linux）でセットアップする。

## 前提として理解しておくこと

- `claude plugin marketplace update` は marketplace の**カタログ（利用可能なバージョン情報）**を更新するだけで、インストール済みプラグイン**本体（実行コード）**は更新しない
- インストール済みプラグイン本体を実際に新バージョンへ切り替えるのは `claude plugin update <plugin>` であり、これは明示実行が必要
- `claude plugin update` は公式ヘルプに "restart required to apply" と明記されているが、これは「ディスク上のプラグイン本体を更新しただけでは起動中セッションに自動反映されない」という意味である。実際には公式コマンド `/reload-plugins` をそのセッション内で実行すれば、再起動せずにディスク上の変更を反映できる（読み込まれる MCP ツール構成が変わりプロンプトキャッシュが無効化される場合は警告が出てデフォルトでスキップされるため、その場合は `/reload-plugins --force` が必要）。このスキルの自動更新自体はディスク上のプラグイン本体を最新化するだけで、起動中セッションへの反映（`/reload-plugins` の実行）まではやってくれない。なお `/reload-plugins` で切り替わるのは hook・MCP サーバー・LSP サーバーまでで、monitor だけはセッションの再起動が要る
- **Claude Code 自身にも marketplace ごとの自動更新がある**（`/plugin` の Marketplaces でオンにすると `~/.claude/plugins/known_marketplaces.json` に `autoUpdate: true` が入る）。これはカタログとインストール済みプラグイン本体の両方を更新するが、**走るのはセッションが始まったあとだけだ**。Claude Code を1つも起動していない間は更新されない
- **このスキルの定期実行はその穴を埋めるものだ。** Claude Code を起動していない間も一定間隔で更新し、次に起動した時点で最新が載っている状態にする。公式の自動更新と併用して構わない
- **`claude plugin update` は古いバージョンのキャッシュディレクトリ（`~/.claude/plugins/cache/nt-tools/<プラグイン名>/<バージョン>/`）をその場で削除しない。** Claude Code は旧バージョンを orphan として印を付け、およそ14日後のバックグラウンド掃除で消す仕様であり、プラグインが1つも入っていない状態では掃除自体が走らない。この待ち時間を埋めるため、このスキルのスクリプト自身が、`~/.claude/plugins/installed_plugins.json` の `installPath`（現在有効なバージョン）と一致せず、かつ `.in_use`（Claude Code がセッション開始時にバージョンディレクトリ配下へ置く生存 pid マーカー）も残っていないディレクトリを削除する。**`installPath` の取得に失敗した場合は削除処理ごと中止する**（使用中のパスが1件も取れない状態で先へ進むと「全部が削除対象」と解釈され、現在使っているバージョンまで消えるため）

## 前提条件の確認

`nt-setup` の `references/common-setup-conventions.md`「前提条件の確認」に加え、実行前に以下を確認しろ。1つでも欠けていたらユーザーに案内して中断しろ。

- **`jq` がインストールされている**（インストール済みプラグイン一覧の JSON パースに必要。無いと marketplace update だけが走り plugin update はスキップされる）— `which jq` で確認。無ければ導入を案内しろ（macOS は `brew install jq`、Linux は `sudo apt install jq` 等）

## ユーザーから設定情報を聞け

`AskUserQuestion` で以下を聞け：

- **更新チェックの間隔**（秒）。デフォルト提案は `10`。marketplace update は git fetch 相当、plugin update はバージョン確認+ファイル同期のみで、どちらもモデル呼び出しを含まずトークン消費ゼロかつ軽量。`.in_use` マーカーで稼働中セッションのバージョンを保護しているため、高頻度に回しても実害は無い。ユーザーが変更したい場合は自由な秒数を受け付けろ

## 既存セットアップの確認

`nt-setup` の `references/common-setup-conventions.md`「既存セットアップの確認（共通の型）」に従え。識別子は `nt-plugin-auto-update`、生成ファイルは `~/.claude/scripts/nt-plugin-auto-update.sh` だ。

## セットアップ手順

### ディレクトリの作成

```bash
mkdir -p ~/.claude/scripts
```

### スクリプトの生成

`${CLAUDE_SKILL_DIR}/templates/nt-plugin-auto-update.sh` を `~/.claude/scripts/nt-plugin-auto-update.sh` にコピーし、実行権限を付与しろ：

```bash
chmod +x ~/.claude/scripts/nt-plugin-auto-update.sh
```

このスクリプトにプレースホルダーは無い（ユーザーごとの設定値を持たないため）。

### 登録ファイルの生成

`nt-setup` の `references/common-setup-conventions.md`「登録ファイルの生成（共通の型）」に従え。識別子は `nt-plugin-auto-update` だ。`__INTERVAL_SECONDS__` はユーザーが指定した更新チェック間隔（秒）で置換しろ。

### 定期実行の登録

`nt-setup` の `references/common-setup-conventions.md`「定期実行の登録（共通の型）」に従え。

### テスト実行

```bash
~/.claude/scripts/nt-plugin-auto-update.sh
claude plugin list --json | jq -r '.[] | select(.id | endswith("@nt-tools")) | "\(.id) \(.version)"'
```

各プラグインの version が marketplace 側の最新版と一致していれば成功。

## 厳守事項

`nt-setup` の `references/common-setup-conventions.md`「厳守事項」に加え、以下を守れ。

- **「このスキルの自動更新だけでは起動中セッションに反映されない」ことを必ず伝えろ**。同一セッション中に反映したい場合は、そのセッション内で `/reload-plugins`（MCP ツール構成が変わる場合は `/reload-plugins --force`）を実行する必要があると案内しろ
- **古いバージョンのキャッシュディレクトリは、`.in_use` に生存中のセッションの pid マーカーが残っている間は削除されないことを伝えろ**
- **既にこのスキルでセットアップ済みの環境では、写しを置き換えるまで修正が反映されないことを伝えろ**。`~/.claude/scripts/nt-plugin-auto-update.sh` はセットアップ時にコピーされた写しなので、テンプレート側を直しても古いまま動き続ける

## アンインストール手順（ユーザーに聞かれた場合のみ案内）

`nt-setup` の `references/common-setup-conventions.md`「アンインストール手順（共通の型）」を識別子 `nt-plugin-auto-update` で案内しろ。
