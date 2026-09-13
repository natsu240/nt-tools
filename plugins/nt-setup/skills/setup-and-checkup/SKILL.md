---
name: setup-and-checkup
description: Claude Code の環境セットアップ・設定チェックをするときに起動しろ。
effort: low
---

# /setup-and-checkup — Claude Code 環境セットアップ・定期チェックアップ支援

ユーザーの Claude Code 環境を **対話的に**整える。初回セットアップだけでなく、しばらく運用したあとの見直し・メンテナンスにも使える。主にやっている作業や好みを聞き、現状を並列で調査し、ギャップを 1 つずつ提案して同意の上で適用する。

## nt-tools リポジトリ

- **GitHub リポジトリ**: `natsu240/nt-tools`（以下 `NT_TOOLS_REPO`）

**nt-tools に何が入っているか（プラグイン・skill・hook・agent・MCP・常駐ジョブ・必要な権限）をこの SKILL.md に書くな。** 実行のたびに `NT_TOOLS_REPO` を読んで集めろ。

## 設計思想

- **やっている作業の種類で「できること」をゲートするな**。capability は全部提示しろ。Step 5 では行動シグナル（セッション履歴・関与 repo・MCP 接続状況）を主軸に提案しろ。「コードを書かないなら plugin は1つで十分」のような決め打ちをするな
- **提案は中立トーンで**。「こういうやり方もあります」と例示し、入れる / カスタマイズ / スキップの 3 択でユーザーに選ばせろ。特定の個人名を出す帰属表現（誰の設定・実例かを名指しする言い方）は使うな
- **nt-tools そのものの扱いは実行者が作者本人かどうかで変えろ**（判定は Step 1 参照）。作者本人ならプラグイン単位でのインストールを気にせず提案してよい。作者以外なら、プラグインという単位ではなく中に入っている個別のノウハウ（skill / hook / workflow / script / setup 手順 / mcp 設定 / system prompt の書き方）を棚卸しして「使えそうです」と報告するだけに留め、ユーザーが興味を示してから初めて具体的な導入方法（そのまま plugin install するか自作するか）を提示しろ
- **既に入っているものは提案するな**。Step 3 の調査結果と差分を取り、未導入のものだけ Step 5 で出せ
- **公式 plugin を再発明するな**。`claude-plugins-official` に既存の機能があれば、まずそちらを案内しろ
- **破壊的操作は必ず事前確認**。シェル設定ファイルへの追記・`claude mcp add`・`/plugin install` 等は、実行コマンドを diff or 全文で見せて承認を取ってから走らせろ

## Step 1 — 実行者判定と同意の取得

`NT_TOOLS_REPO` に実行者自身のコミットがあるかで判定しろ。1 件でも返れば **作者モード** だ。返らない・コマンドが失敗した場合は **利用者モード** として扱え（判定に迷ったら安全側 = 利用者モードに倒せ）。

```bash
EMAIL="$(git config user.email)"
gh api "repos/<NT_TOOLS_REPO>/commits?author=${EMAIL}&per_page=1" --jq '.[0].sha' 2>/dev/null
```

- **作者モード**: Step 4 の `plugin (nt-tools)` カテゴリはプラグイン単位でのインストール提案として扱ってよい
- **利用者モード**: Step 4 の `plugin (nt-tools)` カテゴリは「nt-tools ノウハウ」棚卸しに切り替えろ。プラグインそのものを「入れませんか」と勧めるな（詳細は Step 4・Step 5 参照）

続けてユーザーに以下を 1 メッセージで伝えて同意を取れ（ここでの `hooks` / `workflows` / `CLAUDE.md` / 常駐ジョブの説明が正本。Step 4 の各カテゴリはここを参照するだけで重複記述しない）:

