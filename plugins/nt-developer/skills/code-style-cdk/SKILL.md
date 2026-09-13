---
name: code-style-cdk
description: AWS CDKのコードを書く・編集する前に必ず起動しろ。
effort: low
---

# AWS CDK 固有のコード規約（書く前に読め）

AWS CDK（TypeScript）のインフラコードに固有の構成・規約。

**判断軸は `${CLAUDE_SKILL_DIR}/../../references/quality-axes.md` にある。** この skill が持つのは、その軸に沿って書くための規約とコード例だ。

**共通章（言語問わず）は `code-style` skill を別途起動して読め**：早期 return / 同じ式の変数化 / docblock 規約 / コメントに出典・チケット番号を書かない 等。

**素の TypeScript 構文ルール**は `code-style-ts` skill を別途起動して読め。

**デプロイや `cdk synth` がエラーで落ちたら、`~/.claude/references/cdk-troubleshooting.md` があれば必ず読め。** エラー名から原因を引く対応表だ。

---

## データを壊す操作（書く前に必ず読め）

次の4つは、気づかずにやるとデータが消えるかスタックが動かなくなる。

- **Construct の ID を変えるとリソースが作り直される**: Construct のリネーム・移動は論理 ID を変え、CloudFormation はリソースを置き換える。DB・バケットのような状態を持つリソースでは中身が消える。デプロイ前に必ず `cdk diff` を読み、置換（replace）が出ていないか確認しろ
- **中身の入った S3 バケットは destroy しても残る**: `removalPolicy: DESTROY` と `autoDeleteObjects: true` の両方を指定しろ。バージョニング有効のバケットは削除マーカーが残るため、さらに残りやすい
- **スタック間参照を消すとデプロイが相互ロックする**: 参照している側の import を消すだけでは、export 側が「まだ使われている」と判定してデプロイできない。2回に分けろ。1回目は参照側の import を消し、export 側に `this.exportValue()` を足してデプロイ。2回目で `exportValue()` を消してデプロイする
- **`UPDATE_ROLLBACK_FAILED` で止まったスタックは通常のデプロイでは動かせない**: `cdk rollback $STACK` で戻せ。特定リソースが原因なら `cdk rollback $STACK --orphan <LogicalId>` で切り離せ

## 1 スタック 1 ファイルにしろ。共通部品は種類ごとに分離しろ

```
infra/
  bin/<app>.ts              # CDK アプリのエントリポイント（スタックの生成・依存注入をここで行う）
  lib/
    <resource>-stack.ts     # トップレベルスタック。1 スタック 1 ファイル（例: rds-stack.ts, batch-stack.ts, ci-cd-stack.ts）
    <big-stack-name>/       # 1 スタックが肥大化する場合、同名ディレクトリにサブ Construct を分割
      network-security.ts
      main-load-balancer.ts
    config/                 # 命名規則・環境変数・パラメータパスなど定数の一元管理
      name.ts
      <env>-env.ts
    constructs/             # 複数スタックで再利用する Construct（アラーム定義・通知設定等）
      app-alarms.ts
  test/
```

ルール:

- スタックが 1 つのリソース種別（RDS / ECS サービス / CI-CD 用 IAM・ECR 等）に対応する場合、ファイル名を `<resource>-stack.ts` に揃えろ
- 1 スタックのコンストラクタが長くなり複数の関心事（ネットワーク / ロードバランサ / VPC エンドポイント等）を持つ場合、それぞれを同名ディレクトリのサブファイルに分離してスタック本体からインスタンス化しろ
- 複数スタックで再利用する部品（アラーム定義、通知設定等）は `constructs/` に切り出せ。1 スタックでしか使わない部品をここに置くな

## マジック文字列・リソース名は `config/name.ts` に一元管理しろ

❌ NG（リソース名・ARN export 名がスタックごとにバラバラに直書き）:
```ts
new ecs.FargateService(this, 'AppService', {
  serviceName: 'myapp-prd-app',
  ...
});
// 別のスタックで同じ文字列を別の書き方で再現してしまう
const serviceArn = `arn:aws:ecs:...:service/myapp-prd-cluster/myapp-prd-app`;
```

⭕ OK（`config/name.ts` に集約し、全スタックがそこから import する）:
```ts
// config/name.ts
export const APP = 'myapp' as const;
export const ENV = 'prd' as const;
export const CLUSTER_NAME = `${APP}-${ENV}-cluster` as const;
export const APP_SERVICE_NAME = `${APP}-${ENV}-app` as const;

// 各スタック
import { CLUSTER_NAME, APP_SERVICE_NAME } from './config/name';
new ecs.FargateService(this, 'AppService', { serviceName: APP_SERVICE_NAME, ... });
```

ルール:

- リソース名・SSM パラメータパス・CloudFormation export 名・ロググループ名など、複数スタックで参照される文字列は `config/name.ts`（または同等の定数ファイル）に `as const` で定義しろ
- 環境依存の値（`prd` / `dev` 等）は基底の環境名から派生させ、直書きの重複を避けろ
- 許可 IP リストのような値の集合も、意味が自明でない要素には 1 行コメントでラベルを付けてよい（例: 許可元の区分を示す 1 行ラベル）。ただし各要素にコメントを付けるとしても 1 行に収めろ

