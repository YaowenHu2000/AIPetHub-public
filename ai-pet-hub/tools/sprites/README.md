# 桌宠动作帧

思考 / 查阅 / 施工 / 拖拽 各一套 12 帧循环：`web/sprites/<皮肤>/<动作>_g00 … _g11.png`。
App 优先放这一套；缺图时退回原来的 4 帧（`<动作>_f0…f3`），拖拽退回 `dragged_a` / `dragged_b` 两帧。

这里放的是 PNG 原图，出图和处理的脚本都读写它；`build.sh` 打包时转成 WebP 放进 App（见 `build.sh` 里的说明），
加载素材的代码在 `web/js/stage/sprites.js`，扩展名由其中的 `SPRITE_EXT` 决定。

**fast 形态**（开着 fast 时思考 / 查阅 / 施工换成的那一套，只有克劳蒂娜和吉佩缇有）：`<动作>_fast_g00 … _g05.png`，6 帧。
画法不一样：让模型把 6 帧一次画在同一张图里（3×2），再切开，帧和帧之间细节一致。脚本是 `gen_fast.py`，用法见它开头；
这套做法整理成了技能 `.claude/skills/sprite-sheet-animation`，新的多帧素材都按它来。

## 原则

- **头和身体不动，只动脸和手**：12 帧都在同一张底图上改，头的位置和角度、身体、站位不变；
  动的只有手、手指、道具、眨眼和表情、身边的特效（拖拽是脚轻轻抬起和手扑腾）。
  处理时还会把头部钉在同一个位置，不摇头晃脑、不上下动；思考 / 查阅 / 施工时 CSS 也不加任何浮动、转动、拉伸。
- **拖拽来回播、整体摆动**：拖拽的 12 帧按 00→11→01 来回播（每帧 100ms，直接换帧，不叠化：叠化两帧重影看着晃眼），因为 AI 画到后面身子会慢慢偏一点，
  从 11 直接跳回 00 会猛地弹一下像抽搐；另外整个人以抓住的头顶为支点像钟摆一样轻轻摆（±3.5°），
  摆过中间时竖向被拉长 1.5%，连续的摆动把帧和帧之间的小跳动盖住。
  某一位腿踢得太大时，在 `web/js/stage/sprites.js` 的 `STRUGGLE_PICK` 里只挑几帧来回播、隔一会儿插一次眨眼（吉佩缇就是这样）。
- **表情要有变化**：每套里有眨眼（闭眼 → 半睁）、看向一边、小表情（微笑、嘟嘴、鼓腮），否则看着僵。
- **在同一个对话里画、一次只画一帧**：每帧参考底图和上一帧，细节一致；一个对话里连着让它画十几张时，
  画到后面常常不再真的生成、而是复制上一张，所以由脚本一帧一帧要、并检查确实是新图。
- **透明背景直接生成**（Codex 的 `transparent_background=true`）：不用抠图。绿幕抠图会让半透明的光环、
  键盘、特效发绿发虚；不同方法抠的帧放在一起还会一帧亮一帧暗。
- **不用程序插值补帧**：插值出来的帧会拉伸变形，像橡皮人。

## 用法

```sh
python3 -m venv .venv && .venv/bin/pip install pillow numpy scipy
export PY=.venv/bin/python
tools/sprites/gen_loop.sh gpt/v2 reading "吉佩缇：银白淡紫长发、小龙角……" /tmp/gpt_reading   # 开对话，先画一批
tools/sprites/fill_frames.sh /tmp/gpt_reading                                             # 一帧一帧补齐缺的帧
tools/sprites/process_loop.sh gpt/v2 reading /tmp/gpt_reading                              # 检查、处理、写进 sprites
```

**更快的办法（默认用这个）：走本地 CPA 反代并发出图**，一帧一个请求、一起发，几十张几分钟画完（`codex exec` 约一分钟一帧、只能串行）：

```sh
python tools/sprites/gen_cpa.py 16 gpt/v2:happy:/tmp/gpt_happy gpt/v2:sleep:/tmp/gpt_sleep gpt/v2:keys:/tmp/gpt_keys
```

接口和重试在 `tools/rig/imgapi.py`（`/v1/images/edits`，`gpt-image-2.6-sunburst`）。目前支持 `sleep`、`happy` 和过渡帧 `keys`；
帧之间不在同一个对话里，靠提示词写明「第几帧、动到几成」来连贯。工作目录里已有的帧会跳过，不满意的挪走再跑一遍。
画完一样用 `process_loop.sh` / `process_keys.sh` 处理。

动作可以是 `thinking`、`reading`、`working`、`dragged`，也可以是 `sleep`、`happy`（底图是 `sleep.png` / `happy.png`，
睡觉只画呼吸起伏和 zZZ，开心画蹦跳挥手）。

入睡 / 醒来的 4 张过渡帧（`yawn_0`、`yawn_1` 打哈欠，`wake_0` 揉眼睛，`wake_1` 伸懒腰）以 `idle.png` 为底图单独画：

```sh
tools/sprites/gen_keys.sh gpt/v2 "吉佩缇：……" /tmp/gpt_keys     # 一张一张画
tools/sprites/process_keys.sh gpt/v2 /tmp/gpt_keys              # 对齐到 idle.png，写进 sprites
```

`process_keys.sh` 用 `fit_keys.py` 对齐：只比下半身（裙子、腿、脚这些没改的部分），手举过头顶的帧也不会被缩小。

- 某一帧不满意：把它挪走，再跑 `fill_frames.sh <工作目录> "补充要求"`，会在同一个对话里只重画缺的那几帧。
- `process_loop.sh` 依次：
  1. `check_frames.py`：和底图比颜色分布，画成别的角色、特效走样、背景没透明干净（后面多一块方框）的标出来并停下；
     人工确认是误报（比如道具颜色比底图深）可加 `SKIP_CHECK=1`；
  2. `fit_frame.py`：对齐到底图（缩放、平移，让轮廓重合度最大）；
  3. `normcolor.py`：12 帧统一颜色，帧和帧之间不会一亮一暗；
  4. `pin_head.py`：用头部区域做模板，整帧左右上下平移，把头钉在同一个位置（只平移，不变形）。
- 身边特效每帧亮度、大小漂得厉害时加 `FX_FROM_BASE=1`：人物轮廓以外的特效 12 帧都用底图上的（`fxblend.py`）。
- 绿幕画的帧（Gemini 的 `generate_image` 只能出不透明的图）加参数 `green`：多一步抠图，特效沿用底图；
  原画里没有绿色的角色可再用 `degreen.py` 去掉残留的绿。

## 去闪烁（逐帧重画后）

- `stabilize.py <目录> <动作>`：去掉线稿每帧细微的抖动（只保留和第 0 帧大幅不同的地方）。会让动作偏僵，现在没用在任何动作上，桌宠用 AI 原生逐帧。
- `lock_prop.py <目录> <动作>`：道具（按颜色找，默认青色全息屏）每帧都换成第 0 帧的那一块，人物不动。
  AI 每帧会把平板上的图标、文字、颜色重画，连着播就闪；吉佩缇的查阅用了这个。