> これからあなたの Claude Code 環境を診断して、入れたら良さそうなものを 1 つずつ提案します。調査するもの:
> - `~/.claude/CLAUDE.md`（Claude Code が会話のたびに必ず読み込む、ルールを書いたファイル） / `~/.claude/settings.json` / hooks（特定のタイミングで自動実行される小さなスクリプト） / agents / skills / workflows（複数のサブエージェントを決まった手順で連携させる仕組み） / 常駐ジョブ（あなたのマシン自身が決まった時刻やログイン時にプログラムを起動する、OS 標準の仕組み。macOS は launchd、Linux は systemd）
> - clone 済み repo と、各 repo の `.claude/`（プロジェクト固有の CLAUDE.md・設定・skill）
> - `claude mcp list` と `/plugin` の状態
> - `~/.claude/projects/` の直近 30 日のセッション履歴（よく使うスキル・ツールの傾向）。OTel（Elasticsearch）が動いていれば `otel-analysis` でコスト傾向・繰り返しパターンも調査します
> - あなたが所属している GitHub org で関わっている repo（`gh api` で所属 org を取得し、commit author 検索）
> - Anthropic 公式 plugin marketplace の在庫（再発明しないため）
> - GitHub 上の nt-tools に入っている技術的ノウハウ（skill / hook / workflow / script / setup 手順 / mcp 設定 / system prompt の書き方）
>
> 何も書き換えはしません。書き換えは提案 → 承認後に 1 つずつやります。続けていい？

同意がなければここで止まれ。

## Step 2 — 主な作業内容の聞取りと clone 先ディレクトリの自動検出

### clone 先ディレクトリの自動検出

Step 3 の調査に使う repo の clone 先ディレクトリを特定しろ。`~` 直下で `.git` ディレクトリを多く含む候補ディレクトリ（`~/pj` / `~/code` / `~/projects` / `~/dev` / `~/repos` / `~/src` / `~/work` 等）を探し、最も git リポジトリを多く含むディレクトリを `CLONE_DIR` として採用しろ。候補が僅差で複数ある、またはどれも見つからない場合だけ、下の聞取りとあわせて「リポジトリはどこに clone していますか？（デフォルト: `~/pj`）」と一言聞け。

特定した `CLONE_DIR` を、以降 Step 3 の `local-repos` explorer・`gh-org` との突き合わせ、Step 4 の `repo clone` / `plugin 化候補` カテゴリの判定、「plugin 化候補の踏み込み」節で使え。**clone 先を固定パスで書くな。**

### 主な作業内容の聞取り

AskUserQuestion で聞け（multiSelect=false）:

- **Claude Code で主にやっていること**: 実装・開発 / 調査・資料作成 / デザイン / その他（自由入力）

**選択肢に description を付けるな。** 説明文を添えると「これを選んだからこの機能が要る/要らない」という誤解を招く。ラベルだけを並べろ。

**「最近よくやる作業・やりたい作業」を本人に聞くな。** それは Step 3 の session-history 調査（直近30日のスキル・ツール利用傾向の集計）で機械的に把握しろ。

回答は Step 4 のギャップ分析で「優先度ヒント」として使うだけ。回答内容で提案カテゴリをゲートするな（設計思想を参照）。

## Step 3 — 並列自動調査

### 3a. nt-tools の取得（explorer 起動前にメインで実行）

**メイン Claude 側**で `NT_TOOLS_REPO` をこのセッションの scratchpad へ浅く clone しろ。

```bash
gh repo clone <NT_TOOLS_REPO> <scratchpad>/nt-tools -- --depth 1
```

clone した `README.md` を Read し、プラグイン一覧・各プラグインの用途を把握して、3b でどのプラグインを重点的に読ませるかの当たりをつけろ。**個々の skill 名の収集は README.md に依存せず 3b の explorer に委ねろ。**

### 3b. explorer 並列調査

`subagent_type: nt-common:explorer` で以下を **1 メッセージで全部並列**起動しろ（1 メッセージに Agent 呼び出しを並べる）。各 explorer のテーマは 1 つだけ。本数はユーザー環境側 4 本 + nt-tools 側（3a の把握をもとにプラグイン数に応じて数本）。

**ユーザー環境側**

