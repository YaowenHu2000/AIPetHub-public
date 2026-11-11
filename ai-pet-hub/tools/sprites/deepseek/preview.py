"""一套循环帧的预览和一致性检查：上面是各帧（深色底），最后一行是浅色底抽查 3 帧、全部帧叠加平均（不动的地方清晰、动的地方发虚）、相对第 0 帧的最大差异。
用法：python preview.py <目录> <动作> <帧数> <输出.png>   （要 pillow、numpy）"""
import sys
import numpy as np
from PIL import Image, ImageDraw
d, phase, n, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
fs = [Image.open(f'{d}/{phase}_g{k:02d}.png').convert('RGBA') for k in range(n)]
A = [np.asarray(f).astype(np.float32) for f in fs]
pm = lambda a: np.concatenate([a[..., :3] * a[..., 3:] / 255, a[..., 3:]], -1)
h = fs[0].height
ys = np.nonzero(A[0][..., 3] > 128)[0]; top, bot = ys.min(), ys.max()
body = slice(int(top + (bot - top) * 0.45), bot)        # 裙子、腿、鲸尾：不该动的地方
print('帧  上边界  和上一帧的差（下半身）  和第 0 帧的差（下半身）')
for k, f in enumerate(fs):
    prev = np.abs(pm(A[k]) - pm(A[k - 1]))[body].mean()
    first = np.abs(pm(A[k]) - pm(A[0]))[body].mean()
    print(f'g{k:02d}  {f.getchannel("A").getbbox()[1]:4d}   {prev:5.1f}   {first:5.1f}')
C, BG = 320, (34, 36, 44)
cols = 6; rows = (n + cols - 1) // cols
im = Image.new('RGB', (C * cols, C * (rows + 1)), BG); dr = ImageDraw.Draw(im)
def cell(img, x, y, bg=BG):
    t = Image.new('RGBA', (C, C), bg + (255,)); t.alpha_composite(img.resize((C, C), Image.LANCZOS)); im.paste(t.convert('RGB'), (x, y))
for k, f in enumerate(fs):
    cell(f, (k % cols) * C, (k // cols) * C); dr.text(((k % cols) * C + 8, (k // cols) * C + 6), f'g{k:02d}', fill=(200, 204, 220))
y = rows * C
for j, k in enumerate((0, n // 4, 3 * n // 4)):
    cell(fs[k], j * C, y, (240, 240, 240))
cell(Image.fromarray(np.mean(A, 0).astype(np.uint8), 'RGBA'), 3 * C, y); dr.text((3 * C + 8, y + 6), 'average', fill=(200, 204, 220))
mx = np.max([np.abs(pm(a) - pm(A[0])).max(-1) for a in A], 0)
im.paste(Image.fromarray(np.clip(mx * 2, 0, 255).astype(np.uint8)).resize((C, C)).convert('RGB'), (4 * C, y)); dr.text((4 * C + 8, y + 6), 'max diff vs g00', fill=(255, 255, 255))
im.save(out)
