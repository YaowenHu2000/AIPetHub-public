"""用 AI 修过的部件图替换某个图层（比如修干净的手）：按轮廓重合度对回原图层的位置和大小。
用法：python override_layer.py <原图层 png（1024 画布）> <AI 修过的裁剪图> <裁剪框 x0,y0,x1,y1> <输出 png>
"""
import sys

import numpy as np
from PIL import Image

orig_p, ai_p, box, out_p = sys.argv[1:5]
x0, y0, x1, y1 = map(int, box.split(','))
O = Image.open(orig_p).convert('RGBA')
side = x1 - x0
ref = np.asarray(O.crop((x0, y0, x1, y1)).resize((256, 256)))[..., 3] > 100
A = Image.open(ai_p).convert('RGBA').resize((side, side), Image.LANCZOS)
best = (-1, 1.0, 0, 0)
for s in np.arange(0.88, 1.121, 0.02):
    n = max(8, round(256 * s))
    a = np.asarray(A.resize((n, n)))[..., 3] > 100
    for dy in range(-24, 25, 2):
        for dx in range(-24, 25, 2):
            c = np.zeros((256, 256), bool)
            ox, oy = (256 - n) // 2 + dx, (256 - n) // 2 + dy
            sx0, sy0 = max(0, -ox), max(0, -oy)
            dx0, dy0 = max(0, ox), max(0, oy)
            w, h = min(n - sx0, 256 - dx0), min(n - sy0, 256 - dy0)
            if w <= 0 or h <= 0:
                continue
            c[dy0:dy0 + h, dx0:dx0 + w] = a[sy0:sy0 + h, sx0:sx0 + w]
            iou = (c & ref).sum() / max(1, (c | ref).sum())
            if iou > best[0]:
                best = (iou, s, dx, dy)
iou, s, dx, dy = best
k = side / 256
n = round(side * s)
im = A.resize((n, n), Image.LANCZOS)
canvas = Image.new('RGBA', O.size)
canvas.paste(im, (x0 + (side - n) // 2 + round(dx * k), y0 + (side - n) // 2 + round(dy * k)), im)
canvas.save(out_p)
print(f'{out_p}: 轮廓重合度 {iou:.2f}，缩放 {s:.2f}，平移 ({dx * k:.0f}, {dy * k:.0f})')
