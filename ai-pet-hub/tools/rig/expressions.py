"""把 AI 画的各种表情图做成“脸部补丁”：只保留脸上真的变了的地方（眼睛、眉毛、嘴、脸颊），边缘柔化。
运行时盖在头部图层上，换表情只是换这张补丁，头和头发永远是母版那一套。

用法：python expressions.py <master.png> <待机图层目录(含 owner_ids.png, parts.json)> <规格 spec.json> <输出目录> <名字=图片> …
脸的范围：规格里的 eye（眼睛框，1024 像素）往外扩：左右各扩 35%，往上扩到眉毛，往下扩到嘴巴下面。
输出：<输出目录>/expr_<名字>.png
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, str(Path(__file__).parent))
from segment import register, rgba  # noqa: E402


def main():
    master_p, idle_dir, spec_p, out_dir, *items = sys.argv[1:]
    M = rgba(master_p)
    W = M.shape[0]
    k = W / 1024
    spec = json.load(open(spec_p))
    order = json.load(open(Path(idle_dir) / 'parts.json'))['order']
    owner = np.asarray(Image.open(Path(idle_dir) / 'owner_ids.png')).astype(np.int32) - 1
    head = owner == order.index('head')
    x0, y0, x1, y1 = [v * k for v in spec['eye']]
    w, h = x1 - x0, y1 - y0
    fx0, fx1 = x0 - 0.35 * w, x1 + 0.35 * w
    fy0, fy1 = y0 - 0.9 * h, y1 + 1.6 * h
    yy, xx = np.mgrid[0:W, 0:W]
    face = (xx >= fx0) & (xx <= fx1) & (yy >= fy0) & (yy <= fy1) & head
    # 更精确的范围：眼睛（含眉毛）、嘴、脸颊几个椭圆；眼睛类补丁只用眼睛，嘴类只用嘴
    fs = spec.get('face', {})
    ell = lambda cx, cy, rx, ry: ((xx - cx * k) / (rx * k)) ** 2 + ((yy - cy * k) / (ry * k)) ** 2 <= 1
    eyes_r = np.zeros_like(face); mouth_r = np.zeros_like(face); cheeks_r = np.zeros_like(face)
    for e in fs.get('eyes', []):
        cx, cy = e['center']
        eyes_r |= ell(cx, cy - 12, 62, 64)          # 眼睛往上多一点，把眉毛也包进去
    if 'mouth' in fs:
        (mx, my), (mw, mh) = fs['mouth']['center'], fs['mouth']['size']
        mouth_r = ell(mx, my, mw * 0.95, mh * 1.05)
    for cx, cy in fs.get('cheeks', []):
        cheeks_r |= ell(cx, cy, 42, 28)
    region = {'eyes': eyes_r, 'mouth': mouth_r, 'face': eyes_r | mouth_r | cheeks_r}
    pm = lambda a: a[..., :3].astype(np.float32) * (a[..., 3:4] / 255.0) / 255.0
    for item in items:
        name, path = item.split('=', 1)
        E, n = register(rgba(path, W), M, min_inliers=40)
        if E is None:
            print(f'  {name}: 对不上母版（内点 {n}），跳过')
            continue
        diff = ndimage.gaussian_filter(np.abs(pm(E) - pm(M)).max(-1), 1.2 * k)
        kind = 'eyes' if name.startswith(('eyes', 'gaze')) else 'mouth' if name.startswith('mouth') else 'face'
        area = (region[kind] if region[kind].any() else face) & head
        changed = (diff > 0.08) & area
        changed = ndimage.binary_opening(changed, iterations=max(1, int(1 * k)))
        lab, num = ndimage.label(changed)
        sizes = ndimage.sum(changed, lab, range(1, num + 1))
        for i, s in enumerate(sizes):
            if s < 60 * k * k:
                changed[lab == i + 1] = False
        changed = ndimage.binary_closing(ndimage.binary_dilation(changed, iterations=int(5 * k)), iterations=int(4 * k)) & area
        soft = np.clip(ndimage.gaussian_filter(changed.astype(np.float32), 2.5 * k) * 1.6 - 0.2, 0, 1) * area
        layer = E.copy()
        layer[..., 3] = (soft * 255).astype(np.uint8)
        Image.fromarray(layer).save(Path(out_dir) / f'expr_{name}.png')
        print(f'  {name}: 内点 {n}，脸上变了 {int(changed.sum())} 像素')


if __name__ == '__main__':
    main()
