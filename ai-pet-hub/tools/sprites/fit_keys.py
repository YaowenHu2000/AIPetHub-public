"""把单张过渡帧（打哈欠、揉眼睛、伸懒腰）对齐到底图：大小、位置和底图一致，接在待机后面不跳。
和 fit_frame.py 的区别：只拿底图下半身（裙子、腿、脚——这些帧里没改的部分）的轮廓来对齐，
手举过头顶、捂嘴这种改了上半身轮廓的帧也不会被缩小、挪位。
用法：python fit_keys.py raw.png base.png out.png
"""
import sys
import numpy as np
from PIL import Image

raw_p, base_p, out_p = sys.argv[1:4]
base = Image.open(base_p).convert("RGBA")
SIZE = base.width
rgba = np.asarray(Image.open(raw_p).convert("RGBA")).copy()
rgba[..., 3] = np.where(rgba[..., 3] >= 245, 255, rgba[..., 3])
h, w = rgba.shape[:2]
if h != w:
    n = max(h, w)
    sq = np.zeros((n, n, 4), np.uint8)
    sq[(n - h) // 2:(n - h) // 2 + h, (n - w) // 2:(n - w) // 2 + w] = rgba
    rgba = sq
gen = Image.fromarray(rgba, "RGBA").resize((SIZE, SIZE), Image.LANCZOS)

S = 160
def feat(img):
    a = np.asarray(img.resize((S, S), Image.BILINEAR)).astype(np.float32) / 255
    return np.concatenate([a[..., :3] * a[..., 3:4], a[..., 3:4]], -1)

ref = feat(base)
ys = np.nonzero(ref[..., 3] > 0.5)[0]
top, bot = ys.min(), ys.max()
r0 = top + int((bot - top) * 0.55)   # 只比下面 45%

def place(img, scale, dx, dy):
    w = max(1, round(img.width * scale)); h = max(1, round(img.height * scale))
    im = img.resize((w, h), Image.LANCZOS)
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    canvas.paste(im, (round((SIZE - w) / 2 + dx), round(SIZE - h + dy)), im)
    return canvas

def err(scale, dx, dy):
    d = feat(place(gen, scale, dx, dy))[r0:] - ref[r0:]
    return float((d * d).mean())

lim = round(SIZE * 0.08)
step = max(2, SIZE // 80)
best = (err(1, 0, 0), 1.0, 0, 0)
for scale in np.arange(0.84, 1.161, 0.02):
    for dx in range(-lim, lim + 1, step):
        for dy in range(-lim, lim + 1, step):
            e = err(scale, dx, dy)
            if e < best[0]: best = (e, scale, dx, dy)
_, s0, x0, y0 = best
for scale in np.arange(s0 - 0.02, s0 + 0.021, 0.005):
    for dx in range(x0 - step, x0 + step + 1):
        for dy in range(y0 - step, y0 + step + 1):
            e = err(scale, dx, dy)
            if e < best[0]: best = (e, scale, dx, dy)
e, scale, dx, dy = best
place(gen, scale, dx, dy).save(out_p, optimize=True)
print(f"{out_p.split('/')[-1]}: 误差={e:.4f} scale={scale:.3f} dx={dx} dy={dy}")
