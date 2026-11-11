#!/bin/zsh
# 离线测试：不需要任何 CLI、会话记录或网络，几十秒跑完。改了解析器、Markdown 渲染或前端脚本之后跑一遍。
#   tools/test.sh
# 需要真实 CLI 和会话的测试（历史列表、提问、停止、文档预览等）见 tools/selftest.swift 开头的用法。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

echo "编译自测程序…"
swiftc -D HUB_SELFTEST Sources/**/*.swift tools/selftest.swift tools/parsertest.swift tools/livetest.swift -o build/selftest \
  -framework Cocoa -framework WebKit -lsqlite3
echo "解析器："
build/selftest parsers

if command -v node >/dev/null; then
  echo "前端脚本语法："
  for f in web/js/**/*.js; do node --check $f; done
  echo "  都没问题"
  echo "Markdown 渲染："
  node tools/test-markdown.mjs
  echo "界面逻辑："
  node tools/test-logic.mjs
else
  echo "没有 node，跳过前端脚本和 Markdown 的测试。"
fi
