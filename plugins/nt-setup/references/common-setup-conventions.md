# setup 系スキル共通の作法

`setup-*` という名前のスキル（`setup-and-checkup` を除く。他スキルへの委譲役でこの型に当てはまらないため）に共通する前提条件・厳守事項・既存セットアップの確認方法・定期実行の登録手順・アンインストール手順の型をここにまとめる。各 SKILL.md はこのファイルを参照し、個別の追加項目だけを自分の節に書け。

以下の `<識別子>` は各 SKILL.md が指定する名前だ。登録ファイルの名前は macOS が `com.claude.<識別子>.plist`、Linux が `claude-<識別子>.service` と `claude-<識別子>.timer` になる。

## 前提条件の確認（共通）

- **Claude Code CLI がインストールされている** — `which claude` で確認
- **OS を `uname -s` で判定しろ** — `Darwin` なら launchd、`Linux` なら systemd user unit で登録する。以降の OS 別の手順は該当する方だけ実施しろ
- **Linux の場合、systemd user インスタンスが動いている** — `systemctl --user is-system-running` が `running` または `degraded` なら使える。それ以外なら定期実行を登録できない旨を伝えて中断しろ
- **WSL の場合、WSL が自動で止まらない設定になっている** — `/proc/version` に `microsoft` が含まれていれば WSL だ。`wslpath "$(cmd.exe /c 'echo %USERPROFILE%' | tr -d '\r')"` の直下の `.wslconfig` の `[general]` に `instanceIdleTimeout=-1` があるか確認しろ。無ければ、Windows の「WSL Settings」で「Keep WSL running」をオンにするよう案内しろ。systemd のタイマーは WSL を止めない理由にならず、既定のままでは WSL ごと止まって定期実行が動かない

## 既存セットアップの確認（共通の型）

各 SKILL.md が挙げる生成ファイルと、登録ファイル（macOS: `~/Library/LaunchAgents/com.claude.<識別子>.plist` / Linux: `~/.config/systemd/user/claude-<識別子>.service` と `claude-<識別子>.timer`）が既に存在するか確認しろ。

存在する場合は登録状態も確認しろ（macOS: `launchctl list | grep <識別子>` / Linux: `systemctl --user is-enabled claude-<識別子>.timer`）。そのうえで「既にセットアップ済みのようです。上書きしますか？」とユーザーに確認しろ。同意が無ければ中断しろ。

## 登録ファイルの生成（共通の型）

各 SKILL.md が指定するプレースホルダー（`__INTERVAL_SECONDS__` 等）は、macOS と Linux の両方のテンプレートで同じ値に置換しろ。

### macOS（launchd）

`${CLAUDE_SKILL_DIR}/templates/com.claude.<識別子>.plist` を読み、`__HOME__` を `$HOME`（実際のホームディレクトリ絶対パス）で置換した結果を `~/Library/LaunchAgents/com.claude.<識別子>.plist` に書き込め。

### Linux（systemd user unit）

```bash
mkdir -p ~/.config/systemd/user
```

`${CLAUDE_SKILL_DIR}/templates/claude-<識別子>.service` と `${CLAUDE_SKILL_DIR}/templates/claude-<識別子>.timer` を読み、`~/.config/systemd/user/` に同じ名前で書き込め。`__HOME__` は無い（ホームディレクトリは systemd の `%h` で解決される）。

## 定期実行の登録（共通の型）

### macOS（launchd）

```bash
launchctl bootout gui/$(id -u)/com.claude.<識別子> 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude.<識別子>.plist
launchctl list | grep <識別子>
```

`com.claude.<識別子>` が表示されれば成功。

### Linux（systemd user unit）

```bash
systemctl --user daemon-reload
systemctl --user enable --now claude-<識別子>.timer
systemctl --user list-timers claude-<識別子>.timer --no-pager
```

`NEXT` 列に次回の時刻が出れば成功。timer は登録した時点と user マネージャーの起動時に1回、以降は `OnUnitActiveSec` の間隔で動く（launchd の `RunAtLoad` + `StartInterval` と同じ動き）。

**ログインしていない間も動かすには linger が要る。** `loginctl show-user "$USER" -p Linger` が `Linger=no` なら、`sudo loginctl enable-linger "$USER"` を提示してユーザー自身に実行してもらえ。

## 厳守事項（共通）

- **ユーザーの確認なしにファイルを作成・上書きするな**
- **定期実行を登録する（`launchctl bootstrap` / `systemctl --user enable --now`）前に必ずユーザーに「起動していいですか？」と確認しろ**（登録を伴わないスキルは対象外）
- **既存ファイルがある場合は必ず上書き確認を取れ**
- **エラーが出たら勝手にリカバリせず、ユーザーに報告しろ**
- **`sudo` の実行と Windows 側の `.wslconfig` の書き換えを自分でやるな。** コマンドと設定を提示してユーザー自身にやってもらえ

## アンインストール手順（共通の型。ユーザーに聞かれた場合のみ案内）

macOS:

```bash
launchctl bootout gui/$(id -u)/com.claude.<識別子>
rm ~/Library/LaunchAgents/com.claude.<識別子>.plist
rm -rf ~/.claude/scripts/<識別子>*
```

Linux:

```bash
systemctl --user disable --now claude-<識別子>.timer
rm ~/.config/systemd/user/claude-<識別子>.service ~/.config/systemd/user/claude-<識別子>.timer
systemctl --user daemon-reload
rm -rf ~/.claude/scripts/<識別子>*
```

追加の状態ファイル（`~/.claude/state/*` 等）があるスキルは、この型に加えて個別の削除コマンドを書け。
