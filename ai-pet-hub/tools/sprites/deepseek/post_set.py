"""鲸鱼娘整套素材的后处理（要 pillow、numpy、scipy）。

  python post_set.py pick   <工作目录> <动作>:<a|b> …          底图对齐到母版（下半身对齐），存 <工作目录>/<动作>/base.png（640）
  python post_set.py slice  <工作目录> <动作> <B 段备选|-> <输出目录>      前半段用挑好的 <动作>/sheet_A.png
        切格 → 整格平移到底图脚底 → fit_keys 对齐 → 统一颜色 → 钉头 → 被切到的边 3% 渐隐，写 <输出目录>/<动作>_g00…（6 或 12 帧）
  python post_set.py single <工作目录> <名字>:<a|b> … <输出目录>   单张对齐到母版，写 <输出目录>/<名字>.png
  python post_set.py blink  <工作目录> <名字>:<a|b> … <输出目录>   眨眼：只把脸上变了的地方贴到母版上（其余像素和 idle 完全一样，眨眼时不闪）
  python post_set.py height <工作目录> <动作> <帧数> <目录>           整套按同一个比例缩放（脚底不动），让头顶到脚底的高度和底图一样
        （整图里的人头身比和底图有 1–2% 的出入，只对齐下半身的话头会比待机时高 / 低几个像素，切换状态时跳一下）。头顶有特效的动作不要用
  python post_set.py walk   <工作目录> <a|b> <输出目录>            走路整图切 6 格，按 1,2,3,2,4,5,6,5 排成 walk_f0…f7
  python post_set.py place  <目录> <前缀> <缩放> <锚点x> <锚点y> <目标x> <目标y>
        一整套帧用同一个变换：以锚点为中心缩放，再把锚点挪到目标点（原地改 <目录>/<前缀>*.png）。
        头和脚的位置先用 check_pos.py 量；比如开心那套脚低了 6、头高了 6：place 目录 happy_g 0.974 314 627 314 621
"""
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

HERE = Path(__file__).resolve().parent
TOOLS = HERE.parent
sys.path.insert(0, str(TOOLS))
PY = [sys.executable, '-I']
SIZE = 640


def master640(work):
    p = Path(work) / 'master640.png'
    if not p.exists():
        Image.open(HERE / 'master.png').convert('RGBA').resize((SIZE, SIZE), Image.LANCZOS).save(p)
    return p


def fit(raw, ref, out):
    r = subprocess.run(PY + [str(TOOLS / 'fit_keys.py'), str(raw), str(ref), str(out)], capture_output=True, text=True)
    return (r.stdout + r.stderr).strip()


def clean(path):
    """清底雾（alpha ≤ 24），原地改。"""
    a = np.asarray(Image.open(path).convert('RGBA')).copy()
    a[a[..., 3] <= 24] = 0
    Image.fromarray(a, 'RGBA').save(path)


def fade_edges(path):
    """有东西伸到画布边上被切掉时（最外圈 2 像素里有不透明的），边上 3% 做渐隐，不留一条齐的切边；没被切的不动（头顶的水泡离边近也不会被淡掉）。"""
    im = np.asarray(Image.open(path).convert('RGBA')).astype(np.float32)
    n = im.shape[0]
    a = im[..., 3]
    if max(a[:2].max(), a[-2:].max(), a[:, :2].max(), a[:, -2:].max()) < 128:
        return
    ramp = np.clip(np.minimum(np.arange(n), n - 1 - np.arange(n)) / (n * 0.03), 0, 1)
    im[..., 3] *= ramp[None, :] * ramp[:, None]
    Image.fromarray(im.astype(np.uint8), 'RGBA').save(path, optimize=True)


def cut(sheet, base, out_dir):
    from gen_fast import cut_sheet
    out_dir.mkdir(parents=True, exist_ok=True)
    return cut_sheet(sheet, base, out_dir)


