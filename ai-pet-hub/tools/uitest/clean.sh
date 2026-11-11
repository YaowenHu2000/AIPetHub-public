#!/bin/zsh
# 清掉真实窗口测试留下的会话：run.sh 每次把用过的临时工作空间记在 build/uitest-dirs.txt，这里按它一个个清，
# 和 App 里「删除项目」走同一条路（Claude、Gemini、DeepSeek 的会话移到废纸篓，Codex 的归档，都还能找回）。
# 只认临时目录下这几种工作空间，别的目录里的会话不会碰：aipethub-uitest.*/repo（窗口测试）、aipethub-forkplain.*（分叉测试）、
# aipethub-verify（「添加 AI」验证时发的那一句）。
set -u
cd "${0:A:h}/../.."
LIST=build/uitest-dirs.txt
touch $LIST
print -r -- "${TMPDIR:-/tmp}aipethub-verify" >> $LIST   # 验证用的那一句：每次都顺手清
[[ -x build/selftest ]] || tools/test.sh >/dev/null   # selftest 是 test.sh 编出来的
for agent in claude gpt gemini deepseek; do
  while IFS= read -r dir; do
    dir=${dir%/}
    [[ $dir == */aipethub-uitest.*/repo || $dir == */aipethub-forkplain.* || $dir == */aipethub-verify ]] || continue
    for d in "$dir" "/private$dir"; do build/selftest deleteproject $agent "$d" 2>/dev/null | grep "找到"; done
  done < $LIST
done
pkill -f "dsh web --port 0 --host 127.0.0.1" 2>/dev/null || true   # 清 DeepSeek 时起的本机服务
: > $LIST
echo "清理完了"
