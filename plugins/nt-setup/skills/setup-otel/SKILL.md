---
name: setup-otel
description: OTELテレメトリのログ記録をセットアップするときに起動しろ。
effort: low
---

# Claude Code OTELログ 自動セットアップ

Claude Code には OpenTelemetry によるテレメトリ機能が組み込まれている。このスキルはローカルに OTel Collector・Elasticsearch・Kibana の3コンテナを Docker Compose で立て、Claude Code からの送信先として設定し、ログイン時に自動起動する仕組みまで一式セットアップする。

全体構成:

```
Claude Code CLI (CLAUDE_CODE_ENABLE_TELEMETRY=1)
  --OTLP/gRPC (localhost:4317)-->
OTel Collector コンテナ (otel/opentelemetry-collector-contrib)
  --elasticsearchexporter-->
Elasticsearch コンテナ (日本語形態素解析kuromoji組み込み)
  --閲覧・検索・集計-->
Kibana コンテナ (http://localhost:5601)
```

3コンテナは `~/.claude/otel/compose.yaml` の Docker Compose 定義1つで一括管理する（個別にコンテナを起動する運用はしない）。有効化後は API リクエストごとのトークン数・コスト・モデル・実行時間・呼び出し元（メイン会話 / サブエージェント等）が Elasticsearch の `logs-generic.otel-default` という data stream に記録される。作業中のリポジトリ名は Claude Code 側が送らないため、後述の手順でシェルから渡して記録できるようにする。`otel-analysis` スキルはこのデータを前提に動く。保存期間の上限は設けない（無期限。ローテーションによる自動削除は発生しない）。

## 前提条件の確認

`nt-setup` の `references/common-setup-conventions.md`「前提条件の確認」に加え、実行前に以下を確認しろ。1つでも欠けていたらユーザーに案内して中断しろ。

- **OS の判定** — `uname -s` で確認しろ。`Darwin` なら自動起動の登録に launchd、`Linux` なら systemd user unit を使う（後述の手順が分かれている）
- **Linux の場合、systemd user インスタンスが動いている** — `systemctl --user is-system-running` で確認しろ。`running` または `degraded` なら使える。`offline` / コマンド自体が無い場合は自動起動の登録を飛ばし、`docker compose up -d` を手動実行する運用になる旨を伝えろ
- **Docker Compose が使える** — `docker compose version` で確認（Docker Desktop に同梱、または `docker-compose-plugin` 単体導入でも可）。無ければ Docker Desktop の導入を案内して中断しろ。**Apple Container CLI(`container`コマンド)は使うな** — Elasticsearchは`Dockerfile`からのカスタムビルド(kuromoji/icuプラグインの追加インストール)が必要で、Apple Container CLIの`container build`はプラグインのダウンロード元への接続がタイムアウトする事例が確認されているため、Dockerでのビルドのみサポートする
- **ディスク空き容量が5GB以上ある** — Elasticsearch公式ドキュメントで最低5GBの空きディスクが必須と明記されている。`df -h ~ | tail -1` 等で確認し、不足していれば警告しろ

## セットアップ手順

### 既存セットアップの確認

以下を確認しろ:

- `~/.claude/otel/` が既に存在するか
- `~/.claude/settings.json` に `CLAUDE_CODE_ENABLE_TELEMETRY` キーが既にあるか
- 自動起動の既存登録があるか（macOS: `launchctl list | grep otel-container-start` / Linux: `systemctl --user is-enabled claude-otel-container-start.service`）
- `docker ps -a --filter "name=claude-otelcol|claude-elasticsearch|claude-kibana"` で既存コンテナがあるか
- 既存の `~/.claude/otel/start-compose.sh` に `docker info` の待機ループが入っているか（`grep -q 'docker info' ~/.claude/otel/start-compose.sh` 等で確認しろ）。入っていない古い版は、ログイン直後にコンテナ基盤より先に走ると失敗したまま復帰しない（詳細は後述の「コンテナ基盤の起動待ちが要る理由」）。**全体の上書きに同意が得られなかった場合も、このファイルだけは差し替えを勧めろ**

いずれか存在する場合は「既に OTEL ログ設定がセットアップ済みのようです。上書きしますか？」とユーザーに確認しろ。同意が無ければ中断しろ。

### 記録範囲をユーザーに確認

`AskUserQuestion` で以下を聞け:

**トークン数・コストに加えて、プロンプト全文・応答全文・API の生ボディまで記録するか？**

- **メタデータのみ（推奨）**: モデル・トークン数・コスト・実行時間・呼び出し元だけを記録する。会話内容は残らない
- **詳細ログも含む**: 上記に加えてプロンプト全文・応答全文・API リクエスト/レスポンスの生ボディまで平文でElasticsearchに記録される。**会話・コード内容がまるごとローカルのElasticsearchに記録される点、`otel-analysis`スキルの`search_text.py`で過去発言をあいまい検索できるようになる点を明示して選ばせろ**

