#!/bin/zsh
# 清掉真实窗口测试留下的会话：run.sh 每次把用过的临时工作空间记在 build/uitest-dirs.txt，这里按它一个个清，
# 和 App 里「删除项目」走同一条路（Claude、Gemini、DeepSeek 的会话移到废纸篓，Codex 的归档，都还能找回）。
# 只认临时目录下这几种工作空间，别的目录里的会话不会碰：aipethub-uitest.*/repo（窗口测试）、aipethub-forkplain.*（分叉测试）、
# aipethub-verify（「添加 AI」验证时发的那一句）。
set -u
cd "${0:A:h}/../.."
# UITEST_DIRS_FILE：只清这一份清单（all.py 每次运行一份，跑完自动清；两个 agent 同时跑测试也不会删到对方的）
LIST=${UITEST_DIRS_FILE:-build/uitest-dirs.txt}
touch $LIST
print -r -- "${TMPDIR:-/tmp}aipethub-verify" >> $LIST   # 验证用的那一句：每次都顺手清
# selftest 是 test.sh 编出来的；没有就提示，不在这里顺手跑整套测试（会重编 build/selftest，干扰同时在跑的测试）
[[ -x build/selftest ]] || { echo "没有 build/selftest，先跑 tools/test.sh；这次没清，清单还在 $LIST"; exit 1; }
# 四位各自的存储互不相干，同时清（以前挨个清要 30 秒）；同一位里仍逐个目录删
clean_agent() {
  local agent=$1
  while IFS= read -r dir; do
    dir=${dir%/}
    [[ $dir == */aipethub-uitest.*/repo || $dir == */aipethub-forkplain.* || $dir == */aipethub-verify ]] || continue
    for d in "$dir" "/private$dir"; do build/selftest deleteproject $agent "$d" 2>/dev/null | grep "找到"; done
  done < $LIST
}
for agent in claude gpt gemini deepseek; do clean_agent $agent & done
wait
# 不按名字结束 dsh 的本机服务：正在用的 App 也有一个同名的。清 DeepSeek 会话时起的那个随 selftest 退出自己结束。
: > $LIST
echo "清理完了"
