"""在母版上切图层（专业 rigger 的做法：从原图切，不靠 AI 重画部件的位置）。

用法：python segment.py <master.png> <规格 spec.json> <部件图目录> <输出目录>

1. 切分：规格里每个部件给几笔种子线（seeds，按 1024 图的像素），用分水岭沿着线稿的深色描边自动长出每个部件的范围；
   哪笔种子都没长到的零碎像素归给最近的部件。
2. 每层的像素：
   - 归自己的地方：母版原像素（静止时所有图层叠起来和母版一模一样）；
   - 被前面图层挡住、离自己不远（fill_band 像素以内）的地方：用图像修补把自己往里延伸（动作小的时候露出来的就是这一圈）；
   - 规格里 fill_from 指定了 AI 部件图的（比如身体）：先用特征点把 AI 图配准到母版，被挡住的地方整块用 AI 图补；
   - 归后面图层的地方：透明。
3. 和后面图层交界的地方往里柔化 1 像素，动起来边缘不锯齿。
输出：<部件>.png、owner.png（切分结果，看效果用）、owner_ids.png（每个像素归哪层，给姿势覆盖层用）、parts.json。
"""
import json
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image
from scipy import ndimage
from skimage.segmentation import watershed


def rgba(p, size=None):
    im = Image.open(p).convert('RGBA')
    if size and im.size != (size, size):
        im = im.resize((size, size), Image.LANCZOS)
    return np.asarray(im)


def gray_on_white(a):
    al = a[..., 3:4] / 255.0
    return cv2.cvtColor((a[..., :3] * al + 255 * (1 - al)).astype(np.uint8), cv2.COLOR_RGB2GRAY)


def register(part, master, min_inliers=15):
    """特征点匹配 + RANSAC 求相似变换，把 AI 部件图对到母版上；对不上返回 None。"""
    sift = cv2.SIFT_create(nfeatures=5000)
    km, dm = sift.detectAndCompute(gray_on_white(master), (master[..., 3] > 20).astype(np.uint8) * 255)
    kp, dp = sift.detectAndCompute(gray_on_white(part), (part[..., 3] > 20).astype(np.uint8) * 255)
    if dp is None or dm is None:
        return None, 0
    good = [a for a, b in cv2.BFMatcher().knnMatch(dp, dm, k=2) if a.distance < 0.75 * b.distance]
    if len(good) < 6:
        return None, len(good)
    src = np.float32([kp[a.queryIdx].pt for a in good])
    dst = np.float32([km[a.trainIdx].pt for a in good])
    A, inl = cv2.estimateAffinePartial2D(src, dst, method=cv2.RANSAC, ransacReprojThreshold=4)
    n = int(inl.sum()) if inl is not None else 0
    if A is None or n < min_inliers:
        return None, n
    W = master.shape[0]
    return cv2.warpAffine(part, A, (W, W), flags=cv2.INTER_LINEAR, borderValue=(0, 0, 0, 0)), n


def cut(M, seeds, order):
    """分水岭切分：每个部件的种子线沿着线稿描边长出范围；返回每个像素归哪层（-1 = 透明）。
    两层交界处的深色描边归前面那层（前面物体的轮廓线画在上面）。"""
    W = M.shape[0]
    k1024 = W / 1024
    solid = M[..., 3] > 12
    g = gray_on_white(M).astype(np.float32) / 255
    edge = np.hypot(ndimage.sobel(g, 0), ndimage.sobel(g, 1))
    elev = ndimage.gaussian_filter(edge / (edge.max() + 1e-6) + 0.9 * (1 - g) ** 2, 0.8)
    markers = np.zeros((W, W), np.int32)
    for i, name in enumerate(order):
        for line in seeds.get(name, []):
            pts = (np.array(line, np.float32) * k1024).astype(np.int32)
            if len(pts) == 1:
                cv2.circle(markers, tuple(int(v) for v in pts[0]), int(6 * k1024), i + 1, -1)
            else:
                cv2.polylines(markers, [pts.reshape(-1, 1, 2)], False, i + 1, int(7 * k1024))
    markers[~solid] = 0
    lab = watershed(elev, markers, mask=solid)
    hole = solid & (lab == 0)
    if hole.any():
        _, (iy, ix) = ndimage.distance_transform_edt(lab == 0, return_indices=True)
        lab[hole] = lab[iy[hole], ix[hole]]
    owner = lab - 1
    dark = solid & (g < 0.45)
    for k in range(len(order) - 1, 0, -1):
        near_k = ndimage.binary_dilation(owner == k, iterations=max(1, int(3 * k1024)))
        steal = near_k & dark & (owner >= 0) & (owner < k)
        owner[steal] = k
    return owner


