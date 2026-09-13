---
name: code-style-cicd
description: GitHub Actions 等の CI/CD ワークフローを書く・編集する前に必ず起動しろ。
effort: low
---

# CI/CD 固有の規約（書く前に読め）

GitHub Actions などの CI/CD ワークフローに固有の構成・規約。

**判断軸は `${CLAUDE_SKILL_DIR}/../../references/quality-axes.md` にある。** この skill が持つのは、その軸に沿って書くための規約とコード例だ。

**共通章（言語問わず）は `code-style` skill を別途起動して読め**：コメントに出典・チケット番号を書かない、複数行コメントの原則 等。

---

## パスフィルタで差分検出しろ。無関係な変更でジョブを走らせるな

❌ NG（どんな変更でも全ジョブを実行する）:
```yaml
on:
  push:
    branches: [main]
jobs:
  deploy-infra: { ... }
  build-backend: { ... }
  build-frontend: { ... }
```

⭕ OK（変更されたパスを検出し、該当ジョブだけ実行する）:
```yaml
jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      infra: ${{ steps.filter.outputs.infra }}
      backend: ${{ steps.filter.outputs.backend }}
    steps:
      - uses: actions/checkout@v5
      - id: filter
        uses: dorny/paths-filter@<pinned-sha> # vX.Y.Z
        with:
          filters: |
            infra:
              - 'infra/**'
            backend:
              - 'backend/**'

  deploy-infra:
    needs: changes
    if: needs.changes.outputs.infra == 'true' || github.event_name == 'workflow_dispatch'
    runs-on: ubuntu-latest
    steps: [...]
```

ルール:

- 複数コンポーネント（backend / frontend / infra 等）を 1 リポジトリで管理する場合、まず差分検出ジョブを置き、以降のジョブは `if: needs.changes.outputs.<component> == 'true'` で条件付き実行しろ
- フィルタ内で肯定パターンと否定パターンを混在させるな（`predicate-quantifier` のデフォルトは OR 評価のため、否定パターン単体だと「ほぼ全ファイルにマッチ」してしまう）。除外したい拡張子（`.md` 等）は `on.push.paths` 側の `!path/**.md` で弾け

## ジョブ間の実行順序は `needs` で明示しろ。concurrency の FIFO 非保証に頼るな

```yaml
jobs:
  deploy-infra: { needs: changes }
  build-backend: { needs: [changes, deploy-infra] }
  build-nginx: { needs: [changes, deploy-infra] }
  deploy-app: { needs: [changes, deploy-infra, build-backend, build-nginx] }
```

ルール:

- 「インフラ更新 → イメージビルド → アプリデプロイ」のような順序保証が必要な処理は、同じ workflow 内で `needs` チェーンを組め。並行実行してよいジョブ（例: backend と frontend の image ビルド）は同じ `needs` を持たせて並列化しろ
- 本番デプロイ系の workflow 同士（例: 通常デプロイと定期メンテナンス処理）が衝突しうる場合は `concurrency: { group: <shared-name>, cancel-in-progress: false }` で直列化しろ

## Docker イメージビルドでは必ずキャッシュを使え

❌ NG（毎回フルビルド）:
```yaml
- uses: docker/build-push-action@v7
  with:
    context: ./backend
    push: true
```

⭕ OK（GitHub Actions キャッシュを使ってレイヤーを再利用する）:
```yaml
- uses: docker/setup-buildx-action@v4
- uses: docker/build-push-action@v7
  with:
    context: ./backend
    file: ./backend/Dockerfile
    push: true
    cache-from: type=gha,scope=backend
    cache-to: type=gha,mode=max,scope=backend
    tags: |
      ${{ env.REGISTRY }}/backend:${{ github.sha }}
      ${{ env.REGISTRY }}/backend:latest
```

ルール:

- `docker/build-push-action` を使うときは必ず `cache-from` / `cache-to` に `type=gha` を指定しろ。複数イメージをビルドする場合は `scope` を分けてキャッシュの取り違えを防げ
- ビルド対象アーキテクチャと実行環境の CPU アーキテクチャが一致するなら（例: Graviton/ARM64 本番環境向けに ARM ランナーでビルドする）、QEMU エミュレーションを避けてネイティブランナー上でビルドする方が大幅に速い

