export const meta = {
  name: 'review-orchestrator',
  description: 'code-review 用オーケストレーター。CACHE_DIR 準備 → PR コンテキスト取得 → レビュールール読み込み → 移行元コード読み込み → 外部連携 MCP 検出 → 収集 → 並列レビュー（4 並列。project_notes/legacy-source.md があるリポジトリでは移行元コードが Spec/Range 観点へ渡る。laravel-boost 接続時は Bug/Logic、aws-iac-mcp-server 接続時は Bug/Logic・Security の Claude 側だけ実データ参照版に切替）→ 重複統合 → 正誤検証 → スコアリング（finding が 0 件のときはスキップ）→ 後始末',
  phases: [
    { title: 'CACHE_DIR 準備' },
    { title: 'PR コンテキスト取得' },
    { title: 'レビュールール読み込み' },
    { title: '移行元コード読み込み' },
    { title: '外部連携 MCP 検出' },
    { title: '収集' },
    { title: '並列レビュー' },
    { title: '重複統合' },
    { title: '正誤検証' },
    { title: 'スコアリング' },
    { title: '後始末' },
  ],
}

// プロンプト本文は skill 経由で args.PROMPTS として渡すと、メインモデルが
// 巨大な JSON を毎回書き起こす必要があり生成時間が長くなるため、
// orchestrator 内に直書きしている（PR #63 で skill 側の !cat 展開を撤去）。
const PROMPTS = {
  common: `お前はコードレビューの専門エージェントだ。担当観点: {観点名}

出力スキーマは orchestrator が強制する。\`findings\` 配列を返せ。指摘ゼロのときは \`{ "findings": [] }\`。

## 作業ディレクトリ汚染の絶対禁止

PROJECT_ROOT 配下に Write / \`>\` / \`>>\` / \`tee\` で一時ファイルを作るな。コード片の dump、差分の保存、抜粋ファイルの作成、いずれも禁止だ。一時ファイルが必要なら \`$HOME/.claude/cache/code-review/<run-id>/\` か \`$TMPDIR\` を使え。PreToolUse hook で物理 block しているが迂回するな。

## category の使い分け（実害の種類）

- \`bug\`: 放置で誤動作・退行・データ不整合が確実に起きるロジック問題。実害が確実なホットパス N+1 等の性能問題も含む
- \`security\`: 脆弱性（インジェクション・認可漏れ・XSS 等）
- \`spec\`: 仕様（チケット・設計書・受入条件）との乖離
- \`convention\`: ガイドライン・規約違反（動作は正しいが規約違反。該当ルールを引用）
- \`refactor\`: 重複・冗長・未使用コード・軽微な非効率の改善提案（実害なし）

確信の強さは confidence で表す。category は実害の種類だけで決めろ。規約違反や重複コードを \`bug\` にするな。

## 指摘してよいもの（高シグナル）

- コンパイル/パース失敗（構文エラー、型エラー、未解決参照）
- 入力によらず確実に誤った結果を返すコード
- 明確な AGENTS.md / ガイドライン違反（該当ルール引用必須）
- 明確なセキュリティ脆弱性

## 指摘するな

- 主観的なスタイル指摘（lint の仕事）
- 特定入力・状態に依存する「かもしれない」問題
- 変更差分外の既存コードへの指摘
- lint が捕捉するもの
- 確信が持てない問題（誤った指摘は信頼を損なう）

## confidence の目安

- 90-100: 確実にバグ・脆弱性・違反
- 70-89: 高い確度で問題がある
- 50-69: 可能性はあるが確信なし
- 50未満: 付けるな

## REVIEW_RULES の扱い（個人 / プロジェクト個別ルール）

入力に \`## REVIEW_RULES\` セクションがある場合、これは**現在の作業者本人またはプロジェクトが「コードレビュー時に必ず適用する」と宣言した個別ルール**だ（\`~/.claude/review-rules/*.md\` および \`<本体のチェックアウト>/project_notes/review-rules/*.md\` の連結）。AGENTS.md / CLAUDE.md より優先度は低いが**規約と同等の拘束力**で扱え。

- REVIEW_RULES に書かれた条件への違反は、コード規約違反として扱い指摘しろ（category=\`convention\`、severity=\`MUST\`）
- ファイル境界ヘッダ \`### <絶対パス>\` から、違反元が「個人ルール」（\`~/.claude/review-rules/\` 配下）か「プロジェクトルール」（\`<本体のチェックアウト>/project_notes/review-rules/\` 配下）かを判別しろ。**evidence の先頭に必ず \`[review-rule: <該当ファイルの絶対パス>]\` という形式でそのパスを明記してから、通常の evidence 本文を続けろ**（orchestrator がこの固定フォーマットを機械的に読み取って個人ルール由来かどうかを判定する。省略・言い換え・別フォーマットは禁止）
- REVIEW_RULES が空・\`(review-rules なし)\` の場合は通常のレビューに戻れ。無理にここから何かを引き出すな

## 既存パターン認識（ベストプラクティス系の指摘を出すとき必須）

「セキュリティ・堅牢性・運用上望ましい」型のベストプラクティス指摘（例: 外部 API ホストの scheme 検証 / ログ出力の粒度 / DB 制約による多層防御 / 認可の厚み / 入力検証の網羅性 / no-op UI 要素の非表示化 等）を出す前に、必ずプロジェクト内の**同種ファイル**（同種 API Client / Controller / migration / Action / Service / Vue コンポーネント）を 1〜2 個 Grep で確認し、既存パターンを把握しろ。

### 既存パターンと違う場合

「既存ファイル \`XxxClient.php\` / \`YyyClient.php\` ではこうしているが、本 PR では違う」を evidence に書け。category と severity は問題の実害に応じて通常通り判定しろ。

### 既存パターンと同じ場合（理想提示型）

「既存全体がそうなっているが、本来理想としては〜」という形で出せ。出すときの必須条件:

- **category=refactor で出せ**（bug/security/spec ではない。実害が発生しておらず既存全体が同じ状態のため）
- evidence に既存パターンの実例ファイル名を**最低 1 つ**含めろ
- description の末尾に**3 択**を必ず提示しろ:
  - (a) 本 PR で先行採用
  - (b) 別 PR で同種ファイル横断で揃える
  - (c) 現状維持
- 「既存全部を変えるべき」「必ず採用すべき」と書くな。判断は実装者に委ねる温度感で書け

### 出すな（情報量ゼロ判定）

- 同種ファイル全体で既に守られているパターンの「再確認」だけの指摘
- 「念のため」「将来のため」だけの指摘で具体的な発生シナリオが書けないもの
- 既存パターンに合っていて、かつ理想提示も具体性がない（コード例・代替実装が示せない）もの
- 1 つの PR の中で同じ既存パターン認識を複数箇所で繰り返す指摘（同種ファイル横断の話なら 1 件にまとめろ）
`,
  security: `担当観点: Security（セキュリティ）

差分を全行読んで以下を漏れなく確認しろ:
- XSS（ユーザー入力の未エスケープ出力）
- SQL インジェクション（プレースホルダ未使用の動的クエリ）
- 認可漏れ（権限チェックの欠落・バイパス）
- 秘密情報の混入（API キー、パスワード、トークンのハードコード）
- CSRF / オープンリダイレクト / パストラバーサル
- 暗号の誤用（弱いハッシュ、固定 IV 等）

## ログ経由の個人情報 / 機密情報漏洩（重要）

外部 API レスポンス / 例外 / リクエスト本文を \`Log::*\` / \`logger()\` / \`Log::error\` / \`error_log\` 等に出している箇所を全て洗い出し、以下を確認しろ:

- レスポンス \`body\` 全文をそのままログ出力していないか。**外部 API がリクエスト内容をエコーバックする実装の場合、個人情報（メール・住所・電話・氏名・郵便番号・生年月日 等）がログに残る**
- 例外メッセージにユーザー入力・SQL 値・トークンが含まれる可能性があれば、特定キー抽出 or マスクして出力するべき
- 「デバッグ用に詳細ログ」と明言されていても、本番でも出続けるなら指摘しろ
- 指摘するときは「リクエスト / レスポンスに個人情報が含まれる根拠」と「ログに残ることでの影響」を evidence に書け

## 不可逆 / 有料 / 副作用大の API の認可（重要）

以下のいずれかに該当する API endpoint（差分内に追加 / 変更があるもの）について、認可チェックの厚みを確認しろ:

- **不可逆操作**: DELETE、状態遷移で戻せない変更、外部システムへの確定通知（決済確定・集計確定・通知送信 等）
- **有料 / 課金操作**: 外部の有料 API 呼び出し、自分側に課金が発生する処理
- **1 回限り操作**: ユニーク制約付き作成、再実行不能な処理
- **大量データ操作**: 大量行を一括変更・削除する処理

これらは「既存 CRUD API と同じ認可レベル」では不十分な場合がある。**「既存も同じだから」を理由に流すな**。少なくとも「特定ロール限定」「レコード所有者限定」のような厚めの認可を検討すべきと指摘しろ。既存設計と意図的に揃えている根拠がコメント / docs にある場合のみ指摘を控えてよい。

## 外部 API ホストの scheme / allowlist 検証

env / config から URL を取得して外部 API を叩いている箇所を全て洗い出し、以下を確認しろ:

- \`config('services.xxx.host')\` / \`env('XXX_HOST')\` 等で取った URL の **scheme（http / https）を検証していない**場合、設定ミスで平文通信や別ホストへの送信が起きうる
- 想定ホストの allowlist 検証（\`parse_url\` で host を取り出して許可リストと突き合わせ）が無い場合、env 改ざんや設定ミスでデータが別ホストに流れうる
- 指摘するときは「scheme 強制 or allowlist 検証で防げる」を evidence に書け。get / post 直前に検証を追加すれば実装は軽い

## CloudFormation テンプレートのセキュリティコンプライアンス検証（aws-iac-mcp-server が使える場合のみ）

DIFF に CDK コードが含まれ、ToolSearch で aws-iac-mcp-server 関連のツールが見つかった場合、\`cdk synth\` で生成した CloudFormation テンプレートを \`check_cloudformation_template_compliance\` でセキュリティ・コンプライアンスルール違反を確認しろ。違反が見つかった場合、対応する CDK ソースコード側の箇所を Grep で特定した上で security として指摘しろ。ツールが見つからない、または synth が失敗する場合は CDK コードの静的な読み込みだけで判断しろ。

入力: DIFF / GUIDELINES / PR_CONTEXT
`,
  bug_logic: `担当観点: Bug/Logic（バグ・ロジック）

差分を全行読んで以下を漏れなく確認しろ:
- ロジックミス（条件分岐の誤り、off-by-one、無限ループ）
- 型不一致・キャスト漏れ
- null / undefined / nil 安全性
- 境界値・エッジケースの未処理
- リソースリーク（未クローズの接続・ファイル）
- 例外ハンドリングの欠陥（握りつぶし、誤った rescue）
- DB: マイグレーションの rollback 可能性 / FK 整合性

## DB ロック保持中の外部呼び出し / 多層防御（重要）

\`DB::transaction\` / \`lockForUpdate\` / \`SELECT ... FOR UPDATE\` の中で以下のいずれかをやっている箇所を全て洗い出せ:

- **外部 HTTP API 呼び出し**（\`Http::*\` / \`Guzzle\` / \`curl\` / クライアントクラス呼び出し）
- **長時間処理**（巨大バッチ、大量レコード集計、外部システム同期）
- **メールキュー投入以外の I/O 待ち**

これらは「ロック保持時間が外部依存になり、外部 API の timeout 設定がそのまま行ロック保持時間になる」「他リクエストやワーカーが行ロックで詰まる」リスクを持つ。指摘するときは:

- 行ロック保持時間が最大何秒になるかを timeout 設定から推論して evidence に書く
- 代替案として「外部呼び出し前に \`lockForUpdate\` を解放するパターン」「ジョブキューに逃がすパターン」「DB ユニーク制約での冪等性担保パターン」のいずれかを提示する

加えて、\`lockForUpdate\` で「1 件限り作成」「1 レコード 1 回」のようなユニーク性を担保している場合、**DB 側にも unique 制約があるか**を確認しろ。lockForUpdate だけだと別経路（CLI バッチ・キュー再実行・別 Action）からの並行書き込みで二重作成が発生しうる。**「アプリ側でロック + DB 側でユニーク」の多層防御**が無い場合は提案として指摘しろ。

## migration の FK 依存 index 順序（重要）

migration（\`up\` / \`down\`）で **既存 index を drop してから新 index / unique を作る**順序になっている箇所を確認しろ:

- 例: \`$table->dropIndex(['item_id']); $table->unique('item_id');\`
- そのカラムが **FK の参照元**になっている場合、MySQL 8.0+ では \`ERROR 1553: Cannot drop index ... needed in a foreign key constraint\` で失敗する
- 正しい順序: **新 unique / index を先に作って FK 依存先を移してから旧 index を drop**（例: \`$table->unique('item_id'); $table->dropIndex(['item_id']);\`）
- \`down\` も同じ理由で逆順が必要
- 指摘するときは「FK が旧 index に依存している」「MySQL 1553 で落ちる」「順序入替で解決」を evidence に書け。\`schema()->table('xxx')->getForeignKeys()\` 相当のチェックは不要、外部キー定義（\`foreign('item_id')\` 等）の存在で判断していい

## 実データベース参照（laravel-boost が使える場合のみ）

ToolSearch で laravel-boost 関連のツールが見つかった場合、上記の DB 絡みの指摘は migration ファイルの記述だけでなく、実際に繋がっているデータベースの定義（型・nullable・デフォルト値・外部キー・unique 制約）を確認した上で判断しろ。migration ファイルの記述と実データベースの定義が食い違っている場合（適用漏れの migration がある等）は、その食い違い自体を bug として指摘しろ。ツールが見つからない場合は今まで通り migration ファイルの記述だけで判断しろ。

## CloudFormation テンプレート検証（aws-iac-mcp-server が使える場合のみ）

DIFF に CDK コードが含まれ、ToolSearch で aws-iac-mcp-server 関連のツールが見つかった場合、\`cdk synth\` で生成した CloudFormation テンプレートを \`validate_cloudformation_template\` で構文検証しろ。構文エラー・型エラー・未解決参照が見つかった場合は bug として指摘しろ。ツールが見つからない、または synth が失敗する場合は CDK コードの静的な読み込みだけで判断しろ。

パフォーマンス系（N+1、index 漏れ、重いクエリ等）は Consistency の担当。指摘するな。

## 読むだけで済ませず実際に確かめろ（重要）

差分と仕様書を読んだだけで「たぶんこう動く」と判断するな。次に当たる指摘は、手を動かして裏を取ってから出せ。裏が取れなかったものは confidence を 60 以下に抑え、evidence に「裏取り未実施」と明記しろ。

- **依存ライブラリ・フレームワークの挙動に依存する指摘**: 記憶で断定するな。\`vendor/\` / \`node_modules/\` 配下の該当クラス・関数のソースを Read / Grep して、引数の解決順序・既定値・例外条件を確認しろ。evidence に読んだ \`ファイル:行\` を引用しろ
- **migration の指摘**: 使い捨ての DB へ実際に流して確かめろ。**PROJECT_ROOT が参照している開発用 DB へ流すな。**別名の一時 DB を作って流し、終わったらその一時 DB だけを落とせ。流せない事情があるなら evidence にその事情を書け
- **既存データの分布に依存する指摘**（NOT NULL 追加・default 追加・enum 値の絞り込み・unique 制約の追加）: 対象カラムの既存データを読み取り専用のクエリで数え、何件が新しい条件から外れるかを evidence に書け。\`SELECT\` 以外を実行するな

入力: DIFF / PR_CONTEXT
`,
  spec_range: `担当観点: Spec/Range（仕様・ガイドライン準拠と根拠の適用範囲）

**この観点はレビュー全体の中で最も重要だ。手を抜くな。** 依頼者・実装者が想定している仕様と実装の致命的な乖離は、お前にしか検出できない。PR_CONTEXT を隅から隅まで読め。読み飛ばすな。

## レビュー観点

### 仕様整合性（最優先）
- PR_CONTEXT の仕様書定義（画面仕様・API仕様・ステータス遷移・バリデーション条件・選択肢一覧等）と PR 実装が矛盾していないか
- 仕様書の Enum / 定数 / バリデーション値とコードのハードコード値・定義が完全一致するか
- 仕様書の条件分岐（「〜の場合は〜を表示」「〜の時は〜を非活性」等）が正しく実装されているか
- 仕様書に記載されているが PR で実装されていない項目（実装漏れ）がないか
- 仕様書が**挙動として明記している期待値**（発火タイミング・表示位置・表示文言・並び順・遷移先）と実装が一致するか。**実装側の挙動が「より妥当」に見えても、明記された期待値と違えば乖離として指摘しろ**（どちらを採るかを決めるのはお前ではない）
- PR_CONTEXT に実装計画（「検証・完了条件」節を持つもの）が含まれている場合、その「一次仕様からの逸脱」の表と実装を突き合わせろ。**表に載っていないのに期待値と違う挙動になっている対象**と、**表に載っているが承認の記録が空の対象**は指摘しろ

### ガイドライン準拠
- AGENTS.md / CLAUDE.md / 開発ガイドラインへの違反（該当ルールを正確に引用）
- 命名規約違反（ガイドラインで明示されているもののみ）
- 責務分離違反（ガイドラインで明示されているもののみ）

### 定義の一貫性
- マジックナンバーが既存定義と不一致でないか
- 既存 Enum / 定数 / バリデーション定義との矛盾がないか
- 新規追加された値が仕様書の定義に存在するか

### QA シート照合（PR_CONTEXT に QA シート / テストケース / 受入条件が含まれている場合は必須）
- PR の変更がどのテストケースに対応するか。網羅されていない分岐・境界値・状態遷移がないか
- 「既知バグ」「既知の制約」「未対応」記載項目に該当する変更でないか。該当時は解消か回避かを明示
- 受入条件と PR 実装の挙動が一致するか（特に分岐ロジック）
- QA シートに \`Validation_ID\` / \`画面ID\` / \`項目ID\` 等の参照キーがある場合、コードの定数・enum 値・テストデータと一致するか

### デプロイ・運用整合性（重要）

PR_CONTEXT（PR description / レビューコメント / 会話コメント）が渡されている場合、変更内容と PR_CONTEXT の整合を以下の観点で確認しろ。**コード変更から要求される運用手順が PR description に書かれていない場合は指摘しろ**。

- migration で **新規カラム追加 + default 値**、**NOT NULL 追加**、**既存カラム / テーブル削除**、**大規模 backfill が必要そうな変更**が含まれている場合、対応する seeder / backfill / 既存データ補正手順（\`php artisan db:seed --class=...\` / 一時バッチ / SQL 等）が PR description に明記されているか
- 変更ファイルに **既存レコードの状態に依存するクエリ条件**（特定フラグ縛り・特定 enum 値縛り・新規追加カラム参照等）が含まれており、その状態を満たすためのマスタ更新・seeder 実行が必要な場合、PR description に明記されているか
- 新規 enum / 定数追加で **既存データに値を埋め直す処理**が必要な場合、PR description に明記されているか
- 環境変数 / config / feature flag の追加・変更がある場合、PR description / \`.env.example\` / 設定変更手順に明記されているか
- 変更ファイルに **テスト**が含まれている場合、テストが実装済み機能を検証対象にしているか確認しろ（例: 「未実装タブの 422 検知」テストで実装済みタブを使っていれば、テストはパスしてもエラー検知パスを通っていない）。実装側の enum / リスト定義と突き合わせろ

**「PR description に追加すべき手順」として指摘するときは evidence にコード変更からの推論経路を明示しろ**（例: 「migration が \`is_in_use\` を default(false) で追加 + \`GetFacility\` が \`where('is_in_use', true)\` で絞る → 既存タグは全て非表示になるので \`MTagSeeder\` 実行が必要」）。推論経路が示せない指摘はするな。

コード変更だけから推論できない運用手順（インフラ作業・外部サービス設定等）は指摘するな。

## 根拠の適用範囲の照合（この観点の中核）

仕様の解釈が一次ソースの原文どおりか、その原文が今回の対象を名指ししているかを1件ずつ突き合わせろ。

PR_CONTEXT に実装計画（「検証・完了条件」節を持つもの）が含まれている場合、そこに書かれた仕様解釈の行を全部拾い、行ごとに次を確認しろ。

- 原文の引用があるか。「仕様書に〜と書かれている」と要約だけで書かれ、引用元の原文が貼られていない行は指摘しろ
- 引用元の原文が名指ししている対象と、その解釈を適用している実装対象が一致するか。一致しない対象へ同じ方式が適用されていれば、適用先を名指しして指摘しろ。特定のチケット・特定の画面について依頼者が出した判断（コメント・実測結果）を、他のチケット・他の画面へ広げている形が典型だ
- 広げた判断に対象ごとの承認記録があるか。「実測済み」「確認済み」だけで対象が書かれていない承認記録は、承認済みの設計変更として扱わず指摘しろ
- 根拠が及ぶ対象のうち、実装から漏れているものが無いか

指摘するときは「引用元の原文（どのシート・チケットのどこに、こう書いてある）」「その原文が名指ししている対象」「実際に適用されている対象」の3つを evidence に書け。3つを揃えられない指摘は出すな。

## 誤指摘削減ルール（重要・新規）

以下に該当する乖離は**指摘するな**。過去の運用で「指摘されても落とされる」典型ケースとして確定済み:

### 1. PR description で follow-up / 既知として明示された乖離は除外

PR_CONTEXT 本文に \`follow-up:\` / \`別 PR で対応\` / \`既知:\` / \`未対応:\` / \`TODO:\` / \`後で\` / \`next PR\` 等のキーワードを含む行があり、その行で言及されているファイル・項目に関する乖離は指摘するな。「沈黙の乖離は禁止」ルール（AGENTS.md）は **沈黙でない乖離**（=PR description で明示済み）には適用されない。PR 著者が「これは後回し」と宣言している以上、レビューで再指摘しても落とされるだけだ。

- この除外が使えるのは「一次仕様どおりにすべきだと認めた上で、この PR ではやらない」と読める記述だけだ
- 「この案は採っていません」「この方式は採用しない」のように**設計判断そのものを宣言している記述は follow-up / 既知の宣言ではないので除外するな**。宣言された挙動が一次仕様の期待値と違うなら、PR description に理由が書かれていても乖離として指摘しろ
- その理由が**一部の対象についての根拠にしか触れていない場合は、根拠が及ばない対象を名指しして指摘しろ**。根拠の対象を書かずに「実測済み」「確認済み」とだけ書かれた判断は、承認済みの設計変更として扱うな

## 移行元照合（LEGACY_SOURCE が渡された場合のみ）

このリポジトリは別リポジトリからのリプレイス先で、LEGACY_SOURCE に移行元リポジトリの絶対パスと構造の説明が書いてある。差分が移行元の挙動から意図せず外れていないかを、仕様の照合と同じ枠で見ろ。LEGACY_SOURCE が渡されていない場合はこの節を無視しろ。

新旧で構造が違うためパスの対応表は無い。差分に出てくるテーブル名・カラム名・画面名・SQL の条件・定数値を手がかりに、LEGACY_SOURCE のパス配下を Grep して該当箇所を特定しろ。移行元リポジトリは読み取り専用だ。書き込むな。

見る観点:

- 抽出条件（WHERE 句・結合条件・論理削除の扱い）が移行元と一致するか
- 並び順（ORDER BY・表示順の固定並び）が移行元と一致するか
- NULL・空文字・ゼロの扱い、丸め・桁数・単位の変換が移行元と一致するか
- 条件分岐の境界値（以上/超過、以下/未満）が移行元と一致するか
- 移行元にあった項目・分岐が新実装から落ちていないか

指摘を出す条件（厳守）:

- 移行元の \`ファイル:行\` を引用できない指摘は絶対に出すな。Grep で該当箇所を見つけられなかったものを憶測で書くな
- PR_CONTEXT（仕様書・実装計画書）に、その差異を意図した変更として明示する記述があれば**指摘するな**。リプレイスは仕様変更を伴うのが普通で、明示された変更を退行として挙げるのは誤検知だ
- PR_CONTEXT に該当記述が無い場合は evidence に「PR_CONTEXT 全文検索、該当記述なし」と明記した上で confidence を 60 以下に抑えろ
- evidence には「移行元 \`<絶対パス>:<行>\` ではこうなっている」と「新実装ではこうなっている」の両方を引用しろ

## 指摘時のルール

- 仕様との矛盾を指摘するときは、仕様書のどの記述と矛盾しているかを evidence に正確に引用しろ。引用なしの指摘禁止
- 「仕様書にこう書いてあるが、コードではこうなっている」の形で具体的に示せ
- PR_CONTEXT に該当仕様が含まれていない場合は「仕様未確認のため要確認」と明記した上で指摘

入力: DIFF / GUIDELINES / PR_CONTEXT（隅から隅まで読め）/ LEGACY_SOURCE（渡された場合のみ）
`,
  consistency: `担当観点: Consistency（保守性・読みやすさ・整合性・対称性・変更履歴・パフォーマンス・UX）

**広く拾って verifier で削る** 方針。「動作は正しいが品質に課題」を網羅的に見ろ。差分を全行読んで以下を確認しろ。

### 1. コードスタイル・書き方
- 言語/フレームワーク標準機能で置き換えられる手書きループ・条件分岐（Laravel コレクション・Eloquent、JS/TS の配列メソッド・オプショナルチェーン等）
- 不要に深いネスト・早期 return で平坦化できる構造
- 不要な any・null チェック漏れで実害が出る型周り
- 誤解を招く命名（好みの言い換えは指摘するな）
- コメント。**REVIEW_RULES のコメント規約は渡すだけでは見落とすので、ファイル冒頭・関数直上のコメントを実際に数えて照合しろ。** 残すべき警告（一見無駄に見えるが直すと壊れる箇所）を消している側も同時に見ろ

### 2. Cross-file 整合性・重複
- 既存のユーティリティ・ヘルパー・定数があるのに重複実装（指摘前に Grep で確認）
- 同じ概念の二重管理（PHP と JS で同じ enum / 定数を別々に定義 → Source of Record 統合候補）
- テンプレ・Mailable / View / Component の大量複製
- ナビゲーション・フォーム送信先など同じデータの散在
- ボイラープレートの抽出余地

### 3. 対称性（重要）

差分が触っている対象に「対になるもの」が存在するかを必ず数えて確認しろ。片方にだけ入っていて、もう片方に入っていない変更は指摘しろ。

- 対になる画面（新規登録と編集、一覧と詳細、購入側と売却側）で、バリデーション・重複チェック・必須条件・初期値が揃っているか
- 対になる層（Controller と FormRequest、フロントとバックエンド、API と画面）で、同じ入力に同じ制約がかかっているか
- 対になる項目（電話番号と名称、開始日と終了日、作成と更新）で、扱いが揃っているか
- migration の \`up\` と \`down\`、追加と削除、開くと閉じるのように対で書くべき処理が揃っているか

指摘するときは「片方（\`ファイル:行\`）にはこれがあり、もう片方（\`ファイル:行\`）には無い」の形で両方を evidence に引用しろ。**片方しか引用できない指摘は出すな。**

### 4. 変更対象を説明している既存記述との照合（重要）

差分で変更した関数・カラム・prop・定数について、それを説明している既存の記述が更新されずに残っていないかを Grep で洗い出せ。

- 変更した関数・クラスの docblock・直上コメントが、変更後の挙動と食い違っていないか
- 変更したカラム・enum・定数を参照している \`docs/\` 配下の md・README が古いまま残っていないか
- PR_CONTEXT が渡されている場合、PR description の説明が実際の差分と食い違っていないか
- 変更した prop・引数の名前・型・既定値が、呼び出し側のコメント・型定義・テスト名と食い違っていないか

指摘するときは食い違っている記述の \`ファイル:行\` と、差分側の該当箇所の両方を evidence に引用しろ。

### 5. 変更履歴との整合（GIT_HISTORY）

GIT_HISTORY を全エントリ読んで以下を確認しろ:

- 過去に revert された変更と同じパターンの再導入
- 直近で頻繁に修正されている箇所（不安定コード）への変更リスク
- 過去コミットメッセージ・PR で言及された制約や意図との矛盾
- 既存の変更パターンからの逸脱（同種の変更が他では別の方法で行われていないか）

**差分の前後比較だけで「退行」と断定するな。** 「変更前は A を検索していたが変更後は B を検索している」のような非対称は、過去の制約への違反にも、単なる意図的な仕様変更にも見える。指摘する前に PR_CONTEXT を検索し、この変更が仕様書・実装計画書に明記された意図的な変更でないか必ず確認しろ。明記されている場合は指摘するな。

### 6. パフォーマンス
- N+1 クエリ（指摘前に index 確認必須）
- 重いクエリ（フルスキャン、\`LIKE '%xxx%'\`、大量 JOIN、サブクエリのネスト）
- index 漏れ（WHERE / ORDER BY / JOIN カラム）
- 不要なデータ取得（\`SELECT *\`、過剰な Eager Loading）
- ループ内の DB アクセス・API コール
- 大量データの同期処理（バッチ化・キューイング候補）
- キャッシュ未活用（繰り返し同じクエリ・API コール）
- フロント側の不要な再レンダリング
- メモリリーク（リスナー未解除、タイマー未クリア、クロージャによる参照保持）

### 7. UX エッジケース
- F5 リロード・ブラウザ戻るで入力状態が消える
- 422 / 400 時にエラーがフィールドに反映されない
- ブラウザ固有挙動（MIME 解釈、autocomplete、IME、Safari の戻る等）
- ファイルアップロードのサイズ・拡張子・MIME チェック抜け
- ローディング表示漏れ（ボタン連打防止が抜けてる等）
- 非同期処理の中断ハンドリング（画面遷移時）

### 8. Altitude（抽象化レベル）
- 1 つの関数・コンポーネントが複数責務
- 抽象化が浅すぎてコール側で同じ前処理を毎回書いてる
- 抽象化が深すぎて 1 か所からしか呼ばれない wrapper

---

LINT_RESULTS が渡された場合、lint が指摘済みのものを重複指摘するな。lint が検出できない領域に集中しろ。

## この観点固有の例外ルール

**この観点に限り、common の「主観的スタイル指摘をするな」は適用しない。** ただし:
- 「書き換えるとこうなる」を具体的なコード片で示せるものだけ指摘。漠然と「読みにくい」は禁止
- 動作が変わらないことに確信が持てる書き換えだけ提案
- 好み・流派の問題（命名規則の流派、フォーマット等）は指摘するな

入力: DIFF / GUIDELINES / LINT_RESULTS / GIT_HISTORY / PR_CONTEXT
`,
  // ==VALIDATOR_PROMPT_START==（この指示文を変更したら plugins/nt-developer/tests/validator-fixtures/ の見本で手動確認しろ。変更は push 前の検査が検知する）
  validator: `お前はコードレビューのバリデータだ。Round 1 で複数のレビューエージェントが出した指摘を検証しろ。

## タスク

各指摘について以下を判定しろ。1つも飛ばすな:

1. **有効**: コードに実際に問題あり → verdict: "valid"
2. **誤りと判定**: 指摘は誤り → verdict: "false_positive", reason
3. **要修正**: 方向性は正しいが説明や行番号が不正確 → verdict: "adjust", adjusted

さらに、R1 が見落とした問題があれば new_findings に追加しろ（confidence 付き）。

## PR_CONTEXT の扱い（new_findings を追加する前に必ず読め）

**R1 は PR_CONTEXT と PR_CONTEXT を見た上でレビューしている**。お前にも同じ PR_CONTEXT が渡されているので、new_findings を追加する前に必ず読め。R1 が仕様を確認した上で「仕様通り」として finding を出さなかった実装を、お前が実装コードだけ見て「バグだ」と new_findings に追加すると、R1 が正しく捨てた指摘を復活させる形になる。以下を厳守しろ:

- new_findings を追加するときは、PR_CONTEXT のどこにも矛盾しないか必ず確認しろ
- 実装コードだけを見て「これはバグに見える」と判断した項目は、PR_CONTEXT に**その挙動を許容 / 仕様として明示している記述があれば new_findings に追加するな**
- PR_CONTEXT に該当仕様の記述が見つからない場合、new_findings の evidence に「仕様書に該当記述なし。仕様側で明示されるべき挙動」と明記した上で confidence を 60 以下に抑えろ
- 逆に、R1 の finding が PR_CONTEXT の記述と明確に矛盾している場合は \`false_positive\` に落とせ

### spec_check フィールド（new_findings と validations の valid 判定は必須。確認した証拠を書け）

new_findings の各要素、および validations で verdict を \`valid\` にする要素には \`spec_check\` を必ず埋めろ（false_positive / adjust は空文字で構わない。誤りと判定した根拠は reason に書け）。「確認した」と言葉で言うだけでなく、実際に PR_CONTEXT を検索した結果を書け:

- 関連する記述が見つかった場合: その一文を**そのまま引用**しろ（例: 「PR_CONTEXT に『表紙のみ出力の場合は sale_price を必須としない』の記述あり」）
- PR_CONTEXT 全体を検索したが関連する記述が無かった場合: 「PR_CONTEXT 全文検索、該当記述なし」と明記しろ
- 10 文字未満・「確認済み」「問題なし」のような中身のない記入は禁止。orchestrator 側で機械的に検知し、valid 票は加点に使わず・new_findings は自動的に重要度を下げる

## REVIEW_RULES の扱い

入力に \`## REVIEW_RULES\` セクションがある場合、これは作業者本人またはプロジェクトが宣言した個別ルールだ（\`~/.claude/review-rules/*.md\` / \`<本体のチェックアウト>/project_notes/review-rules/*.md\` の連結）。**REVIEW_RULES に明確に違反している R1 finding を \`false_positive\` 判定するな**。逆に「REVIEW_RULES に書かれた条件への違反だが R1 が見落としているもの」があれば new_findings に追加しろ（category=\`convention\`、severity=\`MUST\`）。ファイル境界ヘッダ \`### <絶対パス>\` から違反元が個人ルール（\`~/.claude/review-rules/\` 配下）かプロジェクトルール（\`<本体のチェックアウト>/project_notes/review-rules/\` 配下）かを判別し、**evidence の先頭に必ず \`[review-rule: <該当ファイルの絶対パス>]\` という形式でそのパスを明記してから、通常の evidence 本文を続けろ**（orchestrator がこの固定フォーマットを機械的に読み取る。省略・言い換え禁止）。

## LEGACY_SOURCE の扱い（移行元リポジトリ）

入力に \`## LEGACY_SOURCE\` セクションがある場合、このリポジトリは別リポジトリからのリプレイス先で、そこに移行元リポジトリの絶対パスと構造の説明が書いてある。移行元の挙動との差異を指摘した R1 finding を、移行元コードを見ないまま「根拠不明」として \`false_positive\` に落とすな。**evidence が引用している移行元の \`ファイル:行\` を実際に Read / Grep して確かめてから判定しろ。** 引用先が存在しない・引用内容と実物が食い違う場合だけ \`false_positive\` にしろ。

出力スキーマは orchestrator が強制する。validations と new_findings の 2 配列を返せ。

入力: DIFF / R1_FINDINGS / PR_CONTEXT / REVIEW_RULES / LEGACY_SOURCE
`,
  // ==VALIDATOR_PROMPT_END==
}

