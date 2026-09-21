---
name: git-rules
description: ブランチ作成・worktree 追加・push・tag・PR の手元チェックアウトの前に必ず起動しろ。
effort: low
---

# Git 作業の作法

- **`nt-tools` は、ファイルを変更する作業を必ずワークツリーで行え。本体のチェックアウトは main の更新・PR のマージ・掃除にだけ使え**（同梱の hook が、本体での編集とブランチ作成の両方を止める）。**それ以外のリポジトリでワークツリーを使うかは、そのリポジトリの `project_notes/git.md` を読んで従え。書いていなければユーザーに確認し、確認した内容をそこへ追記しろ。** 依存パッケージがコンテナの中にあり `container_name`・ポート・ボリューム名まで固定されているリポジトリでは、ワークツリーに開発環境を立てられないので強制対象にするな。
- **ワークツリーは必ず `orca worktree create` で作れ。`git worktree add` を直接叩くな**（同梱の hook が止める）。生の git で作るとフォルダだけができて Claude 自身は元のディレクトリで動き続けるため、Orca に出るカードと実際に動いているセッションがズレる。

  ```
  orca worktree create --repo id:<リポジトリの id> --name <名前> \
    --base-branch <base> --issue <Issue 番号> --agent claude --prompt "<引き継ぎ内容>" --json
  ```

  - **`--repo` は必ず `id:<リポジトリの id>` で指定しろ。`path:` を使うな。** WSL では Orca がリポジトリを Windows 側の UNC パスで登録するため、`path:` は `repo_not_found` で弾かれる。id は `orca repo list --json | jq -r '.result.repos[] | "\(.id)\t\(.displayName)"'` で引け。
  - `--name` がそのままブランチ名になり、`~/pj/workspaces/<リポジトリ名>/<名前>` に作られる。
  - **GitHub Issue のある作業では `--issue <番号>` を必ず付けろ。** Orca のカードが Issue に紐付く。`gh issue develop` は使うな（本体にブランチを切ることになる）。
  - `--agent claude --prompt` を付けるとそのワークツリーの中で Claude が起動して作業を引き継ぐ。**呼び出し元のセッションは自分で実装せず、引き継ぎ内容をプロンプトに書いて渡せ**（両方揃っていなければ同梱の hook が止める）。
  - **`--base-branch` と `--name` に渡す値はリポジトリごとに違う。そのリポジトリの `project_notes/git.md`（無ければ `CLAUDE.md`）を読め。書いていなければユーザーに確認し、確認した内容を `project_notes/git.md` に追記しろ。**
  - **Orca のカードの親子は、オプションを付けなければ呼び出し元の子になる。`implement` から派生する実装作業では何も付けるな。** `--no-parent` を付けるのは、今の作業と無関係な作業を独立したカードにするときだけだ（`gripe` がこれに当たる）。付け間違えたら `orca worktree set --worktree <ワークツリーの selector> --parent-worktree <親の selector>` で後から付け替えられる。
  - 片付けは `orca worktree rm --worktree path:<ワークツリーの絶対パス> --run-hooks --json` だ。ワークツリー・ブランチ・フォルダーがまとめて消える。**`--run-hooks` を必ず付けろ。** 付けないと archive フック（Docker のコンテナ・イメージ・ボリュームの削除等）が黙ってスキップされる（`orca worktree rm --help` に `Repo-defined orca.yaml archive hooks are skipped unless --run-hooks is passed.` と書いてある。Orca が安全側に倒しているだけなので、明示的に付ければ走る）。**共有ブランチ・他人のブランチは絶対に消すな。** 消していいのは自分がその作業のために作ったものだけだ。
  - **`git worktree add` を使っていいのは `--detach` のときだけだ。** README / CLAUDE.md だけの main 直 push に必要で、Orca は必ずブランチを作るため代替できない。
