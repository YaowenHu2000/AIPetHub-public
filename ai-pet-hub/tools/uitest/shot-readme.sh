#!/bin/zsh
# 截 README 用的界面图（docs/images/screenshot.png）：在一个空的主目录里起 App，只显示演示数据，不会截到本机的会话。
set -euo pipefail
HERE="${0:A:h}"
H=$(mktemp -d -t aipethub-shot); H=${H:A}
# 产物目录自己指定：run.sh 只输出结果 JSON，不再打印产物路径；演示会话只在空主目录里，不用记进 clean.sh 的清单
OUT=$(mktemp -d -t aipethub-shot-out); OUT=${OUT:A}
trap 'rm -rf "$H" "$OUT"' EXIT
env -i HOME="$H" CFFIXED_USER_HOME="$H" USER="$USER" SHELL=/bin/zsh TMPDIR="$TMPDIR" LANG=zh_CN.UTF-8 PATH=/usr/bin:/bin \
  UITEST_ARTIFACT_DIR="$OUT" UITEST_DIRS_FILE="$OUT/dirs.txt" REAL=1 "$HERE/run.sh" claude shot-readme.js haiku 60 > "$OUT/result.json" \
  || { cat "$OUT/result.json"; exit 1; }
cp "$OUT/readme.png" "$HERE/../../../docs/images/screenshot.png"
echo "已更新 docs/images/screenshot.png"