| explorer | テーマ | 抽出するもの |
|---|---|---|
| **claude-config** | `~/.claude/CLAUDE.md` / `~/.claude/settings.json` / `~/.claude/hooks/` / `~/.claude/agents/` / `~/.claude/skills/` / `~/.claude/workflows/`（あれば） を Read | CLAUDE.md のルール構成・カスタム hook/agent/skill/workflow の有無・名前一覧（`~/.claude/skills/` 配下のディレクトリ名一覧は Step 4 の名前衝突判定に使うので必ず含めろ）・`settings.json` の `permissions.allow` 配列の中身（生の配列をそのまま報告しろ）・`settings.json` のトップレベルキー一覧 |
| **session-history** | `~/.claude/projects/` 配下の直近 30 日の `.jsonl` を `mtime` でフィルタして集計（**利用者モードでは本文を原文のまま引用するのは禁止、頻度のみ集計**）。`Bash` で `find ~/.claude/projects -name '*.jsonl' -mtime -30 \| head -200` してファイル列挙し、必要なら `jq` で tool 名・skill 名を tally。**作者モード限定で追加調査**: 直近 30 日の会話ログから、一次ソース未確認のまま断定的な発言をして後で訂正した実例を最大 2 件探し、原文そのままではなく 1〜2 文に要約して報告しろ | 直近 30 日でよく呼ばれた skill / tool / MCP のトップ 10（コスト・モデル別傾向・作業パターンは 3c の `otel-analysis` 呼び出しに任せる）+ 作者モードのみ: 断定して後で訂正した実例の要約（最大2件） |
| **local-repos** | Step 2 で特定した `CLONE_DIR` 配下の repo 一覧 + 各 repo の `git log --author=<user.email> --since=30.days.ago --oneline \| wc -l` で user の commit 数 + 各 repo の `.claude/` 配下を Read | clone 済み repo と user の活動度 + プロジェクトごとの Claude Code 設定内容（`.claude/skills/` 配下のディレクトリ名一覧を含む）+ **なぜその運用にしているかの思想パターン**（複数プロジェクトで繰り返し現れる考え方を言語化する） |
| **gh-org** | まず `gh api user/orgs --jq '.[].login'` で実行者の所属 org を取得しろ（org 名を決め打ちするな）。取得できた org ごとに `gh api 'search/commits?q=author:<user-email>+org:<org>'` で関与 repo を取得（`user-email` は `git config user.email` から取得。検索結果の `commit.author.date` からユーザーの各 repo での最終コミット日も控える） + `gh repo list <org> --limit 100 --json name,description,updatedAt`。org が 1 つも取れなければ「所属 org なし」と報告して終われ | 関与 repo の名前 + ユーザーの最終コミット日（直近90日以内か） + local-repos と差分（clone してない関与 repo） |

**nt-tools 側**（作者モード・利用者モード問わず常時実行）

各プラグイン（または関連の近いプラグイン同士をまとめたテーマ）ごとに 1 explorer を割り当て、3a で clone した `plugins/<プラグイン名>/` 配下を Read させろ。以下を必ず報告させろ。

- 個別の仕組み単位（1 hook・1 skill・1 agent・1 setup 手順・1 MCP 設定 等）の一覧と、それぞれ何をしていて何が有益かの短い要約
- 各プラグインの `skills/` 配下のディレクトリ名一覧（Step 4 の名前衝突判定に使う）
- 各プラグインの `.mcp.json` に書かれた MCP サーバーと、`env` で参照している環境変数名
- セットアップ系 skill ごとに、その SKILL.md に書かれた「導入済みかどうかの確認方法」（常駐ジョブの識別子・設定キー・疎通先等）と、提案時に伝えるべき注意書き（トークン消費等）
- 各 SKILL.md に書かれた、プラグインが必要とする `permissions.allow` エントリ
- README や各 skill の「設計思想」節から拾った、なぜその仕組みにしているかの思想パターン

並行して **メイン Claude 側**で以下も実行しろ（explorer に渡せないので）:

- `claude mcp list` を Bash で → 接続中の MCP 一覧
- `cat ~/.claude/plugins/installed_plugins.json` または `/plugin` 状態 → インストール済み plugin
- `WebFetch` で `https://raw.githubusercontent.com/anthropics/claude-plugins-official/main/.claude-plugin/marketplace.json` → 公式 plugin 在庫（再発明回避用）

### 3c. 疎通確認ベースの追加調査（メイン Claude 側）