def main():
    master_p, spec_p, parts_dir, out_dir = sys.argv[1:5]
    spec = json.load(open(spec_p))
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    M = rgba(master_p)
    W = M.shape[0]
    k1024 = W / 1024
    order = spec['idle_order']
    solid = M[..., 3] > 12

    # ── 1. 分水岭切分 ──
    owner = cut(M, spec['seeds'], order)
    Image.fromarray((owner + 1).astype(np.uint8)).save(out / 'owner_ids.png')

    # ── 2. AI 部件图配准（只用来补被挡住的大块） ──
    fills = {}
    for name, src in spec.get('fill_from', {}).items():
        p = Path(parts_dir) / src / f'{src}.png'
        if not p.exists():
            print(f'  {name}: 没有 AI 部件图 {p.name}，只用修补')
            continue
        warped, n = register(rgba(p, W), M)
        print(f'  {name}: AI 部件图配准 {"成功" if warped is not None else "失败"}（内点 {n}）')
        if warped is not None:
            fills[name] = warped

    # ── 3. 每层 ──
    band = int(spec.get('fill_band', 40) * k1024)
    meta = {}
    for k, name in enumerate(order):
        mine = owner == k
        above = owner > k
        layer = np.zeros((W, W, 4), np.uint8)
        layer[mine] = M[mine]
        # 被挡住、离自己不远的一圈：修补延伸
        near = ndimage.distance_transform_edt(~mine) <= band
        grow = above & near
        # 规格里 fill_clip 给了椭圆的，补画只在椭圆里（比如头：手挪开后，下巴下面不该补出一块脸）
        clip = spec.get('fill_clip', {}).get(name)
        if clip:
            ex, ey, erx, ery = [v * k1024 for v in clip['ellipse']]
            yy, xx = np.mgrid[0:W, 0:W]
            grow &= ((xx - ex) / erx) ** 2 + ((yy - ey) / ery) ** 2 <= 1
        if grow.any():
            rgb = np.ascontiguousarray(layer[..., :3])
            # 只用自己的“底色”往外延伸：往里收 4 像素、去掉深色描边，不然补出来的是一圈黑
            lum = M[..., :3].astype(np.float32).mean(-1) / 255
            known = ndimage.binary_erosion(mine, iterations=max(1, int(4 * k1024))) & (M[..., 3] > 200) & (lum > 0.45)
            if known.sum() < 50:
                known = mine & (M[..., 3] > 200)
            # 把底色往外“抹”开（每个位置取最近的底色像素），再稍微模糊一下去掉条纹
            _, (iy, ix) = ndimage.distance_transform_edt(~known, return_indices=True)
            smear = M[iy, ix, :3].astype(np.float32)
            smear = np.stack([ndimage.gaussian_filter(smear[..., c], 2.5 * k1024) for c in range(3)], -1)
            rgb[grow] = np.clip(smear[grow], 0, 255).astype(np.uint8)
            layer[grow, :3] = rgb[grow]
            layer[grow, 3] = M[grow, 3]       # 透明度沿用母版：剪影边缘半透明的那圈不会被垫实
        # 被挡住的大块：AI 部件图
        if name in fills:
            f = fills[name]
            use = above & (f[..., 3] > 128)
            layer[use, :3] = f[use, :3]
            layer[use, 3] = M[use, 3]
        # 和后面图层交界处往里柔化
        lower = (owner >= 0) & (owner < k)
        if lower.any():
            d = ndimage.distance_transform_edt(~lower)
            soft = np.clip(0.6 + 0.4 * (d - 1), 0.6, 1.0)   # 只柔化紧贴交界的 1 像素
            layer[mine, 3] = (layer[mine, 3] * soft[mine]).astype(np.uint8)
        Image.fromarray(layer).save(out / f'{name}.png')
        ys, xs = np.nonzero(layer[..., 3] > 5)
        meta[name] = {'bbox': [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())], 'own_px': int(mine.sum()),
                      'fill_px': int((layer[..., 3] > 5).sum() - mine.sum())}
        print(f'  {name}: 自己 {meta[name]["own_px"]} 像素，补 {meta[name]["fill_px"]} 像素')

    rng = np.random.default_rng(7)
    cols = (rng.random((len(order), 3)) * 200 + 40).astype(np.uint8)
    vis = M.copy()
    over = np.zeros((W, W, 3), np.uint8)
    for k in range(len(order)):
        over[owner == k] = cols[k]
    vis[..., :3] = (vis[..., :3] * 0.45 + over * 0.55).astype(np.uint8)
    vis[~solid] = (30, 30, 40, 255)
    vis[..., 3] = 255
    Image.fromarray(vis).save(out / 'owner.png')
    json.dump({'size': W, 'order': order, 'layers': meta}, open(out / 'parts.json', 'w'), ensure_ascii=False, indent=1)


if __name__ == '__main__':
    main()