回答を後述の settings.json 設定に反映しろ。

### ディレクトリ作成とファイル配置

```bash
mkdir -p ~/.claude/otel/elasticsearch/data
```

このスキルの `templates/` ディレクトリ（`${CLAUDE_SKILL_DIR}/templates/`）から以下をコピーしろ:

- `templates/compose.yaml` → `~/.claude/otel/compose.yaml`（3コンテナ一括管理のDocker Compose定義。プレースホルダなし、そのままコピーでよい）
- `templates/collector-config.yaml` → `~/.claude/otel/collector-config.yaml`（OTel Collectorの設定。`elasticsearchexporter`でElasticsearchへ直接書き込む）
- `templates/elasticsearch/Dockerfile` → `~/.claude/otel/elasticsearch/Dockerfile`（kuromoji・icuプラグインを組み込んだ独自イメージのビルド手順）
- `templates/elasticsearch/component-template.json` → `~/.claude/otel/elasticsearch/component-template.json`（日本語区切り設定の定義。後述の手順でcomponent templateとして登録する）
- `templates/start-compose.sh` → `~/.claude/otel/start-compose.sh`（コピー後 `chmod +x ~/.claude/otel/start-compose.sh`）。**中身を書き換えるな。** コンテナ基盤の応答を待ってから compose を叩き、PATH を自分で組み立てる作りにしてある（理由は後述の「コンテナ基盤の起動待ちが要る理由」）

### コンテナの作成・起動

```bash
docker compose -f ~/.claude/otel/compose.yaml up -d
```

初回はElasticsearchイメージのビルド（kuromoji・icuプラグインのダウンロード・インストール）に数分かかる。

### Elasticsearchの日本語検索対応（初回のみ、データを書き込む前に必ず実施しろ）

Elasticsearchが起動するまで待て（最大120秒程度ポーリングしろ）:

```bash
for i in $(seq 1 24); do
  curl -s -o /dev/null "http://localhost:9200" && break
  sleep 5
done
```

起動を確認したら、`templates/elasticsearch/component-template.json` の内容を、Elasticsearchが標準で用意している3つの拡張差し込み口（`logs-otel@custom` / `traces-otel@custom` / `metrics-otel@custom`という決まった名前のcomponent template）に登録しろ:

```bash
curl -X PUT "http://localhost:9200/_component_template/logs-otel@custom" \
  -H "Content-Type: application/json" -d @"$HOME/.claude/otel/elasticsearch/component-template.json"
curl -X PUT "http://localhost:9200/_component_template/traces-otel@custom" \
  -H "Content-Type: application/json" -d @"$HOME/.claude/otel/elasticsearch/component-template.json"
curl -X PUT "http://localhost:9200/_component_template/metrics-otel@custom" \
  -H "Content-Type: application/json" -d @"$HOME/.claude/otel/elasticsearch/component-template.json"
```

**`-d @` の後ろのパスは `~` ではなく `$HOME` で書け。** チルダ展開はシェルが語頭でしか行わないため、`-d @~/.claude/...` と書くと `~` がリテラル文字のまま curl に渡り、`curl: option -d: error encountered when reading a file` で必ず落ちる。

**この登録は、Claude Codeからログが1件も送信される前（=Elasticsearch側でdata streamがまだ作成されていない状態）に済ませろ。** 独立したindex templateとして登録するな（Elasticsearchのotel-data組み込みテンプレートに優先度で負けて一切適用されない）。上記3つの決まった名前のcomponent templateに登録することで、組み込みのECSマッピングを壊さずに安全に拡張できる。

万が一、この手順より先にログが送信されてdata streamが既に作成済みだった場合は、component template登録後に以下でロールオーバーして新しいバッキングインデックスに反映させろ:

```bash
curl -X POST "http://localhost:9200/logs-generic.otel-default/_rollover"
```

### ログイン時の自動起動登録

**登録する前に必ずユーザーに「ログイン時に OTel Collector / Elasticsearch / Kibana を自動起動する設定を登録していいですか？」と確認しろ。** 同意後、OS に応じて以下のどちらかを実施しろ。

#### コンテナ基盤の起動待ちが要る理由（`start-compose.sh` の待機ループを削るな）

ログイン直後は Docker Desktop / Podman Desktop の仮想マシンがまだ起動しておらず、`/var/run/docker.sock` が存在しない。launchd の `RunAtLoad` はこれより先に走るため、`docker compose up -d` を即座に叩くと `dial unix /var/run/docker.sock: connect: no such file or directory` で落ちる。**実測では、macOS 起動の7分後にようやくソケットが作られていた**（Podman Desktop をログイン項目から起動している環境。`ls -la /var/run/docker.sock` の作成時刻と `sysctl -n kern.boottime` の差で確認した）。

