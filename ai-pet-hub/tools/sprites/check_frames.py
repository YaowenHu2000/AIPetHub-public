"""检查一套帧有没有画走样：每帧和底图比颜色分布（色相 × 饱和度 × 明度直方图），差得多的标出来。
AI 偶尔不看参考图、凭文字画出另一个角色，或者特效整个变了，看一眼数字就能发现。
用法：python check_frames.py <底图> <帧1> <帧2> …   有问题时退出码 1
"""
import sys
import numpy as np
from PIL import Image

def hist(p):
    im = Image.open(p).convert('RGBA').resize((256, 256))
    a = np.asarray(im)
    hsv = np.asarray(im.convert('RGB').convert('HSV')).reshape(-1, 3)[a.reshape(-1, 4)[:, 3] > 200]
    h, _ = np.histogramdd(hsv, bins=(12, 4, 4), range=((0, 256), (0, 256), (0, 256)))
    return h.ravel() / max(1, h.sum())

def boxed_bg(p):
    """背景没透明干净（后面多了一块灰色方框）：四个角 8% 见方区域里至少两个角有不透明的像素。
    只有一个角不透明多半是特效（比如思考气泡）画到了角上，不算。"""
    a = np.asarray(Image.open(p).convert('RGBA'))[..., 3].astype(float) / 255
    n = max(4, int(a.shape[0] * 0.08))
    corners = [a[:n, :n].mean(), a[:n, -n:].mean(), a[-n:, :n].mean(), a[-n:, -n:].mean()]
    return sum(c > 0.001 for c in corners) >= 2

base, *frames = sys.argv[1:]
hb = hist(base)
d = np.array([0.5 * np.abs(hist(f) - hb).sum() for f in frames])   # 0 = 完全一样，1 = 完全不同
LIMIT = 0.35
bad = [i for i, x in enumerate(d) if x > LIMIT]
boxed = [i for i, f in enumerate(frames) if boxed_bg(f)]
msg = '和底图的颜色差异：' + ' '.join(f'{x:.2f}' for x in d)
if bad: msg += f'  ← 走样：第 {bad} 帧'
if boxed: msg += f'  ← 背景没透明干净：第 {boxed} 帧'
print(msg + ('' if bad or boxed else '  ✓'))
sys.exit(1 if bad or boxed else 0)
