"""去掉逐帧动画里线稿的“闪”：AI 每画一帧都会把整张图的线条重新描一遍、每次差一点点，连起来播就一闪一闪。
做法：以第 0 帧为底，每一帧只保留和底帧“大幅不一样”的地方（眨眼、手、道具、特效），其余全部用底帧像素。
线条细微的抖动经过模糊后差别很小，不会被保留；真正的动作是成片的大差别，会保留下来。

用法：python stabilize.py <sprites 目录> <动作名> [阈值，默认 0.22]   （原地改 <动作>_g01 … g11）
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

d, phase = Path(sys.argv[1]), sys.argv[2]
base = np.asarray(Image.open(d / f'{phase}_g00.png').convert('RGBA')).astype(np.float32)
W = base.shape[0]
k = 1.0   # 按像素算（不随图大小缩放：线条抖动就是 1–2 像素）
pm = lambda a: a[..., :3] * (a[..., 3:4] / 255.0)
for i in range(1, 12):
    p = d / f'{phase}_g{i:02d}.png'
    f = np.asarray(Image.open(p).convert('RGBA')).astype(np.float32)
    diff = np.abs(pm(f) - pm(base)).max(-1) / 255
    # 人物外轮廓附近 5 像素：AI 每帧的轮廓都偏 1–2 像素，这里的差别不算动作（除非是成片的大变化，下面的阈值会处理）
    solid = (base[..., 3] > 128) | (f[..., 3] > 128)
    both = (base[..., 3] > 128) & (f[..., 3] > 128)
    edge = solid & ~ndimage.binary_erosion(both, iterations=5)
    diff[edge] *= 0.25
    # 人物外面（比如飘着的特效、道具伸出去的部分）：按透明度差算
    outside = (base[..., 3] < 30) & (f[..., 3] < 30)
    diff = np.where(outside, 0, diff)
    blur = ndimage.gaussian_filter(diff, 4.0)        # 细线的抖动模糊后就很淡了
    keep = blur > float(sys.argv[3]) if len(sys.argv) > 3 else blur > 0.22
    keep = ndimage.binary_opening(keep, iterations=max(1, int(2 * k)))
    lab, n = ndimage.label(keep)
    if n:
        sizes = ndimage.sum(keep, lab, range(1, n + 1))
        keep = np.isin(lab, [j + 1 for j, s in enumerate(sizes) if s > 60 * k * k])
    keep = ndimage.binary_dilation(keep, iterations=int(4 * k))
    m = np.clip(ndimage.gaussian_filter(keep.astype(np.float32), 2.0 * k) * 1.4, 0, 1)[..., None]
    out = f * m + base * (1 - m)
    Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).save(p)
    print(f'{phase}_g{i:02d}: 保留变化 {int(keep.sum())} 像素（{keep.mean() * 100:.1f}%）')