- **OTel 疎通確認**: `curl -fsS --max-time 2 http://localhost:9200 -o /dev/null` で Elasticsearch に疎通できるか確認しろ。**成功したら** Skill ツールで `nt-common:otel-analysis` を呼び出し、「setup-and-checkup の提案材料にするため、直近 30 日でよく使われている skill / tool / MCP、モデル別・実行元別のコスト傾向、繰り返し発生している作業パターン（自動化や skill 化の余地があるもの）を教えて」と依頼しろ。**この skill はバックグラウンドで走るので、結果は完了通知として後から届く。届いてから Step 4 のギャップ分析に使え**
- **セットアップ済みかの確認**: 3b の nt-tools 側 explorer が報告した「導入済みかどうかの確認方法」を、セットアップ系 skill ごとにそのまま実行しろ。常駐ジョブの確認は `uname -s` で OS を判定し、macOS は `launchctl list`、Linux は `systemctl --user list-unit-files` で見ろ
- **MCP の scope 重複確認**: 3b で取得済みの `claude mcp list` の結果を再利用しろ。`plugin:<プラグイン名>:<サーバー名>` 形式のエントリと、同じサーバー名を持つ `plugin:` プレフィックス無しのエントリが両方存在する場合、user scope 等でプラグイン提供設定と重複登録されていると判定しろ
- **MCP の認証状態確認**: `claude mcp list` で `plugin:` 付きのサーバーが `Needs authentication` または接続失敗になっている場合、3b で報告された認証用の環境変数が現在のシェルに設定されているかを確認しろ。**値は表示するな。有無だけ確認しろ**

すべての結果が揃ったら Step 4 へ。

## Step 4 — ギャップ分析

収集したシグナルを照合し、未導入で「入れる価値がありそうなもの」をカテゴリ別に列挙しろ:

### 提案カテゴリと判定基準

| カテゴリ | 提案条件 |
|---|---|
| **plugin (nt-tools)**（作者モードのみ） | 3b の nt-tools 側 explorer が報告したプラグインのうち、Step 3 の plugin 状態に無く、Step 2/3 のシグナルと合致するもの |
| **nt-tools ノウハウ**（利用者モードのみ） | 3b の nt-tools 側 explorer の調査結果と、ユーザー環境側 explorer（`claude-config` / `local-repos`）の現状を突き合わせ、手元に無くて有益そうな個別の仕組みを列挙する。プラグイン単位ではなく「この hook」「この workflow パターン」「このセットアップ手順」単位で拾え |
| **運用ノウハウ（考え方）**（作者モード・利用者モードの両方） | `local-repos` explorer が拾った思想パターンと nt-tools 側の思想パターンを突き合わせ、複数プロジェクトで繰り返し現れているが `~/.claude/CLAUDE.md` にはまだ反映されていないものを列挙する。実装物を伴わない「なぜその運用にしているか」の考え方が対象 |
| **plugin (公式)** | 公式 marketplace に該当があり、ユーザーの行動シグナルと合致 |
| **MCP** | セッション履歴で関連ツールの利用や言及があるが `claude mcp list` に無い（nt-tools 側 explorer が報告した同梱 MCP を含めて判定しろ） |
| **hook** | 3b で報告された hook のうち、提供元プラグインが未導入で、ユーザーの行動シグナルや CLAUDE.md のルールと合致するもの。**利用者モードでは Step 5 の棚卸し表示フォーマット（3択なし）で提示しろ** |
| **subagent** | セッション履歴で重い grep / 多ファイル Read を頻繁にやっているが subagent 委譲が無い。3b で報告された agent から合致するものを出せ。**利用者モードでは Step 5 の棚卸し表示フォーマット（3択なし）で提示しろ** |
| **workflow**（用語説明は Step 1 の同意メッセージを参照） | セッション履歴で「複数並列の独立タスク」が頻発しているが Workflow tool 未利用 |
| **セットアップ**（常駐ジョブの用語説明は Step 1 の同意メッセージを参照） | 3c の確認で未導入と判定されたセットアップ系 skill。3b で報告された注意書き（トークン消費等）は必ず添えろ。何を記録・実行して何をしてくれるのかを具体的にイメージできる言い方で説明しろ |
| **repo clone** | gh-org で関与確認できた repo が `CLONE_DIR` に無く、かつユーザーの直近90日以内のコミットがそのリポジトリにある。単発の過去コミットしか無い repo は提案するな |
| **plugin 化候補**（作者モードのみ） | `~/.claude/skills/` 配下に独自 skill があり、汎用性がありそうで nt-tools に同名が無い。利用者モードでは棚卸し報告の対象にもしない |
| **settings許可リスト** | 3b で報告された `permissions.allow` エントリのうち、対応するプラグインがインストール済みなのに `claude-config` explorer が報告した `permissions.allow` 配列に無いもの |
| **MCP 認証** | 3c の MCP の認証状態確認で、認証用の環境変数が未設定だったもの。3b で報告された環境変数名を、ユーザーのシェル設定ファイルに設定するよう案内しろ |
| **local-skill-collision** | `claude-config` / `local-repos` explorer が報告した `.claude/skills/` 配下のディレクトリ名を、3b の nt-tools 側 explorer が報告した `skills/` 配下ディレクトリ名一覧と照合しろ。一致するものがあれば、ローカル優先でプラグイン版が無効化されている旨を伝え、ローカル skill の削除を提案する |
| **mcp-scope-duplicate** | 3c で `plugin:` プレフィックス無しのエントリが同名の `plugin:<プラグイン名>:<サーバー名>` と重複していた場合、`claude mcp remove <name> -s user` での削除を提案する |

