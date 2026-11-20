#!/bin/zsh
# 离线测试：不需要任何 CLI、会话记录或网络。改了解析器、Markdown 渲染或前端脚本之后跑一遍。
#   tools/test.sh                 全部（提交前跑这个），约 45 秒
#   tools/test.sh --only 词1,词2   只编译并跑名字含这些词的离线测试组（改代码调试时用；组名见 tools/tests/offline.swift）
#     它只筛「离线主体」；下面其余几步不在组表里，编译过一次后各自单跑：build/selftest preview-fixes git|browser|docs、
#     build/selftest preview-bridge、python3 tools/test-deepseek.py <模式>…（模式名见该文件开头）、python3 tools/test-suspend.py、node tools/test-*.mjs
# 需要真实 CLI 和会话的测试（历史列表、提问、停止、文档预览等）见 tools/tests/selftest.swift 开头的用法。
#
# 各步之间没有共享状态（临时目录带 UUID / pid，端口由系统分配，WebKit 不落盘），所以编译完同时跑；
# 离线主体再按组拆成 OFFLINE_SHARDS 份。每步的输出写进自己的日志，最后逐个 wait 汇总，失败的那几步把日志打出来。
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
typeset -A pids names
step() {   # step 名字 命令…：后台跑，输出进 $LOG/名字.log
  local name=$1; shift
  ( "$@" ) > "$LOG/$name.log" 2>&1 &
  local pid=$!   # 先取到普通变量里：直接写 pids[$name]=$! 时 zsh 存进去的是字面上的「$!」
  pids[$name]=$pid
}

# 编译到临时名再换上：另一个 test.sh / clean.sh 同时在用 build/selftest 时不会执行到写了一半的程序
compile() {
  local tmp="build/selftest.$$"
  swiftc -D HUB_SELFTEST -j "$(sysctl -n hw.ncpu)" Sources/**/*.swift tools/tests/*.swift -o "$tmp" -framework Cocoa -framework WebKit -lsqlite3 \
    && mv -f "$tmp" build/selftest
}

if [[ ${1:-} == --only ]]; then
  [[ -n ${2:-} ]] || { echo "用法：tools/test.sh --only 词1,词2"; exit 2; }
  echo "编译自测程序…"
  compile || exit 1
  AIPETHUB_OFFLINE_ONLY=$2 build/selftest offline
  exit $?
fi
# --only 走不到最后的 rm，所以日志目录在它之后才建，免得每次在 $TMPDIR 留一个空目录
LOG=$(mktemp -d "${TMPDIR:-/tmp}/aipethub-test.XXXXXX")
# 份数不超过核数：CI 的 macOS 机器只有 3 核，8 份再加上同时跑的预览、DeepSeek、前端几步会把机器压满，
# 带时限的用例（打开历史 15 秒、桥消息补发等）每次随机挑一条超时；本机核多，仍是 8 份
CORES=$(sysctl -n hw.ncpu)
SHARDS=${OFFLINE_SHARDS:-$(( CORES < 8 ? CORES : 8 ))}

if command -v node >/dev/null; then
  frontend() {
    for f in web/js/**/*.js; do node --check $f || return 1; done
    echo "前端脚本语法：都没问题"
    node tools/test-markdown.mjs && node tools/test-logic.mjs && node tools/test-frontend-modules.mjs && node tools/test-session-logic.mjs
  }
  step 前端脚本 frontend
else
  echo "没有 node，跳过前端脚本和 Markdown 的测试。"
fi

echo "编译自测程序…"
start=$SECONDS
compile || exit 1
echo "  编译 $((SECONDS - start)) 秒；开始并行测试（离线主体 $SHARDS 份）…"
for i in {0..$((SHARDS - 1))}; do step "离线主体-$i" env AIPETHUB_OFFLINE_SHARD=$i/$SHARDS build/selftest offline; done
step 预览和网页桥 build/selftest preview-bridge
step 暂停恢复 python3 tools/test-suspend.py
step DeepSeek生命周期 python3 tools/test-deepseek.py
step 预览和归因-git build/selftest preview-fixes git
step 预览和归因-浏览器 build/selftest preview-fixes browser
step 预览和归因-文档 build/selftest preview-fixes docs
# 全局带 LFS 过滤器只影响 git 命令，所以只重跑 git 段
step 预览和归因-git-GitLFS env GIT_CONFIG_GLOBAL="$PWD/tools/fixtures/gitconfig-lfs" build/selftest preview-fixes git

failed=()
for name in ${(ko)pids}; do
  wait ${pids[$name]} || failed+=($name)
done
for name in ${(ko)pids}; do
  if (( ${failed[(Ie)$name]} )); then echo "✗ $name"; else echo "✓ $name：$(tail -1 "$LOG/$name.log")"; fi
done
echo "总用时 $((SECONDS)) 秒"
if (( ${#failed} )); then
  for name in $failed; do echo "\n===== $name 的输出 ====="; cat "$LOG/$name.log"; done
  echo "\n${#failed} 步没通过；完整日志在 $LOG"
  exit 1
fi
rm -rf "$LOG"
echo "全部通过"
