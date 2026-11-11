"""把做好的骨骼模型导出给 App 用：web/rig/<id>/rig.js + 图片（WebP，透明图压得很小）。
用法：python export_rig.py <模型目录（含 rig.json）> <App 里的 id> <输出目录 web/rig/<id>>
rig.json 写成 rig.js（window.__PET_RIGS[id] = …），App 用 <script> 加载，不需要 fetch（file:// 下更稳）。
"""
import json
import sys
from pathlib import Path

from PIL import Image

src, pid, dst = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
dst.mkdir(parents=True, exist_ok=True)
rig = json.load(open(src / 'rig.json'))
total = 0


def conv(rel):
    global total
    out = Path(rel).with_suffix('.webp')
    (dst / out).parent.mkdir(parents=True, exist_ok=True)
    im = Image.open(src / rel).convert('RGBA')
    im.save(dst / out, 'WEBP', quality=92, method=6, alpha_quality=100)
    total += (dst / out).stat().st_size
    return str(out)


for L in rig['layers']:
    if L.get('file'):
        L['file'] = conv(L['file'])
for k, v in (rig.get('patches') or {}).items():
    rig['patches'][k] = conv(v)
if rig.get('blink'):
    for k in ('half', 'closed'):
        rig['blink'][k] = conv(rig['blink'][k])
(dst / 'rig.js').write_text(f'window.__PET_RIGS = window.__PET_RIGS || {{}};\nwindow.__PET_RIGS[{json.dumps(pid)}] = {json.dumps(rig, ensure_ascii=False)};\n')
print(f'{pid}: {len(rig["layers"])} 层，{len(rig.get("patches") or {})} 个补丁，图片共 {total / 1e6:.1f} MB')