## Step 5 — 対話的提案

Step 4 の結果を**全項目まとめてテーブル形式で一覧表示**しろ（列: 項目名／一言で何をするか／なぜおすすめか）。**一覧を出したらそこで一旦区切れ。** こちらから「気になるものはありますか？」等と重ねて問いかけたり、上位のものを続けて深堀りしたりするな。ユーザーが番号や名前で選んだときだけ、その項目について下の提示フォーマットで個別に詳細を出せ。

### 提示フォーマット（各提案ごと）

**原則**: nt-tools 固有の仕組み（そのまま使うにはプラグインのインストールが要るもの）を提案するときは、利用者モードでは常に下の棚卸し表示フォーマットを使う。対象カテゴリは `plugin (nt-tools)` / `hook` / `subagent` だ（`plugin (nt-tools)` は利用者モードでは「nt-tools ノウハウ」という名前で提示される）。

**上記の対象カテゴリ以外**（作者モードの `plugin (nt-tools)` を含む）は以下のとおり:

- **何をするか**（1〜2 文）
- **なぜおすすめか**（Step 3 で見たどのシグナルから来た提案かを明示）
- **作者モード限定**: 事実確認のルールに関わる提案で、session-history explorer が断定して後で訂正した実例を見つけていれば「実際にこういう場面がありました: 〈要約〉」を添える。利用者モードでは引き続き頻度集計のみ使え
- **具体的に入る内容**（コマンド / コードスニペット / 設定ファイル全文を見せる）
- **3 択**: 入れる / カスタマイズ（中身を編集してから入れる）/ スキップ

**上記の対象カテゴリのうち利用者モードで提示されるもの（`nt-tools ノウハウ` / `hook` / `subagent`）は報告に留めろ。3 択は出すな**:

- **何のノウハウか**（1〜2 文。nt-tools のどの plugin・ファイルに実装されているかを明示）
- **なぜ使えそうか**（Step 3 で見つかったユーザー側のギャップ）
- ここで一旦止めろ。ユーザーが興味を示したら初めて次の 2 択を出せ:
  - nt-tools をそのまま `claude plugin install <plugin名>@nt-tools` で使う
  - 該当ファイルを参考に自分の環境（`~/.claude/hooks/` 等）に同等の仕組みを自作する（選んだら Step 6 の適用フローに合流）

**「運用ノウハウ（考え方）」カテゴリ**は作者モード・利用者モードで表示形式を分けろ:

- **作者モード**: 自分の `~/.claude/CLAUDE.md` へ横展開する提案として、他の対象カテゴリ以外と同じ3択（入れる/カスタマイズ/スキップ）で提示してよい
- **利用者モード**: 他の nt-tools 固有カテゴリと同じ棚卸し報告のみに留めろ。3 択は出すな。ユーザーが興味を示したら「あなたの環境にも取り入れてみますか」に反応があった場合だけ、Step 6 の「自作する」導線へ合流する 2 択（自作する / スキップ）を出せ