そのため `start-compose.sh` は `docker info` が通るまで5秒間隔で最大15分待ってから compose を叩く。**plist / unit 側に再実行の設定（`KeepAlive` 等）は足すな。** 待ちで足りるうえ、ユーザーが基盤を意図的に止めている間もログが延々と伸びる。

**`compose.yaml` の `restart: unless-stopped` を、OS 再起動をまたいだ復帰の保険として数えるな。** Podman では machine の再起動後にコンテナの再起動方針を適用するのは machine 内の `podman-restart.service` の役目で、これが無効な限りコンテナは起動しない（実測: `podman machine ssh 'systemctl is-enabled podman-restart.service'` が `disabled` を返し、3コンテナの `Created` が手で `docker compose up -d` を叩いた時刻に揃っていた。restart 方針による復帰なら `Created` は据え置きで `StartedAt` だけが更新される）。Docker Desktop での挙動はこの環境で検証していないので、そちらは復帰する前提で説明するな。

**つまり launchd / systemd からの起動が唯一の復帰経路で、ここで失敗すると手で `docker compose up -d` を叩くまでテレメトリが記録されない。**

Podman を使っている環境では、この保険を自分で有効化できる。**machine 内の `sudo` を勝手に叩くな。** 以下を提示してユーザー自身に実行してもらえ:

```bash
podman machine ssh 'sudo systemctl enable --now podman-restart.service'
```

有効化すると、待機ループが上限まで待って諦めた後や、ユーザーが後から Podman Desktop を起動した場合でも machine 起動の時点でコンテナが復帰する。

`start-compose.sh` が PATH を自分で組み立てているのも同じ事情だ。launchd / systemd から起動されたプロセスは対話シェルの設定を読まないため、`/opt/homebrew/bin` が PATH に入っておらず `command -v docker` が空になる。PATH 自体が未設定で渡ることもあるので、`date` / `sleep` の探索先（`/usr/bin` / `/bin`）まで自分で並べてある。

#### macOS（launchd）

`templates/com.claude.otel-container-start.plist` を読み、`__HOME__` を `$HOME`（実際のホームディレクトリ絶対パス）で置換した結果を `~/Library/LaunchAgents/com.claude.otel-container-start.plist` に書き込め。

```bash
launchctl bootout gui/$(id -u)/com.claude.otel-container-start 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude.otel-container-start.plist
launchctl list | grep otel-container-start
```

`com.claude.otel-container-start` が表示されれば成功。

#### Linux（systemd user unit）

`templates/claude-otel-container-start.service` を読み、`~/.config/systemd/user/claude-otel-container-start.service` へそのまま書き込め（プレースホルダーは無い。ホームディレクトリは systemd の `%h` で解決される）。

```bash
mkdir -p ~/.config/systemd/user
systemctl --user daemon-reload
systemctl --user enable --now claude-otel-container-start.service
systemctl --user status claude-otel-container-start.service --no-pager
```

`Active: active (exited)` になっていれば成功（`Type=oneshot` + `RemainAfterExit=yes` のため、compose を叩き終えた後は exited のまま「起動済み」として保持される）。

**ログインしていない間もコンテナを立ち上げておきたい場合は linger の有効化が要る。** 管理者権限が要るので**ユーザー自身に実行してもらえ**（このスキルが勝手に sudo を叩くな）:

```bash
sudo loginctl enable-linger "$USER"
```

なお Docker のデーモン自体が別途自動起動している必要がある。Docker Desktop を使わない環境では `sudo systemctl enable --now docker` が別途要る旨も伝えろ。

### Claude Code 側の設定（settings.json）

**`~/.claude/settings.json` のバックアップファイル（`*.bak.*` 等）を作るな。** 代わりに、書き込みが壊れない手順そのもので守れ:

- 編集前に Read で現在の内容を全文確認しろ
- 書き込みは別ファイルへ出してから `mv` で差し替えろ（途中で失敗しても元ファイルが半端な状態にならない）
- 書き込み後は必ず Read し直して、既存キーが消えていないこと・意図した値が入っていることを確認しろ
- 既に目的の値が入っているなら、書き込み自体をするな

記録範囲の回答が「メタデータのみ」の場合、以下を `env` にマージしろ:

```json
{
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1",
  "OTEL_METRICS_EXPORTER": "otlp",
  "OTEL_LOGS_EXPORTER": "otlp",
  "OTEL_TRACES_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4317",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
  "OTEL_METRICS_INCLUDE_VERSION": "true",
  "OTEL_METRICS_INCLUDE_ENTRYPOINT": "true"
}
```

