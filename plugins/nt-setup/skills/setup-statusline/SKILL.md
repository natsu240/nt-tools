---
name: setup-statusline
description: ステータスラインをセットアップするときに起動しろ。
effort: low
---

# Claude Code ステータスライン 自動セットアップ

Claude Code のステータスライン（画面下に常時表示される情報バー）を対話式にセットアップする。ローカルスクリプトが描画するだけなのでトークンは一切消費しない。5h/7d の使用率を Elasticsearch に記録する設定も併せて行う（`/setup-otel` 導入済みの環境のみ。下記「利用枠の使用率を Elasticsearch に記録する」参照）。

公式仕様: `https://code.claude.com/docs/en/statusline`（実装前に必ず WebFetch で最新仕様を確認しろ。特に `Available data` セクションのフィールド一覧は変わる可能性がある）。

## 前提条件の確認

`nt-setup` の `references/common-setup-conventions.md`「前提条件の確認」に加え、以下を確認しろ。

- **`jq` コマンドがある** — `command -v jq` で確認。無ければ導入を案内して中断しろ（macOS は `brew install jq`、Linux は `sudo apt install jq` 等）

## 既存セットアップの確認

以下を確認しろ:

- `~/.claude/statusline.sh` が既に存在するか
- `~/.claude/settings.json` に `statusLine` キーが既にあるか

いずれか存在する場合は「既にステータスラインが設定済みのようです。上書きしますか？」とユーザーに確認しろ。同意が無ければ中断しろ。

## 表示内容

以下をすべて表示する（表示レベルの選択肢は無い。6行構成）:

- 1行目: モデル名・バージョン(+latest比較)・effort・作業ディレクトリ+ブランチ
- 2行目: コンテキスト使用率バー(70%黄/90%赤)・使用トークン数(実際のコンテキストウィンドウ上限に対する割合)
- 3行目: 直近ターンのキャッシュヒット率・セッション全体のキャッシュヒット率とミス回数（`prompt_cache.hit_ratio` が無ければ非表示。Claude Code 2.1.251 未満、またはセッションの最初のAPI応答前は非表示。どちらも取れないときは行ごと非表示）
- 4行目: 直近のキャッシュミスの原因と経過時間（`prompt_cache.last_miss_cause` が無ければ行ごと非表示）
- 5行目: 5h 利用制限の予測%とリセットまでの残り時間（値が無ければ非表示）
- 6行目: 7d 利用制限の予測%とリセットまでの残り時間（値が無ければ非表示）
- 追加行: 現在のブランチに紐づく実装計画書・GitHub Issue・PR（該当情報がある項目だけ、項目ごとに1行。最大で計画書/Issue/PRの3行が追加される）。計画書の行はパス構造から状態（進行中/レビュー中/完了）を取り出して `📋 [進行中] plans/進行中/...` のように先頭に表示し、記録ファイルから確定できないぶんは候補として `📋? [進行中・候補] plans/進行中/...` の形で区別する

5h/7d の「予測%」は Claude Code が直接提供する値ではなく、現在の使用率とリセットまでの残り時間から線形外挿した自前の見積もりである点をユーザーに明示しろ（7d 側は平日/週末で消費ペースが異なる前提で、未来分は平日ペースのみで外挿する）。

**紐づく計画の検出は、まずブランチ名からの推測で行う。** ステータスラインは Claude Code の会話内容・TaskList には原理的にアクセスできない独立した bash スクリプトなので、ブランチ名から GitHub Issue 番号（ブランチ名が `issue-<数字>`）を検出し、それを手がかりに `gh issue view` / `gh pr view` を行う。この制約をユーザーに明示しろ。

**`nt-developer:plan` skill が「今このリポジトリで作業中の計画書」を記録する経路がある。** ステータスラインはその記録を読むだけなので、ブランチ名にも git の差分にも依存しない（詳細は下記「作業中の計画書の記録ファイルを読む」）。