- **`orca worktree create` の前に base を手で最新化するな。** Orca の設定 `refreshLocalBaseRefOnWorktreeCreate` がオンで、ワークツリー作成時にリモートの base を取り込んで fast-forward する。
- **ワークツリーを作らずにブランチだけ切るときは、切る前に必ず base を最新化しろ**。`git fetch origin && git switch main && git pull --ff-only origin main && git switch -c <new-branch>` の順だ。未コミットの変更があるなら `git stash push -u` してから pull しろ。古い base から切ると、直近でマージされた他の PR と衝突してやり直しになる。同梱の hook が base ブランチ上でのブランチ作成を見ているが、feature ブランチから「main に戻って最新化して切る」流れまでは面倒を見ない。この手順は自分で守れ。
- **PR のマージは `gh pr merge <PR番号> --merge` の形だけを使え。`--squash` / `--rebase`（短縮形の `-s` / `-r`）を付けるな。PR 番号を省くな**（同梱の hook が両方止める）。**この規約の実体はこの skill と `gate-branch-op-approval.sh` の2箇所にしか無い。どこに書いてあるか問われたらその2つを Read してから答えろ。`CLAUDE.md` 等の別ファイルに書いてあると推測で答えるな。**
- **タグ付け・Release 作成の手順がそのリポジトリの `CLAUDE.md` / `README.md` に書かれているなら、`git tag` / `gh release create` を手で打つ前にそれを読んで従え**（バージョンの整合を検証してからタグを作るコマンドが用意されていることがある）。
- **PR をローカル確認用に `gh pr checkout` / `git checkout` したら、確認が終わったら忘れずにそのブランチを削除しろ**（`git branch -d <branch>`）。放置すると `git branch -vv` に残骸が積もる。PR がマージされてリモート側が消えれば `prune-gone-branches.sh` が `git fetch` / `git pull` のたびに自動で消すが、**PR が open のまま確認だけして放置した場合は消えない**。そのケースは自分で消せ。
- **stashしなくても現在の作業ツリーにある変更はそのまま切り替わるため、ブランチ切り替える時にはいちいちstashするな。**
- **`git rebase -i` でコミットを `drop` / `squash` する前に、そのコミットの実際の差分内容（`git show <hash> --stat` 等）を確認しろ**。コミットメッセージ・ファイル名が似ているという理由だけで「base に既にある内容と重複」と判断し、中身を確認せず drop するな。特に他者（author が自分以外）のコミットが対象のときは要注意。

## Orca のセットアップスクリプトを登録する

依存パッケージ（`node_modules` / `vendor`）や `.env` を持つリポジトリでは、ワークツリーを作った直後にそれらを用意しないと作業できない。Orca はリポジトリごとにセットアップスクリプトを走らせる枠を持っているので、そこへ登録しろ。**この値を書き込む CLI は無い**（`orca repo` 配下は `list` / `add` / `show` / `set-base-ref` / `search-refs` しか無い）。**値の実体は `orca-data.json`（macOS: `~/Library/Application Support/orca/profiles/local-default/orca-data.json` / Linux: `~/.config/orca/profiles/local-default/orca-data.json`）の `repos[].hookSettings.scripts`（`setup` / `archive`）に平文の JSON で入っている（Linux 版で `scripts` 配下の形は未確認）。ただし Orca アプリが起動中は、このファイルを直接編集しても反映されない**（編集後に `orca repo show` を叩き直しても編集前の値が返る。Orca は起動中メモリ上の状態を正としているため、アプリが次にこのファイルへ保存した時点で編集が消える）。**Orca を起動したまま直接編集するな。** アプリを終了させてから編集すれば反映されると見られるが未検証なので、直接編集を選ぶなら再起動後に `orca repo show` で値が入ったことを必ず確認しろ。

1. 雛形（`${CLAUDE_SKILL_DIR}/templates/orca-worktree-setup.sh`）を対象リポジトリの `scripts/orca-worktree-setup.sh` としてコピーし、`COPY_FROM_MAIN` と `INSTALL_TARGETS` をそのリポジトリの実態に合わせて書き換えてコミットしろ。
2. Orca アプリでそのリポジトリの設定を開き、セットアップスクリプトの欄に `bash scripts/orca-worktree-setup.sh` の1行だけを入れろ。**設定欄に長いコマンド列を直接書くな。** 設定欄の中身は Git 管理外なので、実体をリポジトリ側に置かないと変更を追跡できない。
3. `orca repo show --repo id:<リポジトリの id> --json` の `hookSettings.scripts.setup` に値が入ったことを確認しろ。`setupRunPolicy` が `run-by-default` なら以降はワークツリー作成時に自動で走る（走らせたいことを明示するなら `orca worktree create` に `--setup run` を付けろ）。

登録済みかどうかを一覧で見るには次を叩け。

```
orca repo list --json | jq -r '.result.repos[] | "\(.path)\tsetup=\(.hookSettings.scripts.setup)"'
```

**そのリポジトリで用意が必要なもの（本体からコピーする Git 管理外ファイル・依存インストールを走らせるディレクトリ）は、対象リポジトリの `project_notes/git.md` を読め。書いていなければユーザーに確認し、確認した内容をそこへ追記しろ。** **Docker で開発環境を立てるリポジトリでは、依存インストールをホスト側で走らせても意味が無い**（コンテナ内のボリュームが実体だ）。

`nt-tools` 自体は `node_modules` / `vendor` も `.env` も持たないので、セットアップスクリプトの登録が要らない。