`CLAUDE_CODE_ENHANCED_TELEMETRY_BETA` は Traces（beta機能）を実際に有効化するための必須フラグ。`OTEL_TRACES_EXPORTER` を設定していてもこのフラグが無いと Traces は送信されない。

`OTEL_METRICS_INCLUDE_VERSION` / `OTEL_METRICS_INCLUDE_ENTRYPOINT` は既定 false のため明示的に有効化する（他の `OTEL_METRICS_INCLUDE_*` は既定 true なので指定不要）。有効にすると Claude Code のバージョン（`app.version`）と起動経路（`app.entrypoint`。値は `cli` = ターミナルからの対話起動 / `sdk-cli` = `claude -p` の無人実行）が記録され、「特定バージョンから消費が増えた」「無人実行分だけ切り出したい」といった集計ができる。

**変数名はメトリクス向けだが、実際には `api_request` を含むログ側のイベントにも入る。** 公式ドキュメントはログへの影響に触れていないが、有効化の前後で実データを比較して確認済み（有効化前は `user_prompt` 3,180 件中 0 件、有効化後は 14 件中 10 件に付与）。`/otel-analysis` はメトリクスではなくログ側を集計する設計（メトリクスは Elasticsearch の時系列モードで作られ、数時間より古いタイムスタンプを受け付けないため）なので、ログにも入ることでコスト集計に実際に使える。

「詳細ログも含む」の場合、まず API の生ボディの保存先ディレクトリを作成しろ:

```bash
mkdir -p ~/.claude/otel/api-bodies
```

その上で、以下を `env` にマージしろ（`OTEL_LOG_RAW_API_BODIES` の値は `file:` の後ろに実際のホームディレクトリの絶対パスを入れろ。`~` は JSON の値としては展開されない）:

```json
{
  "OTEL_LOG_USER_PROMPTS": "1",
  "OTEL_LOG_ASSISTANT_RESPONSES": "1",
  "OTEL_LOG_TOOL_DETAILS": "1",
  "OTEL_LOG_TOOL_CONTENT": "1",
  "OTEL_LOG_RAW_API_BODIES": "file:/home/<ユーザー名>/.claude/otel/api-bodies",
  "CLAUDE_CODE_OTEL_CONTENT_MAX_LENGTH": "262144"
}
```

**`OTEL_LOG_RAW_API_BODIES` は `"1"`（inline）ではなく `file:<絶対パス>` にしろ。** `file:<dir>` を指定すると、API の生ボディ（`api_request_body` / `api_response_body`）は Elasticsearch のドキュメントには入らず、指定ディレクトリ配下に `<dir>/<uuid>.request.json`（リクエストごと）・`<dir>/<request_id>.response.json`（Anthropic API のレスポンスヘッダーの request-id）として**切り捨てなしで**保存され、Elasticsearch側のイベントにはそのファイルへの絶対パスを指す `body_ref` 属性だけが残る（`body_truncated` も付かなくなる）。公式ドキュメント（`https://code.claude.com/docs/en/monitoring-usage`）で確認済み。**`file:` 記法は `OTEL_LOG_RAW_API_BODIES` 専用で、`OTEL_LOG_USER_PROMPTS` 等の他の詳細ログ変数には存在しない。** それらが持つ属性（応答全文・ツール入出力等）は今までどおり `CLAUDE_CODE_OTEL_CONTENT_MAX_LENGTH` の上限で inline のまま切り捨てられる。

`CLAUDE_CODE_OTEL_CONTENT_MAX_LENGTH` は本文を持つ属性（応答・ツール入出力・システムプロンプト。API の生ボディは `file:` モードでは対象外）の長さ上限で、既定は `61440`（60KB、UTF-16 単位）。既定のままだと長いやり取りの応答・ツール入出力が軒並み 61440 文字で切り捨てられるため、`262144`（256KB、公式ドキュメントが引き上げ例として挙げている値）にする。Claude Code v2.1.214 以降でのみ有効。

`jq` が使えるなら以下のように既存の `env` を保持したままマージしろ（`<マージするJSON>` は上で選んだ方の内容に置き換えろ）:

```bash
jq --argjson new_env '<マージするJSON>' '.env = (.env // {}) + $new_env' ~/.claude/settings.json > ~/.claude/settings.json.new
mv ~/.claude/settings.json.new ~/.claude/settings.json
```

`jq` が無ければ導入を案内する（macOS は `brew install jq`、Linux は `sudo apt install jq` 等。sudo が使えないなら公式 GitHub Releases の静的バイナリを `sha256sum.txt` と突き合わせてから `~/.local/bin` へ）か、Edit ツールで `~/.claude/settings.json` の `env` セクションを直接編集しろ。**既存の `env` キーを消さないよう注意しろ。**

