#!/bin/zsh
# 把 gen_keys.sh 画好的过渡帧（yawn_0、yawn_1、wake_0、wake_1）对齐到 idle.png，写进 web/sprites/<皮肤目录>/。
# 用法：tools/sprites/process_keys.sh <皮肤目录> <工作目录>      （PY=… 指定装了 pillow、numpy 的 Python）
set -u
SKIN=$1 W=$2
T=${0:A:h}
SPR=$T/../../web/sprites
PY=${PY:-python3}
for name in yawn_0 yawn_1 wake_0 wake_1; do
  [[ -e $W/$name.png ]] || { echo "缺 $name"; exit 1; }
  $PY -I $T/fit_keys.py $W/$name.png $SPR/$SKIN/idle.png $SPR/$SKIN/$name.png
done
