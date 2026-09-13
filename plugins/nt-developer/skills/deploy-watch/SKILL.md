---
name: deploy-watch
description: PRマージ後にデプロイ完了を待って後始末する前に必ず起動しろ。
argument-hint: "[Issue番号 または plans/完了/<管理表>/<ファイル名>.md]"
effort: low
---

# デプロイ監視とマージ後の後始末

PR がマージ済みで、計画の「検証・完了条件」にデプロイ後でないと確認できない項目が残っている状態から始まるセッションだ。

**ここでやるのは実際の環境での確認と後始末だけで、コードの実装ではない。** 確認の結果あらたに直すべきものが見つかっても、このセッションでは直すな。

| 詳細手順 | いつ読むか |
|---|---|
| `${CLAUDE_SKILL_DIR}/../../references/issue-body-update.md` | Issue の description を書き換えるとき |

## 呼ばれ間違いの検出

- **PR がまだマージされていないなら、それは `review` の担当だ。** `/nt-developer:review` を案内して止まれ
- **計画の「検証・完了条件」に未完のチェックボックス（`- [ ]`）が1件も無いなら、この skill でやることは無い。** その旨を伝えて止まれ
- **デプロイを持たないリポジトリでは起動するな。** このリポジトリ（nt-tools）自身が該当する

## 入口でこれを全部やれ

- **Issue 経路**: `gh issue view <番号> --json body --jq .body` で description を**全文読め**
- **plans 経路**: `plans/完了/<管理表>/<ファイル名>.md` を Read で**全文読め**
- 「検証・完了条件」に残っている未完タスクを列挙しろ。**そのうちデプロイの完了を待つ必要があるものと、待たずに今すぐ確認できるものを分けろ**

待つ必要があるものが1件も無ければ、監視を飛ばして下の「後始末」へ直接進め。

## デプロイの監視方法を取得しろ

対象リポジトリの `project_notes/deploy.md` の「デプロイ監視」節を Read しろ。

**節が無い、またはファイル自体が無い場合、推測でコマンドを組み立てるな。** ユーザーに以下を聞き、**聞いた内容を `project_notes/deploy.md` へ追記することを提案しろ**（次回から聞かずに済む）。

- デプロイの経路（GitHub Actions / CodePipeline / その他）
- 監視に使うコマンド
- 完了までの所要時間の目安

追記する形はこれだ。

```markdown
## デプロイ監視

- 経路: GitHub Actions（ワークフロー `deploy.yml`）
- 監視コマンド: gh run watch <run-id> --exit-status
- 所要時間の目安: 約20〜30分
```

## 監視の必須要件

**以下は全部守れ。1つでも外すと、デプロイが失敗したまま無言で待ち続ける事故になる。**

- **監視を前景で実行するな。必ず `Bash` の `run_in_background` に回せ。** 前景で流すと待っている間ずっと出力が会話に入り続け、トークンを食い潰す
- **成功だけを待つループを書くな。** 成功・失敗・キャンセル・タイムアウトの全ての終端状態で必ず抜けろ。成功だけを待つと、失敗したときスクリプトが終わらず、無言のまま気づけない
- **上限時間を必ず設けろ。** 上限に達したら「タイムアウト」として抜けて報告しろ。**タイムアウトを失敗と同じ出力にするな。** どちらも「成功しなかった」だが、失敗はデプロイの結果で、タイムアウトはまだ結果が出ていないという意味で、ユーザーが次に取る行動が違う
- **待つ前に、監視する対象の実行を1つに特定しろ。「そのワークフロー / パイプラインの最新の状態」を見るな。** マージした直後はまだ新しい実行が始まっていないことがあり、そのとき最新の状態として返るのは**前回のデプロイの結果**だ。前回が成功していれば、1周目でそれを拾って「デプロイ成功」と報告して終わる。CodePipeline はデプロイが1つも走っていない状態でも最終ステージの状態として `Succeeded` を返す
- **`Monitor` ツールを使うな。** `Monitor` は標準出力の1行が会話メッセージ1個になる。**必要なのは終端状態だけで、途中の段階（ビルド完了・デプロイ開始等）は受け取るな**
- **`gh run watch` の `--interval` を指定するな。** これは gh が自分の表示を描き直す間隔（既定3秒）でしかなく、背景実行では誰も画面を見ないため意味が無い。Claude 側が一定間隔で確認するという意味でもない

## 経路ごとの書き方

### GitHub Actions

`gh run watch <run-id> --exit-status` は**完了するまで戻ってこないコマンド**だ。問い合わせは gh のプロセスの中で完結するので、これを背景に投げるだけでよい。終了コードで成否が分かる（成功が 0、失敗は 0 以外）。

**run は、今マージしたコミットの SHA で特定しろ**（`gh run list -c <SHA>`）。`--limit 1` で最新を取るだけでは、run がまだ作られていない一瞬に前回の run を掴む。

```bash
sha=$(git rev-parse HEAD)   # マージ後の base ブランチの先頭
run_id=""
for _ in $(seq 1 20); do    # run が作られるまで最大10分待つ
  run_id=$(gh run list --workflow <ワークフローのファイル名> -c "$sha" --limit 1 --json databaseId --jq '.[0].databaseId')
  [ -n "$run_id" ] && break
  sleep 30
done
if [ -z "$run_id" ]; then echo "result=NoRun"; exit 0; fi

gh run watch "$run_id" --exit-status --compact &
watch_pid=$!
( sleep <上限秒数>; kill "$watch_pid" 2>/dev/null ) &
killer_pid=$!
wait "$watch_pid"
rc=$?
kill "$killer_pid" 2>/dev/null
case "$rc" in
  0)   echo "result=Succeeded" ;;
  143) echo "result=Timeout" ;;   # 上限に達して kill した（SIGTERM）
  *)   echo "result=Failed rc=$rc" ;;
esac
```