### 作業中のリポジトリ名を記録できるようにする

**Claude Code は作業ディレクトリ・リポジトリ名をテレメトリに一切含めない。** 記録されるのは `session.id` までで、`api_request` / `user_prompt` などどのイベントにも cwd 相当の属性は無い（`workspace.host_paths` という属性は存在するがデスクトップアプリで選んだフォルダ限定で、CLI 起動では付かない）。そのため「どのリポジトリでいくら使ったか」を集計するには、`~/.claude/projects/<パスをハイフンに置換した名前>/<session.id>.jsonl` というファイルの置き場所から逆算するしかない。

`OTEL_RESOURCE_ATTRIBUTES` に自分でリポジトリ名を渡せば、ログ・メトリクス・トレースの全ドキュメントに `resource.attributes.project` として乗せられる。この変数は Claude Code のプロセス起動時に読まれるため、`settings.json` の `env` に書くと固定値になってしまう（起動ディレクトリごとに変えられない）。**必ずシェル側で渡せ。**

ユーザーに確認した上で、シェルの設定ファイルに以下を追記しろ。**使っているシェルに合う方だけを入れろ**（`echo $SHELL` またはログインシェルの設定で判定しろ）。

zsh（`~/.zshrc`）の場合:

```zsh
# OTel の全ログ・メトリクス・トレースに作業中のリポジトリ名を載せる。
# Claude Code 自身は作業ディレクトリをテレメトリに含めないため、起動時に自分で渡すしかない。
# git リポジトリ内ならそのルート名、外ならカレントディレクトリ名を使う。
function claude() {
  local root proj attrs
  root=$(git rev-parse --show-toplevel 2>/dev/null)
  proj=${${root:-$PWD}:t}
  attrs="project=${proj// /_}"
  if [[ -n "$OTEL_RESOURCE_ATTRIBUTES" ]]; then
    attrs="${OTEL_RESOURCE_ATTRIBUTES},${attrs}"
  fi
  OTEL_RESOURCE_ATTRIBUTES="$attrs" command claude "$@"
}
```

bash（`~/.bashrc`）の場合:

```bash
# OTel の全ログ・メトリクス・トレースに作業中のリポジトリ名を載せる。
# Claude Code 自身は作業ディレクトリをテレメトリに含めないため、起動時に自分で渡すしかない。
# git リポジトリ内ならそのルート名、外ならカレントディレクトリ名を使う。
claude() {
  local root proj attrs
  root=$(git rev-parse --show-toplevel 2>/dev/null)
  proj=$(basename "${root:-$PWD}")
  attrs="project=${proj// /_}"
  if [[ -n "$OTEL_RESOURCE_ATTRIBUTES" ]]; then
    attrs="${OTEL_RESOURCE_ATTRIBUTES},${attrs}"
  fi
  OTEL_RESOURCE_ATTRIBUTES="$attrs" command claude "$@"
}
```

**zsh 版の `${${root:-$PWD}:t}` を bash に持ち込むな。** 末尾要素だけを取り出す `:t` は zsh 固有の修飾子で、bash では `bad substitution` になって関数ごと落ちる。bash では `basename` を使え。

どちらも `command claude` で実体を呼ぶため再帰しない。既に `claude` を内部で呼ぶ独自の短縮コマンド（起動用のシェル関数）を定義している場合も、この関数を経由するので個別に直す必要はない。値にスペースは使えない仕様なので `_` に置換している。

**`project=` を代入で上書きせず、既存の `OTEL_RESOURCE_ATTRIBUTES` の後ろに足す形にしろ。** `nt-common` の `research` / `otel-analysis` skill は、別タブで claude を起動する前に `launched_by=<skill名>` を export している。上書きしてしまうとその値が消え、「どの skill が起動したセッションか」を OTel 側で集計できなくなる（専用の属性が他に無いため、プロンプト本文のテキスト検索に頼ることになる）。

**常駐の仕組み（launchd / systemd timer）や cron から `claude -p` を無人実行しているスクリプトには、この関数は効かない**（非対話シェルはシェルの設定ファイルを読まない）。該当するスクリプトを洗い出し、`claude -p` を呼ぶ前に個別に `export` させろ:

```bash
export OTEL_RESOURCE_ATTRIBUTES="project=<リポジトリ名>,job=<処理の名前>"
```

作業ディレクトリの概念が無い処理（枠の暖機・定期集計など）は `job` だけ渡せばよい。`job` の有無で無人実行分を切り分けて集計できる。**キー名に `entrypoint` は使うな** — Claude Code が標準で持つ `app.entrypoint` と紛らわしく、標準属性と同名にした場合は標準側が優先される仕様のため。

