#!/bin/zsh
# 核心十套同时跑（最长的先开，约 1.5 分钟）；默认 Claude 主流程 + DeepSeek 整套。
# 用自己的 App 副本和会话清单，跑完自动清掉这次的测试会话（不必再跑 clean.sh）。
# tools/uitest/all.sh [claude|gpt|gemini ...]；参数替换主流程 CLI，DeepSeek 始终单独跑。
# JSON 见 build/uitest-results，失败退出非零，模型没照做的段落单列。
set -euo pipefail
HERE="${0:A:h}"
exec python3 "$HERE/all.py" "$@"