**それでも見つからない場合、`/pr` skill の経路B と同じ考え方で「変更したファイルのパスが `plans/進行中/` 配下の計画書の『触るファイル』節に重なるか」を見て候補を探す。** これは確定的な紐付けではないため、確定表示（`📋`）とは区別して `📋?` で候補として表示する（内容の照合まではしないため、同じファイルを触る別作業の計画書を誤って候補に挙げる可能性がある）。

検出の優先順位は **記録ファイル → 変更ファイルのパスが重なった候補** だ。リポジトリ単位の記録を先に置き、パスが重なっただけの候補が最後になる。

**7d の平日/週末の内訳は、`/setup-otel` 導入済みなら OTel の Elasticsearch（`logs-generic.otel-default` の `attributes.cost_usd`）から今週分を日別に直接集計し、実際の日付から曜日判定して求める。** これが正しい内訳の取り方で、未導入・未接続の環境だけ「描画された瞬間の曜日に消費をまるごと計上する」差分の積み上げ方式にフォールバックする（この方式は、描画が飛んだ区間の消費が誤った曜日に計上される誤差を持つ。実測で洗い出し済み）。外挿そのもの（今週これまでの実測ペースをそのまま残り時間に伸ばす）は共通で、過去の週の平均や時間帯パターンは一切使わない。

## 作業中の計画書の記録ファイルを読む

ブランチ名を個人名で固定しているリポジトリでは、ブランチ名から手がかりが一切取れない。さらに `plans/` はコミットしないため `git diff --name-only` にも出てこず、コード変更を伴わない調査タスクでは「触るファイル」節との突き合わせも当たらない。この組み合わせでは、ブランチ名と git の差分だけを手がかりにする限り計画書を見つけられない。

そこで `nt-developer:plan` skill が、計画書を作った時点で次の1件を記録する。ステータスラインはそれを読むだけだ。

- 置き場所: `~/.claude/state/plan-current<リポジトリルートの絶対パスの / を _ に置き換えた文字列>.json`
- 中身: `{"repo": "<リポジトリルートの絶対パス>", "plan": "<計画書の絶対パス>"}`

**この記録はセッション ID で分けない。** 同じ計画の続きを別のセッションで進めることが多いため、リポジトリ単位で永続させ、セッションを開き直しても復元できるようにしている（他の一時ファイルが `/tmp/statusline-*-<session_id>` なのと対照的だ）。

読むときの決まり:

- ファイル内の `repo` が今の `git rev-parse --show-toplevel` と一致するときだけ使う（別リポジトリで作業中の計画書を誤って出さないため）
- 記録されたパスが存在しなければ、**同じファイル名を `plans/` 配下から探し直し、見つかったパスで記録を更新する**。`plan` の運用で「変わるのは状態のディレクトリだけで、管理表のディレクトリとファイル名は変えない」と決まっているため、これで `進行中` → `レビュー中` → `完了` の移動に追従できる。`pr` skill・移動を担当する hook のどれにも記録の更新処理を持たせずに済む
- 探し当てた先が `plans/完了/` 配下なら表示せず、記録ファイルを消す
- 名前でも見つからない（計画書を消した・改名した）場合は何もせず、次の経路へ落とす。記録ファイル自体は残すが無視されるだけで、次に `/nt-developer:plan` を使ったときに上書きされる

## ファイル配置

このスキルの `templates/statusline.sh`（`${CLAUDE_SKILL_DIR}/templates/statusline.sh`）を `~/.claude/statusline.sh` にコピーしろ。

コピー後、実行権限を付与しろ:

```bash
chmod +x ~/.claude/statusline.sh
```

## Claude Code 側の設定（settings.json）

