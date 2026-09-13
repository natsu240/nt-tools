#!/usr/bin/env bash

set -uo pipefail
unset GIT_DIR GIT_WORK_TREE

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/sync-branch-after-pr-merge.sh"
[[ -f "$HOOK" ]] || { echo "sync-branch-after-pr-merge.sh が見つかりません: $HOOK"; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

GIT_QUIET=(git -c user.name=test -c user.email=test@example.com -c init.defaultBranch=main -c advice.detachedHead=false)

ORIGIN="$TMP_ROOT/origin.git"
SEED="$TMP_ROOT/seed"
WORK="$TMP_ROOT/work"

"${GIT_QUIET[@]}" init --quiet --bare "$ORIGIN"
"${GIT_QUIET[@]}" init --quiet "$SEED"
printf 'seed\n' >"$SEED/README.md"
"${GIT_QUIET[@]}" -C "$SEED" add README.md
"${GIT_QUIET[@]}" -C "$SEED" commit --quiet -m "初期コミット"
"${GIT_QUIET[@]}" -C "$SEED" remote add origin "$ORIGIN"
"${GIT_QUIET[@]}" -C "$SEED" push --quiet -u origin main

"${GIT_QUIET[@]}" -C "$SEED" switch --quiet -c feature-x
printf 'feature\n' >>"$SEED/README.md"
"${GIT_QUIET[@]}" -C "$SEED" commit --quiet -am "feature コミット"
"${GIT_QUIET[@]}" -C "$SEED" push --quiet -u origin feature-x
"${GIT_QUIET[@]}" -C "$SEED" switch --quiet main
"${GIT_QUIET[@]}" -C "$SEED" merge --quiet --no-ff -m "PR マージ" feature-x
"${GIT_QUIET[@]}" -C "$SEED" push --quiet origin main

mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  "pr view "*"--json baseRefName -q .baseRefName") echo "$GH_MOCK_BASE" ;;
  "pr view "*"--json headRefName -q .headRefName") echo "$GH_MOCK_HEAD" ;;
  "repo view --json deleteBranchOnMerge -q .deleteBranchOnMerge") echo "$GH_MOCK_AUTO_DELETE" ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

failures=0
total=0

# WORK を作り直し、PR の head ブランチ（マージ元）をチェックアウトした状態にする。
reset_work_on_head() {
  rm -rf "$WORK"
  "${GIT_QUIET[@]}" clone --quiet "$ORIGIN" "$WORK"
  "${GIT_QUIET[@]}" -C "$WORK" fetch --quiet origin feature-x
  "${GIT_QUIET[@]}" -C "$WORK" switch --quiet -c feature-x origin/feature-x
}

# WORK を作り直し、base ブランチ（gh がマージ後に切り替え済みの想定）をチェックアウトした状態にする。
reset_work_on_base() {
  rm -rf "$WORK"
  "${GIT_QUIET[@]}" clone --quiet "$ORIGIN" "$WORK"
}

run_case() {
  local label=$1 base=$2 head=$3 auto_delete=$4 cmd=$5
  local out
  total=$((total + 1))
  export GH_MOCK_BASE="$base" GH_MOCK_HEAD="$head" GH_MOCK_AUTO_DELETE="$auto_delete"
  out="$(jq -n --arg c "$cmd" --arg d "$WORK" '{tool_name: "Bash", cwd: $d, tool_input: {command: $c}}' | bash "$HOOK" 2>&1)"
  printf '%s\t%s\n' "$label" "$out"
}

assert() {
  local label=$1 condition=$2
  total=$((total + 1))
  if [[ "$condition" != "true" ]]; then
    failures=$((failures + 1))
    printf 'NG  %s\n' "$label"
  fi
}

# --- gh --repo 付きマージ後もローカルが head ブランチのままの場合、base 切替 + ローカルブランチ削除まで到達すること ---
reset_work_on_head
out="$(run_case "gh pr merge --repo 付きの回帰確認" main feature-x true \
  'gh pr merge 1 --repo owner/repo --merge --delete-branch')"
