---
name: code-style-vue
description: Vue 3 / SCSS のコードを書く・編集する前に必ず起動しろ。
effort: low
---

# Vue / SCSS 固有のコード規約（書く前に読め）

Vue 3 / SCSS / Element Plus に固有の構文・フレームワーク規約。

**判断軸は `${CLAUDE_SKILL_DIR}/../../references/quality-axes.md` にある。** この skill が持つのは、その軸に沿って書くための規約とコード例だ。

**共通章（言語問わず）は `code-style` skill を別途起動して読め**：早期 return / 同じ式の変数化 / 関数分割 / docblock 規約 / コメントに出典・チケット番号・デザイン参照を書かない 等。

**素の TypeScript 構文ルール**（`as` 濫用禁止 / Optional Chaining / 配列・オブジェクトの型明示 等）は `code-style-ts` skill を別途起動して読め。

---

## 実装を始める前に、使う既存部品の対応表を作れ

同じ画面を作り直すたびに違う見た目が出てくるのは、既存資産を無視して新しい CSS を書き足すからだ。手を動かす前に、画像の構成要素それぞれに「使う既存コンポーネント / 既存トークン」を対応付けた表を作り、ユーザーに提示しろ。

- 色・余白・タイポは既存のトークン（`v.color(...)` 等）、部品は既存コンポーネントを使え
- 対応する既存資産が無い要素だけ「新規実装」と明記しろ
- 似た既存画面があるなら、その実装をレイアウトの雛形にしろ（プロジェクト内の一貫性 > デザインの再現度）
- 表に無い判断（新しい色・独自の余白・独自部品）を実装中に勝手に増やすな

## デザインカンプの px を絶対に参考にするな、画像と実機の見た目で判断しろ

**最重要ルール**。

デザインカンプ上で計測した px 値（要素幅・余白・フォントサイズ等）を「これが正」として実装に当てるな。カンプは実装の見た目を完全に再現しているとは限らず、ピクセル単位で食い違うことが多い（例: カンプの入力欄寸法をそのまま当てると実画面で長く見える、ラベル幅が画像のバランスと違う、等）。

### やるべきこと

- プロジェクトに保存されたデザイン画像（**png ファイル**）を Read で開いて目で見ろ
- 実機（ブラウザ）で表示を確認しろ。スクショを撮ってもよいが、それは下準備であって合否の根拠にはならない（見た目の合否は人間が決めるの節）
- 2 つを並べて目で見比べ、明らかな差を潰せ。揃ったかどうかの最終判断は人間が実機で行う
- カンプ上の px 値は **絶対に参考にするな**

### 試行錯誤の進め方

- まず明らかに大きすぎる差を捉えて、思い切って値を縮めろ / 広げろ
- 縮めすぎたら少し戻す、足りなければ少し広げる、を繰り返せ
- 画像のキャンバス幅 = 実機のモーダル幅 を前提に、各要素の **比率** で見ろ
- カンプ側の数値表示に頼った瞬間、作画と実画面の差で外す。ただし禁止なのは **カンプの数値を写すこと**だけだ。実機の計測は積極的に使え（「どこが違うか」は目、「何 px どう違うか」は実機の計測の節）

### 「どこが違うか」は目、「何 px どう違うか」は実機の計測

目視で当たりを付けたら、そこから先は実機を測って原因を特定しろ。目視だけで詰めると小さい不揃いを見落とす。

- ブラウザの開発者ツールで `getBoundingClientRect()` / `getComputedStyle()` を叩き、要素の実寸と実際に効いている CSS を取れ
- **左右で「同じはず」のものは必ず実測で照合しろ**。並んだ入力欄の幅・高さ、カラム幅、行ピッチ、対になる余白。ここが目視の精度が最も落ちる箇所だ（例: 250px と 350px の不揃いを「だいたい同じ」と見逃し、共通 CSS の `!important` 由来だと気付けない）
- **原因が計測で分かるものは、値を上下させて探るな。** 特定してから1回で直せ。試行錯誤の進め方の節の「縮めすぎたら少し戻す」を使うのは、余白のバランスのように数値で正解が決まらないものだけだ

