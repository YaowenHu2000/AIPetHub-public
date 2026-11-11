#!/bin/zsh
# 把 gen_loop.sh 画好的 12 帧处理成 App 用的 <动作>_g00 … _g11.png，写进 web/sprites/<皮肤目录>/。
# 用法：tools/sprites/process_loop.sh <皮肤目录> <thinking|reading|working|dragged> <工作目录> [alpha|green]
#   alpha（默认）：Codex 透明背景，不抠图；green：Gemini 绿幕，需要抠图（再加特效沿用关键帧、去绿）。
# 步骤：检查（check_frames.py）→ 对齐到底图（大小、位置）→ 12 帧统一颜色 → 头部钉住（整帧平移，左右上下都不动）。
# 依赖：Python 3 + pillow、numpy、scipy（python3 -m venv .venv && .venv/bin/pip install pillow numpy scipy，用 PY=… 指定）。
set -u
SKIN=$1 PHASE=$2 W=$3 MODE=${4:-alpha}
T=${0:A:h}
SPR=$T/../../web/sprites
PY=${PY:-python3}
O=$W/out
mkdir -p $O/fit $O/fx $O/norm
# 先检查：画成别的角色、特效走样、背景没透明干净的，不处理，回去重画
# 人工看过、确认只是误报（比如道具颜色比底图深）时，用 SKIP_CHECK=1 跳过
if [[ -z ${SKIP_CHECK:-} ]]; then
  $PY -I $T/check_frames.py $W/base.png $W/frame_??.(png|jpg|jpeg|webp) || { echo "有帧不合格，先重画再处理（人工确认是误报可加 SKIP_CHECK=1）"; exit 1; }
fi
names=()
for k in {0..11}; do
  kk=$(printf %02d $k)
  raw=$(ls $W/frame_$kk.(png|jpg|jpeg|webp)(N) | head -1)
  [[ -n $raw ]] || { echo "缺 frame_$kk"; exit 1; }
  # 都对齐到底图（大小、位置和底图一致）
  $PY -I $T/fit_frame.py $raw $W/base.png $W/base.png $O/fit/f$kk.png $MODE | sed 's|.*/||'
  # FX_FROM_BASE=1：身边的特效（光环、图标、气泡）12 帧都用底图上的那一份（AI 每帧画的特效亮度、大小会漂）
  if [[ $MODE == green || -n ${FX_FROM_BASE:-} ]]; then
    $PY -I $T/fxblend.py $O/fit/f$kk.png $W/base.png $W/base.png $O/fx/f$kk.png ${FX_FROM_BASE:+basebody} > /dev/null
    names+=($O/fx/f$kk.png)
  else
    names+=($O/fit/f$kk.png)
  fi
done
$PY -I $T/normcolor.py $O/norm $names
F=()
for k in {0..11}; do kk=$(printf %02d $k); cp $O/norm/f$kk.png $O/norm/${PHASE}_g$kk.png; F+=($O/norm/${PHASE}_g$kk.png); done
# 头部钉住：左右、上下都整帧平移回同一位置（思考 / 查阅 / 施工 / 拖拽时不摇头晃脑、不上下动）
$PY -I $T/pin_head.py apply $SPR/$SKIN $F