current_after="$("${GIT_QUIET[@]}" -C "$WORK" branch --show-current)"
feature_exists="$("${GIT_QUIET[@]}" -C "$WORK" branch --list feature-x)"
[[ "$current_after" == "main" ]] && switched=true || switched=false
[[ -z "$feature_exists" ]] && deleted=true || deleted=false
[[ "$out" == *"を削除しました"* ]] && messaged=true || messaged=false
assert "base へ切り替わる" "$switched"
assert "head ブランチが削除される" "$deleted"
assert "削除完了メッセージが出る" "$messaged"

# --- --delete-branch なしでも auto_delete が有効なら base 切替 + 削除まで到達すること（従来経路の保護） ---
reset_work_on_head
out="$(run_case "delete-branch フラグなし" main feature-x true 'gh pr merge 1 --merge')"
current_after="$("${GIT_QUIET[@]}" -C "$WORK" branch --show-current)"
feature_exists="$("${GIT_QUIET[@]}" -C "$WORK" branch --list feature-x)"
[[ "$current_after" == "main" && -z "$feature_exists" ]] && ok=true || ok=false
assert "delete-branch フラグなしでも base 切替 + 削除される" "$ok"

# --- gh が既に base へ切り替え済みで pull が遅れている場合、追いつき処理をして終わる（後続の auto_delete ブロックには進まない） ---
reset_work_on_base
printf 'more\n' >>"$SEED/README.md"
"${GIT_QUIET[@]}" -C "$SEED" commit --quiet -am "追加コミット"
"${GIT_QUIET[@]}" -C "$SEED" push --quiet origin main
out="$(run_case "pull 遅れの追いつき" main feature-x true \
  'gh pr merge 1 --repo owner/repo --merge --delete-branch')"
[[ "$out" == *"追いつかせました"* ]] && caught_up=true || caught_up=false
assert "遅れた base に追いつくメッセージが出る" "$caught_up"
[[ "$out" != *"本体のチェックアウト"* ]] && no_main_note=true || no_main_note=false
assert "本体でマージしたときは本体同期の報告が付かない" "$no_main_note"

# --- ワークツリーの中でマージした場合、本体（main worktree）の base も追いつくこと ---
MAIN="$TMP_ROOT/main-checkout"
WT="$TMP_ROOT/wt"
rm -rf "$MAIN" "$WT"
"${GIT_QUIET[@]}" clone --quiet "$ORIGIN" "$MAIN"
"${GIT_QUIET[@]}" -C "$MAIN" worktree add --quiet -b wt-feature "$WT" origin/feature-x
printf 'worktree\n' >>"$SEED/README.md"
"${GIT_QUIET[@]}" -C "$SEED" commit --quiet -am "本体を遅らせるコミット"
"${GIT_QUIET[@]}" -C "$SEED" push --quiet origin main
origin_main_sha="$("${GIT_QUIET[@]}" -C "$SEED" rev-parse main)"
WORK="$WT"
out="$(run_case "ワークツリーからのマージ" main wt-feature true \
  'gh pr merge 1 --repo owner/repo --merge --delete-branch')"
[[ "$("${GIT_QUIET[@]}" -C "$MAIN" rev-parse main)" == "$origin_main_sha" ]] && main_synced=true || main_synced=false
assert "本体の main が origin/main に追いついている" "$main_synced"
[[ "$out" == *"本体のチェックアウト"* ]] && main_messaged=true || main_messaged=false
assert "本体を同期した報告が出る" "$main_messaged"

# --- 本体が base 以外のブランチに居る場合、ref だけ更新されること ---
rm -rf "$MAIN" "$WT"
"${GIT_QUIET[@]}" clone --quiet "$ORIGIN" "$MAIN"
"${GIT_QUIET[@]}" -C "$MAIN" switch --quiet -c other-branch
"${GIT_QUIET[@]}" -C "$MAIN" worktree add --quiet -b wt-feature2 "$WT" origin/feature-x
printf 'worktree2\n' >>"$SEED/README.md"
"${GIT_QUIET[@]}" -C "$SEED" commit --quiet -am "本体をさらに遅らせるコミット"
"${GIT_QUIET[@]}" -C "$SEED" push --quiet origin main
origin_main_sha="$("${GIT_QUIET[@]}" -C "$SEED" rev-parse main)"
WORK="$WT"
out="$(run_case "本体が別ブランチのとき" main wt-feature2 false \
  'gh pr merge 1 --repo owner/repo --merge --delete-branch')"