検索するときは `resource.attributes.project.keyword` のように `.keyword` を付けろ。日本語検索用の解析器（kuromoji）が全フィールドに効く設定のため、`.keyword` 無しでは文字列が分解されて完全一致しない。

### 動作確認

Claude Code を完全終了 → 再起動してもらい、しばらく使った後に以下を確認しろ:

```bash
curl -s "http://localhost:9200/logs-generic.otel-default/_count"
```

`count` が使うたびに増えていれば成功。増えない場合は3コンテナの状態（`docker compose -f ~/.claude/otel/compose.yaml ps`）とOTel Collectorのログ（`docker compose -f ~/.claude/otel/compose.yaml logs otelcol`）を確認して報告しろ。Kibana（`http://localhost:5601`）でもデータが見えているか確認できる。

「詳細ログも含む」で `OTEL_LOG_RAW_API_BODIES` を `file:<dir>` モードにした場合、以下も確認しろ:

```bash
ls -la ~/.claude/otel/api-bodies/ | tail -5
```

長い差分・大量のツール出力を含むターンを実行した後、`.request.json` / `.response.json` ファイルが増えていて、Elasticsearch側の `api_request_body` イベントに `attributes.body_ref` としてそのファイルの絶対パスが記録され、`attributes.body_truncated` が付いていないことを確認しろ。

自動起動そのものを確認するなら、その場で `bash ~/.claude/otel/start-compose.sh` を実行して `コンテナ基盤の応答を確認した（待ち時間 0 秒）` と `compose up -d が完了した` の2行が出ることを見ろ（既に起動済みなら何も作り直さない）。OS 再起動後は `~/.claude/otel/container-start-stdout.log` の末尾に同じ2行が時刻付きで残り、待ち時間の秒数で実際にどれだけ待ったか分かる。上限まで待って諦めた場合は `container-start-stderr.log` に中止の行が出る。

## Kibana での見方（セットアップ完了後、そのままユーザーに渡せ）

セットアップ直後のユーザーは「記録は溜まったが画面の見方が分からない」状態になる。以下をそのまま渡せ。

**`http://localhost:5601/app/home` を入口として案内するな。** 「まずデータを入れましょう」という初回案内しか出ない。ログを1件ずつ眺める画面は Discover（`/app/discover`）、合計を出すのは同じ Discover の ES|QL モードだ。

### 先に伝えろ: 条件なしで Discover を開くと失敗する

「詳細ログも含む」を選んだ場合、`/app/discover` を検索条件なしで開くと表示が丸ごと失敗し、`Can't store an async search response larger than [10485760] bytes` と出ることがある。既定の 60KB のままなら起きない。

**`OTEL_LOG_RAW_API_BODIES` を `file:<dir>` モードにしている場合、この失敗の主要因だった `api_request_body` の肥大化は解消されている。** 本文自体はElasticsearchのドキュメントに入らず、`body_ref` という短いパス文字列だけが残るためだ。**ただし解消するのは `api_request_body` / `api_response_body` の分だけだ。** `OTEL_LOG_ASSISTANT_RESPONSES` 等の他の詳細ログ属性（応答全文・ツール入出力等）は `file:` モードの対象外で、依然 `CLAUDE_CODE_OTEL_CONTENT_MAX_LENGTH`（256KB）までinlineのまま残るため、それらのイベントが積み重なった場合は同じ10MB上限に依然当たり得る。

回避は2つある。どちらでも直る。

- **検索欄に条件を入れる** — `not event_name : "api_request_body"` のように何か絞り込めば通る。後述のブックマーク6本はすべて条件付きなので、そのまま使えば遭遇しない
- **取得件数を下げる** — `http://localhost:5601/app/management/kibana/settings?query=sample` を開き、`discover:sampleSize` を既定の `500` から `100` に下げる。記録は1件も捨てずに直るが、Discover でめくれる件数が 100 件までになる

### ブックマークに入れてもらう6本

名前とURLをセットで渡せ。**URL は改変するな** — `.keyword` の有無まで含めて実機で動作確認済みの形だ。

**問い合わせ1回ごとの消費量（直近24時間）**

```
http://localhost:5601/app/discover#/?_a=(columns:!(attributes.cost_usd,attributes.model,attributes.query_source,resource.attributes.project),dataSource:(dataViewId:discover-observability-solution-all-logs,type:dataView),filters:!(),interval:auto,query:(language:kuery,query:'event_name%20:%20%22api_request%22'),sort:!(!('@timestamp',desc)))&_g=(filters:!(),refreshInterval:(pause:!t,value:60000),time:(from:now-24h,to:now))
```

**プロジェクト別の消費量ランキング（直近7日）**

