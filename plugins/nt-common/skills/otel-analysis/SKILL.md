---
name: otel-analysis
description: Claude Code のトークン消費・作業履歴を調べる前に必ず起動しろ。
allowed-tools: Bash, SendMessage
effort: low
---

# otel-analysis

依頼内容: $ARGUMENTS

このスキルは、Orca 管理下の別タブで対話claude（`nt-common:otel-analyst` agent）を起動して集計・分析を任せる。理由: 大量ログの集計・あいまい検索を今のセッションの中で行うと、curlの生JSON出力やスクリプトの中間出力でメインの会話のコンテキストを圧迫する。別タブに切り出せば、集計過程はそのタブに閉じ、メインの会話には最終レポートだけが届く。

## 起動手順

1. 他の分析と衝突しない一意なセッション名を決めろ（例: `otel-$RANDOM`）。**58文字以内に収めろ。** Claude Code のセッション名は64文字が上限で、スクリプトが末尾にPID（`-` + 5〜6桁）を足すためだ。超えた分はスクリプトが先頭58文字で切り詰めるので起動自体は通るが、名前が途中で切れて読めなくなる。以降 `<NAME>` と書く。`<SKILL_DIR>` は、この Skill 呼び出しの冒頭に表示された `Base directory for this skill` の値に置き換えろ
2. 以下で Bash を実行しろ（同期的に実行しろ）:

```bash
CLAUDE_SKILL_DIR="<SKILL_DIR>" bash "<SKILL_DIR>/scripts/launch-analysis.sh" "<NAME>"
```

3. Bash の標準出力に表示された2行を確認しろ（1行目が `<TAB_HANDLE>`、2行目が確定名。確定名は `<NAME>` にPIDが付加された値になる）。以降の `<NAME>` はこの確定名を使え
4. `ListAgents` を呼び、結果冒頭の「This session is `<自セッション名>` ... — the name other sessions use to message it」から自分のセッション名を確認しろ
5. `orca terminal send --terminal <TAB_HANDLE> --text $'SendMessageツールで自分から集計・分析し、完了したら SendMessage で <自セッション名> 宛に結果を送信し、その後Stopしろ。\n\n依頼内容: $ARGUMENTS' --enter --json` で指示を投入しろ（`$'...'` の ANSI-C クォートで `\n\n` を実際の改行にしろ）
6. `orca terminal send --terminal <TAB_HANDLE> --text '/goal 対象期間のログを取りこぼさず集計し、出した数値をすべて実際のクエリ結果で裏付けた上で分析し終え、その結果を SendMessage で <自セッション名> 宛に送信し終えていること。確認できなかった点が残る場合は、確認を試みた手段となぜ確認できなかったかを結果に明記していること' --enter --json` で完了条件を貼れ。**完了条件は「送信し終えたこと」だけにするな。** 送信の有無しか条件に入っていないと、集計を尽くさないまま結論を出しても条件を満たしてしまう。**`/goal` の後ろに依頼本文を続けるな。** `/goal` はスラッシュコマンドなので、同じメッセージに書いた本文はすべて完了条件の文字列として渡り（上限4000文字）、依頼本文がタスクとして届かない
7. `orca terminal read --terminal <TAB_HANDLE> --screen --json` で画面に `Goal set:` が出ているのを確認しろ。出ていなければ完了条件が貼られていないので、原因を報告して止まれ
8. これ以上ツールを呼ばず、`SendMessage` で確定名からの返信（分析結果）が届くのを待て
9. **返信が届いたら、他の何より先に `orca terminal close --terminal <TAB_HANDLE> --tab --json` を実行しろ。** 返信内容を見た直後の最初の行動はこれだ。後回しにすると、以降の「これ以上何もするな」の指示に引っ張られてタブを閉じること自体を忘れる
10. タブを閉じ終えたら、**これ以上何もするな。** `SendMessage` で届いた分析結果（cross-session-message）はシステムが起動元ユーザーに直接表示する。再掲・要約・言い換えを含め一切出力を行うな

## 相手が見つからない・応答が無いとき

- `bash launch-analysis.sh` が非0で終了した場合、`orca terminal create` の失敗（Orca 未起動・Orca 管理外のターミナルで実行した等）が原因だ。標準エラー出力の内容をそのまま報告しろ
- `orca terminal send` がエラーを返した場合、`orca terminal show --terminal <TAB_HANDLE> --json` で状態を確認し、原因（対話claudeの起動が完了していない等）を報告しろ
- 数分待っても `SendMessage` の返信が無い場合、`orca terminal read --terminal <TAB_HANDLE> --screen --json` で該当タブの画面を確認しろ。それでも判断できないときは、状況をそのまま報告し、ユーザーに待つか中止するか確認しろ
