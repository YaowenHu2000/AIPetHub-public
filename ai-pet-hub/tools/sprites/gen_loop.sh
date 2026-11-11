#!/bin/zsh
# 让 Codex 在一个对话里连续画一套 12 帧循环（透明背景，不用抠图）。
# 用法：tools/sprites/gen_loop.sh <皮肤目录，如 gpt/v2> <thinking|reading|working|dragged|sleep|happy> <角色描述> <工作目录>
#   底图：思考/查阅/施工用 <动作>_f0，拖拽用 dragged_a，睡觉 / 开心用 sleep / happy 那一张；
#   12 帧都在底图上只改手、道具、眼睛、特效（拖拽改脚和手；睡觉改 zZZ、嘴、耳朵尾巴尖），
#   头和身体不动。其余关键帧只参考手的姿势（睡觉 / 开心没有关键帧，只给底图）。
#   结果：<工作目录>/frame_00.png … frame_11.png（Codex 生成的原图），之后用 process_loop.sh 处理。
set -u
SKIN=$1 PHASE=$2 DESC=$3 W=$4
SPR=${0:A:h}/../../web/sprites
mkdir -p $W
REFS=(-i $W/base.png -i $W/key1.png -i $W/key2.png -i $W/key3.png)
REFNOTE="后 3 张 key1–key3 只用来参考手和道具的姿势（它们的头、身体位置不作数）。"
if [[ $PHASE == sleep || $PHASE == happy ]]; then
  cp $SPR/$SKIN/$PHASE.png $W/base.png
  REFS=(-i $W/base.png)
  REFNOTE=""
  case $PHASE in
    sleep) MOVE="她睡着了，眼睛一直闭着不睁开，睡得很安稳。只有这些在轻轻动：头边的 zZZ 字母一个接一个慢慢变大、往斜上方飘一点、变淡，再从最小的那个重新冒出来；嘴巴很轻地一张一合（像在呼吸、偶尔咂一下嘴）；头顶的呆毛、头上趴着的小东西、兽耳、尾巴尖这些（有哪个画哪个）很轻地动一下。手、抱着的东西不动。" ;;
    happy) MOVE="她很开心。手小幅度地挥动 / 上下摆，眼睛在弯弯的笑眼和睁开发亮之间变化、中间眨一次，嘴巴笑着一张一合，身边的小星星、爱心、音符这些特效闪烁、变换位置和大小。" ;;
  esac
elif [[ $PHASE == dragged ]]; then
  cp $SPR/$SKIN/dragged_a.png $W/base.png
  cp $SPR/$SKIN/dragged.png $W/key0.png; cp $SPR/$SKIN/dragged_a.png $W/key1.png
  cp $SPR/$SKIN/dragged.png $W/key2.png; cp $SPR/$SKIN/dragged_b.png $W/key3.png
  MOVE="两只脚轻轻交替抬起、落下（frame_00–05 左脚抬起再落下，frame_06–11 右脚抬起再落下），两只手在原位小幅度扑腾。按正常的实心衣服、白色袖口画（参考图里袖口的发暗半透明是抠图瑕疵，不要照抄）。"
else
  cp $SPR/$SKIN/${PHASE}_f0.png $W/base.png
  for i in 0 1 2 3; do cp $SPR/$SKIN/${PHASE}_f$i.png $W/key$i.png; done
  case $PHASE in
    thinking) MOVE="托腮或点下巴的手、手指轻轻动，眼睛眨一眨，头顶思考气泡里的符号、身边的特效轻轻变化。" ;;
    reading)  MOVE="拿书 / 平板的手轻轻翻页或滑动，手指点着页面移动，眼睛视线左右移动、眨眼，页面上的内容和身边的特效轻轻变化。不要低头抬头。" ;;
    working)  MOVE="两只手的手指在键盘上交替敲击（手指起落、手在键盘上小幅左右移动），键盘 / 屏幕上的字符和身边的特效变化，眼睛可以眨。" ;;
  esac
fi
cd $W
codex exec --skip-git-repo-check -s workspace-write -c 'model_reasoning_effort="low"' -C $W \
  $REFS -o $W/last.md -- \
"附上的第 1 张 base.png 是 Q 版桌宠角色（$DESC）的底图；$REFNOTE
请用图像生成工具画一套 12 帧的循环动画 frame_00 … frame_11，全部以 base.png 为底图修改：
- 头、脸的位置和角度、头发、身体、衣服、腿、脚、整个人在画面里的位置和大小，12 帧都必须和 base.png 完全一样，一点都不动：不点头、不歪头、不摇头、不上下起伏、不左右晃。
- 只有这些在动：$MOVE
- 动作幅度小、柔和、连贯：按顺序一帧一帧画，每一帧都把 base.png 和上一帧刚画好的图一起作为参考，和上一帧几乎一样，只改在动的那一点点；frame_11 要能自然接回 frame_00。
- 每次调用生成工具都必须：transparent_background=true（透明背景、带 alpha 通道的 PNG），正方形 1024x1024；画风、线条、上色、配色和 base.png 完全一致；不要阴影、地面、背景。
- 每画完一张，立刻把生成的原始 PNG（在 \$CODEX_HOME/generated_images/ 里本次会话的目录）原样复制到当前目录 frame_XX.png，不要做任何后期处理。
12 张全部画完后只回复「完成」。" > $W/log.txt 2>&1
echo "$SKIN $PHASE exit=$? frames=$(ls $W | grep -c '^frame_')"