```
http://localhost:5601/app/discover#/?_a=(dataSource:(type:esql),filters:!(),interval:auto,query:(esql:'FROM%20logs-generic.otel-default%20%7C%20WHERE%20event_name%20%3D%3D%20%22api_request%22%20%7C%20STATS%20cost%20%3D%20SUM%28attributes.cost_usd%29%2C%20calls%20%3D%20COUNT%28*%29%20BY%20project%20%3D%20resource.attributes.project.keyword%20%7C%20SORT%20cost%20DESC'),sort:!())&_g=(filters:!(),refreshInterval:(pause:!t,value:60000),time:(from:now-7d%2Fd,to:now))
```

**サブエージェント別・台本別の消費量ランキング（直近30日）**

```
http://localhost:5601/app/discover#/?_a=(columns:!(total,runs,name),dataSource:(type:esql),filters:!(),interval:auto,query:(esql:'FROM%20logs-generic.otel-default%20%7C%20WHERE%20%28event_name%20%3D%3D%20%22api_request%22%20AND%20STARTS_WITH%28attributes.query_source.keyword%2C%20%22agent%3A%22%29%29%20OR%20event_name%20%3D%3D%20%22subagent_completed%22%20%7C%20STATS%20cost%20%3D%20SUM%28attributes.cost_usd%29%2C%20agent%20%3D%20MAX%28attributes.agent_type.keyword%29%2C%20wf%20%3D%20MAX%28attributes.workflow.name.keyword%29%20BY%20span%20%3D%20span_id%20%7C%20EVAL%20name%20%3D%20COALESCE%28agent%2C%20CONCAT%28%22wf%2F%22%2C%20wf%29%29%20%7C%20WHERE%20name%20IS%20NOT%20NULL%20%7C%20STATS%20total%20%3D%20SUM%28cost%29%2C%20runs%20%3D%20COUNT%28*%29%20BY%20name%20%7C%20SORT%20total%20DESC'),sort:!())&_g=(filters:!(),refreshInterval:(pause:!t,value:60000),time:(from:now-30d,to:now))
```

`wf/` で始まる行が Workflow（決まった手順を並列で回す仕組み）で、それ以外がサブエージェント名だ。

**Workflow 別の消費量ランキング（直近30日）**

```
http://localhost:5601/app/discover#/?_a=(dataSource:(type:esql),filters:!(),interval:auto,query:(esql:'FROM%20logs-generic.otel-default%20%7C%20WHERE%20event_name%20%3D%3D%20%22api_request%22%20%7C%20STATS%20cost%20%3D%20SUM%28attributes.cost_usd%29%2C%20calls%20%3D%20COUNT%28*%29%20BY%20wf%20%3D%20attributes.workflow.name.keyword%20%7C%20SORT%20cost%20DESC'),sort:!())&_g=(filters:!(),refreshInterval:(pause:!t,value:60000),time:(from:now-30d,to:now))
```

**モデル切り替え履歴（直近30日）**

`nt-common` プラグインの `PostModelSwitch` フックが送っている記録を見る。

```
http://localhost:5601/app/discover#/?_a=(columns:!(attributes.from_model,attributes.to_model,attributes.source,attributes.estimated_cache_write_usd),dataSource:(type:esql),filters:!(),interval:auto,query:(esql:'FROM%20logs-generic.otel-default%20%7C%20WHERE%20event_name%20%3D%3D%20%22model_switch%22%20%7C%20KEEP%20%40timestamp%2C%20attributes.from_model%2C%20attributes.to_model%2C%20attributes.source.keyword%2C%20attributes.estimated_cache_write_usd%20%7C%20SORT%20%40timestamp%20DESC'),sort:!())&_g=(filters:!(),refreshInterval:(pause:!t,value:60000),time:(from:now-30d,to:now))
```

`attributes.source` は他のイベントの同名属性と型が競合するため、ES|QLでは `.keyword` を付けて明示的にキャストしないと `unsupported` 型として弾かれる。

**全種類のログを時系列で眺める（直近15分・条件付き）**

```
http://localhost:5601/app/discover#/?_a=(dataSource:(dataViewId:discover-observability-solution-all-logs,type:dataView),filters:!(),interval:auto,query:(language:kuery,query:'not%20event_name%20:%20%22api_request_body%22'),sort:!(!('@timestamp',desc)))&_g=(filters:!(),refreshInterval:(pause:!t,value:60000),time:(from:now-15m,to:now))
```

期間は画面右上の `Last 24 hours` 等と出ている箇所を押せば選び直せると添えろ。

### 渡すときに一緒に伝えること