### 見た目の合否は人間が決める

**Claude の比較で完結させるな。** 画像と実機スクショの比較は**人間が見る前の下準備**であって、合否の判定ではない。実装した側は「合っていてほしい」前提で見るため、自分のスクショ比較を根拠に「一致しました」と報告するな。

- **スクショを合否の根拠にするな。** 撮った画面には、意図した状態とは違うものが写っていることがある（モーダルが開く前・データが入る前・別の画面）。撮れた画像を見て「揃った」と結論するな
- 報告には**ユーザーが自分で再現できる情報**を書け。「どの URL を開いて、何をどう操作したときの画面か」と「どこがどう違って見えるか」の2点だ。スクショを貼って済ませるな
- 最終確認は、人間がデザインカンプとローカルの実機を自分で開いて行う。その工程を飛ばすな
- 手が止まったら周回を増やさず人間に投げろ。数値を上下させる試行錯誤を延々続けるより、残っている差分を挙げて見てもらう方が速い
- 報告するのは「揃えた箇所」と「揃いきらなかった箇所（と理由）」の両方だ。残った差分を「概ね一致」に丸めるな

### コメントに書くな

- デザインカンプの URL / 要素 ID / 仕様番号をソースコードのコメントに直書きするな
- 「カンプ通り」「デザイン仕様」「カンプ計測値」のような表記をコメントに残すな
- 設計意図は PR description / `plans/*.md` に集約しろ（共通章 `code-style` の docblock / コメントに出典・経緯・チケット番号・他ファイル参照を書くなの節を参照）

## scoped style と :deep / :global を使い分けろ

Vue の `<style scoped>` はコンポーネント内に閉じる。子コンポーネント内部のクラスに当てるには `:deep()` を、グローバル CSS に出すには `:global()` を使え。

### :deep（子コンポーネント内部へ）

子の DOM 構造（例: Element Plus の `.el-input__inner` や `.ui-input.el-input`）にスタイルを当てる：

```scss
.sample-record-dialog__amount :deep(.el-input__inner) {
  text-align: right;
}
```

scoped 属性が剥がれて子コンポーネントの DOM までスタイルが届く。

### :global（モーダル / ポータル先など、コンポーネント外へ）

`Teleport` で `body` 直下に出る要素（モーダルのオーバーレイなど）にスタイルを当てる場合、scoped attribute がそもそも付かないので `:global` を使え：

```scss
:global(.sample-record-dialog.message-dialog--action .message-dialog__body) {
  overflow-y: auto;
  scrollbar-gutter: stable both-edges;
}
```

### 注意

- `:deep` も `:global` も乱用するとスタイル衝突の原因になる。**できるだけ親コンポーネントの DOM に閉じたクラスを足してから狙え**
- `!important` は最後の手段。子コンポーネントの inline style や別の `:deep` と競合して効かないときに限って使え

## Element Plus の幅指定は内部 wrapper まで届かせろ

`el-input` / `el-select` / `el-textarea` の幅を変えるとき、Vue ラッパーコンポーネント（例: `Input.vue` / `Select.vue` / `Textarea.vue`）の `width` prop が `widthMap` で size を持っているはず。だがラッパーの style は `.el-input` 自身にしか当たらない。親要素が `display: inline-flex` や `flex: 1 1 auto` だと、`width: 100%` を渡しても内側で縮む。

❌ NG（widthMap で `width="full"` を指定したのに、親が inline-flex で 中身が縮む）:
```vue
<Input v-model="form.name" width="full" />
```

実測:
- `.sample-record-dialog__owner-name` (flex 1 1 auto): 280px
- `.ui-input-container` (display: inline-flex, 中身固有幅): 169px ← 縮んだ

