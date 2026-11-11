#!/bin/zsh
# 截 README 用的界面图（docs/images/screenshot.png）：在一个空的主目录里起 App，只显示演示数据，不会截到本机的会话。
set -euo pipefail
HERE="${0:A:h}"
H=$(mktemp -d -t aipethub-shot); H=${H:A}
OUTDIR=$(env -i HOME="$H" CFFIXED_USER_HOME="$H" USER="$USER" SHELL=/bin/zsh TMPDIR="$TMPDIR" LANG=zh_CN.UTF-8 PATH=/usr/bin:/bin \
  REAL=1 "$HERE/run.sh" claude shot-readme.js haiku 60 | sed -n 's/^截图和结果在 //p')
cp "$OUTDIR/readme.png" "$HERE/../../../docs/images/screenshot.png"
echo "已更新 docs/images/screenshot.png"
