---
name: setup-plugin-cache-cleanup
description: プラグインキャッシュの自動掃除をセットアップするときに起動しろ。
effort: low
---

# プラグインキャッシュ掃除 自動セットアップ

このスキルは、プラグインのキャッシュに溜まる目印ファイルを定期的に掃除する仕組みを、launchd（macOS）または systemd timer（Linux）でセットアップする。

## 何を掃除するのか

`~/.claude/plugins/cache/<marketplace>/<プラグイン名>/<バージョン>/.in_use/` は「このプロセスがこのプラグインを使用中」を示す目印の置き場だ。Claude Code はセッション開始時にここへファイルを1つ置く。中身はこの形式（3割ほどは中身のない空ファイル）。

```
{"pid":40587,"procStart":"Sat Aug  1 00:29:05 2026"}
```

**プロセスが終了しても消えない。** 実測（2026-08-14）では約2週間で 22.4万件溜まり、そのうち生きているプロセスのものは30件だけだった。ファイル自体はほぼ0バイトだが、1ディレクトリに4万件並ぶとディレクトリのメタデータだけで100MB を超え、全プラグイン合計で 602MB になっていた。

**公式プラグインで特に溜まりやすい。** バージョン番号を持たないプラグイン（キャッシュのディレクトリ名が `unknown` になるもの）は更新しても同じディレクトリが上書きされるため、ディレクトリごと消える機会が無く目印だけが残り続ける。

この蓄積は Claude Code 本体側の掃除が機能していないことによるもので、こちらから消す以外に手段が無い。

## 掃除の判定

- 今動いている claude プロセスの pid を `ps` で集める
- `~/.claude/plugins/cache` 配下の全 `.in_use` を探し、ファイル名の pid 部分がその一覧に無いものを削除する
- claude プロセスが1つも見つからないときは全件を削除対象にする（誰も使っていない状態なので消して問題ない）

目印を作るのは claude プロセス自身なので、動いている claude の pid に無い目印は終了済みプロセスのものと判断できる。中身の `procStart` は判定に使わない（空ファイルが3割あり、pid だけで判定する経路がどうしても必要になるため、判定を2通り持たない）。

**対象は全 marketplace だ**（`nt-tools` に限らず `claude-plugins-official` も含む）。実際に溜まっているのは公式側なので、自分のプラグインだけ見ても意味がない。

**定期実行はマシンごとの仕組みなので、セットアップしたマシンでしか掃除は動かない。**

## 前提条件の確認

`nt-setup` の `references/common-setup-conventions.md`「前提条件の確認」に従え。

## セットアップ手順

### 既存セットアップの確認

`nt-setup` の `references/common-setup-conventions.md`「既存セットアップの確認（共通の型）」に従え。識別子は `nt-plugin-cache-cleanup`、生成ファイルは `~/.claude/scripts/nt-plugin-cache-cleanup.sh` だ。

### ディレクトリの作成

```bash
mkdir -p ~/.claude/scripts
```

### スクリプトの生成

`${CLAUDE_SKILL_DIR}/templates/nt-plugin-cache-cleanup.sh` を読み、そのまま（プレースホルダー置換なし）`~/.claude/scripts/nt-plugin-cache-cleanup.sh` に書き込め。

書き込み後、実行権限を付与しろ:

```bash
chmod +x ~/.claude/scripts/nt-plugin-cache-cleanup.sh
```

### 登録ファイルの生成

`nt-setup` の `references/common-setup-conventions.md`「登録ファイルの生成（共通の型）」に従え。識別子は `nt-plugin-cache-cleanup` だ。`__HOME__` 以外のプレースホルダーは無い。

### 定期実行の登録

**登録前に必ずユーザーに「起動していいですか？」と確認しろ。** 登録した時点で1回掃除が走る。

`nt-setup` の `references/common-setup-conventions.md`「定期実行の登録（共通の型）」に従え。登録後は1日ごと（86400 秒）に実行される。

### テスト実行

```bash
~/.claude/scripts/nt-plugin-cache-cleanup.sh
```

実行結果は `~/.claude/scripts/nt-plugin-cache-cleanup.log` に記録される。削除した件数と、残した pid が1行で残る。

掃除の前後で容量を比べたい場合は `du -sh ~/.claude/plugins/cache` を実行の前後で取れ。

掃除後に `claude plugin list` を実行し、プラグインが全部認識されていることを確認しろ。

## 厳守事項

`nt-setup` の `references/common-setup-conventions.md`「厳守事項」に加え、以下を守れ（登録の確認では、登録した時点で1回掃除が走る点も併せて伝えろ）。

- **旧バージョンのディレクトリ（バージョン名のディレクトリそのもの）はこのスキルの対象外だと伝えろ**。nt-tools の旧バージョンは `/setup-plugin-auto-update` が担当する

## アンインストール手順（ユーザーに聞かれた場合のみ案内）

`nt-setup` の `references/common-setup-conventions.md`「アンインストール手順（共通の型）」を識別子 `nt-plugin-cache-cleanup` で案内しろ。
