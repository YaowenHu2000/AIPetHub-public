#!/bin/zsh
# 把当前提交导出成一个干净的公开仓库：只有一次提交、不带历史，去掉只对作者本机有用的东西。
#   ai-pet-hub/tools/export-public.sh <目标目录>
# 去掉的：.claude/（作者自己的 Claude Code 技能）、web/sprites/*/v1（界面已经不用的旧版素材）、
#        tools/uitest/clean-machine.sh 以外的东西都留着。导出后会扫一遍有没有本机路径、密钥之类的字样。
set -euo pipefail
ROOT=$(git -C "${0:A:h}" rev-parse --show-toplevel)
DEST=${1:?用法：export-public.sh <目标目录>}
[[ -e $DEST ]] && { echo "目标已存在：$DEST（换一个空目录）"; exit 1; }
mkdir -p "$DEST"
git -C "$ROOT" archive HEAD | tar -x -C "$DEST"
cd "$DEST"
rm -rf .claude ai-pet-hub/web/sprites/claude/v1 ai-pet-hub/web/sprites/gpt/v1
# 扫一遍：本机用户名、本机路径、密钥的样子
# 要找的字样都从本机取（用户名、git 和系统里的邮箱），不写死在脚本里——写死的话脚本自己就把它们公开出去了
ME=$(id -un); MAIL=$(git -C "$ROOT" config user.email || true); PAT="/Users/$ME|sk-[A-Za-z0-9-]{16,}|workbuddy"
[[ -n $MAIL ]] && PAT="$PAT|${MAIL%%@*}"
[[ -n ${AIPETHUB_PRIVATE_WORDS:-} ]] && PAT="$PAT|$AIPETHUB_PRIVATE_WORDS"   # 另外要查的字样，用 | 隔开
if grep -rInE "$PAT" . --exclude-dir=.git --exclude-dir=vendor --exclude=export-public.sh; then
  echo "⚠️ 上面这些行看起来是本机的东西，先处理再公开"; exit 1
fi
git init -q -b main
git add -A
git -c user.name="${GIT_AUTHOR_NAME:-$(git -C "$ROOT" config user.name)}" -c user.email="${GIT_AUTHOR_EMAIL:-$(git -C "$ROOT" config user.email)}" \
  commit -q -m "AIPetHub：在一个原生 macOS 窗口里使用 Gemini、Claude Code、Codex 与 DeepSeek"
echo "导出到 $DEST：$(git ls-files | wc -l | tr -d ' ') 个文件，$(du -sh .git | cut -f1)"
