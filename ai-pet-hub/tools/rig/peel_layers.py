"""用“一层层剥”出来的整图修改做分层美术。

用法：python peel_layers.py <母版 master.png> <规格 spec.json> <剥层图目录> <输出目录>

剥层图（都是 AI 在整张图上的修改，自然和母版对齐；这里再用特征点对齐一次）：
  noarms.png   拿掉两只手臂（手、袖口、袖子），补出后面的脸、肩、衣服、头发
  noears.png   拿掉猫耳，补出下面的头发
  nohead.png   在 noarms 上再拿掉头，补出脖子和头后面的头发
  nobody.png   在 nohead 上再拿掉身体，只剩完整的后发和尾巴
规格里 peels 说明每张图里“还剩哪些部件”，例如 {"noarms": ["back_hair", "tail", …, "head"], …}。

做法：
1. 母版和每张剥层图都用同样的种子切分（剥层图只切它还剩的部件），知道每个像素属于哪层；
2. 每层：自己在母版上可见的地方 = 母版原像素（静止时和母版一模一样）；
   被前面图层挡住的地方，按剥层图的顺序找“这张图里这个位置正好是这一层”的像素来补，
   补之前按两张图里这一层都可见的像素做颜色对齐（均值、方差），接缝不明显；
   还没补到、但离自己不远的一圈，用自己的底色往外抹（和 segment.py 一样）；
3. 和后面图层交界处往里柔化 1 像素。
输出：<部件>.png、owner_ids.png、owner.png、parts.json（和 segment.py 一样，后面的步骤直接接着用）。
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, str(Path(__file__).parent))
from segment import cut, register, rgba  # noqa: E402


def color_match(src, ref, mask):
    """src 的颜色按 mask 里的像素对齐到 ref（每个通道均值、方差）。"""
    out = src.astype(np.float32).copy()
    if mask.sum() < 200:
        return out
    for c in range(3):
        a, b = src[..., c][mask].astype(np.float32), ref[..., c][mask].astype(np.float32)
        sa, sb = a.std() + 1e-3, b.std() + 1e-3
        g = np.clip(sb / sa, 0.8, 1.25)
        out[..., c] = (out[..., c] - a.mean()) * g + b.mean()
    return np.clip(out, 0, 255)


def main():
    master_p, spec_p, peel_dir, out_dir = sys.argv[1:5]
    spec = json.load(open(spec_p))
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    M = rgba(master_p)
    W = M.shape[0]
    k = W / 1024
    order = spec['idle_order']
    owner = cut(M, spec['seeds'], order)
    # 规格里 no_hair_in 列的图层（手）：蓝紫色、饱和度高的像素（头发）不属于它，还给离得最近的其他图层
    nh = [order.index(n) for n in spec.get('no_hair_in', []) if n in order]
    if nh:
        rgbf = M[..., :3].astype(np.float32) / 255
        sat = rgbf.max(-1) - rgbf.min(-1)
        lum = rgbf.mean(-1)
        hairy = (rgbf[..., 2] > rgbf[..., 0] + 0.08) & (sat > 0.22) & (lum < 0.62)   # 浅色袖口不算
        bad = np.isin(owner, nh) & hairy
        # 只拿掉和手外面连着的蓝色块（真的是头发伸进来）；整块被手包住的（袖口上的阴影线）留着
        outside = ndimage.binary_dilation(~np.isin(owner, nh), iterations=1)
        lab_b, nb = ndimage.label(bad)
        if nb:
            touch = set(np.unique(lab_b[outside & bad])) - {0}
            for c in range(1, nb + 1):   # 被包住但颜色是饱和深蓝的（指缝里夹着的头发）也拿掉
                comp = lab_b == c
                if c not in touch and comp.sum() > 15 and sat[comp].mean() > 0.38:
                    touch.add(c)
            bad = np.isin(lab_b, list(touch))
        keep_ok = (owner >= 0) & ~np.isin(owner, nh)
        if bad.any() and keep_ok.any():
            _, (iy, ix) = ndimage.distance_transform_edt(~keep_ok, return_indices=True)
            owner[bad] = owner[iy[bad], ix[bad]]
            print(f'  手里的头发像素还给其他图层：{int(bad.sum())}')
        # 细长伸出去的线（比如下巴轮廓线）不属于手：开运算去掉细线，再在原范围里长回来
        for i in nh:
            m = owner == i
            core = ndimage.binary_opening(m, iterations=3)
            core = ndimage.binary_dilation(core, iterations=3) & m
            thin = m & ~core
            if thin.any():
                _, (iy, ix) = ndimage.distance_transform_edt(~((owner >= 0) & (owner != i)), return_indices=True)
                owner[thin] = owner[iy[thin], ix[thin]]
        # 和手不相连的零碎小块也还回去
        for i in nh:
            lab, num = ndimage.label(owner == i)
            if num > 1:
                sizes = ndimage.sum(owner == i, lab, range(1, num + 1))
                big = int(np.argmax(sizes)) + 1
                stray = (lab > 0) & (lab != big)
                _, (iy, ix) = ndimage.distance_transform_edt(~((owner >= 0) & (owner != i)), return_indices=True)
                owner[stray] = owner[iy[stray], ix[stray]]
    Image.fromarray((owner + 1).astype(np.uint8)).save(out / 'owner_ids.png')

    peels = []
    for name, keep in spec['peels'].items():
        p = Path(peel_dir) / f'{name}.png'
        if not p.exists():
            print(f'  没有剥层图 {name}，跳过')
            continue
        P, n = register(rgba(p, W), M, min_inliers=25)   # 拿掉身体以后可对的特征少，门槛放低
        if P is None:
            print(f'  {name}: 对不上母版（内点 {n}），跳过')
            continue
        sub = [o for o in order if o in keep]
        po = cut(P, {o: spec['seeds'][o] for o in sub}, sub)
        # 换回总顺序里的编号
        ids = np.full(po.shape, -1, np.int32)
        for i, o in enumerate(sub):
            ids[po == i] = order.index(o)
        peels.append((name, P, ids))
        Image.fromarray(((ids + 1) * 18).astype(np.uint8)).save(out / f'_cut_{name}.png')
        print(f'  {name}: 内点 {n}，剩 {len(sub)} 个部件')

    band = int(spec.get('fill_band', 60) * k)
    meta = {}
    for li, name in enumerate(order):
        mine = owner == li
        above = owner > li
        layer = np.zeros((W, W, 4), np.float32)
        layer[mine] = M[mine]
        filled = mine.copy()
        sources = []
        # 剥层图说这里露出来的是更后面的层：这一层在这里必须透明，不能再抹颜色盖住它
        behind = np.zeros((W, W), bool)
        for _, _, ids in peels:
            behind |= above & (ids >= 0) & (ids < li)
        for pname, P, ids in peels:
            want = above & ~filled & (ids == li) & (P[..., 3] > 40)
            if not want.any():
                continue
            # 颜色对齐：两张图里这一层都可见、而且离要补的地方不远的像素
            near = ndimage.distance_transform_edt(~want) < 80 * k
            both = mine & (ids == li) & (P[..., 3] > 200) & (M[..., 3] > 200) & near
            Pc = color_match(P[..., :3], M[..., :3], both)
            layer[want, :3] = Pc[want]
            layer[want, 3] = P[want, 3]
            filled |= want
            sources.append(f'{pname} {int(want.sum())}')
        # 剩下被挡住、离自己不远的一圈：把底色抹开
        grow = above & ~filled & ~behind & (ndimage.distance_transform_edt(~filled) <= band)
        if grow.any():
            lum = M[..., :3].astype(np.float32).mean(-1) / 255
            known = ndimage.binary_erosion(filled, iterations=max(1, int(3 * k))) & (layer[..., 3] > 200) & (lum > 0.4)
            if known.sum() > 50:
                _, (iy, ix) = ndimage.distance_transform_edt(~known, return_indices=True)
                smear = layer[iy, ix, :3]
                smear = np.stack([ndimage.gaussian_filter(smear[..., c], 2.5 * k) for c in range(3)], -1)
                layer[grow, :3] = smear[grow]
                layer[grow, 3] = M[grow, 3]
                sources.append(f'抹开 {int(grow.sum())}')
        # 和后面图层交界处往里柔化 1 像素
        lower = (owner >= 0) & (owner < li)
        if lower.any():
            d = ndimage.distance_transform_edt(~lower)
            soft = np.clip(0.6 + 0.4 * (d - 1), 0.6, 1.0)
            layer[mine, 3] *= soft[mine]
        Image.fromarray(np.clip(layer, 0, 255).astype(np.uint8)).save(out / f'{name}.png')
        ys, xs = np.nonzero(layer[..., 3] > 5)
        meta[name] = {'bbox': [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())], 'own_px': int(mine.sum())}
        print(f'  {name}: 自己 {int(mine.sum())}，补：{"，".join(sources) or "无"}')

    rng = np.random.default_rng(7)
    cols = (rng.random((len(order), 3)) * 200 + 40).astype(np.uint8)
    vis = M.copy()
    over = np.zeros((W, W, 3), np.uint8)
    for i in range(len(order)):
        over[owner == i] = cols[i]
    vis[..., :3] = (vis[..., :3] * 0.45 + over * 0.55).astype(np.uint8)
    vis[M[..., 3] <= 12] = (30, 30, 40, 255)
    vis[..., 3] = 255
    Image.fromarray(vis).save(out / 'owner.png')
    json.dump({'size': W, 'order': order, 'layers': meta}, open(out / 'parts.json', 'w'), ensure_ascii=False, indent=1)


if __name__ == '__main__':
    main()