⭕ OK（`:deep` で container と el-input を両方 width 100% に強制）:
```scss
.sample-record-dialog__owner-name :deep(.ui-input-container),
.sample-record-dialog__owner-name :deep(.ui-input.el-input) {
  width: 100% !important;
}
```

ルール:

- Vue ラッパーの `width` prop は便利だが、親要素の display と相性が悪いケースがある
- `getBoundingClientRect().width` で実測して、想定通りでないなら `:deep` で内部 wrapper を強制

## Composable / Store / Component の責務を分離しろ

| レイヤ | 責務 |
|---|---|
| Pages | 画面状態・イベント制御・遷移制御。ビジネスルールを直書きしない |
| Client (`*Client.ts`) | HTTP I/O とレスポンス整形。API 呼び出しの窓口を集中管理 |
| Stores (Pinia) | 状態保持、load / save / reset |
| Composables | 共通ロジック（バリデーション・ローディング等）。UI 描画責務を持たない |
| Common Components | 再利用 UI 部品の提供 |

Pages から axios を直接呼ぶのは GET（参照系・マスタ取得・初期表示の補助）のみ。POST / PATCH / DELETE は Client 経由。

## v-model / props / emit は型を書け

### v-model（子から親へ）

```ts
const props = defineProps<{ modelValue: string }>()
const emit = defineEmits<{ 'update:modelValue': [value: string] }>()
const model = computed({
  get: () => props.modelValue,
  set: (v) => emit('update:modelValue', v)
})
```

### props は型を絞れ

`any` / `unknown` を使うな。必ず interface or type で形を書け：

```ts
interface Props {
  modelValue: boolean
  itemId: number
}
const props = defineProps<Props>()
```

### emit は型を書け

```ts
const emit = defineEmits<{
  (event: 'update:modelValue', value: boolean): void
  (event: 'request-export', input: SampleRecordModalInput): void
}>()
```

### emit / props / ref 変数に docblock を強要するな

イベント名・prop 名・変数名 + 型シグネチャから意図が伝わるなら docblock 不要。

❌ NG（名前で十分なのに docblock を盛る）:
```ts
const emit = defineEmits<{
  /** 出力ボタン押下時: 確認モーダルへ。入力 payload を親へ渡し、親が確認後 downloadSampleRecordPdf を呼ぶ */
  (event: 'request-export', input: SampleRecordModalInput): void
  /** テンプレ保存成功（親で SUCCESS トーストを表示するためのフック） */
  (event: 'template-saved'): void
  /** エラー（親側でエラーバナーを表示するためのフック） */
  (event: 'error', message: string): void
}>()

/** 敬称セレクト（BE enum OwnerHonorificCode が SSOT。FE に直書きしない） */
honorific_options: SelectOption[]
```
→ 名前 + 型で意図は伝わる。docblock 内に「親で〜」「BE enum〜が SSOT」のような他レイヤ参照が混じったらほぼ違反（共通章 `code-style` の docblock / コメントに出典・経緯・チケット番号・他ファイル参照を書くなの節）。

⭕ OK（名前で意図が伝わるので docblock なし）:
```ts
const emit = defineEmits<{
  (event: 'request-export', input: SampleRecordModalInput): void
  (event: 'template-saved'): void
  (event: 'error', message: string): void
}>()

honorific_options: SelectOption[]
```

⭕ OK（名前から読み取れない Why を 1 行で示す。実装契約として残す）:
```ts
/** 取得失敗時に空フォームの編集状態を残さないため、エラー時はダイアログを閉じる */
watch(() => props.modelValue, ...)
```

判定軸: docblock を消したときに **「次に触る人がイベント・prop・変数の意図を読み違えるか」**。読み違えないなら不要。

## TypeScript の型注釈は code-style-ts を読め

`as` 濫用禁止 / Optional Chaining / 配列・オブジェクトの型明示など、Vue コンポーネントに限らない素の TypeScript の型注釈ルールは `code-style-ts` に移した。TypeScript を書くときは必ず併せて起動して読め。

## SCSS は色をトークン経由で書け