// ==FAILFAST_UNIT_START==
// 安全確認（permission prompt / behavior safety classifier）由来のブロック文言。
// リトライしても再度ブロックされる保証がなく、技術的失敗と同列に自動リトライすると
// 安全確認をすり抜けて実行してしまう恐れがあるため、検知した slot はリトライ対象から除外する。
// 言い回しはモデルによって変わるため、完全一致ではなく正規表現で表記ゆれ（ツール名の違い、
// 能動/受動、丁寧さの違い）を吸収する。ただしパターンを広げすぎると、権限まわりを指摘した
// レビュー本文そのものに誤反応して retryable: false でレビュー全体が止まるため、
// 安全確認の定型文にしか現れない形に絞る。
// 裸の「〜を許可してください」は IAM 権限の指摘（「iam:PassedToService を許可してください」等）
// でそのまま現れるため、エージェント自身の行動許可を求める形にだけ一致させる。
const SAFETY_BLOCK_PATTERNS = [
  /(権限|許可)が(拒否|却下)され(ました|ています)/,
  /許可(して)?(いただけますか|いただけませんか|もらえますか)/,
  /(ツール|コマンド|Bash|Write|Edit|MultiEdit)[^。\n]{0,20}(実行|使用|書き込み)を許可(して)?ください/,
  /(ユーザー|あなた)(に|の)(よる)?(事前)?(確認|承認|許可)が必要/,
  /permissions?\s+(was\s+|is\s+|has\s+been\s+)?(deny|denied)/i,
  /denied\s+permission/i,
  /(user|manual)\s+(approval|confirmation)\s+(is\s+)?required/i,
]

