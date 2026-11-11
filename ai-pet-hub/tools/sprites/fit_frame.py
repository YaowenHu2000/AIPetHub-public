"""把画出来的中间帧处理成和原图同尺寸、能直接接进循环的透明 PNG。
用法：python fit_frame.py raw.png prev.png next.png out.png [alpha|green|magenta]
1. 背景：alpha = 生成时已是透明背景（Codex transparent_background），只把身体 alpha 补满；green|magenta = 抠纯色背景（绿幕 #00FF00 或品红 #FF00FF），边缘按"偏离背景色的程度"给半透明，并去掉溢色；
2. 对齐：在缩放 ±10%、平移 ±24px 范围里搜索，使新帧的轮廓和前后两张原图轮廓的平均重合度（IoU）最大，
   保证角色大小、位置、脚底和原图一致，循环里身体不会跳。
"""
import sys
import numpy as np
from PIL import Image

raw_p, prev_p, next_p, out_p = sys.argv[1:5]
key = sys.argv[5] if len(sys.argv) > 5 else "green"
SIZE = Image.open(prev_p).width   # 和原图同尺寸（极其猫 512，另两位 320）

src_img = Image.open(raw_p)
if key == "alpha":
    # 生成时就是透明背景（Codex transparent_background）：不用抠图；身体的 alpha 是 250–254，补成完全不透明
    rgba = np.asarray(src_img.convert("RGBA")).copy()
    rgba[..., 3] = np.where(rgba[..., 3] >= 245, 255, rgba[..., 3])
    # 不是正方形的画布：居中补成正方形
    h, w = rgba.shape[:2]
    if h != w:
        n = max(h, w)
        sq = np.zeros((n, n, 4), np.uint8)
        sq[(n - h) // 2:(n - h) // 2 + h, (n - w) // 2:(n - w) // 2 + w] = rgba
        rgba = sq
    gen = Image.fromarray(rgba, "RGBA")
    raw = None
else:
    raw = np.asarray(src_img.convert("RGB")).astype(np.float32)
if raw is not None:
    r, g, b = raw[..., 0], raw[..., 1], raw[..., 2]
    if key == "green":
        keyness = g - np.maximum(r, b)          # 越绿越像背景
    else:
        keyness = np.minimum(r, b) - g          # 越品红越像背景
    # keyness 高于 t1 全透明，低于 t0 不透明，中间线性
    t0, t1 = 40.0, 120.0
    alpha = 1.0 - np.clip((keyness - t0) / (t1 - t0), 0, 1)
    # 半透明只允许出现在真正背景旁边（4px 内）：角色身上本来就偏绿/偏品红的地方（比如薄荷色键盘）保持不透明
    from scipy.ndimage import binary_dilation
    bg = keyness > t1
    near_bg = binary_dilation(bg, iterations=4)
    alpha = np.where(bg, 0.0, np.where(near_bg, alpha, 1.0))
    # 去溢色：边缘残留的背景色压回去
    if key == "green":
        g = np.where(alpha < 0.999, np.minimum(g, np.maximum(r, b)), g)
    else:
        spill = (np.minimum(r, b) - g).clip(0)
        r = np.where(alpha < 0.999, r - spill, r)
        b = np.where(alpha < 0.999, b - spill, b)
if raw is not None:
    rgba = np.dstack([r, g, b, alpha * 255]).clip(0, 255).astype(np.uint8)
    gen = Image.fromarray(rgba, "RGBA")

# 先粗缩到 512 画布（保持比例）
gen = gen.resize((SIZE, SIZE), Image.LANCZOS)

def amask(img, s=128):
    a = np.asarray(img.convert("RGBA").resize((s, s), Image.BILINEAR))[..., 3].astype(np.float32) / 255
    return a

ref = (amask(Image.open(prev_p)) + amask(Image.open(next_p))) / 2

def place(img, scale, dx, dy, size=SIZE):
    """以画布底部中点为锚缩放，再平移。"""
    w = max(1, round(img.width * scale))
    h = max(1, round(img.height * scale))
    im = img.resize((w, h), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    x = round((size - w) / 2 + dx)
    y = round(size - h + dy)
    canvas.alpha_composite(im, (x, y)) if (x >= 0 and y >= 0 and x + w <= size and y + h <= size) else canvas.paste(im, (x, y), im)
    return canvas

def score(scale, dx, dy):
    a = amask(place(gen, scale, dx, dy))
    inter = np.minimum(a, ref).sum()
    union = np.maximum(a, ref).sum()
    return inter / union

best = (score(1, 0, 0), 1.0, 0, 0)
for scale in np.arange(0.90, 1.101, 0.02):
    for dx in range(-24, 25, 4):
        for dy in range(-24, 25, 4):
            s = score(scale, dx, dy)
            if s > best[0]:
                best = (s, scale, dx, dy)
# 细调
_, s0, x0, y0 = best
for scale in np.arange(s0 - 0.02, s0 + 0.021, 0.005):
    for dx in range(x0 - 4, x0 + 5):
        for dy in range(y0 - 4, y0 + 5):
            s = score(scale, dx, dy)
            if s > best[0]:
                best = (s, scale, dx, dy)

iou, scale, dx, dy = best
out = place(gen, scale, dx, dy)
out.save(out_p, optimize=True)
base = (lambda: (np.minimum(amask(Image.open(prev_p)), amask(Image.open(next_p))).sum()
                 / np.maximum(amask(Image.open(prev_p)), amask(Image.open(next_p))).sum()))()
print(f"{out_p}: IoU={iou:.3f}（前后两张原图之间 {base:.3f}） scale={scale:.3f} dx={dx} dy={dy}")
