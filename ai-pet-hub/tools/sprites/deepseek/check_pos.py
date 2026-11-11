"""量各帧的头和脚相对 idle 的位置（状态切换时人跳不跳）。要 pillow、numpy。
用法：python check_pos.py <目录> <帧名…>      目录里要有 idle.png，帧名不带 .png（如 happy_g00 happy_g06）

头：拿 idle 的头部（发带到下巴）做模板，在每帧上暴力找缩放 0.95–1.05 和位移 ±18 像素里最像的。
  s 是帧里的头是 idle 的几倍，dy 为正是比 idle 低。表情、头边的特效不同，误差在 15–25 都算对上了。
脚：中间那一条（避开两边的鲸尾、特效）最低的不透明行，和 idle 比。
「身高」= (脚 dy − 头 dy) / 头中心到脚底的距离；状态切换时头、脚各差 1% 以内看不出来，超过 2% 要重新对齐（post_set.py place）。
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

Y0, Y1, X0, X1 = 50, 300, 160, 470          # 640 画布上的头部区域
C = (320, 175)                              # 头部中心（缩放原点）


def load(p, s=1.0):
    im = Image.open(p).convert('RGBa')
    if s != 1.0:
        a = 1 / s
        im = im.transform(im.size, Image.AFFINE, (a, 0, C[0] - a * C[0], 0, a, C[1] - a * C[1]), Image.BICUBIC)
    return np.asarray(im).astype(np.float32)


def foot(A):
    al = A[..., 3] > 160
    al[:, :180] = False
    al[:, 460:] = False
    return int(np.nonzero(al.sum(1) >= 3)[0].max())


def head(p, ref):
    best = None
    for s in np.arange(0.95, 1.051, 0.01):
        F = load(p, s)
        for dy in range(-18, 19, 2):
            for dx in range(-12, 13, 2):
                e = np.abs(F[Y0 + dy:Y1 + dy:2, X0 + dx:X1 + dx:2] - ref).mean()
                if best is None or e < best[0]:
                    best = (e, s, dx, dy)
    e, s, dx, dy = best
    F = load(p, s)
    for ddy in (-1, 0, 1):
        for ddx in (-1, 0, 1):
            e2 = np.abs(F[Y0 + dy + ddy:Y1 + dy + ddy:2, X0 + dx + ddx:X1 + dx + ddx:2] - ref).mean()
            if e2 < best[0]:
                best = (e2, s, dx + ddx, dy + ddy)
    return best


if __name__ == '__main__':
    d = Path(sys.argv[1])
    R = load(d / 'idle.png')
    ref = R[Y0:Y1:2, X0:X1:2]
    f0 = foot(R)
    span = f0 - C[1]
    for n in sys.argv[2:]:
        p = d / f'{n}.png'
        e, s, dx, dy = head(p, ref)
        fd = foot(load(p)) - f0
        print(f'{n:22s} 头 s={s:.2f} dx={dx:+3d} dy={dy:+3d}（误差 {e:4.1f}）  脚 dy={fd:+3d}  身高 {(fd - dy) / span * 100:+.1f}%')