## IAM 権限は必要最小限の resource ARN に絞れ。ワイルドカードには理由を添えろ

❌ NG（何でも `*`）:
```ts
role.addToPolicy(new iam.PolicyStatement({
  actions: ['ecs:UpdateService', 'ecs:RunTask'],
  resources: ['*'],
}));
```

⭕ OK（対象を ARN で絞り込む。ワイルドカードにする場合は理由を 1 行で明示）:
```ts
// ECS サービスの更新（対象クラスタ・サービスに限定）
role.addToPolicy(new iam.PolicyStatement({
  actions: ['ecs:UpdateService', 'ecs:DescribeServices'],
  resources: [this.formatArn({
    service: 'ecs',
    resource: 'service',
    resourceName: `${CLUSTER_NAME}/${APP_SERVICE_NAME}`,
  })],
}));

// ECR 認証トークン取得（GetAuthorizationToken は resource を取らない仕様のため * のまま）
role.addToPolicy(new iam.PolicyStatement({
  actions: ['ecr:GetAuthorizationToken'],
  resources: ['*'],
}));
```

ルール:

- `resources: ['*']` を書く前に、対象サービスの API が resource-level 権限制御に対応しているか確認しろ（`this.formatArn()` で対象を絞れないか検討しろ）
- どうしても `*` が必要な場合（API 仕様上 resource を取らない等）は、その API 固有の制約を 1 行コメントで残せ。これは「実装契約・技術根拠」なので `code-style`（docblock / コメントに出典・経緯・チケット番号・他ファイル参照を書くなの節）の許可対象
- IAM ロールの `AssumeRole` 条件（`StringLike` 等）は、対象ブランチ・リポジトリを明示的に絞れ

## スタック間の依存は Props 経由で注入しろ。疎結合にしたい参照だけ Export/Import を使え

❌ NG（他スタックのインスタンスを直接 import して結合度を上げる）:
```ts
import { networkStack } from '../bin/app'; // グローバル参照
```

⭕ OK（Props で明示的に受け取る）:
```ts
export interface AppServiceStackProps extends cdk.StackProps {
  readonly vpc: ec2.IVpc;
  readonly cluster: ecs.ICluster;
  readonly dbCluster: rds.IDatabaseCluster;
}

export class AppServiceStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: AppServiceStackProps) {
    super(scope, id, props);
    // props.vpc / props.cluster を使う
  }
}
```

ルール:

- 同一デプロイ内の他スタックへの依存は `StackProps` を継承した専用 interface で明示しろ（`bin/*.ts` 側でインスタンス化して渡す）
- デプロイ順序が独立していてほしい参照（固定名の Secret 等）は、Props 経由ではなく `Fn.importValue` / 名前検索（`fromSecretNameV2` 等）で疎結合にしろ。どちらを選んだかは 1 行コメントで理由を残せ（例: 「固定名の Secret を名前参照で取得し、他スタックへの依存を弱める」）

## セクション区切りコメントは使ってよい

スタックのコンストラクタが長くなる場合、罫線 + 見出しでセクションを区切るのは可読性を上げるので問題ない：

```ts
// ------------------------------------------------------
// タスク定義 (ARM64 / Fargate)
// ------------------------------------------------------
```

ただし区切りコメントの直後に続く個別リソースへのコメントは `code-style`（docblock / コメントに出典・経緯・チケット番号・他ファイル参照を書くなの節）の複数行コメント原則（1 行が基本、将来のバグ回避に必要な場合のみ複数行）に従え。

## スタックを書き終えたら aws-iac-mcp-server で実際の CloudFormation テンプレートを検証しろ

`aws-iac-mcp-server`（AWS 公式の MCP サーバー。CloudFormation テンプレートの構文検証・セキュリティコンプライアンス検証ができる外部ツール）が導入済みなら、スタックの実装が一段落した時点で以下を確認しろ:

1. `cdk synth` で実際に生成される CloudFormation テンプレートを取得しろ
2. `validate_cloudformation_template` で構文・スキーマエラーが無いか検証しろ（TypeScript の型チェックを通っていても、CloudFormation のプロパティ名や値の組み合わせが不正な場合がある）
3. `check_cloudformation_template_compliance` でセキュリティ・コンプライアンスルール違反が無いか検証しろ

`cdk diff` だけでは検出できない、実際にデプロイされるテンプレートそのものの構文エラー・設定ミスを事前に捕まえられる。導入されていないプロジェクトでは、この項目は無視して構わない。

## 送信前に自分の diff を読み直せ

コード書き終わったら自分の diff を読み直して、上記の各項目と **共通章（`code-style` skill）** ・**TypeScript 構文（`code-style-ts` skill）** の全項目をチェックしろ。特に：

- リソース名・ARN export 名を直書きせず `config/` の定数を使っているか
- IAM `resources: ['*']` に理由コメントが付いているか
- スタック間依存が Props 経由で明示されているか
- aws-iac-mcp-server が使えるなら、実際の CloudFormation テンプレートを検証したか

読みづらい箇所が残っていたら直してから報告しろ。
