#!/bin/zsh
# 用标准的 claude（不是 reclaude）测「会话在别处开着时另开分支」：
#   先在临时目录里起一个一直开着的 claude 会话 A（模拟终端里开着的那个），再让 AIPetHub 往 A 里发话，应该分叉；
#   然后把 A 关掉再发一次，应该接着 A 聊、不分叉。
set -euo pipefail
HERE="${0:A:h}"; CLAUDE=${AIPETHUB_CLAUDE:-$HOME/.local/bin/claude}
T=$(mktemp -d -t aipethub-forkplain); T=${T:A}
cd "$T"
( printf '%s\n' '{"type":"user","message":{"role":"user","content":"只回复：甲"}}'; sleep 600 ) \
  | "$CLAUDE" -p --model haiku --input-format stream-json --output-format stream-json --verbose > "$T/live.log" 2>&1 &
for i in {1..60}; do A=$(grep -o "\"session_id\":\"[^\"]*\"" "$T/live.log" 2>/dev/null | head -1 | cut -d\" -f4 || true); [[ -n $A ]] && break; sleep 1; done
[[ -n ${A:-} ]] || { echo "起不来会话 A"; exit 1; }
for i in {1..30}; do grep -q '"type":"result"' "$T/live.log" && break; sleep 1; done
echo "会话 A：$A（$T）"
echo "$T" >> "$HERE/../../build/uitest-dirs.txt"   # clean.sh 按它清
cd "$HERE/../.."
for EXPECT in fork nofork; do
  if [[ $EXPECT == nofork ]]; then pkill -f "$CLAUDE -p --model haiku --input-format stream-json" || true; sleep 6; fi
  sed "s/__SID__/$A/; s/__EXPECT__/$EXPECT/" "$HERE/e2e-fork.js" > "$HERE/_fork_run.js"
  AIPETHUB_CLAUDE="$CLAUDE" "$HERE/run.sh" claude _fork_run.js haiku 240 | grep -E '✓|✗|"ok"|error' || true
done
rm -f "$HERE/_fork_run.js"
echo "测试会话在 $T，用 tools/uitest/clean.sh 清"
