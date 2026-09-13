---
name: code-style-laravel
description: Laravel の PHP コードを書く・編集する前に必ず起動しろ。
effort: low
---

# Laravel 固有のコード規約（書く前に読め）

Laravel に固有の構文・フレームワーク規約。

**判断軸は `${CLAUDE_SKILL_DIR}/../../references/quality-axes.md` にある。** この skill が持つのは、その軸に沿って書くための規約とコード例だ。

**共通章（言語問わず）は `code-style` skill を別途起動して読め**：早期 return / 同じ式の変数化 / 関数分割 / docblock 規約 / コメントに出典・チケット番号を書かない 等。

---

## 文字列結合 `.` を連打するな。文字列補間 `"{$var}"` を使え

❌ NG:
```php
return $year . '年' . $month . '月' . $day . '日';
$summary .= $total . '件';
```

⭕ OK:
```php
return "{$year}年{$month}月{$day}日";
$summary .= "{$total}件";
```

## 不要なキャストをつけるな

❌ NG（過剰防衛）:
```php
return (string) ($item->name ?? '');
return (string) $value;
return (string) config('myapp.x.y', '');
```

⭕ OK:
```php
return $item->name ?? '';
return $value;
return config('myapp.x.y', '');
```

理由:

- `FormRequest::validated()` 経由なら rules で型確定済み（`nullable, string` は string or null のみ）
- Eloquent property は migration の型 + `$casts` で確定済み
- メソッドシグネチャの型（`: string`, `?int`）は呼び出し側との契約として残せ
- 例外: `int → string` の意図的変換（`(string) $item->id` 等）は残せ
- `config()` の戻り値は mixed だが、自前で書いたリテラル値は信頼してよい

## `Model::query()` を使うな。直接 static 呼び出しにしろ

❌ NG:
```php
$item = Item::query()->with(['owner', 'category'])->findOrFail($id);
$group = MGroup::query()->where('id', $groupId)->first();
```

⭕ OK:
```php
$item = Item::with(['owner', 'category'])->findOrFail($id);
$group = MGroup::where('id', $groupId)->first();
```