- **「サブエージェント別・台本別」と「Workflow 別」で同じ Workflow の回数が桁違いに見える。** 前者の `runs` は起動された回数、後者の `calls` は Anthropic への問い合わせ回数で、単位が別物だ。金額はほぼ一致する。実測では同じ Workflow が 43 回の起動に対して 8,680 回の問い合わせだった
- **`resource.attributes.project` の列が空（`(null)`）になるのは正常**。「作業中のリポジトリ名を記録できるようにする」の手順を入れる前に起動したセッションには名前が付かない。環境変数はプロセス起動時に一度読まれるだけなので、**すでに走っているセッションを閉じて開き直すまで空のままだ**
- **`dataViewId` を含む2本（「問い合わせ1回ごとの消費量」「全種類のログを時系列で眺める」）は Kibana の監視向け表示（Observability）に依存する。** `discover-observability-solution-all-logs` は Kibana が自分で用意している固定の名前で、こちらで作るものではない（保存済みデータビューは0件でよい）。表示モードが監視向けでない環境では存在しないので、その場合は残り4本（ES|QL 方式。`FROM logs-generic.otel-default` を直接書くのでデータビューに依存しない）を使わせろ
- **`.keyword` は付ける場所と付けない場所がある。** `resource.attributes.project` / `attributes.model` / `attributes.query_source` / `attributes.agent_type` / `attributes.workflow.name` / `attributes.source` は付けろ（`attributes.source` は他イベントの同名属性と型が競合し `unsupported` になるため、`.keyword` で明示的にキャストしないと参照できない。他は付けないと日本語解析で分解されて一致しない）。`event_name` は最初から集計可能な型なので、付けると `Unknown column [event_name.keyword]` になる

## 厳守事項

`nt-setup` の `references/common-setup-conventions.md`「厳守事項」に加え、以下を守れ（自動起動の登録確認は launchd に限らず `systemctl --user enable --now` の前にも必要）。

- **`sudo` を勝手に実行するな**。`loginctl enable-linger` / Docker デーモンの有効化はコマンドを提示してユーザー自身に実行してもらえ
- **`~/.claude/settings.json` のバックアップファイル（`*.bak.*` 等）を作るな**。別ファイルへ書いてから `mv` で差し替え、書き込み後に Read で検証しろ
- **日本語検索用component templateの登録は、ログが1件も送信される前に済ませろ**（後回しにするとロールオーバーが追加で必要になる）

## 注意点（セットアップ完了後、必ずユーザーに伝えろ）

- **記録される `cost_usd` は請求額ではない**。Anthropic のトークン単価から Claude Code 側が計算した「同じトークン量を従量課金の API で使ったらいくらか」の換算値だ。サブスクリプション（Pro / Max / Team のシート等の定額）で使っている場合は実際の支払いに一切影響せず、利用枠（5時間枠・7日枠）をどれだけ食ったかの目安としてのみ意味を持つ。従量課金の API キーで使っている場合は実費に近い値になる
- 「詳細ログも含む」を選んだ場合、プロンプト全文・応答全文・API の生ボディが平文でElasticsearchに記録される。会話・コードの内容がまるごと記録される
- `user.email` や `session.id` などの識別情報もイベントごとに記録される
- **保存期間の上限は設けていない（無期限）。使用量に応じてディスクを消費し続ける**ため、定期的にディスク使用量（`docker exec claude-elasticsearch du -sh /usr/share/elasticsearch/data`等）を確認することを勧めろ
- 「詳細ログも含む」を選ぶと `CLAUDE_CODE_OTEL_CONTENT_MAX_LENGTH` を既定の4倍（60KB→256KB）にするため、API 生ボディが多いセッションではディスクの増え方も4倍近くになり得る。ディスクを抑えたい場合はこの値を下げるか、`OTEL_LOG_RAW_API_BODIES` を切れと案内しろ
- Kibana（`http://localhost:5601`）でも同じデータを画面で閲覧・検索できる。**見方は「Kibana での見方」の節をそのまま渡せ。** 「詳細ログも含む」を選んだ場合、条件なしで Discover を開くと10MB上限で必ず失敗する点は必ず先に伝えろ

## アンインストール手順（ユーザーに聞かれた場合のみ案内）

macOS:

```bash
launchctl bootout gui/$(id -u)/com.claude.otel-container-start
rm ~/Library/LaunchAgents/com.claude.otel-container-start.plist
docker compose -f ~/.claude/otel/compose.yaml down
rm -rf ~/.claude/otel
```

Linux:

```bash
systemctl --user disable --now claude-otel-container-start.service
rm ~/.config/systemd/user/claude-otel-container-start.service
systemctl --user daemon-reload
docker compose -f ~/.claude/otel/compose.yaml down
rm -rf ~/.claude/otel
```

`~/.claude/settings.json` の `env` から OTEL 関連キーを削除するのは手動編集を案内しろ（他の設定を壊さないよう自動削除するな）。
