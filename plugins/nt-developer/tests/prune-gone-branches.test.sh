#!/usr/bin/env bash

set -uo pipefail

HOOK="$(cd "${BASH_SOURCE[0]%/*}/../hooks" && pwd)/prune-gone-branches.sh"
[[ -f "$HOOK" ]] || { echo "prune-gone-branches.sh が見つかりません: $HOOK"; exit 1; }

failures=0
total=0

check() {
  local label=$1 expected=$2 actual=$3
  total=$((total + 1))
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    printf 'NG  期待=%-8s 実際=%-8s %s\n' "$expected" "$actual" "$label"
  fi
}

# origin 側で削除済みのブランチ（upstream が gone）を持つ作業リポジトリを組み立てる。
# branch_in_worktree に渡した名前のブランチだけ worktree でチェックアウトした状態にする（git branch -vv の行頭が `+` になる）。
# 第3引数に skip-prune を渡すと、origin 側の削除をローカルへ反映しないまま返す（リモート追跡ブランチが残った状態）。
setup_repo() {
  local root=$1 branch_in_worktree=${2:-} prune_mode=${3:-}
  local origin="$root/origin.git" work="$root/work"

  git init --quiet --bare "$origin"
  git clone --quiet "$origin" "$work" 2>/dev/null
  git -C "$work" config user.email test@example.com
  git -C "$work" config user.name test
  git -C "$work" commit --quiet --allow-empty -m init
  git -C "$work" branch -M main
  git -C "$work" push --quiet -u origin main 2>/dev/null

  local branch
  for branch in gone-plain gone-worktree; do
    git -C "$work" branch "$branch" main
    git -C "$work" push --quiet -u origin "$branch" 2>/dev/null
  done
  git -C "$work" branch keep-alive main
  git -C "$work" push --quiet -u origin keep-alive 2>/dev/null

  if [[ -n "$branch_in_worktree" ]]; then
    git -C "$work" worktree add --quiet "$root/wt" "$branch_in_worktree" 2>/dev/null
  fi

  local head
  head=$(git -C "$work" rev-parse main)
  git -C "$work" push --quiet origin --delete gone-plain gone-worktree 2>/dev/null
  # push --delete はローカルのリモート追跡ブランチも一緒に消す。他所で削除された状況を再現するため復元する。
  if [[ "$prune_mode" == "skip-prune" ]]; then
    git -C "$work" update-ref refs/remotes/origin/gone-plain "$head"
    git -C "$work" update-ref refs/remotes/origin/gone-worktree "$head"
    return 0
  fi
  git -C "$work" fetch --quiet origin --prune 2>/dev/null
}

gone_count() {
  git -C "$1" branch -vv 2>/dev/null | grep -c ': gone]' || true
}

# managed に渡した値が `orca worktree show` の "ok" になる。本物の rm はブランチも消すので stub も両方畳む。
write_orca_stub() {
  local path=$1 managed=$2
  cat >"$path" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$ORCA_STUB_LOG"
target=\${4#path:}
case "\$2" in
  show)
    printf '{"ok": $managed}\n'
    ;;
  rm)
    branch="\$(git -C "\$target" symbolic-ref --quiet --short HEAD 2>/dev/null)"
    git -C "\$ORCA_STUB_REPO" worktree remove --force "\$target" >/dev/null 2>&1
    [ -n "\$branch" ] && git -C "\$ORCA_STUB_REPO" branch -D "\$branch" >/dev/null 2>&1
    printf '{"ok": true}\n'
    ;;
esac
EOS
  chmod +x "$path"
}

branches_of() {
  git -C "$1" for-each-ref --format='%(refname:short)' refs/heads | sort | tr '\n' ' '
}

# --- Orca 管理下のワークツリー: orca worktree rm で畳むこと ---
root="$(mktemp -d)"
setup_repo "$root" gone-worktree
write_orca_stub "$root/orca" true
export ORCA_STUB_LOG="$root/orca.log" ORCA_STUB_REPO="$root/work"
: >"$ORCA_STUB_LOG"
out="$(cd "$root/work" && ORCA_BIN="$root/orca" bash "$HOOK" 2>&1)"
log="$(cat "$ORCA_STUB_LOG")"

check "Orca 経路で orca worktree rm が呼ばれる" "called" \
  "$(grep -q 'worktree rm' <<<"$log" && echo called || echo missing)"
check "Orca 経路でワークツリーが畳まれる" "absent" "$([[ -d "$root/wt" ]] && echo present || echo absent)"
check "Orca 経路で gone ブランチが削除される" "keep-alive main " "$(branches_of "$root/work")"
check "Orca 経路で手動確認の警告が出ない" "clean" "$(grep -q '手動確認' <<<"$out" && echo dirty || echo clean)"
unset ORCA_STUB_LOG ORCA_STUB_REPO
rm -rf "$root"

# --- orca はあるが Orca 管理外のワークツリー: git worktree remove へフォールバックすること ---
root="$(mktemp -d)"
setup_repo "$root" gone-worktree
write_orca_stub "$root/orca" false
export ORCA_STUB_LOG="$root/orca.log" ORCA_STUB_REPO="$root/work"
: >"$ORCA_STUB_LOG"
out="$(cd "$root/work" && ORCA_BIN="$root/orca" bash "$HOOK" 2>&1)"
log="$(cat "$ORCA_STUB_LOG")"

check "管理外なら orca worktree rm を呼ばない" "missing" \
  "$(grep -q 'worktree rm' <<<"$log" && echo called || echo missing)"
check "管理外でもワークツリーが畳まれる" "absent" "$([[ -d "$root/wt" ]] && echo present || echo absent)"
check "管理外でも gone ブランチが削除される" "keep-alive main " "$(branches_of "$root/work")"
check "管理外でも手動確認の警告が出ない" "clean" "$(grep -q '手動確認' <<<"$out" && echo dirty || echo clean)"
unset ORCA_STUB_LOG ORCA_STUB_REPO
rm -rf "$root"

# --- orca が PATH に無い環境: 従来どおり git worktree remove で畳めること ---
root="$(mktemp -d)"
setup_repo "$root" gone-worktree
out="$(cd "$root/work" && ORCA_BIN="$root/orca-not-installed" bash "$HOOK" 2>&1)"

check "orca 不在でワークツリーが畳まれる" "absent" "$([[ -d "$root/wt" ]] && echo present || echo absent)"
check "orca 不在で gone ブランチが削除される" "keep-alive main " "$(branches_of "$root/work")"
check "orca 不在で手動確認の警告が出ない" "clean" "$(grep -q '手動確認' <<<"$out" && echo dirty || echo clean)"
rm -rf "$root"

# --- worktree 無しの gone ブランチ: 従来どおり畳めること ---
root="$(mktemp -d)"
setup_repo "$root"
out="$(cd "$root/work" && ORCA_BIN="$root/orca-not-installed" bash "$HOOK" 2>&1)"

check "worktree 無しの gone ブランチが削除される" "keep-alive main " "$(branches_of "$root/work")"
check "手動確認の警告が出ない（worktree 無し）" "clean" "$(grep -q '手動確認' <<<"$out" && echo dirty || echo clean)"
rm -rf "$root"

# --- 止めてはいけない例: 本体の作業ツリーは orca worktree rm に渡さない ---
root="$(mktemp -d)"
setup_repo "$root"
git -C "$root/work" switch --quiet gone-plain
write_orca_stub "$root/orca" true
export ORCA_STUB_LOG="$root/orca.log" ORCA_STUB_REPO="$root/work"
: >"$ORCA_STUB_LOG"
(cd "$root/work" && ORCA_BIN="$root/orca" bash "$HOOK" >/dev/null 2>&1)
log="$(cat "$ORCA_STUB_LOG")"

check "本体の作業ツリーで orca worktree rm を呼ばない" "missing" \
  "$(grep -q 'worktree rm' <<<"$log" && echo called || echo missing)"
check "本体の作業ツリーが消えない" "present" "$([[ -d "$root/work" ]] && echo present || echo absent)"
unset ORCA_STUB_LOG ORCA_STUB_REPO
rm -rf "$root"

# --- 止めてはいけない例: gone でないブランチは消さない ---
root="$(mktemp -d)"
setup_repo "$root" gone-worktree
write_orca_stub "$root/orca" true
export ORCA_STUB_LOG="$root/orca.log" ORCA_STUB_REPO="$root/work"
: >"$ORCA_STUB_LOG"
(cd "$root/work" && ORCA_BIN="$root/orca" bash "$HOOK" >/dev/null 2>&1)
check "リモートに残るブランチは削除されない" "present" \
  "$(git -C "$root/work" show-ref --verify --quiet refs/heads/keep-alive && echo present || echo absent)"
check "main は削除されない" "present" \
  "$(git -C "$root/work" show-ref --verify --quiet refs/heads/main && echo present || echo absent)"
unset ORCA_STUB_LOG ORCA_STUB_REPO
rm -rf "$root"

# --- 止めてはいけない例: 未コミットの変更が残っているワークツリーは畳まない ---
root="$(mktemp -d)"
setup_repo "$root" gone-worktree
printf 'wip\n' >"$root/wt/wip.txt"
write_orca_stub "$root/orca" true
export ORCA_STUB_LOG="$root/orca.log" ORCA_STUB_REPO="$root/work"
: >"$ORCA_STUB_LOG"
out="$(cd "$root/work" && ORCA_BIN="$root/orca" bash "$HOOK" 2>&1)"
log="$(cat "$ORCA_STUB_LOG")"

check "未コミットの変更があると orca worktree rm を呼ばない" "missing" \
  "$(grep -q 'worktree rm' <<<"$log" && echo called || echo missing)"
check "未コミットの変更があるワークツリーは畳まれない" "present" \
  "$([[ -d "$root/wt" ]] && echo present || echo absent)"
check "未コミットの変更があるとブランチも残る" "present" \
  "$(git -C "$root/work" show-ref --verify --quiet refs/heads/gone-worktree && echo present || echo absent)"
check "畳まなかったことを報告する" "reported" \
  "$(grep -q '未コミットの変更が残っている' <<<"$out" && echo reported || echo silent)"
unset ORCA_STUB_LOG ORCA_STUB_REPO
rm -rf "$root"

# --- リモート追跡ブランチが残ったまま: hook 自身の fetch --prune で畳めること ---
root="$(mktemp -d)"
setup_repo "$root" gone-worktree skip-prune
write_orca_stub "$root/orca" true
export ORCA_STUB_LOG="$root/orca.log" ORCA_STUB_REPO="$root/work"
: >"$ORCA_STUB_LOG"

check "hook 実行前は gone が立っていない" "0" "$(gone_count "$root/work")"

out="$(cd "$root/work" && ORCA_BIN="$root/orca" bash "$HOOK" 2>&1)"

check "prune 前でもワークツリーが畳まれる" "absent" "$([[ -d "$root/wt" ]] && echo present || echo absent)"
check "prune 前でも gone ブランチが削除される" "keep-alive main " "$(branches_of "$root/work")"
check "prune 前でも手動確認の警告が出ない" "clean" "$(grep -q '手動確認' <<<"$out" && echo dirty || echo clean)"
unset ORCA_STUB_LOG ORCA_STUB_REPO
rm -rf "$root"

# --- 止めてはいけない例: リモート追跡ブランチが残っていてもリモートに在るブランチは消さない ---
root="$(mktemp -d)"
setup_repo "$root" keep-alive skip-prune
out="$(cd "$root/work" && ORCA_BIN="$root/orca-not-installed" bash "$HOOK" 2>&1)"

check "prune 前でもリモートに残るブランチは削除されない" "present" \
  "$(git -C "$root/work" show-ref --verify --quiet refs/heads/keep-alive && echo present || echo absent)"
check "prune 前でもリモートに残るブランチの作業ツリーは畳まれない" "present" \
  "$([[ -d "$root/wt" ]] && echo present || echo absent)"
check "prune 前でも本体の作業ツリーが消えない" "present" "$([[ -d "$root/work" ]] && echo present || echo absent)"
rm -rf "$root"

# --- 止めてはいけない例: remote が1つも無いリポジトリで素通しすること ---
root="$(mktemp -d)"
git init --quiet "$root/solo"
git -C "$root/solo" config user.email test@example.com
git -C "$root/solo" config user.name test
git -C "$root/solo" commit --quiet --allow-empty -m init
git -C "$root/solo" branch -M main
git -C "$root/solo" branch feature main
out="$(cd "$root/solo" && ORCA_BIN="$root/orca-not-installed" bash "$HOOK" 2>&1)"
status=$?

check "remote 無しで異常終了しない" "0" "$status"
check "remote 無しでブランチが消えない" "feature main " "$(branches_of "$root/solo")"
check "remote 無しで何も出力しない" "" "$out"
rm -rf "$root"

if [[ "$failures" -gt 0 ]]; then
  printf '\nprune-gone-branches: %d/%d 件が期待と違いました\n' "$failures" "$total"
  exit 1
fi
printf 'prune-gone-branches: %d 件すべて期待どおり\n' "$total"
