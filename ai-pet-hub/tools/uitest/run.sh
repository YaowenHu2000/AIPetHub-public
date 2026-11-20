#!/bin/zsh
# 真实窗口核心测试。先 ./build.sh（不安装），再：
#   tools/uitest/run.sh <claude|gpt|gemini|deepseek> <脚本.js> [模型] [最长秒数]
# 不用 CLI：e2e-frontend-modules（输入/独立模块）、e2e-session-sync（同步/身份/队列）、
#           e2e-ui（运行标记/文件链接/舞台/面板/原生按钮；自动 REAL=1）。
# 真实 CLI：e2e-live（审批/改动/补充）、e2e-input-history（输入/历史/搜索/模型用量/分叉）、
#           e2e-images-stop（图片/带图补充/停止后同步）、e2e-compact（上下文与压缩）、
#           e2e-lifecycle（冷/热/大图/停止/子进程/辅助超时/退出）、
#           e2e-browser（内置浏览器工具开关/打开/执行/截图）、e2e-deepseek（整套）。
# 不花模型额度的退出回归：python3 tools/uitest/lifecycle.py --exit-only（只跑自动退出和 SIGTERM 两段，辅助 CLI 是假的）。
# all.sh 默认 Claude、Codex、Gemini 各跑六套真实 CLI 的套件，加 DeepSeek 整套、不用 CLI 的三套和四位的 e2e-stream，最多 10 套同时跑；
# all.sh claude 只换跑真实 CLI 套件的那几位，其余照跑。
# 测试模型都用最便宜的（DEF），思考强度由各套设成 low。
# stdout 是断言计算出的 JSON；失败退出 1，模型没照做单列 skips；产物路径在 artifactDir。
# 每次使用独立临时工作空间；仅跟踪和清理自己启动的 PID。clean.sh 清测试会话。
# AIPETHUB_TEST_APP 可指向构建产物副本，供反向验证，不会修改仓库前端。
set -euo pipefail
HERE="${0:A:h}"
A=${1:-claude}; SCRIPT=${2:-e2e-live.js}
typeset -A DEF=(claude haiku gpt gpt-6-luna gemini gemini-3.8-flash deepseek deepseek-v4-flash)
[[ -n ${DEF[$A]:-} && -f "$HERE/$SCRIPT" ]] || { print -u2 '未知 CLI 或脚本'; exit 2; }
MODEL=${3:-$DEF[$A]}
# 560 秒总上限要大于 until 的统一上限（UITEST_WAIT，默认 240 秒）加最慢一套的正常耗时：某条等不到时，先由那一条报出名字，而不是整套超时
if [[ "$SCRIPT" == e2e-lifecycle.js && -z ${UITEST_LIFECYCLE_PHASE:-} ]]; then
  exec python3 "$HERE/lifecycle.py" "$A" "$MODEL" "${4:-560}"
fi
[[ "$SCRIPT" == e2e-ui.js ]] && export REAL=${REAL:-1}
exec python3 "$HERE/run-suite.py" "$A" "$SCRIPT" "$MODEL" "${4:-560}"
