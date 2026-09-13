#!/usr/bin/env python3
# 同一ファイルへの操作が、直近のセッション内で繰り返し拒否(is_error)されている場合、他の hook の deny/allow 判定には一切介入せず、allow + reason で「同じ理由で繰り返し弾かれている」ことを横断的に警告する。
import json
import os
import sys

THRESHOLD_HITS = 2  # 過去2回、同一ファイルへの操作が失敗していたら(今回で3回目)警告


def extract_path_candidates(cmd):
    candidates = set()
    for word in cmd.split():
        word = word.strip("'\"")
        if "://" in word or "?" in word or "&" in word:
            continue
        if "/" in word and not word.startswith("-"):
            candidates.add(os.path.basename(word))
    return candidates


try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)

if not isinstance(data, dict):
    sys.exit(0)

if data.get("tool_name") != "Bash":
    sys.exit(0)

command = (data.get("tool_input") or {}).get("command") or ""
if not command:
    sys.exit(0)

target_paths = extract_path_candidates(command)
if not target_paths:
    sys.exit(0)

transcript_path = data.get("transcript_path") or ""
if not transcript_path or not os.path.isfile(transcript_path):
    sys.exit(0)

tool_uses = {}
results = {}

# transcript は会話が進むほど肥大化する(数十MBに達することもある)。毎回の Bash 呼び出しのたびに全文を読むと呼び出しごとの遅延が蓄積するため、末尾の一定量だけを見る。
TAIL_BYTES = 300 * 1024

try:
    size = os.path.getsize(transcript_path)
    with open(transcript_path, "rb") as f:
        if size > TAIL_BYTES:
            f.seek(size - TAIL_BYTES)
        raw = f.read()
except OSError:
    sys.exit(0)

for line in raw.decode("utf-8", errors="ignore").splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        continue
    t = obj.get("type")
    if t == "assistant":
        msg = obj.get("message") or {}
        for c in msg.get("content") or []:
            if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == "Bash":
                cid = c.get("id")
                cmd = (c.get("input") or {}).get("command") or ""
                if cid:
                    tool_uses[cid] = cmd
    elif t == "user":
        msg = obj.get("message") or {}
        content = msg.get("content")
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") == "tool_result":
                    tuid = c.get("tool_use_id")
                    if tuid:
                        results[tuid] = bool(c.get("is_error"))

history = [(cmd, results[cid]) for cid, cmd in tool_uses.items() if cid in results]

hits = sum(
    1
    for cmd, is_error in history
    if is_error and extract_path_candidates(cmd) & target_paths
)

if hits >= THRESHOLD_HITS:
    reason = (
        f"同じファイルへの操作が直近で{hits}回拒否されています。"
        "書き方を変えて再試行する前に、直前の拒否理由を読んで対処方法を変えるか、"
        "解決できないならユーザーに判断を仰いでください。"
    )
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": reason,
        },
        "systemMessage": reason,
    }))
    sys.exit(0)

sys.exit(0)
