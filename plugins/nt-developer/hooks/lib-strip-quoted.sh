#!/usr/bin/env bash
# コマンド文字列から「クォートで囲まれた中身」を落とす処理。
#
# `grep 'git commit' file` のように語が文字列として現れただけの読み取り専用コマンドを止めないため、実行される部分だけを判定に載せる。
#
# **sed の置換（`s/'[^']*'/''/g; s/"[^"]*"/""/g`）で代用するな。** クォートの種類ごとに別々に処理するため入れ子で境界がずれる。次の形では 'msg' が先に消え、続くダブルクォートのペアを取り違えて `&& git commit` がむき出しで残り、コミットしない実行が誤検出される:
#
#   echo "1) 結果: $(req "git add x && git commit -m 'msg'")"
#
# バックスラッシュのエスケープとバッククォートのコマンド置換は扱わない。

# 標準出力へ、クォートの中身を落とした文字列を返す（末尾に改行は付けない）。
# クォート記号そのもの・コマンド置換の `$(` と `)` は位置を保つために残す。
strip_quoted() {
  printf '%s' "$1" | awk '
    # 入力全体を1レコードとして読む（改行もそのまま中身に含める）
    BEGIN { RS = "\001"; ORS = "" }
    {
      s = $0
      n = length(s)
      out = ""
      top = 0
      stack[0] = "bare"
      i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        nx = (i < n) ? substr(s, i + 1, 1) : ""
        st = stack[top]

        if (st == "single") {
          # シングルクォートの中では何も特別扱いしない
          if (c == "\047") { top--; out = out c }
          i++
          continue
        }

        if (st == "double") {
          if (c == "\"") { top--; out = out c; i++; continue }
          # ダブルクォートの中でもコマンド置換は展開される
          if (c == "$" && nx == "(") { top++; stack[top] = "cmdsub"; out = out "$("; i += 2; continue }
          i++
          continue
        }

        # クォートの外（bare / cmdsub）
        if (c == "\047") { top++; stack[top] = "single"; out = out c; i++; continue }
        if (c == "\"") { top++; stack[top] = "double"; out = out c; i++; continue }
        if (c == "$" && nx == "(") { top++; stack[top] = "cmdsub"; out = out "$("; i += 2; continue }
        if (c == ")" && st == "cmdsub") { top--; out = out c; i++; continue }
        out = out c
        i++
      }
      print out
    }
  '
}
