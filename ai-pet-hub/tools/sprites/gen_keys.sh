#!/bin/zsh
# 让 Codex 画入睡 / 醒来的 4 张过渡帧（透明背景）：yawn_0、yawn_1（打哈欠）、wake_0（揉眼睛）、wake_1（伸懒腰）。
# 和 fill_frames.sh 一样一次只要一帧，画完检查这次对话里确实多了一张新图。
# 用法：tools/sprites/gen_keys.sh <皮肤目录，如 gpt/v2> <角色描述> <工作目录>
#   底图是 idle.png：站姿、身体、位置和大小不变，只改手臂、眼睛、嘴。
#   结果：<工作目录>/yawn_0.png …（Codex 生成的原图），之后用 process_keys.sh 处理。
set -u
SKIN=$1 DESC=$2 W=$3
SPR=${0:A:h}/../../web/sprites
mkdir -p $W
cp $SPR/$SKIN/idle.png $W/base.png
cd $W
typeset -A WHAT=(
  yawn_0 "困了、刚开始打哈欠：眼睛半闭、眼皮耷拉着，嘴巴张开一半，一只手抬到嘴边。"
  yawn_1 "哈欠打到最大：眼睛闭紧（眼角挤出一小滴泪珠），嘴巴张得圆圆的，一只手捂在嘴前。"
  wake_0 "刚睡醒、揉眼睛：一只手握成小拳头揉着一只眼睛（那只眼闭着），另一只眼半睁、睡眼惺忪，嘴巴小小地抿着。"
  wake_1 "伸懒腰：两只手举过头顶伸直，眼睛闭着弯成笑眼，嘴巴张开一点，很舒服的样子。"
)
RULE="以 base.png 为底图修改：头的位置和角度、头发、身体、衣服、腿、脚、整个人在画面里的位置和大小都和 base.png 完全一样，只改手臂、眼睛、嘴（和一点点小表情符号）。画风、线条、上色、配色和 base.png 完全一致；不要阴影、地面、背景。必须调用图像生成工具画一张新图：transparent_background=true（透明背景、带 alpha 通道的 PNG），正方形 1024x1024。"
SID=""
for name in yawn_0 yawn_1 wake_0 wake_1; do
  [[ -e $name.png ]] && continue
  for try in 1 2 3; do
    [[ -z $SID && -e log.txt ]] && SID=$(grep -m1 -o "session id: [0-9a-f-]*" log.txt | awk '{print $3}')
    GEN=$HOME/.codex/generated_images/$SID
    before=0; [[ -n $SID ]] && before=$(ls $GEN/*.png 2>/dev/null | wc -l | tr -d ' ')
    if [[ -z $SID ]]; then
      codex exec --skip-git-repo-check -s workspace-write -c 'model_reasoning_effort="low"' -C $W -i $W/base.png -o $W/last.md -- \
"附上的 base.png 是 Q 版桌宠角色（$DESC）站着待机的底图。请画她的一张动作帧 $name：${WHAT[$name]}
$RULE
画完把生成的原始 PNG（在 \$CODEX_HOME/generated_images/ 里本次会话的目录）原样复制到当前目录 $name.png，不要做任何后期处理，只回复「完成」。" > log.txt 2>&1
      SID=$(grep -m1 -o "session id: [0-9a-f-]*" log.txt | awk '{print $3}')
      GEN=$HOME/.codex/generated_images/$SID
    else
      codex exec resume --skip-git-repo-check -c 'model_reasoning_effort="low"' -c 'sandbox_mode="workspace-write"' -- $SID \
"现在画另一张动作帧 $name：${WHAT[$name]}
$RULE 不要复制任何已有的图。画完把新生成的这张原样复制成 $name.png，只回复「完成」。" >> log_fill.txt 2>&1
    fi
    after=$(ls $GEN/*.png 2>/dev/null | wc -l | tr -d ' ')
    newest=$(ls -t $GEN/*.png 2>/dev/null | head -1)
    if (( after > before )) && [[ -n $newest ]]; then cp $newest $name.png; echo "$name ok（第 $try 次）"; break; fi
    echo "$name 第 $try 次没画出新图，重来"
    rm -f $name.png
  done
done
echo "${W:t}: $(ls | grep -c -E '^(yawn|wake)_[01]\.png$') 帧"