理由: `::query()` は内部的に `__callStatic` 経由の static 呼び出しと等価で動作差なし。Laravel 12.x 公式ドキュメント（[Eloquent](https://laravel.com/docs/12.x/eloquent) + [Eloquent: Relationships](https://laravel.com/docs/12.x/eloquent-relationships)）のコード例でも、直接 static 呼び出しが 154 件 / `::query()->` は 2 件と圧倒的多数（取得日 2026-06-23 JST、curl + grep でカウント）。全 Laravel プロジェクトで Laravel 公式の流儀に揃えろ。

## null チェックを書く前に DB スキーマと FormRequest を確認しろ

❌ NG（DB スキーマ・FormRequest を確認せず、防衛的に null チェックを書く）:
```php
private function findCategory(?int $categoryId): ?MCategory
{
    if ($categoryId === null) {
        return null;
    }
    return MCategory::find($categoryId);
}
```

⭕ OK（migration で NOT NULL を確認 → 引数を non-null に、null チェック削除、findOrFail に変更）:
```php
// migration: $table->unsignedBigInteger('category_id'); // NOT NULL
private function findCategory(int $categoryId): MCategory
{
    return MCategory::findOrFail($categoryId);
}
```

ルール:

- nullable じゃない DB カラム / required な FormRequest 入力に null チェックを書くのは無駄
- 引数の型シグネチャ（`?int` か `int` か）も実際の挙動と一致させろ
- null セーフ演算子（`$obj?->name`）が残っている箇所は、型を non-null にした時に同時に外せ（残すと「null になり得る」と読み手が誤読する）

## 複数引数のメソッド呼び出しは名前付き引数 + 改行 + 末尾カンマで書け

❌ NG（同じ型の値が並んで位置引数で書くと、どれがどれか分からない）:
```php
$mpdf = $this->createMpdf($tempDir, 16, 16, 18, 18);
```

❌ NG（改行だけして名前付き引数 / 末尾カンマがない）:
```php
$mpdf = $this->createMpdf(
    $tempDir,
    16,
    16,
    18,
    18
);
```

⭕ OK:
```php
$mpdf = $this->createMpdf(
    marginLeft: 16,
    marginRight: 16,
    marginTop: 18,
    marginBottom: 18,
);
```

ルール:

- 引数 3 つ以上で同じ型（数値リテラル等）が並ぶ場合、名前付き引数で意図を明示
- 末尾カンマを付けると、次回引数を追加する diff が直前行に波及しない
- 名前付き引数は PHP 8.0+ で利用可、末尾カンマも PHP 8.0+ で許容

## FormRequest / Validation は既存プロジェクトの慣例に揃えろ

（既存プロジェクトに従え。`backend-flow.md` などプロジェクト固有規約がある場合はそちらを優先）

主要原則:

- `rules()` には `nullable` / `string` / `integer` / `exists` 等の **形式検証** のみ
- ステータス連動の条件付き必須は `StatusRules` / `ValidateRequiredFields` などビジネスロジック層で扱え
- 422 メッセージは固定文 + Laravel 標準の errors ハッシュで返せ
- `attributes()` / `messages()` でフィールド名・メッセージを日本語化するかは **プロジェクトの 422 レスポンス運用次第**。下記 3 パターンに分かれる:
  - **(A) 凍結パターン**: FE が `errors` ハッシュを表示しない運用（例: メイン更新 API）。`attributes()` / `messages()` は `return []` で空配列を返す。**復活用の辞書をコメントアウトで保持**しておくと、後で FE が errors を表示する設計に切り替わったとき即座に復活させられる
  - **(B) 定義パターン**: FE が errors を表示する単純な FormRequest（例: ログイン / ユーザー作成）。`attributes()` で日本語マッピングを定義する。`messages()` は必要なルールだけ
  - **(C) 不定義パターン**: 内部 API でログだけで運用するなら、英語メッセージのまま `attributes()` / `messages()` を一切書かないのも選択肢
- どのパターンを採るかは **既存ファイルの慣例に揃えろ**。同じプロジェクト内で (A) と (B) を混在させてよい（メイン更新 API は (A)、認証系は (B) 等）
- **「主要原則だから書け」と機械的に追加するな**。既存の同種ファイルが (A) で空にしているなら、新規追加も (A) に揃えろ

## Action / Service / Model の責務を分離しろ

| レイヤ | 責務 |
|---|---|
| Controller | リクエスト受理・Action 呼び出し・レスポンス返却のみ |
| FormRequest | 入力検証 |
| Action | 業務ロジック・データ加工 |
| Model | テーブル操作のみ。加工・判定ロジックは持たせない |
| Repository / Service | 必要時のみ。不要な抽象化は避ける |

複数テーブル更新は必ず `DB::transaction` で囲め。

## 自前実装より先に Laravel 本体機能 / 導入済みパッケージを確認しろ

❌ NG（Laravel 本体や導入済みパッケージにある処理を素の PHP で再実装）:
```php
$slug = strtolower(preg_replace('/[^a-zA-Z0-9]+/', '-', trim($title)));

$diffDays = (strtotime($end) - strtotime($start)) / 86400;

$grouped = [];
foreach ($items as $item) {
    $grouped[$item->category_id][] = $item;
}
```

⭕ OK（Laravel 標準機能を使う）:
```php
$slug = Str::slug($title);

$diffDays = Carbon::parse($start)->diffInDays(Carbon::parse($end));

$grouped = $items->groupBy('category_id');
```

ルール:

- 文字列操作は `Str::` / `Illuminate\Support\Str`、配列・コレクション操作は `Arr::` / `collect()` を自前の `preg_replace` / `foreach` 集計より優先しろ
- 日付操作は `Carbon`（Laravel 標準採用）を自前の `strtotime` / `DateTime` 計算より優先しろ
- バリデーション・キャッシュ・キュー・ページネーション等のインフラ層機能は Laravel 本体の仕組みを使え
- **既にプロジェクトの `composer.json` に入っている外部パッケージ**の機能も同様に、自前実装より優先して使え（例: 既存プロジェクトが日付処理系パッケージや PDF 生成系パッケージを導入済みならそれに乗る）
- 新規に処理を書く前に「これは Laravel 本体 or 導入済みパッケージで代替できないか」を先に確認する癖をつけろ
- **新規パッケージの追加判断はこのルールに含まない**（`composer require` 等のパッケージ追加は CLAUDE.md の「実行前確認が必要な操作」に該当するため、必要ならユーザーに確認してから追加しろ）

## アプリの実際の状態確認は laravel-boost MCP を優先しろ

`laravel-boost` という MCP サーバー（Laravel アプリの Artisan コマンド・Eloquent クエリ・ルーティング・マイグレーションを扱える外部ツール）が導入済み。ルート一覧・DB スキーマ・Eloquent のリレーション等、アプリの実際の状態を確認する場面（null チェックを書く前に DB スキーマと FormRequest を確認しろの節の判断を含む）では、migration ファイルを手読みしたり `php artisan` コマンドを手打ちしたりする前に、まず laravel-boost の MCP ツールで確認できないか検討しろ。

**migration を書いたら、書いた内容が実際に反映されているか確認しろ**。laravel-boost の `database-schema` 系のツールで実際のテーブル定義（型・nullable・デフォルト値・外部キー）を確認し、書いた migration ファイルの記述と食い違っていないか照合しろ。食い違っている場合、migration の適用漏れ（`php artisan migrate` の実行忘れ等）の可能性がある。

## laravel/boost 導入プロジェクトでは、生成されたベストプラクティス skill も必ず確認しろ

`composer.json` に `laravel/boost` が入っているプロジェクトでは、`php artisan boost:install` が `.claude/skills/`（プロジェクトルート、または Laravel アプリのルートディレクトリ配下。モノレポ構成だと `backend/.claude/skills/` のようにネストしていることがある）に `laravel-best-practices` / `pest-testing` 等の skill を生成している場合がある。存在するなら PHP 実装前に必ず起動して読め。`laravel/boost` が導入されていないプロジェクトでは無視してよい。

## 送信前に自分の diff を読み直せ

コード書き終わったら自分の diff を読み直して、上記の各項目と **共通章（`code-style` skill）** の全項目をチェックしろ。読みづらい箇所が残っていたら直してから報告しろ。