if __name__ == '__main__':
    cmd, work = sys.argv[1], Path(sys.argv[2])
    if cmd == 'pick':
        for spec in sys.argv[3:]:
            name, v = spec.split(':')
            d = work / name
            d.mkdir(parents=True, exist_ok=True)
            print(fit(work / 'base' / f'{name}_{v}.png', master640(work), d / 'base.png'))
            clean(d / 'base.png')
    elif cmd == 'slice':
        name, vb, out = sys.argv[3], sys.argv[4], Path(sys.argv[5])
        d = work / name
        out.mkdir(parents=True, exist_ok=True)
        for sub in ('fit', 'norm'):
            (d / sub).mkdir(exist_ok=True)
        fits = []
        for i, (seg, v) in enumerate((('A', ''), ('B', vb))):
            if v == '-':
                continue
            cells = cut(d / ('sheet_A.png' if seg == 'A' else f'sheet_B_{v}.png'), d / 'base.png', d / f'cut_{seg}')
            seg_fits = [d / 'fit' / f'{name}_g{i * 6 + k:02d}.png' for k in range(len(cells))]
            with ThreadPoolExecutor(6) as ex:
                for msg in ex.map(lambda cf: fit(cf[0], d / 'base.png', cf[1]), zip(cells, seg_fits)):
                    print(' ', msg, flush=True)
            fits += seg_fits
        subprocess.run(PY + [str(TOOLS / 'normcolor.py'), str(d / 'norm')] + [str(f) for f in fits], check=True)
        subprocess.run(PY + [str(TOOLS / 'pin_head.py'), 'apply', str(out)] + [str(d / 'norm' / f.name) for f in fits], check=True)
        for f in fits:
            fade_edges(out / f.name)
    elif cmd in ('single', 'blink'):
        out = Path(sys.argv[-1])
        out.mkdir(parents=True, exist_ok=True)
        ref = master640(work)
        for spec in sys.argv[3:-1]:
            name, v = spec.split(':')
            tmp = work / 'single' / f'{name}_fit.png'
            print(fit(work / 'single' / f'{name}_{v}.png', ref, tmp))
            clean(tmp)
            if cmd == 'blink':
                m = np.asarray(Image.open(ref).convert('RGBA')).astype(np.float32)
                b = np.asarray(Image.open(tmp).convert('RGBA')).astype(np.float32)
                ys = np.nonzero(m[..., 3] > 128)[0]
                top, bot = ys.min(), ys.max()
                diff = np.abs(m[..., :3] - b[..., :3]).max(-1)
                face = np.zeros(diff.shape, bool)
                face[int(top + (bot - top) * 0.28):int(top + (bot - top) * 0.48)] = True     # 眼睛那一带
                mask = Image.fromarray(((diff > 40) & face).astype(np.uint8) * 255).filter(ImageFilter.MaxFilter(13)).filter(ImageFilter.GaussianBlur(3))
                k = np.asarray(mask).astype(np.float32)[..., None] / 255
                print(f'  {name}: 贴回母版的像素 {float((k > 0.5).mean()) * 100:.2f}%')
                Image.fromarray((m * (1 - k) + b * k).clip(0, 255).astype(np.uint8), 'RGBA').save(out / f'{name}.png', optimize=True)
            else:
                Image.open(tmp).save(out / f'{name}.png', optimize=True)
    elif cmd == 'height':
        name, n, out = sys.argv[3], int(sys.argv[4]), Path(sys.argv[5])
        def span(p):
            ys = np.nonzero((np.asarray(Image.open(p).convert('RGBA'))[..., 3] > 128).any(1))[0]
            return ys.min(), ys.max()
        bt, bb = span(work / name / 'base.png')
        files = [out / f'{name}_g{k:02d}.png' for k in range(n)]
        spans = [span(f) for f in files]
        ft, fb = np.median([s[0] for s in spans]), np.median([s[1] for s in spans])
        s = (bb - bt) / (fb - ft)
        for f in files:
            im = Image.open(f).convert('RGBA')
            w = round(SIZE * s)
            im2 = im.resize((w, w), Image.LANCZOS)
            canvas = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
            canvas.paste(im2, (round((SIZE - w) / 2), round(bb - fb * s)), im2)
            canvas.save(f, optimize=True)
        print(f'{name}: 底图 {bt}–{bb}，帧 {ft:.0f}–{fb:.0f}，缩放 {s:.3f}')
    elif cmd == 'place':
        prefix, s = sys.argv[3], float(sys.argv[4])
        ax, ay, tx, ty = (float(x) for x in sys.argv[5:9])
        a = 1 / s       # PIL 的仿射是「输出坐标 → 输入坐标」
        for f in sorted(work.glob(f'{prefix}*.png')):
            im = Image.open(f).convert('RGBa')      # 预乘后再插值，透明边上不出黑边
            im = im.transform(im.size, Image.AFFINE, (a, 0, ax - a * tx, 0, a, ay - a * ty), Image.BICUBIC)
            im.convert('RGBA').save(f, optimize=True)
            print(f'  {f.name}')
    elif cmd == 'walk':
        # 腿在动，不能拿下半身对齐：6 格都用「双脚着地那一格」对出来的缩放和位移，再按头部（上 40%）对到母版上
        import re
        v, out = sys.argv[3], Path(sys.argv[4])
        out.mkdir(parents=True, exist_ok=True)
        d = work / 'walk'
        ref = master640(work)
        cells = cut(d / f'sheet_{v}.png', ref, d / 'cut')
        msg = fit(cells[0], ref, d / 'c0_fit.png')
        print(msg)
        scale, dx, dy = (float(x) for x in re.search(r'scale=([\d.]+) dx=(-?\d+) dy=(-?\d+)', msg).groups())
        R = np.asarray(Image.open(ref).convert('RGBA')).astype(np.float32)
        ys = np.nonzero(R[..., 3] > 128)[0]
        r0, r1 = ys.min(), ys.min() + int((ys.max() - ys.min()) * 0.40)
        pm = lambda a: np.concatenate([a[..., :3] * a[..., 3:] / 255, a[..., 3:]], -1)
        Rf = pm(R)[r0:r1:2, ::2]
        frames = []
        for c in cells:
            im = Image.open(c).convert('RGBA').resize((SIZE, SIZE), Image.LANCZOS)
            w = round(SIZE * scale)
            im = im.resize((w, w), Image.LANCZOS)
            canvas = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
            canvas.paste(im, (round((SIZE - w) / 2 + dx), round(SIZE - w + dy)), im)
            F = pm(np.asarray(canvas).astype(np.float32))
            best = None
            for oy in range(-24, 25, 2):
                for ox in range(-24, 25, 2):
                    e = ((np.roll(F, (-oy, -ox), (0, 1))[r0:r1:2, ::2] - Rf) ** 2).mean()
                    if best is None or e < best[0]:
                        best = (e, ox, oy)
            _, ox, oy = best
            shifted = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
            shifted.paste(canvas, (-ox, -oy), canvas)
            print(f'  {c.name}: 头部对到母版，平移 {-ox},{-oy}')
            frames.append(shifted)
        (d / 'aligned').mkdir(exist_ok=True)
        paths = []
        for k, f in enumerate(frames):
            f.save(d / 'aligned' / f'c{k}.png')
            paths.append(d / 'aligned' / f'c{k}.png')
        subprocess.run(PY + [str(TOOLS / 'normcolor.py'), str(d / 'norm')] + [str(p) for p in paths], check=True)
        for i, c in enumerate((0, 1, 2, 1, 3, 4, 5, 4)):
            Image.open(d / 'norm' / f'c{c}.png').save(out / f'walk_f{i}.png', optimize=True)
