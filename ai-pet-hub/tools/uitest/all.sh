#!/bin/zsh
# 一键把真实窗口测试全跑一遍（要用真的 CLI，会花一些额度，三位同时跑，大约 20～30 分钟）。先 ./build.sh，再：
#   tools/uitest/all.sh                 三位都跑
#   tools/uitest/all.sh gpt             只跑一位（claude / gpt / gemini，可以写多个）
# 每位依次跑 e2e-live、more、misc、jump、browser、models、stream、fast；不用 CLI 的 e2e-stage、e2e-chrome（真实窗口）只跑一次。
# 每个脚本的结果存在 build/uitest-results/<谁>-<脚本>.json，最后列一张表：脚本自己报错的、没出结果的标 ✗。
# 结果里的每一项是「看到了什么」，不是对错判断——✓ 只说明脚本从头跑到了尾，具体数值还要看一眼。
# 跑完用 tools/uitest/clean.sh 清掉测试留下的会话。
set -u
HERE="${0:A:h}"; OUT="$HERE/../../build/uitest-results"
AGENTS=($@); (( $#AGENTS )) || AGENTS=(claude gpt gemini)
SCRIPTS=(e2e-live e2e-more e2e-misc e2e-jump e2e-browser e2e-models e2e-stream e2e-fast)
rm -rf "$OUT"; mkdir -p "$OUT"
"$HERE/run.sh" claude e2e-stage.js "" 120 > "$OUT/stage.json" 2>&1 &
REAL=1 "$HERE/run.sh" claude e2e-chrome.js "" 120 > "$OUT/chrome.json" 2>&1 &   # 真实窗口：红绿灯、顶栏上的点击、整窗截图
for a in $AGENTS; do
  ( for s in $SCRIPTS; do "$HERE/run.sh" $a $s.js > "$OUT/$a-$s.json" 2>&1; done ) &
done
wait
echo "结果在 $OUT"
for f in "$OUT"/*.json; do
  if grep -q '"ok" : true' "$f" && ! grep -q '"error"' "$f"; then echo "  ✓ ${f:t:r}"
  else echo "  ✗ ${f:t:r}：$(grep -m1 -E '"error"|没有结果' "$f" | cut -c1-200)"; fi
done