## 外部 action はコミット SHA で固定しろ。GitHub 公式や Verified creator バッジ付きの作者はタグ固定でよい

GitHub 公式ガイド（Secure use reference）の推奨は二段構え:

- **最も安全**: フルコミット SHA で固定する。タグは書き換え可能なため、悪意ある変更が加わるサプライチェーンリスクがある
- **許容される代替**: 作者を信頼できるならタグ固定でもよい。GitHub Marketplace の「Verified creator」バッジ（GitHub が本人確認済みの作者だという印）が信頼できるかどうかの目安になる、とGitHub自身が明記している

「外部だから一律SHA固定」ではなく、以下で線引きしろ:

- GitHub 自身が管理する `actions/*`（`actions/checkout` 等）、および Verified creator バッジ付きの作者はタグ固定で構わない
- 個人メンテナ・バッジ無しの作者は、フルコミット SHA で固定しろ

❌ NG（Verified creator バッジの無い個人メンテナの action をタグ参照）:
```yaml
- uses: dorny/paths-filter@v4
```

⭕ OK（個人メンテナの action は SHA 固定 + 可読性のためバージョンをコメントで残す）:
```yaml
- uses: dorny/paths-filter@7b450fff21473bca461d4b92ce414b9d0420d706 # v4.0.2
```

⭕ OK（GitHub 公式・Verified creator バッジ付きの作者はタグ固定で構わない）:
```yaml
- uses: actions/checkout@v4
```

SHA で固定する場合、`code-style`（docblock / コメントに出典・経緯・チケット番号・他ファイル参照を書くなの節）の「コードを読めば分かる自明な What」には該当しない。SHA だけではバージョンが人間に読めないため、コメント併記が正当化される数少ない例外。

## 依存バージョン管理 bot を導入しろ。更新方針はエコシステムごとに分けろ

`.github/dependabot.yml`（または Renovate 等）で各パッケージエコシステムを監視する：

```yaml
version: 2
updates:
  - package-ecosystem: npm
    directory: /frontend
    schedule:
      interval: weekly
      day: monday
    open-pull-requests-limit: 5
    groups:
      minor-and-patch:
        update-types: [minor, patch]
    ignore:
      - dependency-name: "*"
        update-types: ["version-update:semver-major"]

  # GitHub Actions は major を ignore しない。
  # ランタイム廃止のようなセキュリティ関連の変更が action の major に乗ることがあるため、
  # ここで major を抑止すると取りこぼす。
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
      day: monday
```

ルール:

- 依存関係を持つエコシステム（`composer` / `npm` / `github-actions` 等）ごとに監視対象を登録しろ。バージョン管理 bot が入っていないプロジェクトに CI/CD 設定を追加する場合は、bot 導入も合わせて提案しろ
- minor/patch は `groups` でまとめて 1 PR に集約し、レビュー負荷を下げろ
- major は原則 `ignore` してよいが、**その判断が正しくない場合がある**（GitHub Actions のように「ランタイム廃止」がマイナーではなく major で来るエコシステムがある）。ignore するかどうかは機械的に揃えず、エコシステムごとに検討し、ignore しない理由 / する理由を 1 行コメントで残せ

## 主要ジョブの成功/失敗を通知しろ

デプロイ系の重要ジョブ（インフラ更新・アプリデプロイ等）は、成功/失敗を通知するステップを `if: success()` / `if: failure()` で追加しろ。所要時間も計測して通知に含めると障害対応時に有用。

## 送信前に自分の diff を読み直せ

ワークフロー書き終わったら自分の diff を読み直して、上記の各項目と **共通章（`code-style` skill）** の全項目をチェックしろ。特に：

- 無関係な変更でジョブが走らないか（パスフィルタ）
- Docker ビルドに `cache-from` / `cache-to` があるか
- 新規追加した外部 action が SHA 固定されているか
- 新規依存エコシステムがバージョン管理 bot の監視対象に入っているか

読みづらい箇所が残っていたら直してから報告しろ。
