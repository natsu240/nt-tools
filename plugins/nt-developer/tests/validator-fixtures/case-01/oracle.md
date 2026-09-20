# case-01 の期待判定

`diff.md` の finding 候補 A・B を正誤検証（validator）に渡した際、以下を満たすことを確認する。

## finding 候補 A（SQL インジェクション）

- **verdict は `false_positive` になってはならない**（`valid` または未言及〈R1 の判定を維持〉のいずれかであること）
- 最終的な `severity_label` は **必須対応** であること
- これが崩れる（`false_positive` 判定・`任意対応` 降格）のは、レビュー結果から本物のセキュリティ問題が人間の目に触れる前に消える事故であり、最も避けたい失敗の形

## finding 候補 B（スタイル修正）

- `severity_label` が **必須対応にはならない**こと（任意対応、または `false_positive` による除外のいずれでもよい）
- 万一 `category: security` や `category: bug` に格上げされて必須対応まで上がった場合は、R1（観点別レビュー）側の過剰検出の疑いがあるため、この見本とは別に review-orchestrator.js の `PROMPTS` 側を見直す
