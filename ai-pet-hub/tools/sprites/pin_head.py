"""把一套循环帧的头部钉在同一个位置：思考 / 查阅 / 施工时不摇头晃脑、不上下动。
每帧用第 0 帧的头部区域（角色上 40%）做模板，找左右、上下都重合最好的平移量，再整帧反向平移回去。
只平移、不变形；动作只剩画面里手、道具、表情的变化。
用法：
  python pin_head.py measure <帧1> <帧2> …              只量，不改
  python pin_head.py apply <输出目录> <帧1> <帧2> …       平移后写到输出目录（同名）
"""
import os, sys
import numpy as np
from PIL import Image

def feat(arr, rows):
    al = arr[..., 3:4] / 255
    return np.concatenate([arr[..., :3] * al, arr[..., 3:4]], axis=-1)[rows]

def head_offsets(imgs, lim_frac=0.06):
    ref = np.asarray(imgs[0]).astype(np.float32)
    ys, _ = np.nonzero(ref[..., 3] > 128)
    top, bot = ys.min(), ys.max()
    H, W = ref.shape[:2]
    lim = int(W * lim_frac)
    r0, r1 = max(0, top - lim), min(H, top + int((bot - top) * 0.40))
    R = ref[r0:r1]
    Rf = np.concatenate([R[..., :3] * R[..., 3:4] / 255, R[..., 3:4]], -1)
    out = []
    for im in imgs:
        F = np.asarray(im).astype(np.float32)
        best = None
        for dy in range(-lim, lim + 1, 1):
            if r0 + dy < 0 or r1 + dy > H: continue
            Fy = F[r0 + dy:r1 + dy]
            Ff = np.concatenate([Fy[..., :3] * Fy[..., 3:4] / 255, Fy[..., 3:4]], -1)
            for dx in range(-lim, lim + 1, 1):
                if dx >= 0: d = Ff[:, dx:] - Rf[:, :W - dx]
                else: d = Ff[:, :W + dx] - Rf[:, -dx:]
                e = (d * d).mean()
                if best is None or e < best[0]: best = (e, dx, dy)
        out.append((best[1], best[2]))   # 这一帧的头部相对第 0 帧偏了 (dx, dy)
    return np.array(out, dtype=np.float32)

def shift(img, dx, dy):
    out = Image.new('RGBA', img.size, (0, 0, 0, 0))
    out.paste(img, (int(round(dx)), int(round(dy))), img)
    return out

mode, *rest = sys.argv[1:]
outdir = rest.pop(0) if mode == 'apply' else None
imgs = [Image.open(p).convert('RGBA') for p in rest]
# 先缩小一半量（快），再按比例换算
small = [im.resize((im.width // 2, im.height // 2), Image.BILINEAR) for im in imgs]
off = head_offsets(small) * 2
off -= off.mean(0)                      # 钉在平均位置上，整体不偏
W = imgs[0].width
print(f'头部移动范围：左右 {np.ptp(off[:, 0]) / W * 100:.1f}%  上下 {np.ptp(off[:, 1]) / W * 100:.1f}%（{np.ptp(off[:, 0]):.0f}px / {np.ptp(off[:, 1]):.0f}px）')
if mode == 'apply':
    os.makedirs(outdir, exist_ok=True)
    for p, im, (dx, dy) in zip(rest, imgs, off):
        shift(im, -dx, -dy).save(os.path.join(outdir, os.path.basename(p)), optimize=True)
