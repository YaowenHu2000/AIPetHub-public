"""道具在逐帧里闪（AI 每帧把平板上的图标、文字、颜色重画一遍）：所有帧的道具都换成第 0 帧的那一块。
道具按颜色找（默认找青色全息屏），取每一帧里最大的那一块，合起来当遮罩；其余像素（人物、眼睛、另一只手）一律不动。
需要保留道具某一角的动作（比如翻页）时，用 --keep 给帧号和框（1024 坐标），那几帧的框内保留原样。

用法：python lock_prop.py <sprites 目录> <动作名> [--keep 8,9,10:420,390,580,580]
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

d, phase = Path(sys.argv[1]), sys.argv[2]
keep_frames, keep_box = set(), None
if '--keep' in sys.argv:
    frames, box = sys.argv[sys.argv.index('--keep') + 1].split(':')
    keep_frames = {int(v) for v in frames.split(',')}
    keep_box = [int(v) for v in box.split(',')]

paths = [d / f'{phase}_g{i:02d}.png' for i in range(12)]
frames = [np.asarray(Image.open(p).convert('RGBA')).astype(np.float32) for p in paths]
H, W = frames[0].shape[:2]
s = W / 1024


def prop_mask(f):
    r, g, b, a = f[..., 0], f[..., 1], f[..., 2], f[..., 3]
    cyan = (a > 60) & (b > 170) & (g > 150) & (b - r > 45) & (g - r > 25)
    cyan = ndimage.binary_closing(cyan, iterations=int(6 * s))
    lab, n = ndimage.label(cyan)
    if not n:
        return cyan
    sizes = ndimage.sum(cyan, lab, range(1, n + 1))
    m = lab == (int(np.argmax(sizes)) + 1)
    return ndimage.binary_fill_holes(m)


mask = np.zeros((H, W), bool)
for f in frames:
    mask |= prop_mask(f)
mask = ndimage.binary_fill_holes(ndimage.binary_closing(mask, iterations=int(10 * s)))
mask = ndimage.binary_dilation(mask, iterations=int(5 * s))
soft = np.clip(ndimage.gaussian_filter(mask.astype(np.float32), 2.5 * s) * 1.5, 0, 1)
print(f'道具遮罩占 {mask.mean() * 100:.1f}% 的画面')

base = frames[0]
for i in range(1, 12):
    m = soft.copy()
    if i in keep_frames and keep_box:
        x0, y0, x1, y1 = (int(v * s) for v in keep_box)
        k = np.zeros((H, W), np.float32)
        k[y0:y1, x0:x1] = 1
        k = ndimage.gaussian_filter(k, 8 * s)
        m = m * (1 - k)
    m = m[..., None]
    out = frames[i] * (1 - m) + base * m
    Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).save(paths[i])
print('完成')
