#!/bin/zsh
# 在 gen_loop.sh 开的同一个 Codex 对话里，一次只画一帧，把缺的帧补齐（保持连续性）。
# 一个对话里连着画十几张时，Codex 画到第三四张以后常常不再真的生成，而是把上一张复制过来；
# 所以这里每次只要一帧，画完由脚本检查：这次对话里确实多了一张新图，而且和已有的帧都不一样，否则重画。
# 用法：tools/sprites/fill_frames.sh <工作目录> [补充要求]
set -u
W=$1 NOTE=${2:-}
SID=$(grep -m1 -o "session id: [0-9a-f-]*" $W/log.txt | awk '{print $3}')
GEN=$HOME/.codex/generated_images/$SID
cd $W
for k in {0..11}; do
  kk=$(printf %02d $k)
  [[ -e frame_$kk.png ]] && continue
  prev=$(printf %02d $(( (k + 11) % 12 )))
  for try in 1 2 3; do
    before=$(ls $GEN/*.png 2>/dev/null | wc -l | tr -d ' ')
    codex exec resume --skip-git-repo-check -c 'model_reasoning_effort="low"' -c 'sandbox_mode="workspace-write"' -- $SID \
      "现在只画 frame_$kk 这一帧（12 帧循环里的第 $((k + 1)) 帧）：以 base.png 为底图，头和身体完全不动，只改在动的部位；参考 base.png 和 frame_$prev.png，和前一帧几乎一样、只往下一步动一点点。必须重新调用图像生成工具画一张新图（transparent_background=true，正方形 1024x1024），不要复制任何已有的图。${NOTE}画完把新生成的这张原样复制成 frame_$kk.png，只回复「完成」。" >> $W/log_fill.txt 2>&1
    after=$(ls $GEN/*.png 2>/dev/null | wc -l | tr -d ' ')
    newest=$(ls -t $GEN/*.png 2>/dev/null | head -1)
    if (( after > before )) && [[ -n $newest ]]; then
      cp $newest frame_$kk.png   # 用这次对话刚生成的那张，不信任它自己复制的
      h=$(md5 -q frame_$kk.png)
      dup=0
      for f in frame_??.png; do [[ $f != frame_$kk.png && $(md5 -q $f) == $h ]] && dup=1; done
      (( dup == 0 )) && { echo "frame_$kk ok（第 $try 次）"; break; }
    fi
    echo "frame_$kk 第 $try 次没画出新图，重来"
    rm -f frame_$kk.png
  done
done
echo "${W:t}: $(ls | grep -c '^frame_..\.png$') 帧"