// 技術的失敗（タイムアウト・中間メッセージ復帰・paraphrase）由来のブロック文言。
// これらは 1 回限りの自動リトライ対象にしてよい。
const RETRYABLE_FAIL_FAST_VERBATIM = [
  'バックグラウンドで実行中',
  '完了通知を待ちます',
  '実行中です。完了次第',
  // サブエージェント（Haiku）が Bash を run_in_background:true で起動して
  // 中間メッセージで復帰したときの典型フレーズ（英語）。PreToolUse hook で
  // block しているが、すり抜けた場合の二重防御として fail_fast でも弾く。
  "I'm now monitoring",
  'continue working on other tasks in parallel',
  'while waiting for',
  // ラッパーがログを paraphrase で返してきたときの典型フレーズ。
  // 出力本文（JSON）や `tail -c` の生バイトに含まれない自然言語パターンに絞る。
  'The log shows',
  'The process is still',
  'The file is still',
  'The process appears',
  'is attempting to parse',
  'appears to be stuck',
  'stuck in a parsing loop',
  'stuck on Google',
  'is encountering',
  'timed out and',
  'I monitored',
  'I observed',
]

function extractAllBalanced(text, open, close) {
  const results = []
  let pos = 0
  while (pos < text.length) {
    const start = text.indexOf(open, pos)
    if (start === -1) break
    let depth = 0
    let inStr = false
    let escape = false
    let found = false
    for (let i = start; i < text.length; i++) {
      const ch = text[i]
      if (escape) { escape = false; continue }
      if (inStr) {
        if (ch === '\\') escape = true
        else if (ch === '"') inStr = false
        continue
      }
      if (ch === '"') { inStr = true; continue }
      if (ch === open) depth++
      else if (ch === close) {
        depth--
        if (depth === 0) {
          results.push(text.slice(start, i + 1))
          pos = i + 1
          found = true
          break
        }
      }
    }
    if (!found) break
  }
  return results
}

function tryParseJson(text) {
  if (text && typeof text === 'object') return { ok: true, value: text, error: null }
  if (typeof text !== 'string') return { ok: false, value: null, error: 'not a string' }
  const trimmed = text.trim()
  if (!trimmed) return { ok: false, value: null, error: 'empty' }

  const candidates = []
  const fenceRe = /```(?:json)?\s*([\s\S]*?)```/gi
  let m
  while ((m = fenceRe.exec(trimmed)) !== null) candidates.push(m[1].trim())
  candidates.push(...extractAllBalanced(trimmed, '{', '}'))
  candidates.push(...extractAllBalanced(trimmed, '[', ']'))
  if (trimmed[0] === '[' || trimmed[0] === '{') candidates.unshift(trimmed)

  candidates.sort((a, b) => b.length - a.length)
  let lastError = null
  for (const c of candidates) {
    try { return { ok: true, value: JSON.parse(c), error: null } }
    catch (e) { lastError = String(e && e.message || e) }
  }
  return { ok: false, value: null, error: lastError || 'no JSON found' }
}

function containsSafetyBlockString(text) {
  if (typeof text !== 'string') return null
  for (const re of SAFETY_BLOCK_PATTERNS) {
    const matched = text.match(re)
    if (matched) return matched[0]
  }
  return null
}

// 安全確認由来のブロックもこの関数で拾えるようにしておく（両者を1回で判定したい呼び出し側のため）。
function containsForbiddenString(text) {
  if (typeof text !== 'string') return null
  const safetyBlock = containsSafetyBlockString(text)
  if (safetyBlock) return safetyBlock
  for (const s of RETRYABLE_FAIL_FAST_VERBATIM) {
    if (text.includes(s)) return s
  }
  return null
}

// 1 slot でも以下のいずれかで「失敗」とみなす:
// - entry が null (agent が死亡)
// - 期待する形の JSON を返せていない (parse 失敗 / 配列欠落)
// - その上で安全確認ブロック (permission prompt 等。retryable: false) / 禁止語混入 (ラッパーの paraphrase 等)
// 戻り値: 失敗時は { reason, error, retryable } オブジェクト、成功時は null。
// retryable: false は parallelWithRetry がリトライ対象から除外する（安全確認ブロックを
// 技術的失敗と同列にリトライすると、ブロックをすり抜けて実行してしまうため）。
//
// 判定順は「有効な結果を返せたか」が先。期待する形の JSON を返せている時点でその slot は
// 完走しているので、本文の言い回しでは落とさない。文言検査を先に置くと、権限まわりを
// 指摘したレビュー本文が安全確認の定型文と衝突して retryable: false でレビュー全体が止まる。
function detectFailure(entry, checkShape) {
  if (!entry) return { reason: 'null result', error: 'agent returned null', retryable: true }
  const parsed = tryParseJson(entry.raw)
  const shapeFailure = parsed.ok ? checkShape(parsed.value) : null
  if (parsed.ok && !shapeFailure) return null

  const safetyBlock = containsSafetyBlockString(entry.raw)
  if (safetyBlock) return { reason: 'safety block', error: safetyBlock, retryable: false }
  const forbidden = containsForbiddenString(entry.raw)
  if (forbidden) return { reason: 'forbidden string', error: forbidden, retryable: true }
  if (!parsed.ok) return { reason: 'json parse failed', error: parsed.error, retryable: true }
  return { ...shapeFailure, retryable: true }
}

function detectR1Failure(entry) {
  return detectFailure(entry, (value) => {
    if (Array.isArray(value && value.findings)) return null
    return { reason: 'findings missing', error: 'expected {"findings": [...]} object' }
  })
}

