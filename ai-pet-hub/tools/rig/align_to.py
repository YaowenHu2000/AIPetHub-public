"""把一张整图（闭眼图等）对齐到母版，存成和母版同尺寸的图。
用法：python align_to.py <母版> <要对齐的图> <输出>
用特征点配准（不怕缩放、平移差得多）；对不上就报错。
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
from segment import register, rgba  # noqa: E402

master_p, src, dst = sys.argv[1:4]
M = rgba(master_p)
out, n = register(rgba(src, M.shape[0]), M, min_inliers=40)
if out is None:
    sys.exit(f'{Path(src).name}: 特征点对不上（内点 {n}）')
print(f'{Path(src).name}: 特征点配准，内点 {n}')
Image.fromarray(out).save(dst)
