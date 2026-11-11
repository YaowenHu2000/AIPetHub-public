#!/bin/zsh
# 真实窗口的端到端测试（要用真的 CLI，会花一点额度）。先 ./build.sh，再：
#   tools/uitest/run.sh <claude|gpt|gemini|deepseek> <e2e-live.js|e2e-browser.js> [模型] [最长秒数]
# e2e-live.js    来问→允许、查看全部改动、会话重读后改动卡片还在、拒绝（Claude、Codex）；最高权限下不来问、中途补充（Gemini 是排队）、停止
# e2e-stream.js  流式输出的节奏：正文多久变长一次、每次几个字
# e2e-jump.js    排着的话点「立即发送」插队：正在做的停下，这一句马上发
# e2e-more.js    图片附件、回答中改设置的提示、「再显示 300 条」、排着的多句话一句一句发、内置浏览器工具的开关
# e2e-models.js  模型菜单跟着 CLI 报上来的模型走，选新出现的模型能正常回答
# e2e-fast.js   fast 开关、fast 时桌宠的样子、模型菜单里的剩余用量（Claude 要用有 fast 档的模型：run.sh claude e2e-fast.js opus）
# measure.js    不用 CLI：量对齐——左栏图标列和文字列、同一行大小字的基线、三栏的底边、红绿灯那条线（数字写在 feel.css 的注释里）
# e2e-stage.js   不用 CLI：角色舞台（动作、散步、小憩、拖拽、说话）和预览面板（开文件、开网页）
# e2e-misc.js    ↑ 翻发过的话、/ 命令、@ 文件、消息上的「编辑」、搜索正文、同步时只追加不重画、停止后按钮可用
# e2e-browser.js 智能体用内置浏览器的工具打开测试页、点按钮、截图
# e2e-deepseek.js 第四位（DeepSeek，走 dsh 的本机服务）：添加、提问、续聊、命令和改文件的步骤、停止、历史、移除。这样跑：tools/uitest/run.sh deepseek e2e-deepseek.js
# e2e-chrome.js 真实窗口：红绿灯和顶栏对没对齐、顶栏上的按钮真的点不点得动、整窗截图。要这样跑：REAL=1 tools/uitest/run.sh claude e2e-chrome.js
#                （REAL=1：窗口照常画出来、放在桌面壁纸下面，能截到整个窗口、能发真实的点击；别的脚本不需要）
# 全部跑一遍：tools/uitest/all.sh；清掉测试留下的会话：tools/uitest/clean.sh
# 测试窗口完全透明、点不到，不挡屏幕。在临时目录里建一个 git 仓库当工作空间；结果（JSON）和几张界面截图也放在那里，跑完打印结果。
set -euo pipefail
HERE="${0:A:h}"; APP="$HERE/../../build/AIPetHub.app/Contents/MacOS/AIPetHub"
A=$1; SCRIPT=$2
typeset -A ASK=(claude manual gpt ask gemini default deepseek workspace-write) FULL=(claude bypassPermissions gpt danger-full-access gemini bypassPermissions deepseek danger-full-access) DEF=(claude haiku gpt gpt-6-astra gemini gemini-3.8-flash deepseek deepseek-v4-flash)
MODEL=${3:-$DEF[$A]}
DIR=$(mktemp -d -t aipethub-uitest); DIR=${DIR:A}
mkdir -p "$DIR/repo" && cp "$HERE/page.html" "$DIR/page.html"
echo "$DIR/repo" >> "$HERE/../../build/uitest-dirs.txt"   # 记下这次的工作空间，clean.sh 按它清掉测试留下的会话
# 一张纯红色的图片（测图片附件用）
python3 -c "
import zlib, struct, sys
w = h = 64; raw = b''.join(b'\\x00' + b'\\xff\\x00\\x00' * w for _ in range(h))
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[1], 'wb').write(b'\\x89PNG\\r\\n\\x1a\\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))
" "$DIR/red.png"
( cd "$DIR/repo" && git init -q && echo hello > keep.txt && git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm init )
{ echo "const REPO='$DIR/repo', DIR='$DIR', PAGE='$DIR/page.html', AGENT='$A', MODEL='$MODEL', ASK_PERM='$ASK[$A]', FULL_PERM='$FULL[$A]';"; cat "$HERE/prelude.js" "$HERE/$SCRIPT"; } > "$DIR/run.js"
AIPETHUB_UITEST_REAL=${REAL:-} "$APP" --uitest "$DIR/run.js" "$DIR/result.json" >"$DIR/app.log" 2>&1 &
PID=$!
for i in {1..${4:-560}}; do [[ -s "$DIR/result.json" ]] && break; kill -0 $PID 2>/dev/null || break; sleep 1; done
sleep 2; kill $PID 2>/dev/null || true
[[ -s "$DIR/result.json" ]] && cat "$DIR/result.json" || echo "没有结果（超时或启动失败）"
echo "\n截图和结果在 $DIR"