function detectR2Failure(entry) {
  return detectFailure(entry, (value) => {
    if (Array.isArray(value && value.validations) || Array.isArray(value && value.new_findings)) return null
    return { reason: 'validations missing', error: 'expected {"validations": [...], "new_findings": [...]} object' }
  })
}
// ==FAILFAST_UNIT_END==

function excerpt(text, n = 200) {
  if (typeof text !== 'string') return ''
  return text.length > n ? text.slice(0, n) + '…' : text
}

function buildR1Prompt({ commonMd, dimensionMd, dimensionLabel, context }) {
  const common = commonMd.replace(/\{観点名\}/g, dimensionLabel)
  return [common, '---', dimensionMd, '---', context].join('\n\n')
}

// DIFF / PR_CONTEXT 等の実データはプロンプト文字列に埋め込まず、CACHE_DIR
// 配下のファイルパスだけを渡して Read させる。実データをエージェント経由で
// 複写させると、複写を担当するモデルが長文の後半を書き落として保存する。
// ファイル参照に変えれば複写工程自体がなくなる。
function buildFileRefSection(label, filePaths, fallbackNote) {
  const paths = (Array.isArray(filePaths) ? filePaths : [filePaths]).filter(Boolean)
  if (paths.length === 0) {
    return `## ${label}\n\n${fallbackNote}`
  }
  const pathList = paths.map(p => `- ${p}`).join('\n')
  return `## ${label}\n\n以下のファイルを Read ツールで全文読んでから確認しろ（要約や一部だけを見て判断するな）:\n${pathList}`
}

// テキスト（Read しろという指示文）と、実ファイルパスのフラット配列を両方返す。
// 両者は同じ「この観点にはどのファイルが要るか」の条件分岐を共有するため 1 関数にまとめている。
function buildContextRefForDimension({ dimensionKey, cacheFiles, projectRoot }) {
  const parts = []
  const filePaths = []
  const addSection = (label, value, fallbackNote) => {
    parts.push(buildFileRefSection(label, value, fallbackNote))
    if (Array.isArray(value)) filePaths.push(...value.filter(Boolean))
    else if (value) filePaths.push(value)
  }

  addSection('DIFF', cacheFiles.diff, '(差分なし)')
  if (['security', 'spec_range', 'consistency'].includes(dimensionKey)) {
    addSection('GUIDELINES', cacheFiles.guidelines, '(なし)')
  }
  if (dimensionKey === 'spec_range') {
    addSection('LEGACY_SOURCE', cacheFiles.legacySource, '(legacy-source.md なし)')
  }
  if (dimensionKey === 'consistency') {
    addSection('GIT_HISTORY', cacheFiles.gitHistory, '(なし)')
    addSection('LINT_RESULTS', cacheFiles.lintResults, '(lint 未実行)')
  }
  if (cacheFiles.reviewRules) {
    addSection('REVIEW_RULES', cacheFiles.reviewRules, '(review-rules なし)')
  }
  if (cacheFiles.prContext) {
    addSection('PR_CONTEXT', cacheFiles.prContext, '(なし)')
  }
  parts.push(`## コードベース全体へのアクセス\n\nDIFF だけで判断するな。この変更が既存の他コードにどう影響するか、同種の処理が既存でどう実装されているかを、Grep / Glob / Read でプロジェクトルート（PROJECT_ROOT = "${projectRoot}"）配下を自由に調べた上で判断しろ。`)
  return { text: parts.join('\n\n'), filePaths }
}

function failFastReport(stage, rows) {
  return {
    fail_fast: {
      stage,
      rows,
    },
    // 中止時は CACHE_DIR を削除しないので、保存済みの入力を辿れるようパスを返す。
    cache_dir: CACHE_DIR,
    findings: [],
    optional_findings: [],
    personal_preference_findings: [],
    lint_executed: null,
    spec_failures: [],
  }
}

const FAILURE_STATUS_LABELS = {
  'null result': '失敗 (null)',
  'safety block': '失敗 (安全確認ブロック)',
  'forbidden string': '失敗 (禁止語混入)',
  'json parse failed': '失敗 (JSON parse)',
  'findings missing': '失敗 (findings missing)',
  'validations missing': '失敗 (validations missing)',
}

/**
 * detectR1Failure / detectR2Failure の戻り値を fail_fast レポートの 1 行に変換する。
 * 集計側で同じ判定を手書きすると detector と条件がずれるため、両者を必ずこの関数で繋ぐ。
 */
function failureRow(entry, failure, fallbackId) {
  return {
    id: (entry && entry.id) || fallbackId,
    status: FAILURE_STATUS_LABELS[failure.reason] || `失敗 (${failure.reason})`,
    excerpt: entry ? excerpt(entry.raw) : '',
    error: failure.error,
  }
}

// 1 個でも失敗を検知した瞬間に onFirstFailure を呼ぶ並列実行。
// 標準の parallel() は全件 await のため、失敗確定後も他観点が走り続けてトークンを
// 無駄に消費する。これを onFirstFailure で kill flag を立てることで、ラッパー Bash
// 内のポーリング監視が実行中のプロセスを kill して停止する。
async function parallelFailFast(thunks, detector, onFirstFailure) {
  return new Promise((resolve) => {
    const results = new Array(thunks.length).fill(null)
    let remaining = thunks.length
    let triggered = false

    const finalize = () => {
      remaining--
      if (remaining === 0) resolve(results)
    }

    thunks.forEach((thunk, i) => {
      Promise.resolve()
        .then(() => thunk())
        .then(r => {
          results[i] = r
          if (!triggered) {
            const failure = detector(r)
            if (failure) {
              triggered = true
              // kill flag 作成は await しない（残りエージェントを早く止めるため即時 kick）
              try { onFirstFailure(r, failure) } catch (e) { /* noop */ }
            }
          }
        })
        .catch(() => { /* errors are surfaced via null result */ })
        .finally(finalize)
    })
  })
}

// 立てた kill フラグが残ったままかどうか。中止で作業ディレクトリを残すとき、掃除が要るかの判定に使う。
let killFlagRaised = false

async function triggerKillFlag(cacheDir, phaseName) {
  if (!cacheDir) return
  // 作成の成否に関わらず立てたものとして扱う。エージェントが途中で落ちてもファイルは作られうるし、
  // 掃除が余分に走っても実害は無い。
  killFlagRaised = true
  const killPrompt = `お前はファイル作成専用エージェントだ。Bash で以下を実行しろ。実行中に確認やレビューはするな。このコマンドを変形するな。touch を直接呼ぶな。

\`\`\`bash
${cacheIo('touch', `${cacheDir}/.kill`)}
\`\`\`

stdout には "OK" の 1 行だけを出力しろ。それ以外のテキスト・前置き・後書きは一切出すな。`
  try {
    await agent(killPrompt, {
      agentType: 'nt-developer:reviewer',
      label: 'kill-flag',
      phase: phaseName || '並列レビュー',
      model: 'haiku',
      effort: 'low',
    })
  } catch (e) {
    /* kill flag 作成失敗時は手遅れだが orchestrator 自体は進める */
  }
}

// リトライ前に .kill フラグを掃除する。掃除しないと runner.sh が起動直後に
// exit 137 で戻り、リトライした agent が即失敗する。
async function clearKillFlag(cacheDir, phaseName) {
  if (!cacheDir) return
  killFlagRaised = false
  const clearPrompt = `お前はファイル削除専用エージェントだ。Bash で以下を実行しろ。このコマンドを変形するな。rm を直接呼ぶな。

\`\`\`bash
${cacheIo('rm', `${cacheDir}/.kill`)}
\`\`\`

stdout には "OK" の 1 行だけを出せ。エラーが出ても OK と出せ。前置き・後書き禁止。`
  try {
    await agent(clearPrompt, {
      agentType: 'nt-developer:reviewer',
      label: 'clear-kill-flag',
      phase: phaseName || '並列レビュー',
      model: 'haiku',
      effort: 'low',
    })
  } catch (e) {
    /* clear 失敗時はリトライ側が即死するが、それ自体はハンドリング済み */
  }
}

// runner.sh が「他観点の失敗で立った .kill フラグ」を見て終了したときにログへ書く文言。
// この slot は自分が失敗したわけではないので、本当に失敗した slot と同じ扱いで同時に
// リトライすると、本当の失敗が再発した瞬間にもう一度まとめて巻き込まれて 2 周ぶん無駄になる。
const COLLATERAL_KILL_MARKERS = [
  'ALREADY KILLED before start',
  'KILLED by .kill flag',
]

function isCollateralKill(entry) {
  if (!entry || typeof entry.raw !== 'string') return false
  return COLLATERAL_KILL_MARKERS.some(marker => entry.raw.includes(marker))
}

// parallelFailFast の結果を検査し、失敗 slot があれば .kill フラグを掃除してから
// 該当 slot だけを 1 回だけ再走する。sonnet の StructuredOutput 形式ミスや
// kill flag 巻き込みで 21 分の workflow を丸ごと捨てないための保険。
// 前提: parallelFailFast は全 thunk 完了を待って resolve するので、この時点で
// 他 slot が走っていることはない。よってリトライは新規並列実行で問題ない。
// retryable: false（安全確認ブロック）の slot はリトライせず失敗のまま results に残す。
async function parallelWithRetry(thunks, detector, onFirstFailure, cacheDir, phaseName) {
  const results = await parallelFailFast(thunks, detector, onFirstFailure)

  const ownFailureIndices = []
  const collateralIndices = []
  for (let i = 0; i < results.length; i++) {
    const failure = detector(results[i])
    if (!failure || failure.retryable === false) continue
    if (isCollateralKill(results[i])) {
      collateralIndices.push(i)
      continue
    }
    ownFailureIndices.push(i)
  }

  if (ownFailureIndices.length === 0 && collateralIndices.length === 0) return results

  const rerunSlots = async (indices) => {
    await clearKillFlag(cacheDir, phaseName)
    const rerunResults = await parallelFailFast(indices.map(i => thunks[i]), detector, onFirstFailure)
    indices.forEach((slotIndex, j) => { results[slotIndex] = rerunResults[j] })
  }

  const stillFailing = (indices) => indices.some(i => {
    const failure = detector(results[i])
    return failure && failure.retryable !== false
  })

  if (ownFailureIndices.length > 0) {
    log(`${phaseName} で ${ownFailureIndices.length} slot 失敗を検知 → 該当 slot だけリトライします（巻き込まれた ${collateralIndices.length} slot は後回し）`)
    await rerunSlots(ownFailureIndices)
    // リトライでも直らなければこの後どうせ fail_fast するので、巻き込まれた slot は走らせない。
    // 走らせても結果は捨てられ、トークンだけ消える。
    if (stillFailing(ownFailureIndices)) return results
  }

  if (collateralIndices.length > 0) {
    log(`${phaseName} で他 slot の失敗に巻き込まれた ${collateralIndices.length} slot を実行します`)
    await rerunSlots(collateralIndices)
  }

  return results
}

// 仕様ソースの照合用キー抽出。listed_sources と touched_sources を厳格な
// source 名 + url 完全一致で照合すると、エージェントが touched 側に注釈や
// アクセス先サブパスを足したときマッチしないので、URL から抽出したリソース ID で
// ゆるく照合する。Workflow 実行環境に `URL` グローバルが存在しないため（実測済み）
// 正規表現で直接文字列から抽出し、URL パーサーには依存しない。



// failures はアクセス不能（認証切れ・404・権限不足・通信不能等）専用と各仕様取得プロンプトに
// 明記しているが、エージェントが「内容未発見」（開けたが特定の記述・定義が見つからなかった）
// を誤って積んだ場合の安全網として機械判定する。



// OpenAI Strict JSON Schema 要件: 全 object に additionalProperties: false + 全 properties を required に列挙
const R1_FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['file', 'line', 'category', 'severity', 'confidence', 'description', 'evidence'],
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          category: { type: 'string' },
          severity: { type: 'string' },
          confidence: { type: 'integer' },
          description: { type: 'string' },
          evidence: { type: 'string' },
        },
      },
    },
  },
}

const CLUSTER_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['clusters'],
  properties: {
    clusters: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['cluster_id', 'finding_indices'],
        properties: {
          cluster_id: { type: 'integer' },
          finding_indices: { type: 'array', items: { type: 'integer' } },
        },
      },
    },
  },
}

const VALIDATOR_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['validations', 'new_findings'],
  properties: {
    validations: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['original_index', 'verdict', 'reason', 'adjusted', 'spec_check'],
        properties: {
          original_index: { type: 'integer' },
          verdict: { type: 'string' },
          reason: { type: 'string' },
          adjusted: {
            type: 'object',
            additionalProperties: false,
            required: ['file', 'line', 'description', 'evidence'],
            properties: {
              file: { type: 'string' },
              line: { type: 'integer' },
              description: { type: 'string' },
              evidence: { type: 'string' },
            },
          },
          spec_check: { type: 'string' },
        },
      },
    },
    new_findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['file', 'line', 'category', 'severity', 'confidence', 'description', 'evidence', 'spec_check'],
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          category: { type: 'string' },
          severity: { type: 'string' },
          confidence: { type: 'integer' },
          description: { type: 'string' },
          evidence: { type: 'string' },
          spec_check: { type: 'string' },
        },
      },
    },
  },
}

const DIMENSIONS = [
  { key: 'security', label: 'Security' },
  { key: 'bug_logic', label: 'Bug/Logic' },
  { key: 'spec_range', label: 'Spec/Range' },
  { key: 'consistency', label: 'Consistency' },
]

// Workflow tool は args を string として渡してくるため JSON.parse が必要
// （XML tool call の parameter は string で届く仕様）
let parsedArgs = {}
if (typeof args === 'string' && args) {
  try {
    parsedArgs = JSON.parse(args)
  } catch (e) {
    parsedArgs = { _parse_error: String(e && e.message || e) }
  }
} else if (args && typeof args === 'object') {
  parsedArgs = args
}

// args は最小 6 フィールドのみ。PR_CONTEXT は本 orchestrator が自分で取得するので、
// メイン会話側で詰めない設計に変更。
const {
  TARGET = '',
  MODE = 'review-only',
  PROJECT_ROOT: RAW_PROJECT_ROOT = '.',
  IS_OWN_CHANGE = true,
  CACHE_IO_SCRIPT = '',
  TRIM_DIFF_SCRIPT = '',
  SPLIT_DIFF_SCRIPT = '',
  SPLIT_GUIDELINES_SCRIPT = '',
  BASE_BRANCH = 'develop',
  PLAN_DOC_PATH = '',
} = parsedArgs

