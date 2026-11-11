"""把 APIMart 出的 GIF 拆成帧，对齐到这位角色现有立绘的大小和位置，存成 App 能直接播的帧图。

用法：python gif_frames.py <gif> <参考立绘 png（比如 idle.png）> <输出目录> <名字> [AI 修边帧目录]   → <名字>_00.png …
- 每帧都用同一个缩放和平移（按所有帧合起来的人物范围，对到参考立绘的人物范围：脚底对齐、身高对齐），
  帧和帧之间不会因为各自对齐而抖；
- GIF 的透明只有全透明 / 不透明两种，边缘发硬：把透明度往里收 1 像素再稍微柔化，边缘不会一圈锯齿。
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter, ImageSequence

gif, ref, out_dir, name = sys.argv[1:5]
out = Path(out_dir)
frames = [f.convert('RGBA') for f in ImageSequence.Iterator(Image.open(gif))]
# 可选第 5 个参数：AI 修过边缘的帧所在目录（<gif 名>_XX_ai.png）。里面用 GIF 原像素，边缘一圈和透明度用 AI 修好的
edge_dir = Path(sys.argv[5]) if len(sys.argv) > 5 else None
if edge_dir:
    sys.path.insert(0, str(Path(__file__).parent))
    from scipy import ndimage
    from segment import register
    stem = Path(gif).stem
    fixed = []
    for i, f in enumerate(frames):
        A = np.asarray(f)
        ai = edge_dir / f'{stem}_{i:02d}_ai.png'
        if not ai.exists():
            fixed.append(f); continue
        Bimg = np.asarray(Image.open(ai).convert('RGBA').resize(f.size, Image.LANCZOS))
        Bw, n = register(Bimg, A, min_inliers=40)
        if Bw is None:
            fixed.append(f); continue
        solid = A[..., 3] > 128
        inner = ndimage.binary_erosion(solid, iterations=3)
        out_px = Bw.copy()
        out_px[inner] = A[inner]                       # 里面：GIF 原像素（帧间一致）
        alpha = np.where(inner, 255, Bw[..., 3])        # 边缘和外面：AI 修好的柔和透明度
        out_px[..., 3] = alpha
        fixed.append(Image.fromarray(out_px))
    frames = fixed
R = Image.open(ref).convert('RGBA')
W = R.size[0]


def bbox(a, thr=40):
    ys, xs = np.nonzero(a[..., 3] > thr)
    return xs.min(), ys.min(), xs.max(), ys.max()


rx0, ry0, rx1, ry1 = bbox(np.asarray(R))
# 所有帧合起来的人物范围（用中位数，不被个别帧里飘出去的特效带偏）
bbs = np.array([bbox(np.asarray(f)) for f in frames], float)
gx0, gy0, gx1, gy1 = np.median(bbs[:, 0]), np.median(bbs[:, 1]), np.median(bbs[:, 2]), np.median(bbs[:, 3])
s = (ry1 - ry0) / (gy1 - gy0)                       # 身高对齐
cx_ref, cx_gif = (rx0 + rx1) / 2, (gx0 + gx1) / 2
for i, f in enumerate(frames):
    a = np.asarray(f).copy()
    if not edge_dir:   # 没有 AI 修边时：透明度往里收 1 像素再柔化
        al = Image.fromarray(a[..., 3]).filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.7))
        a[..., 3] = np.asarray(al)
    im = Image.fromarray(a)
    n = round(im.size[0] * s)
    im = im.resize((n, n), Image.LANCZOS)
    canvas = Image.new('RGBA', (W, W))
    ox = round(cx_ref - cx_gif * s)
    oy = round(ry1 - gy1 * s)                       # 脚底对齐
    canvas.paste(im, (ox, oy), im)
    canvas.save(out / f'{name}_{i:02d}.png', optimize=True)
print(f'{Path(gif).name}: {len(frames)} 帧，缩放 {s:.3f} → {out}/{name}_XX.png')
