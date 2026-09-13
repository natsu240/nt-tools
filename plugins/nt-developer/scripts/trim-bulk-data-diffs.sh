#!/usr/bin/env bash
# git diff / gh pr diff の標準出力を標準入力から受け取り、マスタデータとみなせるファイルの差分本体を要約1行に差し替えて標準出力に流す固定フィルタ。
#
# .sql で DDL を含む行があるものを通しているのは、マイグレーション本体はレビュー対象だから。
set -u

awk '
function is_target_ext(fn) { return (fn ~ /\.(csv|tsv)$/) }
function is_sql_ext(fn) { return (fn ~ /\.sql$/) }

function has_ddl(   i, u) {
  for (i = 1; i <= nlines; i++) {
    if (buf[i] !~ /^[-+]/) continue
    if (buf[i] ~ /^(---|\+\+\+)/) continue
    u = toupper(buf[i])
    if (u ~ /(CREATE|ALTER|DROP|TRUNCATE|RENAME COLUMN|ADD COLUMN|MODIFY COLUMN|GRANT|REVOKE)/) return 1
  }
  return 0
}

function flush(   i, seen_hunk, added, removed) {
  if (nlines == 0) return
  if (fname != "" && (is_target_ext(fname) || (is_sql_ext(fname) && !has_ddl()))) {
    seen_hunk = 0; added = 0; removed = 0
    for (i = 1; i <= nlines; i++) {
      if (buf[i] ~ /^@@/) { seen_hunk = 1; continue }
      if (!seen_hunk) { print buf[i]; continue }
      if (buf[i] ~ /^\+/ && buf[i] !~ /^\+\+\+/) added++
      else if (buf[i] ~ /^-/ && buf[i] !~ /^---/) removed++
    }
    if (added > 0 || removed > 0) {
      print "（マスタデータファイルのため内容省略。追加 " added " 行 / 削除 " removed " 行）"
    } else {
      print "（マスタデータファイルのため内容省略）"
    }
  } else {
    for (i = 1; i <= nlines; i++) print buf[i]
  }
  delete buf
  nlines = 0
}

/^diff --git / {
  flush()
  fname = $0
  sub(/^diff --git a\//, "", fname)
  sub(/ b\/.*$/, "", fname)
}
{ nlines++; buf[nlines] = $0 }
END { flush() }
'
