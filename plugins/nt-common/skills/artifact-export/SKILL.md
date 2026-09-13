---
name: artifact-export
description: Artifactの図をSVG/PNG/PDFで書き出す前に必ず起動しろ。
user-invocable: true
effort: medium
---

対象は claude.ai の Artifact に限定しろ。Artifact 以外の HTML から SVG を抜く用途には使うな。

## 手順

### 1. ArtifactのHTMLを手元に置く

`WebFetch` で対象の Artifact URL を取得しろ。フル HTML がローカルにキャッシュされる（`~/.claude/projects/<プロジェクトのスラッグ>/<セッションID>/tool-results/artifact-<...>.html`）。このセッション内で既に同じ URL を `WebFetch` 済みならキャッシュを再利用しろ、同じ URL に何度も `WebFetch` を投げるな。

### 2. 図を一覧させる

```
python3 "${CLAUDE_SKILL_DIR}/scripts/extract-svg.py" list <キャッシュHTMLのパス>
```

`figures` に見出し・キャプション・`index` が入る。`skipped`（アイコンスプライト等、対象外と判定した `<svg>`）は無視してよい。

- 図が1枚なら選ばせずそのまま進め
- 図が複数あれば、各図の見出し・キャプションを添えて `AskUserQuestion` でどれを書き出すか選ばせろ（1枚 or 複数選択）

### 3. 出力形式を確認する

`AskUserQuestion` で「SVG単独ファイル / PNG / PDF」を複数選択で確認しろ。どれか1つに絞らせるな、複数選ばれたら全部書き出せ。

### 4. 書き出す

ここで作るのは作業用のファイルだ。最終的な置き場所は手順5で確認して決めるので、この時点で `$HOME/Downloads` 等の本番の置き場所を勝手に決めるな。

選ばれた図ごとに:

```
python3 "${CLAUDE_SKILL_DIR}/scripts/extract-svg.py" extract <キャッシュHTMLのパス> --index <list の index> --out <出力先.svg>
```

XML妥当性はスクリプト内で検証済みだ（失敗したら非ゼロ終了で理由を stderr に出す）。`unresolved_ids` が空でなければ、参照先が見つからなかった旨をそのまま報告しろ、黒塗りで誤魔化すな。

PNGが必要な場合は続けて:

```
bash "${CLAUDE_SKILL_DIR}/scripts/svg-to-png.sh" <出力先.svg> <出力先.png>
```

PDFが必要な場合は続けて（ページサイズは図の寸法に合わせて作られる）:

```
bash "${CLAUDE_SKILL_DIR}/scripts/svg-to-pdf.sh" <出力先.svg> <出力先.pdf>
```

生成した PNG を `Read` で自分の目で見て、文字・アイコン・枠線が元の Artifact と同じに出ているか確認しろ。PDF だけを頼まれた場合も、確認用に PNG を作って目で見ろ（PDF は `Read` で見られない）。崩れていたら手元での応急編集で済ませず、`extract-svg.py` 側の抽出ロジック（CSS の絞り込み・symbol の解決）を疑え。

**枠の中が真っ黒に潰れていたら CSS の絞り込みが規則を捨てている。** SVG は `fill` 未指定の図形を黒で塗るため、`fill: none` の規則が落ちると枠が塗り潰されて中身が見えなくなる。

### 5. 渡す

**保存先を必ず `AskUserQuestion` で確認しろ。既定は `$HOME/Downloads` だが、聞かずにそこへ置くな。** 確認せずに `SendUserFile` だけで済ませるのも禁止だ（毎回 Downloads に落ちるとは限らず、置き場所は依頼者が決めることだ）。

保存先が決まったら手順4のファイルをそこへ移し、絶対パスを報告しろ。`SendUserFile` はそのうえで追加で渡したいときだけ使え。