`statusLine` フィールドをマージしろ。`refreshInterval` を `1` にしろ（5h/7d の残り時間が毎秒チクタク動くようにするため）。

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 1,
    "refreshInterval": 1
  }
}
```

`jq` で既存キーを保持したままマージしろ:

```bash
jq --argjson sl '<上記いずれかのJSON>' '.statusLine = $sl' ~/.claude/settings.json > ~/.claude/settings.json.new
mv ~/.claude/settings.json.new ~/.claude/settings.json
```

## 利用枠の使用率を Elasticsearch に記録する

5h/7d の使用率は Claude Code が stdin の JSON（`rate_limits.five_hour.used_percentage` 等）で渡してくるだけで、**OTel のログ側には一切入らない**。メトリクス一覧・ログイベント一覧・hook の入力のどれにも該当する項目が無いことを公式ドキュメントで確認済みだ。ステータスラインは毎秒この値を受け取っているので、変化した瞬間だけ Elasticsearch へ書けば「いつ枠が減ったか」の時系列として残せる。

まず記録先があるかを確認しろ:

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 2 http://localhost:9200
```

`200` 以外（`/setup-otel` 未導入・コンテナ停止中）なら**この節は飛ばせ**。ユーザーに聞く必要も無い（記録先が無いだけで、画面表示は変わらない）。`200` が返ったときだけ「利用枠の使用率を Elasticsearch に記録しますか」と確認しろ。

同意が得られたら、インデックステンプレート（`${CLAUDE_SKILL_DIR}/templates/rate-limits-index-template.json`）を登録しろ:

```bash
curl -s -X PUT "http://localhost:9200/_index_template/claude-rate-limits" \
  -H 'Content-Type: application/json' \
  -d @"${CLAUDE_SKILL_DIR}/templates/rate-limits-index-template.json"
```

`{"acknowledged":true}` が返れば登録できている。**テンプレートを登録せずに書き込むと、Elasticsearch が型を推測して勝手にインデックスを作る**（使用率が整数に丸められ、リセット時刻が日時として扱われなくなる）。必ず書き込みより先に登録しろ。

同意が得られなかった場合は、コピー済みの `~/.claude/statusline.sh` の `RATE_LIMIT_INDEX=""` に書き換えろ（画面表示はそのまま残り、書き込みだけ止まる）。

記録される項目:

| 項目 | 内容 |
|---|---|
| `@timestamp` | 記録した時刻（UTC） |
| `five_hour.used_percentage` / `seven_day.used_percentage` | 各枠の使用率（0〜100） |
| `five_hour.resets_at` / `seven_day.resets_at` | 各枠のリセット時刻（Unix 秒） |
| `project` | 作業リポジトリ名（git のトップレベルの名前。git 管理外なら作業ディレクトリ名） |
| `session_id` | セッション ID |
| `model` / `version` | モデル表示名・Claude Code のバージョン |

ユーザーには次の2点を必ず伝えろ:

- **利用枠はアカウント全体で共有される1つの値だ。** 複数セッションを同時に動かしていればどのセッションでも同じ値が見える。`session_id` / `project` は「その時刻に描画していたのがどのセッションか」の目印でしかなく、どのセッションが枠を食ったかの切り分けには使えない
- **ステータスラインが描画されていない間は記録が飛ぶ。** Claude Code を開いていない時間帯・Remote Control 経由のセッションでは値を受け取れないため、連続した時系列にはならない

記録した値の集計・`api_request` との突き合わせは `/otel-analysis` が担当する。

## 動作確認

まずモック入力でスクリプト自体が正しく動くか確認しろ（公式ドキュメントの Tips に準拠）:

```bash
echo '{"model":{"display_name":"Sonnet 5"},"workspace":{"current_dir":"'"$HOME"'/test"},"context_window":{"used_percentage":25,"total_input_tokens":15500},"version":"2.1.211","effort":{"level":"high"},"session_id":"test-session"}' | ~/.claude/statusline.sh
```

出力が崩れず表示されれば OK。このモック入力には `rate_limits` を入れていないので 5h/7d の行は出ず、Elasticsearch への書き込みも走らない（動作確認のたびに架空の使用率が記録に混ざるのを避けるため、ここでは意図的に入れていない）。