- **`result=` の値だけを見て次へ進め。** `Timeout` と `Failed` を混ぜるな（上の `case` が無いと、上限で kill した 143 も失敗と同じ「0 以外」になって区別できない）
- **`result=NoRun` は「デプロイが始まらなかった」だ。** 成功でも失敗でもないので、そのままユーザーに報告して止まれ
- **`timeout` コマンドを使うな。macOS には標準で入っていない**（GNU coreutils を入れた環境にしか無い）。上限は上の形で自分で作れ

### CodePipeline

**AWS CLI の codepipeline には待機用のサブコマンド（`aws codepipeline wait`）が無い。** 状態を問い合わせるループを自分で書くしかない。ループを書くこと自体は問題ではない。背景に投げれば `gh run watch` と同じ扱いになる。

**`get-pipeline-state` でパイプライン全体の状態を見るな。** 返るのは各ステージが最後に走ったときの結果で、新しい実行がまだそのステージに届いていなければ前回の結果がそのまま残る。**待つ実行の ID を先に確定させ、その ID の状態だけを追え。**

**「前回と違う ID が現れるまで待つ」比較（baseline 方式）を書くな。** マージから数秒で新しい実行が作られる環境（WebhookV2 等）では、最初の問い合わせで baseline としてすでに今回の実行を掴んでしまい、以後 ID が変化しないため誤って `NoRun` 判定になる。**実行は、今マージしたコミットの SHA で特定しろ**（`sourceRevisions[].revisionId` がコミット SHA になる）。GitHub Actions 節の `gh run list -c <SHA>` と同じ考え方だ。

```bash
sha=$(git rev-parse HEAD)   # マージ後の base ブランチの先頭

# マージを受けて始まる実行を SHA で特定するまで最大10分待つ。
exec_id=""
for _ in $(seq 1 20); do
  exec_id=$(aws --profile <プロファイル> codepipeline list-pipeline-executions --pipeline-name <パイプライン名> \
    --no-paginate --query "pipelineExecutionSummaries[?sourceRevisions[?revisionId=='$sha']].pipelineExecutionId | [0]" --output text 2>/dev/null)
  [ -n "$exec_id" ] && [ "$exec_id" != "None" ] && break
  sleep 30
done
if [ -z "$exec_id" ] || [ "$exec_id" = "None" ]; then echo "result=NoRun"; exit 0; fi

# 確定した実行 ID の状態だけを追う。
for _ in $(seq 1 <試行回数の上限>); do
  status=$(aws --profile <プロファイル> codepipeline get-pipeline-execution --pipeline-name <パイプライン名> \
    --pipeline-execution-id "$exec_id" --query 'pipelineExecution.status' --output text 2>/dev/null || echo "Unknown")
  case "$status" in
    Succeeded|Failed|Stopped|Superseded) echo "result=$status exec=$exec_id"; exit 0 ;;
  esac
  sleep 30
done
echo "result=Timeout exec=$exec_id"
```

- **`case` に成功以外の終端状態を必ず全部並べろ**（`Failed` / `Stopped` / `Superseded`）
- 問い合わせが一時的に失敗してもループを止めるな（`|| echo "Unknown"` で握って次の周回へ進め）
- **`result=NoRun` は「デプロイが始まらなかった」だ。** 成功でも失敗でもないので、そのままユーザーに報告して止まれ
- **`--profile` を省くな。** 既定の資格情報のまま実行すると、狙った環境とは別の環境の状態を見たまま断定する事故になる
- **`--max-items` を使うな。** AWS CLI は `--max-items` 指定時、`--output text` の出力末尾に NextToken（無ければ文字列 `None`）を独立した行として追加するため、`$()` で拾った変数に2行入る事故になる。`--no-paginate` を使え（ページネーションを無効化し、最初の1ページのみを1回の API 呼び出しで返す）。`list-pipeline-executions` の `maxResults` 既定値は100件なので、直近の実行を取りこぼす心配は無い

## デプロイが成功したら

「検証・完了条件」に残っている未完タスクを実際に実行しろ。

- 確認した結果を「検証・完了条件」に追記し、チェックボックスを `- [x]` に書き換えろ。更新は経路ごとに `${CLAUDE_SKILL_DIR}/../../references/issue-body-update.md`（Issue 経路）または計画書の直接編集（plans 経路）に従え
- **外部のチケット管理ツールへの反映は、計画にそう書かれているときだけやれ。** 書かれていないものを気を利かせて更新するな
- 確認の結果、不具合・想定外の挙動が見つかった場合は、**この Issue / 計画書を再利用するな。** 新しい Issue（または `plans/進行中/` の新しい計画書）を立てて別の対応にしろ。マージ済みの Issue を開き直して実装ステップを追記すると、既に閉じた作業の記録が汚れる
- **Issue を再オープンするな**（マージ時に既に閉じている）

## デプロイが失敗したら

**止まってユーザーに報告しろ。** 以下を勝手にやるな。

- 再実行（`gh run rerun` / `aws codepipeline start-pipeline-execution`）
- ロールバック
- 原因と決めつけたコードの修正

報告には失敗したジョブ・ステージ名と、取得できたエラーの出力をそのまま載せろ。要約で済ませるな。

## 終わり方

- 全ての未完タスクを埋め終えたら、埋めた内容を報告して終われ
- 背景に投げた監視が残っていないか確認し、残っていれば `TaskStop` で止めてから終われ
