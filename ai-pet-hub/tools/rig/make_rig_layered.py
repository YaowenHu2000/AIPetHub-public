"""分层美术版的 rig.json：图层来自“一层层剥”（peel_layers.py），表情 / 口型 / 视线 / 眨眼是脸部补丁，
动作是姿势手臂层（pose_layers.py），键盘、思考气泡、飘着的符号是代码画的画布图层。

用法：python make_rig_layered.py <规格 spec.json> <输出目录> <rig.json>
  输出目录：idle/*.png + parts.json、idle/patch_*.png（脸部补丁）、<姿势>/arm_l.png、arm_r.png + parts.json
"""
import json
import sys
from pathlib import Path

spec_p, D, out_p = sys.argv[1:4]
spec = json.load(open(spec_p))
D = Path(D)
idle = json.load(open(D / 'idle' / 'parts.json'))
n = lambda v: round(v / 1024, 4)


def deform(d):
    if not d:
        return None
    d = dict(d)
    if 'pivot' in d:
        d['pivot'] = [n(d['pivot'][0]), n(d['pivot'][1])]
    for key in ('wave', 'bend'):
        if key in d:
            d[key] = round(d[key] * 3.14159265 / 180, 5) if d.get('type') in ('bend', 'flap') else n(d[key])
    if 'len' in d:
        d['len'] = n(d['len'])
    if 'band' in d:
        d['band'] = [n(d['band'][0]), n(d['band'][1]), n(d['band'][2]), 0]
    return d


def box(b, pad=4):
    return [n(max(0, b[0] - pad)), n(max(0, b[1] - pad)), n(min(1024, b[2] + pad)), n(min(1024, b[3] + pad))]


poses = {}
for p in ('thinking', 'reading', 'working', 'dragged'):
    f = D / p / 'parts.json'
    if f.exists():
        poses[p] = json.load(open(f))['layers']

replaced = set(spec.get('pose_replaces', []))
canvas = spec.get('canvas_layered', {
    'kb': {'bone': 'kb', 'box': [330, 520, 700, 680], 'before_pose': True},
    'bubble': {'bone': 'bubble', 'box': [150, 40, 480, 300], 'top': True},
    'fx': {'bone': 'fx', 'box': [200, 250, 830, 760], 'top': True},
})


def canvas_layer(name, c):
    x0, y0, x1, y1 = c['box']
    return {'name': name, 'canvas': True, 'bone': c['bone'], 'box': [n(x0), n(y0), n(x1), n(y1)], 'px': [x0, y0, x1, y1], 'seg': 2}


def arm_bend(path, shoulder):
    """手臂能弯：肩膀那头不动，越往手那头弯得越多（像肘和手腕一起弯）。
    支点 = 手臂上离肩膀骨骼最近的像素，方向 = 指向离它最远的像素（手），长度 = 两者距离。"""
    import numpy as np
    from PIL import Image
    a = np.asarray(Image.open(path).convert('RGBA'))[..., 3] > 100
    ys, xs = np.nonzero(a)
    if len(xs) < 50:
        return None
    sx, sy = shoulder
    i = int(np.argmin((xs - sx) ** 2 + (ys - sy) ** 2))
    px, py = float(xs[i]), float(ys[i])
    j = int(np.argmax((xs - px) ** 2 + (ys - py) ** 2))
    dx, dy = xs[j] - px, ys[j] - py
    L = max(20.0, float(np.hypot(dx, dy)))
    return {'type': 'bend', 'pivot': [n(px), n(py)], 'dir': [round(dx / L, 4), round(dy / L, 4)], 'len': n(L), 'freq': 1, 'k': 0}


layers = []
after = spec.get('pose_insert_after', 'head')
for name in idle['order']:
    L = {'name': name, 'file': f'idle/{name}.png', 'bone': spec['layer_bone'][name], 'box': box(idle['layers'][name]['bbox']),
         'seg': 40 if name in spec.get('deform', {}) else 16}
    d = deform(spec.get('deform', {}).get(name))
    if d:
        L['deform'] = d
    if name in replaced:
        L['hideIn'] = list(poses)
    if name == 'head':
        L['blink'] = True                      # 头部图层带脸部补丁
    layers.append(L)
    if name == after:
        for cn, c in canvas.items():
            if c.get('before_pose'):
                layers.append(canvas_layer(cn, c))
        for p, ls in poses.items():
            for side in ('arm_l', 'arm_r'):
                if side in ls:
                    bone = 'poseL' if side == 'arm_l' else 'poseR'
                    layers.append({'name': f'{p}_{side}', 'file': f'{p}/{side}.png', 'bone': bone,
                                   'box': box(ls[side]['bbox']), 'group': p, 'seg': 40,
                                   'deform': arm_bend(D / p / f'{side}.png', spec['bones'][bone]['pivot'])})
for cn, c in canvas.items():
    if c.get('top'):
        layers.append(canvas_layer(cn, c))
# 姿势里飘着的特效（AI 照逐帧版画的思考气泡、魔法阵、代码符号…）放在最上面，挂在会轻轻飘的 fx 骨骼上
for p, ls in poses.items():
    if 'fx' in ls:
        layers.append({'name': f'{p}_fx', 'file': f'{p}/fx.png', 'bone': 'fx', 'box': box(ls['fx']['bbox']), 'group': p, 'seg': 8})

patches = {f.stem[6:]: f'idle/{f.name}' for f in sorted((D / 'idle').glob('patch_*.png'))}
bones = {k: ({'pivot': [n(b['pivot'][0]), n(b['pivot'][1])], **({'parent': b['parent']} if b.get('parent') else {})}) for k, b in spec['bones'].items()}
rig = {'name': spec['name'], 'size': idle['size'], 'scale': spec.get('scale', 1.32), 'feet': n(spec['feet']),
       'bones': bones, 'layers': layers, 'patches': patches, 'layered': True}
json.dump(rig, open(out_p, 'w'), ensure_ascii=False, indent=1)
print(f"{spec['name']}: {len(layers)} 层，{len(patches)} 个脸部补丁 ->", ', '.join(l['name'] for l in layers))