### 色は変数（color トークン）経由で書け

❌ NG（リテラル直書き）:
```scss
background-color: #eef2f7;
border: 1px solid #dcdfe6;
```

⭕ OK（プロジェクトの variables から）:
```scss
background-color: v.color(blue-gray-100);
border: 1px solid v.color(blue-gray-200);
```

例外: 確立した hex リテラル（プロジェクト全体で同じ意味で使う色、または variables にない一時的な色）は直書きで OK。ただし変数化を検討しろ。

### `!important` は最後の手段

子コンポーネントの inline style や別の `:deep` と競合して効かないときに限って使え。

### 左右対称を保ちたい縦スクロール領域では `scrollbar-gutter` を使え

縦スクロール領域の左右見た目を対称に保ちたいときに `scrollbar-gutter: stable both-edges` を使うと、スクロールバー有無にかかわらず左右に gutter が確保される。

### SCSS コメントはセレクタ目的だけ残せ。値の説明は書くな

❌ NG（直後のプロパティ値を日本語で言い直すだけ）:
```scss
/* 区分セレクトを 200px に縮小 */
.sample-record-dialog__category :deep(.ui-select.el-select) {
  width: 200px !important;
}

/* 出力 / 戻るボタンを 240px 中央配置に揃える */
.message-dialog__actions {
  align-items: center;
}

/* 入力欄の右端を 320px に統一 */
.ui-form-row--inline .ui-input.el-input {
  max-width: 320px;
}
```
→ `width: 200px` / `align-items: center` / `max-width: 320px` を読めば分かる自明な What（共通章 `code-style` の docblock / コメントに出典・経緯・チケット番号・他ファイル参照を書くなの節）。

⭕ OK（複雑なセレクタの「狙い」を 1 行で示す）:
```scss
/* 区分セレクト */
.sample-record-dialog__category :deep(.ui-select.el-select) {
  width: 200px !important;
}

/* 出力 / 戻るボタン */
.message-dialog__actions {
  align-items: center;
}

/* インライン入力欄の最大幅 */
.ui-form-row--inline .ui-input.el-input {
  max-width: 320px;
}
```

⭕ OK（Why を含む。何故そのサイズか）:
```scss
/* ラベル列 130px（「表示項目の種類」が 1 行に収まる最小幅） */
.ui-form-row__label-side {
  width: 130px;
}

/* 発行日の入力幅（年=4桁、月日=1-2桁を想定） */
.sample-record-dialog__date-year :deep(.ui-input.el-input) {
  width: 80px !important;
}
```

ルール:

- **セレクタ目的**（どの UI 要素 / どの状態を狙ったルールか）は 1 行で残してよい。`:deep()` `:global()` の長いセレクタは特に有用
- **値の説明**（「N px に縮小」「中央配置に揃える」「右寄せ」）はプロパティ値で自明。書くな
- **Why（数値の根拠）**（「年は 4 桁入る幅を確保」「`表示項目の種類` が 1 行に収まる最小幅」）は残してよい
- 「カンプ通り / カンプサイズ / 画像基準」はデザインカンプの px を絶対に参考にするな、画像と実機の見た目で判断しろの節の規約により禁止（値の根拠としても書くな）

## el-form の `rules` は `computed` で定義しろ

`el-form` + Pinia + axios パターンで、`rules` は `computed` で定義しろ。メッセージ文字列は定数（`VALIDATION_MESSAGES` / `ERROR_MESSAGES`）経由。

```ts
const rules = computed<Record<string, FormItemRule[]>>(() => ({
  owner_name: [...requiredInputRule(true), maxLengthRule(100)],
  ...
}))
```

`validationRules.ts` の共通ルールを優先。画面に独自ルールを書くのは Cross-field（開始日 ≦ 終了日 等）のみ。

## Vue template コメントは「ブロック目印」用途だけ残せ

長い template の中で「ここから何のブロックか」を示す HTML コメントは、コードを高速に追うための **目印（navigation aid）** として残してよい。