次に、設定ファイルが正しく反映されているかを確認し、ユーザーに「Claude Code を完全終了 → 再起動すると画面下にステータスラインが表示されます」と案内しろ。

利用枠の記録を有効にした場合は、再起動して少し使ってから件数を確認しろ:

```bash
curl -s "http://localhost:9200/claude-rate-limits/_count"
```

使用率が変わったときだけ書かれるので、起動直後は 0 件のこともある。1件以上になっていれば記録できている。

## 厳守事項

`nt-setup` の `references/common-setup-conventions.md`「厳守事項」に加え、以下を守れ。

- **`~/.claude/settings.json` のバックアップファイル（`*.bak.*` 等）を作るな**。別ファイルへ書いてから `mv` で差し替え、書き込み後に Read で検証しろ

## 設計上の注意点（カスタマイズを頼まれたときのために）

- **直近ターンのキャッシュヒット率は `context_window.current_usage`（stdin の JSON に含まれる公式フィールド。直近1回のAPI呼び出し分のトークン内訳）から直接算出する**。`current_usage` が必要な情報（`input_tokens` / `cache_creation_input_tokens` / `cache_read_input_tokens` / `output_tokens`）を最初から渡してくれるため、会話ログをパースする必要は無い。Stop hook 等の外部状態書き込みにも依存しない
- **セッション全体のヒット率・直近のミス原因は、stdin の JSON に含まれる公式フィールド `prompt_cache`（`hit_ratio` / `misses`。ミス原因は `last_miss_cause` / `last_miss_at` で Claude Code 2.1.260 以降）をそのまま使う。** 自前の状態ファイルで起点を推定する方式は使わない
- **ミス原因のコードは閉じた集合で、本体の `/cost` 表示と同じ対応で日本語ラベルに置き換える。** 未知のコードが増えたときはコードをそのまま出す。`tools_changed` には増減ツール数、`system_prompt_changed` には文字数差を添える
- **キャッシュリセットまでの残り時間（`warm` / `expires_at` / `ttl` / `caching_observed`）は表示しない。** Orca が同じ情報をデフォルトで出すため重複する
- `context_window.context_window_size`（実際のコンテキストウィンドウ上限。200000 または 1000000）を使ってトークン数の分母を表示する。固定値ではなくこの値を使わないと、20万トークン上限のモデルでも分母が「100万」のまま表示されるバグになる
- **最新バージョンの取得結果（`npm view`）は `/tmp/statusline-latest-version` に1時間キャッシュする。キャッシュ名をセッションごとに分けるな。** npm の最新バージョンは全セッションで同じ値なので、`<session_id>` を名前に入れると新しいセッションを開くたびに取り直しになる。`refreshInterval=1` と組み合わさるため、キャッシュが埋まるまでの間は毎秒 `npm view` がバックグラウンド起動され続ける。共有すると複数セッションが同時に取りに行くことがあるので、書き込み中のファイル名にはプロセス番号（`$$`）を入れて衝突を避ける
- **セッションごとに作る `/tmp` のファイルは、上のバージョン取得（1時間に1回しか通らない）のついでに掃除する。** ブランチ名・キャッシュ起点・計画書パスのキャッシュはセッションが終わっても残り、消す仕組みが無いと溜まり続ける（実測で4日ぶんの作業で452件）。`find -H /tmp -maxdepth 1 -name 'statusline-*' -type f -mtime +3 -delete` で3日以上更新されていないものだけ消す。**macOS の `/tmp` は `/private/tmp` へのシンボリックリンクなので、`-H` を付けないと find がリンクの先へ入らず1件も消えない**（実測で確認済み）
- git ブランチ名は `/tmp/statusline-branch-<session_id>` に5秒キャッシュする。`refreshInterval=1` で毎秒 `git` プロセスを起動し続けるコストを避けるため（公式ドキュメントの `Cache expensive operations` の例に準拠）
- **紐づく実装計画書・GitHub Issue・PR の検出はブランチ名だけを手がかりにする。** `plans/*.md` の探索は `/tmp/statusline-plan-<session_id>` に5秒キャッシュ（ブランチキャッシュと同じ考え方）、`gh issue view` / `gh pr view` はネットワーク越しで重いため `/tmp/statusline-issue-<番号>.json` / `/tmp/statusline-pr-<ブランチ名>.json` に60秒キャッシュし、`npm view` の最新バージョンチェックと同じくバックグラウンドで更新する（今回の描画には間に合わず、次回描画で反映される）
- **記録ファイルの読み取りは `jq` 2回だけなので、キャッシュせず毎回の描画で同期実行する。** 記録されたパスが存在せず探し直しが要るときだけ `find` が走り、その結果を `/tmp/statusline-plan-resolve-<session_id>` に5秒キャッシュする。**このキャッシュはセッション単位なので、同じセッションで別リポジトリへ移った直後は前のリポジトリの結果が残る。** 採用する前に、探し当てたパスが今のリポジトリルート配下かどうかを必ず確認しろ
- **記録ファイルの名前は `${REPO_ROOT//\//_}`（bash の文字列置換）で作り、ハッシュ関数を呼ぶな。** 毎秒描画されるスクリプトなのでプロセスを1つ増やさない。`/` を `_` にするだけの変換は理論上は別のパスと衝突しうるが、ファイル内の `repo` を突き合わせているので衝突しても誤表示にはならない（一致しないので無視されるだけだ）
- **計画書が記録ファイルから確定できない場合の候補探索（経路B）は `/tmp/statusline-plan-candidate-<session_id>` に10秒キャッシュする。** `git diff --name-only` の実行と `plans/進行中/` 配下の各 `.md` の「触るファイル」節との突き合わせを含むため、確定探索（5秒キャッシュ）より重い処理として長めに取っている。`plans/進行中/` が無いリポジトリではこの処理自体を実行しない
- **GitHub Issue / PR のリンクは、ターミナルのハイパーリンク（OSC 8）でクリック可能にする。** 対応していないターミナルでもエスケープシーケンスを無視するだけで表示は崩れない
- **`gh` CLI が無い・未認証の環境でも該当行が非表示になるだけで、他の行の表示には影響しない**（各取得処理は `command -v gh` で存在確認してからのみ実行する）
- **`plans/` ディレクトリが無いリポジトリ（GitHub Issue 専業）でも探索処理はエラーにならない**（`find` が単に何も見つけず空を返すだけ）
- 週次(7d)の平日/週末按分は `~/.claude/state/es-weekday-split-<reset_epoch>.json` に Elasticsearch の実測結果を30秒キャッシュする（ES への問い合わせは `refreshInterval=1` の毎秒描画には重いため）。ES が使えない場合だけ `~/.claude/state/week-trace-<reset_epoch>.json` への差分積み上げ方式にフォールバックする。どちらも複数セッション間で共有される想定の値（アカウント全体の利用制限を表しているため）
- 「上限〜XX万」のような枠の絶対量推定は含めていない。5h/7d の利用制限値はセッション横断・アカウント全体で共有される値であり、複数セッションが同時に活発だと分離できず異常値を出すため、意図的に含めていない
- 利用枠の記録は `record_rate_limits` 関数が担当し、`RATE_LIMIT_INDEX` を空にすると止まる。使用率が前回描画時から変わったかどうかは `~/.claude/state/rate-limit-sent.json` に前回送った値を残して判定する。`refreshInterval=1` の毎秒描画でそのまま書くと同じ値が毎秒積み上がるため、変化点だけを記録する
- **送信が成功したときだけ `rate-limit-sent.json` を更新する。** 先に更新してしまうと、Elasticsearch が停止している間に「送ったことになっている」状態が進み、復帰後も使用率が変わるまで1件も書かれない空白ができる
- 書き込みは `curl` を背景で実行して描画を待たせない（`--max-time 2` と `-f` を付けており、Elasticsearch が居なければ何も起きずに終わる）
