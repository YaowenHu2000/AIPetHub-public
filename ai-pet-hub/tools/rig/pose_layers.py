"""从“姿势图”里取出这个姿势的两只手臂（连同手里的道具），做成左右两层。

用法：python pose_layers.py <master.png> <noarms.png> <待机图层目录(含 owner_ids.png, parts.json)> <规格 spec.json> <pose.png> <输出目录>

姿势图和“拿掉手臂的图”都是在母版上整图修改的，都先对齐到母版。
手臂的范围：优先用 AI 在姿势图上“只留手臂”的那张（armsonly_<动作>.png，AI 会把手臂挪位置、缩小，
用特征点对回姿势图），拿它的轮廓当蒙版，像素取姿势图自己的；
没有那张时退回“和 noarms 比哪里不一样”（AI 重画时躯干、头发会漂，结果常常偏大）。再按身体中线分成左右两层，各挂一根肩膀骨骼。
待机手臂在这个姿势里隐藏；手臂下面露出来的肩膀、衣服在待机图层里已经用 noarms 补好了。
输出：arm_l.png、arm_r.png、parts.json、mask.png（看效果用）
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
    master_p, noarms_p, idle_dir, spec_p, pose_p, out_dir = sys.argv[1:7]
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    spec = json.load(open(spec_p))
    M = rgba(master_p)
    W = M.shape[0]
    k = W / 1024
    A, na = register(rgba(noarms_p, W), M, min_inliers=60)
    P, npz = register(rgba(pose_p, W), M, min_inliers=60)
    if A is None or P is None:
        sys.exit(f'对不上母版（noarms 内点 {na}，姿势 内点 {npz}）')
    order = json.load(open(Path(idle_dir) / 'parts.json'))['order']
    owner = np.asarray(Image.open(Path(idle_dir) / 'owner_ids.png')).astype(np.int32) - 1
    arms_ids = [order.index(n) for n in spec.get('pose_replaces', []) if n in order]
    old_arms = np.isin(owner, arms_ids)

    # 优先：AI 在姿势图上“只留手臂”的那张（位置会被挪动、缩小），用特征点对回姿势图，拿它的轮廓当蒙版
    iso = Path(pose_p).with_name(Path(pose_p).name.replace('pose_', 'armsonly_'))
    if iso.exists():
        Praw = rgba(pose_p, W)
        warped, ni = register(rgba(iso, W), Praw, min_inliers=12)
        if warped is not None:
            # 蒙版在“原始姿势图”的坐标里；姿势图本身再对到母版：两步变换都做一遍
            m_raw = warped[..., 3]
            tmp = Praw.copy(); tmp[..., 3] = m_raw
            m_al, _ = register(Praw, M, min_inliers=60)
            # register 返回的是对齐后的图，不是变换；这里用同一组特征点重新算一次变换来搬蒙版
            from segment import gray_on_white
            import cv2
            sift = cv2.SIFT_create(nfeatures=5000)
            km, dm = sift.detectAndCompute(gray_on_white(M), (M[..., 3] > 20).astype(np.uint8) * 255)
            kp, dp = sift.detectAndCompute(gray_on_white(Praw), (Praw[..., 3] > 20).astype(np.uint8) * 255)
            good = [x for x, y in cv2.BFMatcher().knnMatch(dp, dm, k=2) if x.distance < 0.75 * y.distance]
            T, _ = cv2.estimateAffinePartial2D(np.float32([kp[x.queryIdx].pt for x in good]), np.float32([km[x.trainIdx].pt for x in good]), method=cv2.RANSAC, ransacReprojThreshold=4)
            mask = cv2.warpAffine(m_raw, T, (W, W), flags=cv2.INTER_LINEAR) > 100
            print(f'  用“只留手臂”的图做蒙版（内点 {ni}）')
            keep = ndimage.binary_closing(mask, iterations=int(3 * k))
            keep = ndimage.binary_fill_holes(keep)
            keep = ndimage.binary_dilation(keep, iterations=int(2 * k))
            return finish(M, P, keep, spec, out, k, W)
    pm = lambda a: a[..., :3].astype(np.float32) * (a[..., 3:4] / 255.0) / 255.0
    diff = np.abs(pm(P) - pm(A)).max(-1)
    diff = np.maximum(diff, np.abs(P[..., 3].astype(np.float32) - A[..., 3]) / 255.0)
    diff = ndimage.gaussian_filter(diff, 1.5 * k)
    changed = diff > 0.12
    changed = ndimage.binary_opening(changed, iterations=max(1, int(2 * k)))
    changed = ndimage.binary_closing(changed, iterations=int(4 * k))
    changed = ndimage.binary_fill_holes(changed)
    # 只要和“手臂区域”（原来手臂的地方 + 肩膀一带）相连的大块
    zone = ndimage.binary_dilation(old_arms, iterations=int(25 * k))
    lab, num = ndimage.label(changed)
    keep = np.zeros_like(changed)
    for i in range(1, num + 1):
        comp = lab == i
        if comp.sum() < 400 * k * k:
            continue
        if (comp & zone).any() or comp.sum() > 8000 * k * k:
            keep |= comp
    keep = ndimage.binary_dilation(keep, iterations=int(2 * k))
    return finish(M, P, keep, spec, out, k, W)


def finish(M, P, keep, spec, out, k, W):
    # 飘着的特效（思考气泡、魔法阵、卷轴、代码符号、光点）：姿势图里人物外面（母版这里是透明的）多出来、又不是手臂的东西
    fx = (P[..., 3] > 40) & (M[..., 3] < 12) & ~ndimage.binary_dilation(keep, iterations=int(4 * k))
    fx = ndimage.binary_opening(fx, iterations=max(1, int(1 * k)))
    lab, num = ndimage.label(fx)
    sizes = ndimage.sum(fx, lab, range(1, num + 1))
    for i, sz in enumerate(sizes):
        if sz < 120 * k * k:
            fx[lab == i + 1] = False
    fx = ndimage.binary_dilation(fx, iterations=int(3 * k)) & (M[..., 3] < 60)
    # 特效盖在人物上的那部分（比如思考气泡挡住猫耳）：和母版差得多、又和外面那块特效连着的像素也算特效，这样特效在耳朵前面
    if fx.any():
        pm = lambda a: a[..., :3].astype(np.float32) * (a[..., 3:4] / 255.0) / 255.0
        d = ndimage.gaussian_filter(np.abs(pm(P) - pm(M)).max(-1), 1.0 * k)
        over = (d > 0.18) & (M[..., 3] >= 60) & ~ndimage.binary_dilation(keep, iterations=int(6 * k))
        both = fx | over
        lab, num = ndimage.label(both)
        ids = np.unique(lab[fx]); ids = ids[ids > 0]
        grown = np.isin(lab, ids)
        added = grown & ~fx
        fx = grown
        if added.any():
            print(f'  特效盖在人物上的部分：{int(added.sum())} 像素')
    fxm = {}
    if fx.sum() > 300 * k * k:
        layer = P.copy()
        layer[..., 3] = (P[..., 3] * np.clip(ndimage.gaussian_filter(fx.astype(np.float32), 1.0 * k) * 1.5, 0, 1)).astype(np.uint8)
        Image.fromarray(layer).save(out / 'fx.png')
        ys, xs = np.nonzero(layer[..., 3] > 5)
        fxm = {'fx': {'bbox': [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())], 'px': int(fx.sum())}}
        print(f'  fx: {int(fx.sum())} 像素')
    soft = np.clip(ndimage.gaussian_filter(keep.astype(np.float32), 1.5 * k) * 1.4 - 0.2, 0, 1)
    soft *= P[..., 3] > 8
    cx = spec.get('center_x', 512) * k
    xx = np.arange(W)[None, :].repeat(W, 0)
    meta = {}
    for name, side in (('arm_l', xx < cx), ('arm_r', xx >= cx)):
        a = soft * side
        if (a > 0.05).sum() < 300 * k * k:
            continue
        layer = P.copy()
        layer[..., 3] = (P[..., 3] * a).astype(np.uint8)
        Image.fromarray(layer).save(out / f'{name}.png')
        ys, xs = np.nonzero(layer[..., 3] > 5)
        meta[name] = {'bbox': [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())], 'px': int((a > 0.05).sum())}
        print(f'  {name}: {meta[name]["px"]} 像素')
    vis = (M.astype(np.float32) * 0.35).astype(np.uint8)
    vis[..., 3] = 255
    vis[keep & (xx < cx), :3] = (255, 170, 60)
    vis[keep & (xx >= cx), :3] = (90, 200, 255)
    Image.fromarray(vis).save(out / 'mask.png')
    meta.update(fxm)
    json.dump({'size': W, 'layers': meta}, open(out / 'parts.json', 'w'), ensure_ascii=False, indent=1)


if __name__ == '__main__':
    main()
