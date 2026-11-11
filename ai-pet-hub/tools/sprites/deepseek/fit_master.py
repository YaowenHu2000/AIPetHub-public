"""把出图接口给的原图规格化成母版：清底雾（alpha ≤ 24）、按克劳蒂娜母版的头顶 / 脚底位置缩放居中，输出 1024×1024。
用法：python fit_master.py <原图> <输出.png>   （要 pillow、numpy）"""
import sys
from pathlib import Path
import numpy as np
from PIL import Image
REF = Path(__file__).resolve().parents[3] / 'web/lab/rig/claude/master.png'
m = np.asarray(Image.open(REF).convert('RGBA'))[..., 3]
ys = np.nonzero((m > 200).any(1))[0]
TOP, BOT, PAD = ys.min(), ys.max(), 6
a = np.asarray(Image.open(sys.argv[1]).convert('RGBA')).copy()
a[a[..., 3] <= 24] = 0
yy, xx = np.nonzero(a[..., 3] > 200)
box = (max(xx.min() - PAD, 0), max(yy.min() - PAD, 0), min(xx.max() + 1 + PAD, a.shape[1]), min(yy.max() + 1 + PAD, a.shape[0]))
c = Image.fromarray(a, 'RGBA').crop(box)
s = min((BOT - TOP + 2 * PAD) / c.height, 960 / c.width)
c = c.resize((round(c.width * s), round(c.height * s)), Image.LANCZOS)
im = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
im.paste(c, ((1024 - c.width) // 2, BOT + PAD - c.height))
im.save(sys.argv[2], optimize=True)
print(sys.argv[2], 'scale %.3f' % s, 'bbox', im.getchannel('A').getbbox())