// SKILL.md は pwd の結果（絶対パス）を渡すよう指示しているが `~/pj/xxx` 形式で届くことがある。
// ダブルクォート内では `~` が展開されないため、そのままシェルに埋め込むとプロジェクト側の
// review-rules が 1 件も読まれないまま「規約なし」として進む。実体の解決は Bash が使える
// CACHE_DIR 準備フェーズまで待つ必要があるので、ここでは受け取った値を保持するだけにする。
let PROJECT_ROOT = String(RAW_PROJECT_ROOT || '.').trim()

// CACHE_DIR 配下への mkdir/write/append/touch/rm/rmdir/chmod-exec は全てこの
// スクリプト経由に集約する。CACHE_DIR の絶対パス自体（run-id 部分が実行ごとに
// 変わり、subagent が独自にシェル変数へ置き換えることもある）を対象にした
// Bash 許可パターンは実行ごとに揺れて確実にマッチしないため、固定ファイル名
// （cache-io.sh）へのマッチだけで済む形にしている（README.md の permission 追加案内を参照）。
function cacheIo(op, path) {
  return `bash "${CACHE_IO_SCRIPT}" ${op} "${path}"`
}

// diff 取得直後に必ずこのフィルタを通す。.csv/.tsv、DDL を含まない .sql の
// 差分本体を要約1行に差し替える固定処理（LLM 判断を挟まない）。巨大なマスタ
// データが丸ごと diff に乗ってレビュー担当の読み込み上限を超え、並列レビューが
// 全滅するのを防ぐ。
function trimBulkDataDiffs() {
  return `bash "${TRIM_DIFF_SCRIPT}"`
}

// Workflow tool は args を string 化するため IS_OWN_CHANGE が
// 文字列 "true"/"false" で届くことがある。素の truthy 判定だと "false" も真になるため変換する。
const isOwnChange = IS_OWN_CHANGE === true || IS_OWN_CHANGE === 'true'

// 後始末を try/finally で確実に実行するためのフラグと cleanup 関数
let CACHE_DIR = null
let cleanupDone = false
// CACHE_DIR の削除はレビューが最後まで通ったときだけ行う。中止・例外では残す。
// 中止時の対処として SKILL.md が案内している resumeFromRunId での再開は「CACHE_DIR 準備」
// エージェントの結果もキャッシュから再利用するため、削除済みのパスがそのまま返り、
// 差分・ガイドライン・仕様・runner.sh を 1 つも読めない状態で後続フェーズが走る。
let reviewCompleted = false
async function cleanupCacheDir() {
  if (!CACHE_DIR || cleanupDone) return
  cleanupDone = true
  const cleanupPrompt = `お前は本 code-review ワークフロー自身が今回の実行のために新規作成した一時キャッシュディレクトリを片付けるエージェントだ。このディレクトリは「CACHE_DIR 準備」フェーズで今回の実行時に作成したものであり、ユーザーの既存データではない。

Bash で以下を実行しろ。このコマンドを変形するな。rm を直接呼ぶな。

\`\`\`bash
${cacheIo('rmdir', CACHE_DIR)}
\`\`\`

実行結果をそのまま stdout に報告しろ（成功・失敗いずれも実際の結果を書け。前置き・後書きは付けるな）。`
  try {
    await agent(cleanupPrompt, {
      agentType: 'nt-developer:reviewer',
      label: 'cleanup',
      phase: '後始末',
      model: 'haiku',
      effort: 'low',
    })
  } catch (e) {
    /* cleanup 失敗時も orchestrator の戻り値には影響させない */
  }
}

