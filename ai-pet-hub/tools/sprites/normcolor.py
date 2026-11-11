"""同一套帧统一颜色：每帧不透明像素逐通道对齐到整套的平均均值、标准差（帧和帧之间不再一亮一暗）。
用法：python normcolor.py <输出目录> <帧1> <帧2> …"""
import os, sys
import numpy as np
from PIL import Image
outdir, *paths = sys.argv[1:]
os.makedirs(outdir, exist_ok=True)
imgs = [np.asarray(Image.open(p).convert('RGBA')).astype(np.float32) for p in paths]
stats = []
for im in imgs:
    px = im[im[..., 3] > 230][:, :3]
    stats.append((px.mean(0), px.std(0) + 1e-6))
mu = np.mean([s[0] for s in stats], 0)
sd = np.mean([s[1] for s in stats], 0)
for p, im, (m, s) in zip(paths, imgs, stats):
    im = im.copy()
    im[..., :3] = (im[..., :3] - m) / s * sd + mu
    Image.fromarray(im.clip(0, 255).astype(np.uint8), 'RGBA').save(os.path.join(outdir, os.path.basename(p)), optimize=True)
spread = np.ptp([s[0] for s in stats], 0)
print(f'12 帧颜色均值原来最多相差 {np.round(spread)}，已统一')