⭕ OK（長い template の中で目印になる）:
```html
<!-- 入力モーダル（メイン） -->
<SampleRecordDialog ... />

<!-- 「変更箇所があります」警告ダイアログ -->
<MessageDialog title="変更箇所があります。" ... />

<!-- AI要約エラートースト: タブ離脱・リロード・再実行・閉じるで消える -->
<NotificationBanner ... />
```
→ コンポーネント名や `title` 属性と部分的に重複しても、長い template の中での目印として機能するなら残す。

❌ NG（要素 1〜2 個しか無い短い template での重複コメント）:
```html
<template>
  <!-- ボタン -->
  <Button @click="handleClick">押す</Button>
</template>
```
→ template が短いと目印不要。コンポーネント名 + ラベルから自明。

❌ NG（コメントが UI 仕様の説明・経緯を語る）:
```html
<!-- 送信ボタンの正規配置はデザインカンプの Floating action buttons 内部要参照。
     インライン配置は仕様未定義のため一旦未実装とし、PDF 出力機能と合わせて別タスクで対応する。 -->
```
→ デザイン参照（デザインカンプの px を絶対に参考にするな、画像と実機の見た目で判断しろの節）+ TODO 残り + 経緯（共通章 `code-style` の docblock / コメントに出典・経緯・チケット番号・他ファイル参照を書くなの節）。全部違反。

判定軸: **template が長くて速読が必要か**。100 行超えるような template では `<!-- 〇〇 -->` を 5〜10 行ごとに置く運用は有効。短い template では不要。

## 自前実装より先に VueUse / Element Plus を確認しろ

❌ NG（VueUse にある処理を自前実装）:
```ts
const width = ref(window.innerWidth)
window.addEventListener('resize', () => {
  width.value = window.innerWidth
})
onUnmounted(() => window.removeEventListener('resize', handler))

let timer: ReturnType<typeof setTimeout>
function debouncedSearch(keyword: string) {
  clearTimeout(timer)
  timer = setTimeout(() => search(keyword), 300)
}
```

⭕ OK（VueUse の composable を使う）:
```ts
const { width } = useWindowSize()

const debouncedSearch = useDebounceFn((keyword: string) => search(keyword), 300)
```

ルール:

- イベントリスナーの登録/解除、debounce/throttle、localStorage 同期等の定番処理は、自前で `ref` + `addEventListener` + `onUnmounted` を書く前に VueUse（導入済みなら）の composable を確認しろ
- Element Plus の `rules` / バリデーション機構等、フレームワークが用意した仕組みを自前実装で置き換えるな
- 素の TypeScript（`Array.prototype` 系メソッド・日付操作ライブラリ・package.json 確認等）に関する自前実装優先ルールは `code-style-ts`（自前実装より先に TypeScript 標準 / 導入済みパッケージを確認しろの節）を見よ

## 送信前に自分の diff を読み直せ

コード書き終わったら自分の diff を読み直して、上記の各項目と **共通章（`code-style` skill）** ・**素の TypeScript 構文（`code-style-ts` skill）** の全項目をチェックしろ。特に：

- **画像と実機を見比べて明らかな差を潰したか**（カンプの px を直書きしていないか）
- **使う既存部品の対応表を実装前に出したか**（実装を始める前に、使う既存部品の対応表を作れの節）
- **人間が実機で見る前提で報告したか**（自分のスクショ比較を根拠に「一致した」と結論していないか。見た目の合否は人間が決めるの節）
- **コメントにデザインカンプの URL / 要素 ID / 仕様番号を書いていないか**
- **`:deep` / `:global` を乱用していないか**
- **`!important` を最後の手段以外で使っていないか**
- **SCSS コメントが「値の説明」になっていないか**（SCSS は色をトークン経由で書けの節）
- **emit / props / ref の docblock を強要しすぎていないか**（v-model / props / emit は型を書けの節）

読みづらい箇所・デザイン参照が残っていたら直してから報告しろ。