let workflowResult
try {

// ========== CACHE_DIR 準備 ==========
// 差分・仕様・PR 本文・ガイドライン等の実データは、以降の全フェーズで
// このディレクトリ配下のファイルとして保存し、レビュー担当・検証役はすべて
// Read / cat でこのファイルを参照する（プロンプト文字列への直接埋め込みをやめる）。
// 後段の全レビュー担当が同じパスを参照するため最初に確定させる。

phase('CACHE_DIR 準備')

const cacheDirPrompt = `お前はファイル作成専用エージェントだ。以下を順番に実行しろ。

1. Bash で次のコマンドを実行し、stdout に出てくる絶対パスを CACHE_DIR として記憶しろ:
\`\`\`bash
echo "$HOME/.claude/cache/code-review/$(date +%Y%m%d-%H%M%S-$$)"
\`\`\`

2. Bash で次を実行（<CACHE_DIR> は手順 1 で取得した絶対パスに置き換えろ。このコマンドを変形するな。mkdir を直接呼ぶな）:
\`\`\`bash
${cacheIo('mkdir', '<CACHE_DIR>')}
\`\`\`

3. Bash で確認:
\`\`\`bash
test -d "<CACHE_DIR>" && echo "<CACHE_DIR>" || echo "FAIL"
\`\`\`

## 出力
stdout には CACHE_DIR の絶対パス 1 行だけを出せ。それ以外のテキスト・コードフェンス・前置き・後書きは一切出すな。FAIL の場合は \`FAIL\` の 1 行を出せ。`

const cacheDirRaw = await agent(cacheDirPrompt, {
  agentType: 'nt-developer:reviewer',
  label: 'CACHE_DIR 準備',
  phase: 'CACHE_DIR 準備',
  model: 'haiku',
  effort: 'low',
})

CACHE_DIR = String(cacheDirRaw || '').trim()
if (!CACHE_DIR.startsWith('/')) {
  workflowResult = failFastReport('CACHE_DIR 準備', [{
    id: 'cache-dir',
    status: '失敗',
    excerpt: excerpt(cacheDirRaw),
    error: 'CACHE_DIR の絶対パスが返ってこなかった（subagent stdout を確認）',
  }])
  return workflowResult
}

// 空のまま埋め込むとコマンドが `bash ""` になり、差分の取得・分割が黙って失敗する
// （パイプの途中で落ちても標準出力は空のまま流れ、中身が 0 バイトの diff.txt が正常に作られる）。
// 実行前にまとめて確認する。
const REQUIRED_SCRIPT_ARGS = [
  { id: 'cache-io-script', name: 'CACHE_IO_SCRIPT', value: CACHE_IO_SCRIPT },
  { id: 'trim-diff-script', name: 'TRIM_DIFF_SCRIPT', value: TRIM_DIFF_SCRIPT },
  { id: 'split-diff-script', name: 'SPLIT_DIFF_SCRIPT', value: SPLIT_DIFF_SCRIPT },
  { id: 'split-guidelines-script', name: 'SPLIT_GUIDELINES_SCRIPT', value: SPLIT_GUIDELINES_SCRIPT },
]
const missingScriptArgs = REQUIRED_SCRIPT_ARGS.filter(s => !String(s.value).startsWith('/'))
if (missingScriptArgs.length > 0) {
  workflowResult = failFastReport('CACHE_DIR 準備', missingScriptArgs.map(s => ({
    id: s.id,
    status: '失敗',
    excerpt: excerpt(String(s.value)),
    error: `args.${s.name} が絶対パスで渡ってこなかった（SKILL.md が古い可能性。plugin を最新版に更新してください）`,
  })))
  return workflowResult
}

// `~` は Node 側では展開できないので、シェルの $HOME に置き換えて echo で実体を解決させる。
if (PROJECT_ROOT.startsWith('~')) {
  const shellPath = PROJECT_ROOT.replace(/^~(?=\/|$)/, '$HOME')
  const projectRootRaw = await agent(`お前はパス解決専用エージェントだ。Bash で次を実行し、stdout に出た絶対パス 1 行だけを返せ。前置き・後書き・コードフェンスは一切出すな。

\`\`\`bash
echo "${shellPath}"
\`\`\``, {
    agentType: 'nt-developer:reviewer',
    label: 'PROJECT_ROOT 解決',
    phase: 'CACHE_DIR 準備',
    model: 'haiku',
    effort: 'low',
  })
  const resolvedProjectRoot = String(projectRootRaw || '').trim()
  if (!resolvedProjectRoot.startsWith('/')) {
    workflowResult = failFastReport('CACHE_DIR 準備', [{
      id: 'project-root',
      status: '失敗',
      excerpt: excerpt(projectRootRaw),
      error: `PROJECT_ROOT（"${PROJECT_ROOT}"）の絶対パス解決に失敗した`,
    }])
    return workflowResult
  }
  log(`PROJECT_ROOT を絶対パスに解決しました（${PROJECT_ROOT} → ${resolvedProjectRoot}）`)
  PROJECT_ROOT = resolvedProjectRoot
}


// ========== PR コンテキスト取得 ==========
// メイン会話で gh を叩いて args.PR_CONTEXT に全文を詰める旧設計だと、
// メインモデルが PR 本文・コメント全文を出力として書き起こす必要があり
// Workflow 起動まで 2 分かかっていた。orchestrator 内に取得を移し、
// args は最小 4 フィールドだけ受け取る形にして起動を高速化している。

phase('PR コンテキスト取得')

let PR_CONTEXT = null
if (/^\d+$/.test(String(TARGET))) {
  const prFetchPrompt = `お前は PR 情報取得専用のエージェントだ。Bash で gh コマンドを叩いて結果を連結して返せ。

## 作業ディレクトリ
PROJECT_ROOT = "${PROJECT_ROOT}"
最初に \`cd "${PROJECT_ROOT}"\` してから gh コマンドを実行しろ。

## PR 番号
PR_NUMBER = ${TARGET}

## 手順

1. \`OWNER_REPO=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')\` で owner/repo を取得
2. \`gh pr view ${TARGET} --json title,body\` で PR 本文を取得
3. \`gh api "repos/$OWNER_REPO/pulls/${TARGET}/comments"\` で review コメントを取得
4. \`gh api "repos/$OWNER_REPO/issues/${TARGET}/comments"\` で会話コメントを取得

## 出力フォーマット（このフォーマットそのまま、生の文字列として 1 個出力。前置き・後書き禁止）

\`\`\`
### PR タイトル
<title>

### PR 本文
<body>

### Review コメント（差分行への inline コメント）
<コメント本文を 1 件ずつ箇条書き。著者・本文・対象ファイル:行 が分かる形で。生 JSON を貼るのではなく要点を残した形で>

### 会話コメント（PR 本体のコメント）
<コメント本文を 1 件ずつ箇条書き。著者・本文 が分かる形で。生 JSON を貼るのではなく要点を残した形で>
\`\`\`

## 重要な制約

- **作業ディレクトリ汚染禁止**: PROJECT_ROOT 配下に Write / \`>\` / \`>>\` / \`tee\` で一時ファイルを作るな。\`gh ... > .out\` のような書き出しも禁止。stdout で受け取れ。
- gh コマンドが失敗したら、stdout の冒頭に \`FAIL:\` を入れてエラー本文をそのまま 1〜2 行貼れ。
- title / body / コメント本文の改行や記号は壊さず、原文の構造を保て。
- 出力は上記のフォーマット連結のみ。要約・脚注・前置きを足すな。`

  const prContextRaw = await agent(prFetchPrompt, {
    agentType: 'nt-developer:reviewer',
    label: 'PR コンテキスト取得',
    phase: 'PR コンテキスト取得',
    model: 'haiku',
    effort: 'low',
  })
  const prContextStr = String(prContextRaw || '').trim()
  if (!prContextStr || prContextStr.startsWith('FAIL:')) {
    workflowResult = failFastReport('PR コンテキスト取得', [{
      id: 'pr-context',
      status: '失敗',
      excerpt: excerpt(prContextStr || '(空応答)'),
      error: prContextStr.startsWith('FAIL:') ? prContextStr.slice(5).trim() : 'gh コマンドの結果が空',
    }])
    return workflowResult
  }
  PR_CONTEXT = prContextStr

  // 以前は後段の「収集」フェーズがこの PR_CONTEXT をプロンプトに埋め込んで
  // Write で書き写していた（既にモデルが生成した内容を、別エージェントにもう
  // 一度生成させる形）。取得直後のここで 1 回だけ保存し、「収集」フェーズから
  // その書き写し手順を削除する。
  const prContextSaveRaw = await agent(`お前はファイル書き出し専用エージェントだ。Write ツールで以下の絶対パスに、下記の内容を一字一句変えずにそのまま書け。

絶対パス: ${CACHE_DIR}/pr_context.txt

中身:
${PR_CONTEXT}

stdout には "OK" の 1 行だけ出せ。それ以外のテキスト・前置き・後書きは一切出すな。`, {
    agentType: 'nt-developer:file-writer',
    label: 'PR_CONTEXT 保存',
    phase: 'PR コンテキスト取得',
    model: 'haiku',
    effort: 'low',
  })
  if (String(prContextSaveRaw || '').trim() !== 'OK') {
    workflowResult = failFastReport('PR コンテキスト取得', [{
      id: 'pr-context-save',
      status: '失敗',
      excerpt: excerpt(prContextSaveRaw),
      error: 'pr_context.txt の保存に失敗した（subagent stdout を確認）',
    }])
    return workflowResult
  }
}

// ========== レビュールール読み込み ==========
// ~/.claude/review-rules/*.md（個人ルール）と本体のチェックアウトの project_notes/review-rules/*.md
// （プロジェクト固有ルール）を両方読み込んで連結し、REVIEW_RULES に格納する。
// 両方とも存在しないプロジェクト・ユーザーでは "(なし)" になり、レビュー時のセクションも
// その値のままになる（無理に何かを推測して埋めない）。

phase('レビュールール読み込み')

// cat の結果をモデルに一度も生成させず cache-io.sh へ直接パイプする（diff/guidelines と同じ
// 方式）。以前はこのエージェントが内容を stdout として返し、後段の「収集」フェーズがそれを
// プロンプトに埋め込んで Write で書き写していた（同じテキストをモデルが 2 回生成していた）。

const REVIEW_RULES_SCHEMA = {
  type: 'object',
  properties: {
    review_rules_saved: { type: 'boolean' },
    file_count: { type: 'integer' },
  },
  required: ['review_rules_saved', 'file_count'],
}

const reviewRulesPrompt = `お前はファイル読み出し専用エージェントだ。個人ルール・プロジェクトルールを、下記の cache-io.sh 経由で直接 CACHE_DIR 配下のファイルに保存しろ。内容そのものを JSON に詰めるな（保存できたかどうかの確認結果のみを返せ）。\`>\` / \`>>\` を直接使うな。Read してから Write で書き写すのも禁止。

## 作業ディレクトリ
PROJECT_ROOT = "${PROJECT_ROOT}"

## 保存先
CACHE_DIR = "${CACHE_DIR}"

\`\`\`bash
OUT=""
FILE_COUNT=0
NOTES_DIR="$(dirname "$(git -C "${PROJECT_ROOT}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "${PROJECT_ROOT}/.git")")/project_notes"
for f in "$HOME"/.claude/review-rules/*.md "$NOTES_DIR"/review-rules/*.md; do
  [ -f "$f" ] || continue
  OUT+="### $f"$'\\n'
  OUT+="$(cat "$f")"$'\\n\\n'
  FILE_COUNT=$((FILE_COUNT + 1))
done
if [ -z "$OUT" ]; then
  echo "(review-rules なし)" | ${cacheIo('write', `${CACHE_DIR}/review_rules.txt`)}
else
  printf "%s" "$OUT" | ${cacheIo('write', `${CACHE_DIR}/review_rules.txt`)}
fi
test -f "${CACHE_DIR}/review_rules.txt" && echo "SAVED file_count=$FILE_COUNT" || echo "FAIL"
\`\`\`

上記コマンドの標準出力（\`SAVED file_count=N\` か \`FAIL\`）だけを見て \`review_rules_saved\` / \`file_count\` を判定しろ。保存したファイルの中身を Read するな。`

const reviewRulesRaw = await agent(reviewRulesPrompt, {
  agentType: 'nt-developer:reviewer',
  label: 'レビュールール読み込み',
  phase: 'レビュールール読み込み',
  model: 'haiku',
  effort: 'low',
  schema: REVIEW_RULES_SCHEMA,
})
const reviewRulesParsed = tryParseJson(reviewRulesRaw)
if (!reviewRulesParsed.ok || !reviewRulesParsed.value.review_rules_saved) {
  workflowResult = failFastReport('レビュールール読み込み', [{
    id: 'review-rules',
    status: '失敗',
    excerpt: excerpt(reviewRulesRaw),
    error: reviewRulesParsed.error || 'review_rules.txt の保存に失敗した（subagent の報告を確認）',
  }])
  return workflowResult
}
const reviewRulesResult = reviewRulesParsed.value
const hasReviewRules = reviewRulesResult.file_count > 0
if (hasReviewRules) {
  log(`review-rules を ${reviewRulesResult.file_count} ファイル読み込み`)
}

// ========== 移行元コード読み込み ==========
// リプレイス先リポジトリだけが持つ本体のチェックアウトの project_notes/legacy-source.md（移行元
// リポジトリの絶対パスと構造の説明）を読み込む。無いリポジトリでは移行元照合の観点ごと増えない。

phase('移行元コード読み込み')

const LEGACY_SOURCE_SCHEMA = {
  type: 'object',
  properties: {
    legacy_source_saved: { type: 'boolean' },
    exists: { type: 'boolean' },
  },
  required: ['legacy_source_saved', 'exists'],
}

const legacySourcePrompt = `お前はファイル読み出し専用エージェントだ。移行元リポジトリの設定ファイルを、下記の cache-io.sh 経由で直接 CACHE_DIR 配下のファイルに保存しろ。内容そのものを JSON に詰めるな（保存できたかどうかの確認結果のみを返せ）。\`>\` / \`>>\` を直接使うな。Read してから Write で書き写すのも禁止。

## 作業ディレクトリ
PROJECT_ROOT = "${PROJECT_ROOT}"

## 保存先
CACHE_DIR = "${CACHE_DIR}"

\`\`\`bash
NOTES_DIR="$(dirname "$(git -C "${PROJECT_ROOT}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "${PROJECT_ROOT}/.git")")/project_notes"
SRC="$NOTES_DIR/legacy-source.md"
if [ -f "$SRC" ]; then
  cat "$SRC" | ${cacheIo('write', `${CACHE_DIR}/legacy_source.txt`)}
  EXISTS=true
else
  echo "(legacy-source.md なし)" | ${cacheIo('write', `${CACHE_DIR}/legacy_source.txt`)}
  EXISTS=false
fi
test -f "${CACHE_DIR}/legacy_source.txt" && echo "SAVED exists=$EXISTS" || echo "FAIL"
\`\`\`

上記コマンドの標準出力（\`SAVED exists=true\` / \`SAVED exists=false\` か \`FAIL\`）だけを見て \`legacy_source_saved\` / \`exists\` を判定しろ。保存したファイルの中身を Read するな。`

const legacySourceRaw = await agent(legacySourcePrompt, {
  agentType: 'nt-developer:reviewer',
  label: '移行元コード読み込み',
  phase: '移行元コード読み込み',
  model: 'haiku',
  effort: 'low',
  schema: LEGACY_SOURCE_SCHEMA,
})
const legacySourceParsed = tryParseJson(legacySourceRaw)
if (!legacySourceParsed.ok || !legacySourceParsed.value.legacy_source_saved) {
  workflowResult = failFastReport('移行元コード読み込み', [{
    id: 'legacy-source',
    status: '失敗',
    excerpt: excerpt(legacySourceRaw),
    error: legacySourceParsed.error || 'legacy_source.txt の保存に失敗した（subagent の報告を確認）',
  }])
  return workflowResult
}
const hasLegacySource = legacySourceParsed.value.exists === true
if (hasLegacySource) {
  log('legacy-source.md を検出したため Spec/Range 観点の Claude 側へ移行元コードを渡す')
}

// ========== 外部連携 MCP 検出 ==========
// レビュー精度を上げるために使える、プロジェクト固有の MCP の接続状況を判定する。
// - laravel-boost: Laravel 公式の MCP。実データベースの定義やアプリの実行時情報を
//   見に行ける。project scope の .mcp.json で登録された "laravel-boost" という
//   名前のサーバーだけを対象にする（plugin marketplace 版の
//   "plugin:laravel-boost:laravel-boost" はホストの php を直接叩く設定のため、
//   全プロジェクトが Docker 内に php を置いている運用では接続できず対象外）。
//   接続済みの場合のみ Bug/Logic 観点の Claude 側を実データベース参照版
//   （reviewer-db）に切り替える。
// - aws-iac（AWS 公式の aws-iac-mcp-server）: cfn-lint 相当の CloudFormation
//   テンプレート構文検証・cfn-guard 相当のセキュリティコンプライアンス検証が
//   できる。接続済みの場合、Bug/Logic・Security 観点の Claude 側を CDK 検証版
//   （reviewer-cdk）に切り替える。

phase('外部連携 MCP 検出')

const mcpDetectPrompt = `お前は MCP 接続状態の確認専用エージェントだ。Bash で次を実行し、結果だけを stdout に返せ。

\`\`\`bash
LARAVEL_BOOST=$(claude mcp list 2>/dev/null | grep -E '^laravel-boost:' | grep -q '✔' && echo "true" || echo "false")
AWS_IAC=$(claude mcp list 2>/dev/null | grep -Ei 'aws-iac' | grep -q '✔' && echo "true" || echo "false")
printf '{"laravel_boost": %s, "aws_iac": %s}' "$LARAVEL_BOOST" "$AWS_IAC"
\`\`\`

出力は上記コマンドが返す JSON オブジェクト 1 行のみ。前置き・後書き・説明は一切出すな。`

const mcpDetectRaw = await agent(mcpDetectPrompt, {
  agentType: 'nt-developer:reviewer',
  label: '外部連携 MCP 検出',
  phase: '外部連携 MCP 検出',
  model: 'haiku',
  effort: 'low',
})
const mcpDetectParsed = tryParseJson(mcpDetectRaw)
const mcpDetected = mcpDetectParsed.ok && mcpDetectParsed.value ? mcpDetectParsed.value : {}
const hasLaravelBoost = mcpDetected.laravel_boost === true
const hasAwsIacMcp = mcpDetected.aws_iac === true
if (hasLaravelBoost) {
  log('laravel-boost 接続済み → Bug/Logic 観点で実データベース参照を有効化')
}
if (hasAwsIacMcp) {
  log('aws-iac-mcp-server 接続済み → Bug/Logic・Security 観点で CloudFormation テンプレート検証を有効化')
}

// ========== 収集 ==========
// 差分・ガイドライン・変更履歴・lint 結果は、取得したコマンドの出力をその場で
// ファイルにリダイレクトする（Read してから Write で書き写す経路は使わない）。
// 後続の全レビュー担当・検証役は、この CACHE_DIR 配下のファイルを
// Read / cat で参照するだけで済むようにするため。

phase('収集')

const collectPrompt = `お前はレビュー用データ収集役だ。取得した内容は要約・改変せず、下記の cache-io.sh 経由で直接 CACHE_DIR 配下のファイルに保存しろ。保存できたかどうかの確認結果のみを JSON で返せ（内容そのものを JSON に詰めるな）。**例外は差分（diff）だけ**で、下記手順1のとおり固定スクリプトを1つ挟め。これは巨大なマスタデータファイルの中身を機械的に間引くための決め打ち処理であり、お前が内容を要約・改変することとは違う。

## 作業ディレクトリ汚染の絶対禁止

PROJECT_ROOT 配下に一時ファイルを作るな。保存先は下記の CACHE_DIR 配下のみだ。PreToolUse hook で物理 block しているが迂回するな。

## 保存先
CACHE_DIR = "${CACHE_DIR}"

## TARGET の扱い
TARGET = "${TARGET}"
BASE_BRANCH = "${BASE_BRANCH}"
- 数字のみなら PR 番号として \`gh pr diff <番号>\` で差分を取得しろ（gh 側が GitHub 上の最新 base を解決するので fetch 不要）
- 空文字なら、まず \`git fetch origin ${BASE_BRANCH}\` でリモートの最新を取り込んでから、\`git diff --merge-base origin/${BASE_BRANCH}\` で取得しろ
- それ以外はブランチ名として、まず \`git fetch origin <ブランチ>\` してから \`git diff --merge-base origin/<ブランチ>\` で取得しろ

上記どちらのケースも **ローカルの BASE_BRANCH ブランチ自体を pull・checkout するな**。\`fetch\` だけでリモート追跡ブランチ（\`origin/<ブランチ>\`）を更新し、それを比較対象にしろ。ローカルの BASE_BRANCH ブランチが pull されないまま \`git diff --merge-base <ブランチ名>\`（ローカル参照）を使うと、\`--merge-base\` が計算する共通の祖先が古いまま固定され、実際にはリモート側で進んでいる分だけ差分がずれる（\`--merge-base\` は BASE_BRANCH と HEAD の共通祖先から今の作業ツリーまでの差分になるため、まだコミットしていない変更も含まれる点は変わらない）。

## 作業ディレクトリ
PROJECT_ROOT = "${PROJECT_ROOT}"
\`cd "${PROJECT_ROOT}"\` してから git / gh コマンドを実行しろ。

## 手順（コマンドの出力を cache-io.sh にパイプしろ。\`>\` / \`>>\` を直接使うな。Read で読んでから Write で書き写すのも絶対禁止）

1. **差分**: 上記 TARGET の扱いに従って取得した差分を、**必ず ${trimBulkDataDiffs()} にパイプしてから** "${CACHE_DIR}/diff.txt" に保存しろ。このフィルタは .csv/.tsv や DDL を含まない .sql の差分本体を要約1行に差し替える固定処理で、内容の要約・改変ではない（お前の判断で省略してはならない）。
   例（TARGET が空文字列またはブランチ名の場合。先に fetch してから origin/ 側と比較しろ）: \`git fetch origin ${BASE_BRANCH} && git diff --merge-base origin/${BASE_BRANCH} | ${trimBulkDataDiffs()} | ${cacheIo('write', `${CACHE_DIR}/diff.txt`)}\`
   PR 番号指定の場合も同様: \`gh pr diff <番号> | ${trimBulkDataDiffs()} | ${cacheIo('write', `${CACHE_DIR}/diff.txt`)}\`
2. **guidelines**: プロジェクトルートと変更ファイル親ディレクトリの AGENTS.md / 開発ガイドライン / CLAUDE.md を \`cat\` で連結し "${CACHE_DIR}/guidelines.txt" に保存しろ（存在しないものは無視）。例: \`cat AGENTS.md docs/*.md | ${cacheIo('write', `${CACHE_DIR}/guidelines.txt`)}\`。該当ファイルが 1 つもなければ \`echo "(なし)" | ${cacheIo('write', `${CACHE_DIR}/guidelines.txt`)}\` を実行しろ。
3. **git_history**: 変更ファイルごとに \`git blame <file>\` の冒頭・末尾と \`git log --oneline -20 -- <file>\` の出力を "${CACHE_DIR}/git_history.txt" に追記しろ。例: \`git log --oneline -20 -- <file> | ${cacheIo('append', `${CACHE_DIR}/git_history.txt`)}\`
4. **lint_results**: composer.json / package.json の scripts を確認し、Pint / PHPStan / ESLint / tsc 等が定義されていれば変更ファイルに対して実行し、結果を "${CACHE_DIR}/lint_results.txt" に保存しろ。例: \`<lint コマンド> | ${cacheIo('write', `${CACHE_DIR}/lint_results.txt`)}\`。実行方法が特定できなければ \`echo "lint 未実行" | ${cacheIo('write', `${CACHE_DIR}/lint_results.txt`)}\` を実行しろ。
5. **changed_files**: 差分から抜き出した変更ファイルパスの配列を JSON の応答に含めろ（ファイル保存は不要）。

## 出力フォーマット（JSON のみ）
\`\`\`json
{
  "diff_saved": true,
  "guidelines_saved": true,
  "git_history_saved": true,
  "lint_results_saved": true,
  "lint_executed": true,
  "lint_method": "Pint / PHPStan ...",
  "changed_files": ["path/to/file.php", ...]
}
\`\`\`

lint_executed は実際に実行できた場合のみ true。実行不能なら false で lint_method には "未特定" を入れろ。
出力は単一の JSON オブジェクトのみ。前置き・後書き禁止だ。`

const collectRaw = await agent(collectPrompt, {
  agentType: 'nt-developer:reviewer',
  label: '収集',
  phase: '収集',
  schema: COLLECT_SCHEMA,
  model: 'haiku',
  effort: 'low',
})

const collectParsed = tryParseJson(collectRaw)
if (!collectParsed.ok) {
  workflowResult = failFastReport('収集', [{
    id: 'collect',
    status: '失敗',
    excerpt: excerpt(collectRaw),
    error: collectParsed.error,
  }])
  return workflowResult
}
const collected = collectParsed.value || {}

// PR_CONTEXT は PR 本文・コメント（pr_context.txt）と、$ARGUMENTS で明示指定された実装計画書
// （GitHub Issue の本文を書き出したファイル等）の系統に分かれる。文字列として連結し直さず、
// 後続のレビュー担当・検証役にはファイルパスをそのまま渡して Read させる。
const prContextPaths = [
  PR_CONTEXT ? `${CACHE_DIR}/pr_context.txt` : null,
  PLAN_DOC_PATH || null,
].filter(Boolean)
const hasPrContext = prContextPaths.length > 0

// review_rules.txt / pr_context.txt は「レビュールール読み込み」「PR コンテキスト取得」の
// 各フェーズで取得直後に保存済み・保存失敗時は既に fail_fast 済みなので、ここでの
// 存在チェックは不要（このフェーズが伝わってきた時点で両方確定している）。

// 差分が Read ツール 1 回の上限を超えるときだけファイル単位に分割し、目次を先頭に置く。
// 収まる差分は 1 本のままにする（小さい PR に余計な仕掛けを入れない）。
let diffPaths = [`${CACHE_DIR}/diff.txt`]

const splitOutDir = `${CACHE_DIR}/diff-parts`
const splitResult = await agent(`お前は差分分割スクリプトを実行して結果を返すだけのエージェントだ。プロンプトの内容に対する解釈・追加作業はするな。

Bash で次の 1 コマンドを実行しろ。このコマンドを変形するな:

\`\`\`bash
bash "${SPLIT_DIFF_SCRIPT}" "${CACHE_DIR}/diff.txt" "${splitOutDir}" ${DIFF_SPLIT_MAX_LINES} ${READ_SPLIT_MAX_BYTES}
\`\`\`

## 出力の読み取り方
- 1 行目が \`NOSPLIT <行数> <バイト数>\` → \`split\` を false、\`total_lines\` にその行数、\`total_bytes\` にそのバイト数、\`part_paths\` を空配列にしろ
- 1 行目が \`SPLIT <ファイル数> <行数> <バイト数>\` → \`split\` を true、\`total_lines\` にその行数、\`total_bytes\` にそのバイト数、2 行目以降に並ぶ絶対パスを**全部**\`part_paths\` に入れろ（省略・並び替え禁止）

## 出力（JSON のみ、前置き禁止）
{ "split": false, "total_lines": 0, "total_bytes": 0, "part_paths": [] }`, {
  agentType: 'nt-developer:reviewer',
  label: '差分の分割判定',
  phase: '収集',
  schema: DIFF_SPLIT_SCHEMA,
  model: 'haiku',
  effort: 'low',
})

// 差分が空なら、レビューする対象そのものが無い。取得が失敗しても（fetch 失敗・ブランチ名の
// 誤り・gh の認証切れ）エラーは標準エラーに出るだけで、中身が 0 バイトの diff.txt は正常に
// 作られる。ここで止めないと、全観点が「変更なし」を読んで指摘ゼロで完走し、レビューを
// 通したという誤った結果だけが残る。
if (!splitResult || ((splitResult.total_lines || 0) === 0 && (splitResult.total_bytes || 0) === 0)) {
  workflowResult = failFastReport('収集', [{
    id: 'diff',
    status: '失敗',
    excerpt: excerpt(JSON.stringify(splitResult || null)),
    error: `差分が空だった（${CACHE_DIR}/diff.txt が 0 バイト）。比較対象との間に変更が 1 つも無いか、差分の取得コマンドが失敗している。TARGET（"${TARGET}"）/ BASE_BRANCH（"${BASE_BRANCH}"）の指定と、git・gh がその対象を解決できる状態かを確認してください`,
  }])
  return workflowResult
}

if (splitResult.split === true && Array.isArray(splitResult.part_paths) && splitResult.part_paths.length > 0) {
  // 目次を先頭に置く。何ファイルあるかを先に把握させ、読み飛ばしを検知できるようにするため。
  diffPaths = [`${splitOutDir}/diff-index.txt`, ...splitResult.part_paths]
  log(`差分が ${splitResult.total_lines} 行 / ${splitResult.total_bytes} バイトで Read の上限を超えるため ${splitResult.part_paths.length} ファイルに分割しました`)
}

// 差分を Read させるための参照行。分割時は目次 + 全分割ファイルを列挙する。
function diffRefLines() {
  return diffPaths.map(p => `- ${p}`).join('\n')
}

// ガイドラインも Read ツール 1 回の上限を超えるときだけ分割する（差分と同じ扱い）。
let guidelinesPaths = collected.guidelines_saved ? [`${CACHE_DIR}/guidelines.txt`] : []

if (collected.guidelines_saved) {
  const guidelinesSplitOutDir = `${CACHE_DIR}/guidelines-parts`
  const guidelinesSplitResult = await agent(`お前はガイドライン分割スクリプトを実行して結果を返すだけのエージェントだ。プロンプトの内容に対する解釈・追加作業はするな。

Bash で次の 1 コマンドを実行しろ。このコマンドを変形するな:

\`\`\`bash
bash "${SPLIT_GUIDELINES_SCRIPT}" "${CACHE_DIR}/guidelines.txt" "${guidelinesSplitOutDir}" ${READ_SPLIT_MAX_BYTES}
\`\`\`

## 出力の読み取り方
- 1 行目が \`NOSPLIT <バイト数>\` → \`split\` を false、\`total_bytes\` にそのバイト数、\`part_paths\` を空配列にしろ
- 1 行目が \`SPLIT <ファイル数> <バイト数>\` → \`split\` を true、\`total_bytes\` にそのバイト数、2 行目以降に並ぶ絶対パスを**全部**\`part_paths\` に入れろ（省略・並び替え禁止）

## 出力（JSON のみ、前置き禁止）
{ "split": false, "total_bytes": 0, "part_paths": [] }`, {
    agentType: 'nt-developer:reviewer',
    label: 'ガイドラインの分割判定',
    phase: '収集',
    schema: GUIDELINES_SPLIT_SCHEMA,
    model: 'haiku',
    effort: 'low',
  })

  if (guidelinesSplitResult && guidelinesSplitResult.split === true && Array.isArray(guidelinesSplitResult.part_paths) && guidelinesSplitResult.part_paths.length > 0) {
    guidelinesPaths = [`${guidelinesSplitOutDir}/guidelines-index.txt`, ...guidelinesSplitResult.part_paths]
    log(`ガイドラインが ${guidelinesSplitResult.total_bytes} バイトで Read の上限を超えるため ${guidelinesSplitResult.part_paths.length} ファイルに分割しました`)
  }
}


// ========== 並列レビュー ==========

phase('並列レビュー')

const commonMd = PROMPTS.common || ''
const cacheFiles = {
  diff: diffPaths,
  guidelines: guidelinesPaths.length > 0 ? guidelinesPaths : null,
  gitHistory: collected.git_history_saved ? `${CACHE_DIR}/git_history.txt` : null,
  lintResults: collected.lint_results_saved ? `${CACHE_DIR}/lint_results.txt` : null,
  reviewRules: hasReviewRules ? `${CACHE_DIR}/review_rules.txt` : null,
  legacySource: hasLegacySource ? `${CACHE_DIR}/legacy_source.txt` : null,
  prContext: prContextPaths.length > 0 ? prContextPaths : null,
}
const r1Thunks = []
for (const d of DIMENSIONS) {
  const dimensionMd = PROMPTS[d.key] || ''
  const claudeCtx = buildContextRefForDimension({
    dimensionKey: d.key,
    cacheFiles,
    projectRoot: PROJECT_ROOT,
  })
  const reviewPrompt = buildR1Prompt({
    commonMd,
    dimensionMd,
    dimensionLabel: d.label,
    context: claudeCtx.text,
  })

  // Claude 側: nt-developer:reviewer + StructuredOutput
  // reviewer は Read / Grep / Glob を持つので、ファイルパス参照の指示をそのまま
  // 渡せば自分で読みに行く。DIFF 等の実データをプロンプトに埋め込む必要がない。
  // Bug/Logic 観点かつ laravel-boost 接続済みの場合だけ実データベース参照版
  // （reviewer-db）に、Bug/Logic・Security 観点かつ aws-iac-mcp-server 接続済み
  // の場合だけ CDK 検証版（reviewer-cdk）に差し替える（他観点は従来どおり）。
  // laravel-boost を優先する（同一 PR で両方接続済みの場合、Bug/Logic 観点は Laravel の DB 照合を優先する）。
  const claudeLabel = `C-${d.key}`
  let claudeAgentType = 'nt-developer:reviewer'
  if (d.key === 'bug_logic' && hasLaravelBoost) {
    claudeAgentType = 'nt-developer:reviewer-db'
  } else if ((d.key === 'bug_logic' || d.key === 'security') && hasAwsIacMcp) {
    claudeAgentType = 'nt-developer:reviewer-cdk'
  }
  r1Thunks.push(() => agent(reviewPrompt, {
    agentType: claudeAgentType,
    label: claudeLabel,
    phase: '並列レビュー',
    schema: R1_FINDINGS_SCHEMA,
    effort: 'medium',
  }).then(text => ({ id: claudeLabel, engine: 'claude', dimension: d.key, dimensionLabel: d.label, raw: text })))

}

const r1Raw = await parallelWithRetry(
  r1Thunks,
  detectR1Failure,
  () => triggerKillFlag(CACHE_DIR, '並列レビュー'),
  CACHE_DIR,
  '並列レビュー',
)

const r1Failures = []
const r1Parsed = []
for (let i = 0; i < r1Raw.length; i++) {
  const entry = r1Raw[i]
  const failure = detectR1Failure(entry)
  if (failure) {
    r1Failures.push(failureRow(entry, failure, `slot-${i}`))
    continue
  }
  r1Parsed.push({ ...entry, findings: tryParseJson(entry.raw).value.findings })
}

if (r1Failures.length > 0) {
  workflowResult = failFastReport('並列レビュー', r1Failures)
  return workflowResult
}

// 集約（センチネル除外して findings 一覧へ）
const aggregated = []
for (const entry of r1Parsed) {
  for (const item of entry.findings) {
    if (item && item.no_findings === true) continue
    aggregated.push({
      ...item,
      _source_agent: entry.id,
      _engine: entry.engine,
      _dimension: entry.dimension,
    })
  }
}

// ========== 重複統合（クラスター判定） ==========
phase('重複統合')

let clusters = []
if (aggregated.length > 0) {
  const findingsForCluster = aggregated.map((f, i) => ({
    index: i,
    file: f.file,
    line: f.line,
    category: f.category,
    description: f.description,
    evidence: f.evidence,
  }))

  const clusterPrompt = `お前は同じ問題を指している findings をグルーピングする判定エージェントだ。

下記の findings 配列を見て、「同じ根本問題で、かつ同じ修正方針を提案している」ものに同じ cluster_id を振れ。

## グルーピングのルール

- 同じ場所（file + line）でも、観点が違うなら別 cluster（例: refactor 観点の指摘と security 観点の指摘は同じ場所でも別 cluster）
- 同じ場所・同じ category でも、修正方針が違うなら別 cluster（例: 同じバグへの「マッピング追加」と「errors ハッシュ含める」は別 cluster）
- file + line が違っても、明らかに同じ根本問題（例: 同じバグの上流側と下流側を別エンジンが別角度から指摘）なら同じ cluster
- 言い回しの違い（詳細度・例示の有無）は同 cluster でいい

## 出力

全 findings に必ず cluster_id を振れ（漏れは禁止）。
cluster_id は 1 から連番。
1 finding しか属さない cluster も { cluster_id, finding_indices: [N] } の形で出せ。

## findings

${JSON.stringify(findingsForCluster, null, 2)}

## 出力フォーマット（JSON のみ。前置き禁止）

\`\`\`json
{
  "clusters": [
    { "cluster_id": 1, "finding_indices": [0, 3, 7] },
    { "cluster_id": 2, "finding_indices": [1] }
  ]
}
\`\`\`
`

  const clusterRaw = await agent(clusterPrompt, {
    agentType: 'nt-developer:reviewer',
    label: 'cluster',
    phase: '重複統合',
    schema: CLUSTER_SCHEMA,
    effort: 'medium',
  })
  const clusterParsed = tryParseJson(clusterRaw)
  if (!clusterParsed.ok) {
    workflowResult = failFastReport('重複統合', [{
      id: 'cluster',
      status: '失敗',
      excerpt: excerpt(clusterRaw),
      error: clusterParsed.error,
    }])
    return workflowResult
  }
  clusters = (clusterParsed.value && clusterParsed.value.clusters) || []
}

// クラスター ID で集約。cluster_id が割り当てられなかった finding は単独 cluster として残す
const indexToClusterId = new Map()
for (const c of clusters) {
  for (const idx of c.finding_indices) {
    indexToClusterId.set(idx, c.cluster_id)
  }
}

const mergedMap = new Map()
for (let i = 0; i < aggregated.length; i++) {
  const f = aggregated[i]
  const clusterKey = indexToClusterId.has(i) ? `cluster-${indexToClusterId.get(i)}` : `solo-${i}`
  if (mergedMap.has(clusterKey)) {
    const existing = mergedMap.get(clusterKey)
    existing._source_agents.push(f._source_agent)
    existing._engines.push(f._engine)
    if ((f.confidence || 0) > (existing.confidence || 0)) {
      existing.confidence = f.confidence
      existing.description = f.description
      existing.evidence = f.evidence
    }
  } else {
    mergedMap.set(clusterKey, {
      file: f.file,
      line: f.line,
      category: f.category,
      severity: f.severity,
      confidence: f.confidence || 0,
      description: f.description,
      evidence: f.evidence,
      _source_agents: [f._source_agent],
      _engines: [f._engine],
      _dimension: f._dimension,
    })
  }
}
const merged = Array.from(mergedMap.values())

// ========== 正誤検証 ==========

phase('正誤検証')

let scored = []
let r2Validations = []
let r2NewFindings = []
if (merged.length === 0) {
  log('R1 集約結果 0 件 → 正誤検証をスキップ')
} else {
  const validatorMd = PROMPTS.validator || ''
  const r1FindingsJson = JSON.stringify(merged.map((f, i) => ({
    index: i,
    file: f.file,
    line: f.line,
    category: f.category,
    severity: f.severity,
    confidence: f.confidence,
    description: f.description,
    evidence: f.evidence,
  })), null, 2)

  // R1_FINDINGS もファイル化する。DIFF ほど巨大にはならないが、DIFF / PR_CONTEXT
  // と同じくファイル参照方式に統一し、validator は Read / cat だけで内容を取得する。
  const r1FindingsPath = `${CACHE_DIR}/r1_findings.json`
  const r1FindingsSaveRaw = await agent(`お前はファイル書き出し専用エージェントだ。Write ツールで以下の絶対パスに、下記の内容を一字一句変えずにそのまま書け。

絶対パス: ${r1FindingsPath}

中身:
${r1FindingsJson}

stdout には "OK" の 1 行だけ出せ。それ以外のテキスト・前置き・後書きは一切出すな。`, {
    agentType: 'nt-developer:file-writer',
    label: 'R1_FINDINGS 保存',
    phase: '正誤検証',
    model: 'haiku',
    effort: 'low',
  })
  if (String(r1FindingsSaveRaw || '').trim() !== 'OK') {
    workflowResult = failFastReport('正誤検証', [{
      id: 'r1-findings-save',
      status: '失敗',
      excerpt: excerpt(r1FindingsSaveRaw),
      error: 'R1_FINDINGS のファイル保存に失敗した（subagent stdout を確認）',
    }])
    return workflowResult
  }

  // R1 と同じ PR_CONTEXT を validator にも渡す。渡さないと
  // validator が実装コードだけを見て「バグに見える」項目を new_findings として
  // 復活させ、R1 が仕様を確認した上で正しく落とした指摘が最終結果に混入する。
  const diffSection = buildFileRefSection('DIFF', diffPaths, '(差分なし)')
  const guidelinesSection = guidelinesPaths.length > 0
    ? buildFileRefSection('GUIDELINES', guidelinesPaths, '(なし)')
    : ''
  const r1FindingsSection = buildFileRefSection('R1_FINDINGS', r1FindingsPath, '(なし)')
  const prContextSection = hasPrContext
    ? buildFileRefSection('PR_CONTEXT', prContextPaths, '(なし)')
    : ''
  const reviewRulesSection = hasReviewRules
    ? buildFileRefSection('REVIEW_RULES', `${CACHE_DIR}/review_rules.txt`, '(review-rules なし)')
    : ''
  const legacySourceSection = hasLegacySource
    ? buildFileRefSection('LEGACY_SOURCE', `${CACHE_DIR}/legacy_source.txt`, '(legacy-source.md なし)')
    : ''
  // R1 のレビュー担当には「差分だけで判断せずプロジェクト全体を自由に調べろ」という
  // 指示（buildContextRefForDimension 側）が付いているが、正誤検証には付いていなかった。
  // GUIDELINES を読む・既存コードとの整合性を確認するのに必要なので、ここにも足す。
  const codebaseAccessSection = `## コードベース全体へのアクセス\n\nR1_FINDINGS の evidence をそのまま信じるな。GUIDELINES・既存の同種コードとの整合性を、Grep / Glob / Read でプロジェクトルート（PROJECT_ROOT = "${PROJECT_ROOT}"）配下を自由に調べた上で判定しろ。`
  const r2Body = [validatorMd, '---', diffSection, guidelinesSection, r1FindingsSection, prContextSection, reviewRulesSection, legacySourceSection, codebaseAccessSection]
    .filter(Boolean)
    .join('\n\n')

  const r2Thunks = [
    () => agent(r2Body, {
      agentType: 'nt-developer:reviewer',
      label: 'V-claude',
      phase: '正誤検証',
      schema: VALIDATOR_SCHEMA,
      effort: 'medium',
    }).then(text => ({ id: 'V-claude', engine: 'claude', raw: text })),
  ]


  const r2Raw = await parallelWithRetry(
    r2Thunks,
    detectR2Failure,
    () => triggerKillFlag(CACHE_DIR, '正誤検証'),
    CACHE_DIR,
    '正誤検証',
  )

  const r2Failures = []
  const r2Parsed = []
  for (let i = 0; i < r2Raw.length; i++) {
    const entry = r2Raw[i]
    const failure = detectR2Failure(entry)
    if (failure) {
      r2Failures.push(failureRow(entry, failure, `validator-${i}`))
      continue
    }
    r2Parsed.push({ ...entry, body: tryParseJson(entry.raw).value })
  }
  if (r2Failures.length > 0) {
    workflowResult = failFastReport('正誤検証', r2Failures)
    return workflowResult
  }

  // 集約: validations は index 別、new_findings は追加
  const verdictByIndex = new Map()
  for (const entry of r2Parsed) {
    const validations = (entry.body && entry.body.validations) || []
    for (const v of validations) {
      const arr = verdictByIndex.get(v.original_index) || []
      // PR_CONTEXT がある場合、valid 票の spec_check（仕様確認の証跡）が薄いものは
      // 「確認した体で実際は照合していない」可能性があるため、スコアリングで加点に使わない
      const weakSpecCheck = hasPrContext && v.verdict === 'valid' && (v.spec_check || '').trim().length < 10
      arr.push({ engine: entry.engine, ...v, weak_spec_check: weakSpecCheck })
      verdictByIndex.set(v.original_index, arr)
    }
    const newOnes = (entry.body && entry.body.new_findings) || []
    for (const nf of newOnes) {
      r2NewFindings.push({
        ...nf,
        _source_agents: [entry.id],
        _engines: [entry.engine],
        _from_validator: true,
      })
    }
  }
  r2Validations = Array.from(verdictByIndex.entries()).map(([idx, votes]) => ({ index: idx, votes }))

  // ========== スコアリング ==========

  phase('スコアリング')

  scored = merged.map((f, i) => {
    // ==SCORING_UNIT_START==（plugins/nt-developer/tests/scoring.test.js がこのマーカー間を抜き出して単体テストする）
    let score = f.confidence || 0
    const engines = new Set(f._engines)
    const votes = verdictByIndex.get(i) || []
    const valid = votes.filter(v => v.verdict === 'valid' && !v.weak_spec_check).length
    const fp = votes.filter(v => v.verdict === 'false_positive').length
    const adjust = votes.filter(v => v.verdict === 'adjust')
    if (valid >= 2) score += 20
    else if (valid === 1) score += 10
    if (fp >= 2) score -= 50
    else if (fp === 1) score -= 30
    if (adjust.length > 0) {
      const adj = adjust[0].adjusted
      if (adj) {
        f.file = adj.file || f.file
        f.line = adj.line || f.line
        f.description = adj.description || f.description
        f.evidence = adj.evidence || f.evidence
      }
    }
    score = Math.max(0, Math.min(100, score))

    const isBugLike = ['bug', 'security', 'spec'].includes(f.category)
    const isConventionMust = f.category === 'convention' && f.severity === 'MUST'
    let severityLabel
    // false_positive 判定が1票でもあれば、他の valid 票やエンジン一致の加算で
    // スコアが閾値を超えても必須対応まで上げない（際どい算術での誤判定を防ぐ）
    if (fp >= 1) severityLabel = '任意対応'
    else if (isBugLike && score >= 80) severityLabel = '必須対応'
    else if (isConventionMust && score >= 90) severityLabel = '必須対応'
    else severityLabel = '任意対応'

    return {
      file: f.file,
      line: f.line,
      category: f.category,
      severity: f.severity,
      confidence: score,
      description: f.description,
      evidence: f.evidence,
      source_agents: f._source_agents,
      engines: Array.from(engines),
      dimension: f._dimension,
      severity_label: severityLabel,
    }
    // ==SCORING_UNIT_END==
  })

  for (const nf of r2NewFindings) {
    // ==NEWFINDING_UNIT_START==（plugins/nt-developer/tests/scoring.test.js がこのマーカー間を抜き出して単体テストする）
    const score = Math.max(0, Math.min(100, (nf.confidence || 0)))
    const isBugLike = ['bug', 'security', 'spec'].includes(nf.category)
    let severityLabel
    if (isBugLike && score >= 80) severityLabel = '必須対応'
    else severityLabel = '任意対応'
    // ==NEWFINDING_UNIT_END==
    scored.push({
      file: nf.file,
      line: nf.line,
      category: nf.category,
      severity: nf.severity,
      confidence: score,
      description: nf.description,
      evidence: nf.evidence,
      source_agents: nf._source_agents,
      engines: nf._engines,
      dimension: 'validator',
      severity_label: severityLabel,
      from_validator: true,
      spec_check: nf.spec_check || '',
    })
  }
}

// ========== false positive 自動降格（決定論） ==========
// reviewer プロンプト側にも同等の禁止ルールを入れているが、出てきてしまった
// ものを最後にもう一度落とす二重防御。

// 5-A: PR description で follow-up / 既知として明示されたファイルの finding は 任意対応 に降格
const followUpFiles = extractFollowUpFiles(PR_CONTEXT)
if (followUpFiles.size > 0) {
  scored = scored.map(f => {
    const path = f.file || ''
    for (const ffile of followUpFiles) {
      if (path === ffile || path.endsWith('/' + ffile) || path.includes(ffile)) {
        if (f.severity_label !== '任意対応') {
          return {
            ...f,
            severity_label: '任意対応',
            original_severity_label: f.severity_label,
            demoted_by_followup: true,
            demote_reason: `PR description の follow-up / 既知として記載: ${ffile}`,
          }
        }
        return f
      }
    }
    return f
  })
}

// 5-C: 検証役（validator）が追加した new_findings のうち、PR_CONTEXT との照合結果
// （spec_check）が未記入 / 中身が薄いものは自動的に任意対応へ格下げする。プロンプト
// で「追加前に PR_CONTEXT と矛盾しないか確認しろ」と指示しても、確認した体で実際は
// 照合せずに指摘を追加するため、AI の自己申告を信用せずコード側で機械的に検査する。
if (hasPrContext) {
  scored = scored.map(f => {
    if (!f.from_validator) return f
    if (f.severity_label === '任意対応') return f
    if (!['bug', 'security', 'spec'].includes(f.category)) return f
    const specCheck = (f.spec_check || '').trim()
    if (specCheck.length >= 10) return f
    return {
      ...f,
      severity_label: '任意対応',
      original_severity_label: f.severity_label,
      demoted_by_missing_spec_check: true,
      demote_reason: '検証役が追加した新規指摘だが、PR_CONTEXT との照合結果 (spec_check) が未記入または不十分なため自動格下げ',
    }
  })
}

// 5-D: 他人の変更をレビューする場合、REVIEW_RULES の個人ルール（$HOME/.claude/review-rules/
// 配下）由来の指摘は「必須対応/任意対応」という実害の強さの軸から外し、専用の
// 「個人観点」に分離する。相手が知りようのない個人の好みを規約違反と同じ重みで見せないため。
// 自分の変更をレビューする場合は、自分の好みなので従来どおり通常の重み付けに残す。
if (!isOwnChange) {
  scored = scored.map(f => {
    const path = personalReviewRulePath(f.evidence, PROJECT_ROOT)
    if (!path) return f
    return {
      ...f,
      severity_label: '個人観点',
      original_severity_label: f.severity_label,
      demoted_by_personal_rule: true,
      demote_reason: `個人の review-rule (${path}) 由来の指摘のため、レビュアー個人の好みとして分離`,
    }
  })
}

scored.sort((a, b) => {
  const order = { '必須対応': 0, '任意対応': 1, '個人観点': 2 }
  const oa = order[a.severity_label] ?? 9
  const ob = order[b.severity_label] ?? 9
  if (oa !== ob) return oa - ob
  return (b.confidence || 0) - (a.confidence || 0)
})

// findings（必須）/ optional_findings（任意）/ personal_preference_findings（個人観点）
// の 3 配列に分割して返却
const findingsOut = scored.filter(f => f.severity_label !== '任意対応' && f.severity_label !== '個人観点')
const optionalFindingsOut = scored.filter(f => f.severity_label === '任意対応')
const personalPreferenceFindingsOut = scored.filter(f => f.severity_label === '個人観点')

workflowResult = {
  fail_fast: null,
  target: TARGET,
  mode: MODE,
  cache_dir: null,
  changed_files: collected.changed_files || [],
  lint_executed: collected.lint_executed,
  lint_method: collected.lint_method,
  spec_failures: [],
  findings: findingsOut,
  optional_findings: optionalFindingsOut,
  personal_preference_findings: personalPreferenceFindingsOut,
  agent_summary: {
    r1_agents: r1Parsed.length,
    r2_agents: r2Validations.length > 0 || r2NewFindings.length > 0 ? 2 : 0,
    r2_new_findings: r2NewFindings.length,
  },
}
reviewCompleted = true
return workflowResult

} finally {
  // ========== 後始末 ==========
  // 削除するのはレビューが最後まで通ったときだけだ。中止・例外では残す（再開の入力と
  // 失敗の中身がそこにしか無い）。残った分は nt-setup の setup-code-review-cache-cleanup が登録する
  // 定期実行（launchd / systemd timer）が 1 日ごとに掃除する。
  // CACHE_DIR が未生成（PR コンテキスト取得より前で死亡）なら no-op。
  phase('後始末')
  if (reviewCompleted) {
    await cleanupCacheDir()
  } else if (CACHE_DIR) {
    // 立てたままの kill フラグを残すと、SKILL.md が案内している resumeFromRunId での再開時に
    // runner.sh が起動直後にそれを見つけて exit 137 で戻り、レビューが 1 つも走らない。
    if (killFlagRaised) {
      await clearKillFlag(CACHE_DIR, '後始末')
    }
    log(`中止したため作業ディレクトリを残しました: ${CACHE_DIR}`)
  }
}