[[ "$("${GIT_QUIET[@]}" -C "$MAIN" rev-parse main)" == "$origin_main_sha" ]] && ref_synced=true || ref_synced=false
assert "本体の main の ref が origin/main に追いついている" "$ref_synced"
[[ "$("${GIT_QUIET[@]}" -C "$MAIN" branch --show-current)" == "other-branch" ]] && stayed=true || stayed=false
assert "本体のチェックアウト先は変わらない" "$stayed"
[[ "$out" == *"ref だけ"* ]] && ref_messaged=true || ref_messaged=false
assert "ref だけ更新した報告が出る" "$ref_messaged"

setup_main_with_worktree() {
  local head=$1 remote_state=$2
  rm -rf "$MAIN" "$WT"
  "${GIT_QUIET[@]}" clone --quiet "$ORIGIN" "$MAIN"
  "${GIT_QUIET[@]}" -C "$MAIN" worktree add --quiet -b "$head" "$WT" origin/feature-x
  if [[ "$remote_state" == "alive" ]]; then
    "${GIT_QUIET[@]}" -C "$MAIN" push --quiet origin "$head"
  fi
}

# --- 本体でマージしたとき、head ブランチのワークツリーが畳まれること ---
setup_main_with_worktree merged-clean gone
WORK="$MAIN"
out="$(run_case "本体でマージしてワークツリーを畳む" main merged-clean true \
  'gh pr merge 1 --repo owner/repo --merge --delete-branch')"
[[ ! -d "$WT" ]] && folded=true || folded=false
assert "マージ済みブランチのワークツリーが畳まれる" "$folded"
[[ "$out" == *"を畳みました"* ]] && fold_messaged=true || fold_messaged=false
assert "畳んだ報告が出る" "$fold_messaged"

# --- 止めてはいけない例: 未コミットの変更が残っているワークツリー ---
setup_main_with_worktree merged-dirty gone
printf 'wip\n' >"$WT/wip.txt"
WORK="$MAIN"
out="$(run_case "未コミットの変更が残るワークツリー" main merged-dirty true \
  'gh pr merge 1 --repo owner/repo --merge --delete-branch')"
[[ -d "$WT" ]] && kept=true || kept=false
assert "未コミットの変更があるワークツリーは畳まれない" "$kept"
[[ "$out" == *"未コミットの変更が残っている"* ]] && kept_messaged=true || kept_messaged=false
assert "畳まなかった理由が出る" "$kept_messaged"

# --- 止めてはいけない例: リモートのブランチがまだ生きているワークツリー ---
setup_main_with_worktree merged-alive alive
WORK="$MAIN"
out="$(run_case "リモートに残るブランチのワークツリー" main merged-alive false \
  'gh pr merge 1 --repo owner/repo --merge')"
[[ -d "$WT" ]] && alive_kept=true || alive_kept=false
assert "リモートに残るブランチのワークツリーは畳まれない" "$alive_kept"
[[ "$out" != *"を畳みました"* ]] && no_fold_note=true || no_fold_note=false
assert "リモートに残るブランチでは畳んだ報告が出ない" "$no_fold_note"

# --- 止めてはいけない例: ワークツリーの中でマージしたとき、本体のチェックアウトは畳まない ---
setup_main_with_worktree merged-from-wt gone
WORK="$WT"
out="$(run_case "ワークツリーの中でマージ" main merged-from-wt true \
  'gh pr merge 1 --repo owner/repo --merge --delete-branch')"
[[ -d "$MAIN" && -d "$WT" ]] && both_kept=true || both_kept=false
assert "ワークツリーの中でマージしても本体もワークツリーも消えない" "$both_kept"
[[ "$out" != *"を畳みました"* ]] && wt_no_fold=true || wt_no_fold=false
assert "ワークツリーの中でマージしたときは畳んだ報告が出ない" "$wt_no_fold"

if [[ "$failures" -gt 0 ]]; then
  printf '\nsync-branch-after-pr-merge: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'sync-branch-after-pr-merge: %d 件すべて期待どおり\n' "$total"
