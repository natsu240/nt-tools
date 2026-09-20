# nt-tools

Claude Code 向けのスキルを集約したプラグインマーケットプレイスです。用途に応じて3つのプラグインで構成されています。

※各スキルの詳細な仕様は各スキルの `SKILL.md` を、hook の挙動は各スクリプト冒頭のコメントを参照してください。

---

## プラグイン一覧

| プラグイン | 対象者 | 概要 |
|---|---|---|
| **nt-common** | 共通 | 領域を問わず使う共有スキル、MCP サーバー設定、出力スタイル |
| **nt-developer** | 開発作業 | 開発ワークフロー支援スキルおよび事故防止 hook |
| **nt-setup** | 共通 | 各種セットアップの自動化 |

※ `nt-developer` および `nt-setup` の利用には **`nt-common` が必須** です。

---

## インストール手順

### 1. 診断コマンドによる自動提案（推奨）

最初に `nt-setup` のみを導入し、診断コマンドを実行して必要なスキルを選択・インストールしてください。

```bash
claude plugin marketplace add natsu240/nt-tools
claude plugin install nt-setup@nt-tools
```

Claude Code のセッション内で `/setup-and-checkup` を実行すると、現在の役割や作業履歴を解析し、最適な設定と必要なプラグインを提案します。

### 2. 手動で個別にインストールする場合

```bash
claude plugin marketplace add natsu240/nt-tools
claude plugin install <プラグイン名>@nt-tools
```

- コードを書かない用途で使う場合： `nt-common` のみのインストールで十分です。
- スコープ選択： 対話画面でスコープを問われた場合は、全プロジェクトに適用される `Install for you (user scope)` を選択してください。

## インストール後の初期設定

### 1. MCP サーバーの設定 (nt-common)

`nt-common` には `.mcp.json` が同梱されているため、手動での `claude mcp add` は不要です。

| MCP サーバー | 用途 | 必要な事前準備 |
|---|---|---|
| google-workspace | GoogleWorkSpaceツールの操作 | 自身の OAuth 情報を環境変数（`GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`）としてシェルの設定ファイルに設定 |

※ 過去に user scope で同名の MCP を登録している場合は、競合を防ぐため `claude mcp remove <name> -s user` で削除してください。

### 2. 日本語出力スタイルの適用 (nt-common)

全プロジェクトで標準の「日本語」出力スタイルを適用するには、`~/.claude/settings.json`（ユーザー共通設定）に以下の記述を追加します。

```json
{
  "outputStyle": "nt-common:日本語"
}
```

※ `/config` から設定した場合は、現在開いているプロジェクト（`.claude/settings.local.json`）にのみ適用されます。

### 3. project_notes/ を Git の管理対象から外す

最初に使い始めるときに、`~/.config/git/ignore` に以下の1行を追加してください。全リポジトリで `project_notes/` が Git の管理対象から外れます。

```
**/project_notes/
```

## プロジェクト側の設定ファイル

必要に応じて、対象プロジェクトの直下の `project_notes/` に以下の設定ファイルを配置します。ワークツリーで作業する場合も、本体のチェックアウト側に置いたものが参照されます。ファイルが存在しない場合は自動的に判定がスキップされます。

| 設定ファイル | 参照するもの | 説明 |
|---|---|---|
| `project_notes/git.md` | `git-rules` | base ブランチ・ワークツリーを使うか・ブランチ名の決まり |
| `project_notes/deploy.md` | `/deploy-watch` | デプロイ監視の方法 |
| `project_notes/automation.md` | `gate-branch-op-approval.sh` / `deny-session-split.sh` | マージ確認・セッション分割を省くマーカー行（`claude-merge-approval: skip` / `claude-session-split: skip`） |
| `project_notes/environment.md` | 全般 | 環境 URL、ログイン手順、テストデータなどの暗黙知 |
| `project_notes/aws-sources.md` | `/prod-log-triage` | AWS profile 名の設定 |
| `project_notes/legacy-source.md` | `/code-review` | 移行元コードのローカル絶対パスと構造の説明 |
| `project_notes/comment-guard.json` | `gate-comment-reference.sh` | コメント出典チェックの除外パス・追加パターン |
| `project_notes/review-rules/*.md` | `/code-review` | リポジトリ固有のコードレビュー規約 |
| `project_notes/browser-operation-rules.md` | `/browser-operation` | ブラウザ操作の規約（起点 URL、ログイン運用、テストデータ、スクリーンショットの扱い） |

<details>
<summary>aws-sources.md のテンプレート</summary>

# AWS 接続情報

## AWS Profile

| 環境 | profile 名 |
|---|---|
| 本番 | `your-profile-prd` |
| 検証 | `your-profile-dev` |

コマンドは `aws --profile <profile> logs ...` の形で実行してください。profile 指定は必須です。

</details>

## 運用・メンテナンス

### 自動更新の有効化

`nt-setup` インストール後、以下を実行して定期自動更新を有効にしてください。

```bash
/setup-plugin-auto-update
```

更新実行後、セッションを再起動せずに反映したい場合は `/reload-plugins`（MCP 構成変更時は `/reload-plugins --force`）を実行します。

※ WSL では `C:\Users\<ユーザー名>\.wslconfig` の `[general]` に `instanceIdleTimeout=-1` を書いてください（無いと WSL ごと止まり定期実行が動きません）。

### 優先順位についての注意

- ローカルスキルの優先： `~/.claude/skills/` や `.claude/skills/` に同名のスキルが存在する場合、ローカル側が優先されます。
- 開発ルール： このリポジトリ自体の開発・PR 作成手順については CLAUDE.md を参照してください。

## ライセンス

MIT License（[LICENSE](./LICENSE) を参照）

注意： 本リポジトリは natsu240 が個人で管理しているものです。
