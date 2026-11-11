#!/bin/zsh
# 分层美术版：剥层图 → 图层；表情 / 口型 / 视线 / 眨眼图 → 脸部补丁；姿势图 → 姿势手臂层；最后生成 rig.json。
# 用法：tools/rig/build_layered.sh <母版 master.png（1024）> <规格 spec.json> <出图目录> <输出目录>
#   出图目录：noarms / noears / nohead / nobody.png，eyes_* / expr_* / mouth_* / gaze_*.png，pose_<动作>.png
set -u
M=$1 SPEC=$2 G=$3 O=$4
T=${0:A:h}
PY=${PY:-python3}
mkdir -p $O/idle
[[ $M -ef $O/master.png ]] || cp $M $O/master.png
echo "== 图层"
$PY -I $T/peel_layers.py $O/master.png $SPEC $G $O/idle || exit 1
# 出图目录里的 override_<图层>.png：AI 修过的部件（比如修干净的手），直接替换这一层，并更新它的范围
for f in $G/override_*.png(N); do
  n=${${f:t:r}#override_}; cp $f $O/idle/$n.png
  $PY -c "
import json
from PIL import Image
p='$O/idle/parts.json'; d=json.load(open(p)); b=Image.open('$O/idle/$n.png').getbbox()
d['layers']['$n']['bbox']=list(b); json.dump(d,open(p,'w'),ensure_ascii=False,indent=1)"
  echo "  $n：用 AI 修过的图"
done
echo "== 脸部补丁"
items=()
for f in $G/eyes_*.png(N) $G/expr_*.png(N) $G/mouth_*.png(N) $G/gaze_*.png(N); do
  n=${f:t:r}; n=${n#expr_}; items+=($n=$f)
done
rm -f $O/idle/expr_*.png(N) $O/idle/patch_*.png(N)
$PY -I $T/expressions.py $O/master.png $O/idle $SPEC $O/idle $items || exit 1
for f in $O/idle/expr_*.png(N); do mv $f $O/idle/patch_${${f:t}#expr_}; done
for P in thinking reading working dragged; do
  [[ -s $G/pose_$P.png ]] || continue
  echo "== 姿势 $P"
  $PY -I $T/pose_layers.py $O/master.png $G/noarms.png $O/idle $SPEC $G/pose_$P.png $O/$P || echo "  $P 没做成"
done
$PY -I $T/make_rig_layered.py $SPEC $O $O/rig.json
