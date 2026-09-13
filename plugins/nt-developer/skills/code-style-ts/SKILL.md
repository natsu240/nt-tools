---
name: code-style-ts
description: TypeScript のコードを書く・編集する前に必ず起動しろ。
effort: low
---

# TypeScript 固有のコード規約（書く前に読め）

TypeScript に固有の構文ルール。Vue コンポーネント文脈に限らず、Node.js スクリプト・CDK・純粋な TS モジュールでも共通して適用する。

**判断軸は `${CLAUDE_SKILL_DIR}/../../references/quality-axes.md` にある。** この skill が持つのは、その軸に沿って書くための規約とコード例だ。

**共通章（言語問わず）は `code-style` skill を別途起動して読め**：早期 return / 同じ式の変数化 / 関数分割 / docblock 規約 / コメントに出典・チケット番号を書かない 等。

**Vue コンポーネント固有のルール**（Composable / Store 責務分離、v-model、Element Plus、SCSS 等）は `code-style-vue` を別途起動して読め。

---

## `as` を多用するな（不要な type assertion）

❌ NG（過剰防衛）:
```ts
const value = (response.data.name as string) ?? ''
```

⭕ OK（API レスポンスの型を最初に定義して、そこで型が確定する）:
```ts
interface ResponseData { name: string }
const response = await axios.get<ResponseData>(url)
const value = response.data.name ?? ''
```

## Optional Chaining と Null Coalescing を使え

❌ NG:
```ts
const name = obj && obj.name ? obj.name : ''
```

⭕ OK:
```ts
const name = obj?.name ?? ''
```

## 配列・オブジェクトの型は明示しろ

❌ NG:
```ts
const items = []  // any[] になる
const config = {}  // {} になる
```

⭕ OK:
```ts
const items: Item[] = []
const config: Config = { ... }
```

## 自前実装より先に TypeScript 標準 / 導入済みパッケージを確認しろ

❌ NG（標準 API にある処理を自前実装）:
```ts
const total = items.reduce((sum, item) => sum + item.price, 0)  // ← これは OK 例。NG は次の例
let total = 0
for (const item of items) {
  total += item.price
}

const diffDays = (new Date(end).getTime() - new Date(start).getTime()) / 86400000
```

⭕ OK（標準の配列メソッドや導入済みの日付ライブラリを使う）:
```ts
const total = items.reduce((sum, item) => sum + item.price, 0)

const diffDays = dayjs(end).diff(dayjs(start), 'day')
```

ルール:

- 配列・オブジェクト操作は `Array.prototype`（`reduce` / `map` / `filter` / `find` 等）を素の `for` ループより優先しろ
- 日付操作は、プロジェクトが `dayjs` / `date-fns` 等を既に導入しているならそれを使え。自前の `Date` 計算は書くな
- **既にプロジェクトの `package.json` に入っているパッケージ**の機能は自前実装より優先して使え
- **新規パッケージの追加判断はこのルールに含まない**（`npm install` 等のパッケージ追加は CLAUDE.md の「実行前確認が必要な操作」に該当するため、必要ならユーザーに確認してから追加しろ）

## 送信前に自分の diff を読み直せ

コード書き終わったら自分の diff を読み直して、上記の各項目と **共通章（`code-style` skill）** の全項目をチェックしろ。Vue コンポーネントを書いている場合は `code-style-vue` の項目も合わせてチェックしろ。読みづらい箇所が残っていたら直してから報告しろ。
