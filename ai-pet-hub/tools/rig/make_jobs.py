"""生成一位角色的全部出图任务（给 imgapi.py 跑），分三批：
  a：都在母版上改 —— 拿掉手臂 / 耳朵、眨眼、表情、口型、视线、四个姿势
  b：在 noarms 上拿掉头；c：在 nohead 上拿掉身体
  iso：在每张姿势图上“只留手臂”（拿来当手臂的蒙版）
用法：python make_jobs.py <角色配置 pets/<名>.json> <母版 master.png> <输出目录>
角色配置：{"desc": 角色描述, "arms": 手臂和手里东西的描述, "ears": 耳朵描述或 null,
          "nobody_keep": 拿掉身体后留下什么, "poses": {动作: 怎么改手臂}}
"""
import json
import sys
from pathlib import Path

cfg_p, M, R = sys.argv[1:4]
cfg = json.load(open(cfg_p))
R = Path(R)
R.mkdir(parents=True, exist_ok=True)
D = cfg['desc']
KEEP = 'Keep everything else exactly identical: same composition, canvas position, size, pose, colors and line art.'


def job(name, prompt, inputs=None, check=M, min_inliers=120):
    return {'out': str(R / f'{name}.png'), 'inputs': inputs or [M], 'prompt': f'Edit this exact illustration. {D} {prompt} {KEEP}',
            'check': check, 'min_inliers': min_inliers}


A = [job('noarms', f"Remove both of her arms completely: {cfg['arms']}. Repaint everything that was hidden behind them so it looks complete and natural: her cheeks, jawline and chin, bare shoulders, the collar, the chest and waist of her outfit, the sides of the skirt, and the long hair that falls behind and beside her body.")]
if cfg.get('ears'):
    A.append(job('noears', f"Remove only {cfg['ears']} and repaint the hair underneath them naturally."))
A += [job('eyes_closed', 'Only change her eyes: both eyes gently closed (soft downward-curved eyelids with lashes, like a relaxed blink), keep the same mouth.'),
      ]
E = {   # 只要可爱的：眯眼笑、委屈鼓腮（吃惊、认真、思考、害羞、得意、困、看向别处都不要：要么吓人、要么呆、要么像在暗示）
    'smile': 'a happy smile with both eyes closed in gentle upward crescent shapes and the mouth open in a cheerful laugh',
    'pout': 'pouting and a little upset: puffed cheeks, small pursed wavy mouth, eyebrows slightly worried, eyes a bit teary',
}
A += [job('expr_' + k, f'Only change her facial expression to: {v}. Do not move her face, eyes or head.') for k, v in E.items()]
MO = {'closed': 'her mouth closed in a gentle small smile', 'small': 'her mouth slightly open, a small talking mouth',
      'wide': "her mouth wide open as if saying 'ah' happily", 'o': "her mouth in a small round 'o' shape as if saying 'oh'"}
A += [job('mouth_' + k, f'Only change her mouth to {v}. Everything else including eyes stays identical.') for k, v in MO.items()]
G = {'left': 'to the left side of the image', 'right': 'to the right side of the image', 'up': 'upward', 'down': 'downward'}
# 姿势：第 2 张参考图是逐帧版这个动作的第一帧，道具和特效照着它画（风格、颜色、位置都一样）
SPR = Path(__file__).resolve().parents[2] / 'web' / 'sprites' / cfg.get('skin', '')
for k, v in cfg['poses'].items():
    ref = SPR / f'{k}_f0.png'
    prop = cfg.get('props', {}).get(k)
    if prop and ref.exists():
        A.append({'out': str(R / f'pose_{k}.png'), 'inputs': [M, str(ref)], 'check': M, 'min_inliers': 80,
                  'prompt': f'Image 1 is the character: {D} Image 2 is the same character doing her "{k}" action. Edit image 1: change only her arms to the pose in image 2 and add {prop} exactly like in image 2 (same style, colors, shapes and positions). Her head, face, expression, hair, body, legs and her position and size on the canvas stay exactly identical to image 1. Transparent background.'})
    else:
        A.append(job('pose_' + k, v, min_inliers=80))
B = [job('nohead', 'Remove her whole head: the face, the bangs and all the hair on top of the head, ' + (cfg.get('head_extra') or 'the hair accessories') + '. Keep her neck (draw the top of the neck cleanly), and repaint the long back hair that hangs behind her head and shoulders so it is complete and continuous.', inputs=[str(R / 'noarms.png')], min_inliers=40)]
C = [job('nobody', f"Remove her whole body: the neck, the outfit, the skirt, the legs and shoes. Keep ONLY {cfg['nobody_keep']}, and repaint the parts that were hidden behind her body so they are complete and continuous.", inputs=[str(R / 'nohead.png')], min_inliers=15)]
ISO = [{'out': str(R / f'armsonly_{k}.png'), 'inputs': [str(R / f'pose_{k}.png')], 'check': str(R / f'pose_{k}.png'), 'min_inliers': 12,
        'prompt': f"Edit this exact image: erase everything except her two arms — keep only both arms from the shoulders down ({cfg['arms']}) and any item she holds or uses with her hands (book, tablet, page, keyboard, quill). Make everything else (head, hair, body, skirt, legs{', ' + cfg['iso_extra'] if cfg.get('iso_extra') else ''}) fully transparent. Do NOT move, resize or redraw the arms: they must stay at exactly the same position, size and shape on the canvas."}
       for k in cfg['poses']]
for name, jobs in (('a', A), ('b', B), ('c', C), ('iso', ISO)):
    json.dump(jobs, open(R / f'jobs_{name}.json', 'w'), ensure_ascii=False, indent=1)
print(f'a {len(A)}，b {len(B)}，c {len(C)}，iso {len(ISO)}')
