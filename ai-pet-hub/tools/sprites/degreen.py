"""原图里完全没有绿色的角色（克劳蒂娜、极其猫）：帧里偏绿的像素一定是绿幕带进来的，把红绿两个通道对调，变回金色/橙色。
用法：python degreen.py <帧>…（原地修改）"""
import sys
import numpy as np
from PIL import Image
for p in sys.argv[1:]:
    a = np.asarray(Image.open(p).convert('RGBA')).copy()
    r, g, b = a[..., 0].astype(int), a[..., 1].astype(int), a[..., 2].astype(int)
    m = (g > r + 8) & (g > b + 8) & (a[..., 3] > 0)
    a[..., 0] = np.where(m, g, r)
    a[..., 1] = np.where(m, r, g)
    Image.fromarray(a, 'RGBA').save(p, optimize=True)
    print(f'{p.split("/")[-1]}: 修正 {m.sum()} 个偏绿像素')
