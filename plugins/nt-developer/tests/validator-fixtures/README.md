# 正誤検証（validator）の再現性チェック

`../scoring.test.js` が検証するスコアリングの計算部分は決定論的（AI を使わない）だが、その入力になる `valid` / `false_positive` の判定そのものは validator（AI）の判断であり、決定論的にはテストできない。ここでは「本物のバグを間違って `false_positive` に落とさないか」を見本 + 期待値の形で固定し、**自動実行はしない**（後述の理由）。

## なぜ自動実行しないか

この確認を実行するには実際に validator エージェントを動かす必要があり、都度トークンを消費する。`code-review` は PR ごとに何度も走る一方、validator への指示文自体は頻繁には変わらないため、毎コミットで再検証する投資対効果は低い。`review-orchestrator.js` 内の `PROMPTS.validator` を変更したときだけ、この見本を使って手動で確認する運用にする。

**「変更されたこと自体」の検知だけは機械的に自動化している**（AI は呼ばずトークンは消費しない）。`PROMPTS.validator` の変更は `../../../../scripts/check-validator-prompt-change.sh` が push 前に検知する。「変更されたら知らせる」だけで、この見本を使った実際の再確認は代わりに行わない。

## 実行手順

1. `case-01/diff.md` の finding 候補 A・B を、`review-orchestrator.js` の `PROMPTS.validator` と同じ入力形式（`## Round 1 findings` セクション等）に整形する
2. 実際の Claude セッションで validator と同じ指示文を与えて実行する（素の文脈で最低 3 回。1 回だけでは AI の判定ゆらぎを拾えない）
3. 各回の verdict を `case-01/oracle.md` の期待値と突き合わせる
4. finding 候補 A が 1 回でも `false_positive` になった場合、または `severity_label` が必須対応から外れた場合は **回帰とみなし、`PROMPTS.validator` の変更を見直す**

## 最終確認日

- 2026-09-03: 移行元照合の観点追加で `PROMPTS.validator` に LEGACY_SOURCE の節を足した際の動作確認。3 回実行し、finding 候補 A は 3 回とも `valid` / `category: security` / `severity: MUST`、finding 候補 B は 3 回とも `false_positive` で、期待を維持することを確認した
- 2026-08-11: 誤検知修正で `PROMPTS.validator` の spec_check 必須化範囲を拡張した際の動作確認。3 回実行し、finding 候補 A は 3 回とも `valid`（必須対応の期待を維持）、finding 候補 B は `false_positive` または `valid` ながら `severity_label` は常に任意対応の期待を維持することを確認した
