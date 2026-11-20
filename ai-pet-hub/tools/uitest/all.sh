#!/bin/zsh
# 默认 Claude、Codex、Gemini 各跑六套真实 CLI 套件，加 DeepSeek 整套、不用 CLI 的三套、四位的 e2e-stream（假 CLI），共 26 套；
# 最多 10 套同时跑、最长的先开（为什么限 10 见 all.py），总时长约等于最慢的一套加排队。
# 用自己的 App 副本和会话清单，跑完自动清掉这次的测试会话（不必再跑 clean.sh）。
# tools/uitest/all.sh [claude|gpt|gemini ...]；参数只换跑真实 CLI 套件的那几位，DeepSeek、不用 CLI 的三套和四份 e2e-stream 始终跑。
# JSON 见 build/uitest-results，失败退出非零，模型没照做的段落单列。
set -euo pipefail
HERE="${0:A:h}"
exec python3 "$HERE/all.py" "$@"