特定の個人名を出す帰属表現は使うな。

専門用語やあまり馴染みのない仕組みの説明は、「〜ができるようになる」という抽象的な効能の羅列でなく、何を記録・集計して、それを使って何をしてくれるのかを具体的にイメージできる書き方をしろ。

## Step 6 — 適用と検証

ユーザーが「入れる」または「カスタマイズ」を選んだ提案（利用者モードの「nt-tools ノウハウ」で「そのまま plugin install」または「自作する」を選んだ場合も含む）について、以下の順で実行しろ:

- **diff 提示**: ファイル編集が伴うものは Edit ツールで差分を見せる前に「これで書きますね」と明示
- **書き換え or コマンド実行**: 同意があれば実行
- **検証**:
  - シェル設定ファイルへの追記 → 設定の再読み込みを案内（ユーザーが自分で実行）+ 追加した関数・変数が効いているか確認案内
  - MCP 追加 → `claude mcp list` で接続確認
  - plugin install → `/plugin` で確認
  - hook 追加 → 該当コマンドを 1 回試して block されるか確認
  - settings許可リスト追加 → `jq` で `permissions.allow` に追記しろ（`jq --argjson e '["<エントリ>"]' '.permissions.allow = ((.permissions.allow // []) + $e | unique)' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json`）。反映後の `settings.json` を Read してエントリが実際に入っているか確認しろ
  - **セットアップ系 skill に委譲する提案** → この skill 側で手順を重複実装するな。Skill ツールで該当 skill をそのまま起動し、以降の対話（前提条件確認・ユーザーへの設定聞取り・確認プロンプト・検証）はその skill に委ねろ
- **次の提案へ**

途中でユーザーが「もういい」「あとは自分でやる」と言ったら即停止しろ。残りは TODO リスト形式で出力して終わり。

## plugin 化候補の踏み込み

Step 5 で「あなたの独自 skill X は nt-tools に上げると全プロジェクトで使えます」と提案し、ユーザーが同意したら以下を提案しろ:

- `NT_TOOLS_REPO` を `CLONE_DIR` 配下へ clone（既にあれば使う）
- 該当 skill を適切なプラグインの `skills/` 配下にコピー
- 以降のブランチ・バージョン・PR の手順は、clone した nt-tools の `CLAUDE.md` の運用ルールに従え

## 禁止事項

- 特定の個人名を出す帰属表現で例を提示するな（中立トーン厳守）
- 聞取りで得た作業内容で提案カテゴリをゲートするな
- 既に入っているものを「これも入れますか？」と提案するな（Step 3 の調査と必ず差分を取れ）
- セッション履歴・otelログの本文（プロンプト・応答の原文）を原文のまま引用するな。**利用者モードでは禁止（頻度・数値集計のみ）。作者モードは本人自身の過去ログの要約（原文そのままではない）に限り引用可**
- 公式 plugin で済むものを nt-tools 側で再発明する提案を出すな
- シェル設定ファイルや `~/.claude/CLAUDE.md` への書き換えを承認なしに実行するな
- 一覧表示（項目名・一言説明のみ）は全件見せてよいが、詳細説明・3 択の提示はユーザーが選んだものだけ 1 件ずつ行え。一覧を出した直後にこちらから深堀りを促すな
- 利用者モードで nt-tools のプラグインそのものを「入れませんか」と 3 択で提案するな（ノウハウ単位の報告に留め、ユーザーが反応してから導入方法を出せ）
- 利用者モードで `hook` / `subagent` カテゴリを 3 択で提案するな（棚卸し報告のみに留めろ）
- `plugin 化候補` カテゴリを利用者モードで提示するな（作者モード限定。棚卸し報告の対象にもしない）
- **nt-tools の中身（skill 名・hook 名・ジョブ名・権限エントリ等）をこの SKILL.md に書き足すな**。必要な情報は実行時に `NT_TOOLS_REPO` から集めろ
