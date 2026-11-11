"""fast 形态的逐帧素材（开着 fast 时思考 / 查阅 / 施工换成这一套）：<动作>_fast_g00 … _g05.png（6 帧）。
和平时那套不是同一个姿势：头发扎成高马尾被风吹向身后、多一个闪电发夹、眼神更锐利、身边有电光和速度线，手上的动作也更猛
（思考打响指 / 竖手指、查阅飞快翻页 / 连刷三块面板、施工双键盘）。只有克劳蒂娜和吉佩缇有（Gemini 没有 fast）。

走本地 CPA 反代并发出图（tools/rig/imgapi.py），两步：
  1. 底图：python gen_fast.py bases <工作目录> [几张备选，默认 2]
     以平时那套的第 0 帧为参考，每位每个动作画几张备选（<工作目录>/base/<谁>_<动作>_a.png …）。挑好以后：
     python gen_fast.py pick <工作目录> claude:thinking:a gpt:working:b …
     会对齐到平时那套的第 0 帧（下半身对齐，大小、站位一致，切换形态时不跳），存成 <工作目录>/<谁>_<动作>/base.png。
  2. 循环帧：python gen_fast.py sheets <工作目录> [几张备选，默认 2]
     每个 <谁>_<动作>/ 里画 sheet_a.png …：一张图里 3×2 共 6 帧（一次画在一起，帧和帧之间细节一致）。挑好以后：
     python gen_fast.py slice <工作目录> claude:thinking:a gpt:working:b …
     切开、对齐到底图、统一颜色、钉住头，写进 web/sprites/<皮肤>/<动作>_fast_g00 … _g05.png。
"""
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'rig'))
import imgapi  # noqa: E402

SPR = HERE.parent.parent / 'web' / 'sprites'
SKIN = {'claude': 'claude/v2', 'gpt': 'gpt/v2'}
PHASES = ('thinking', 'reading', 'working')

FORM = ('Image 1 is a chibi desktop-pet character. Redraw her in her "FAST / overclock mode" — clearly the same character, same outfit, same chibi proportions, '
        'standing at exactly the same position and size on the canvas with the legs and feet unchanged, but her form changes: '
        'her long hair is now tied up into one high ponytail that streams out horizontally to the right as if blown by a strong headwind (a few loose strands too); '
        'a small glowing golden lightning-bolt hair clip is added next to her existing hair ornament; her eyes are sharp, bright and determined with a confident little smile; '
        'thin golden-yellow lightning sparks crackle around her and a few short horizontal speed lines trail to the right. ')
BASE_POSE = {
    'claude:thinking': 'Pose: one hand raised with the index finger pointing up in a quick "got it!" gesture, the other hand on her hip. The thought bubble now contains a bold lightning bolt and "!!" instead of the light bulb and question mark. Remove the faint thin circles in the background.',
    'claude:reading': 'Pose: she speed-reads — the open book is held in one hand while the other hand flips a page so fast that three or four pages fan out in mid-turn; the round glasses stay on, with a glint. The loose paper scrolls around her are replaced by four small pages whipping past in the wind to the right.',
    'claude:working': 'Pose: she types at high speed on the book-shaped keyboard with both hands, fingers spread, and a second glowing golden holographic keyboard floats just above it; small golden code symbols like </> and {} fly off to the right. Keep the golden hexagons but tilt them as if spinning.',
    'gpt:thinking': 'Pose: one hand raised snapping her fingers with a small spark at the fingertips, the other hand on her hip. The big thought bubble now contains a bold lightning bolt and spinning gears; the small blue cloud creature beside her looks surprised and is being blown back to the right. Her dragon horns, pointed ears, wings and scaly tail stay.',
    'gpt:reading': 'Pose: she swipes rapidly through THREE stacked translucent cyan holographic panels in front of her with one finger, the panels fanned out like cards in mid-swipe; the small blue cloud creature holds on to its magnifying glass while being blown back to the right. Her dragon horns, pointed ears, wings and scaly tail stay.',
    'gpt:working': 'Pose: she types at high speed on TWO green holographic keyboards, one under each hand, arms spread a little wider, with four small green code windows stacked beside her; the small blue cloud creature cheers with tiny fists. Her dragon horns, pointed ears, wings and scaly tail stay.',
}

# 循环帧：一次让模型把 6 帧画在同一张图里（3 列 × 2 行，1536x1024，每格 512），再切开。
# 同一张图里画出来的 6 个人线条、颜色、细节几乎一样，连着播不闪；一帧一个请求分开画的话每帧细节都有出入，要靠后期压。
# {MOVE} 里写这个动作动哪里：按「动到几成」（0 = 和底图一样，3 = 最大）或者 A / B 两拍交替。
SHEET = ('Image 1 is a chibi desktop-pet character in her fast / overclock mode. Make a SPRITE SHEET of a 6-frame looping animation of her working at high speed: '
         'a strict grid of 3 columns x 2 rows of equal square cells on a fully transparent background — no grid lines, no borders, no text, no numbers, no shadows, no background glow. '
         'Every cell shows the SAME character as image 1, at the same size and at the same position inside its cell, fully inside the cell with a margin: '
         'the hair, the bubble, the props and the sparks must not touch or cross into neighbouring cells. '
         'The head position and angle, the face shape, the body, the dress, the legs and the feet are IDENTICAL in all six cells. Only these things change from cell to cell: {MOVE} '
         'In every cell the golden lightning sparks stay in the same places but flicker (bigger and brighter in cells 1, 3, 5; thin and faint in cells 2, 4, 6), '
         'and only the far tips of the ponytail flutter a little. Eyes: open exactly as in image 1 in cells 1, 2, 3, 4 and 6; closed in a quick blink in cell 5. '
         'Cells are numbered in reading order: left to right, top row first.')
LEVEL = 'The cells use motion level 0, 1, 2, 3, 2, 1 in reading order — level 0 is exactly image 1 and level 3 is the extreme, so the animation loops seamlessly. '
BEAT = 'The cells alternate beat A, B, A, B, A, B in reading order, so the animation loops seamlessly. '
MOVE = {
    'claude:thinking': LEVEL + 'Her raised index finger wags: at level 0 the raised hand is exactly as in image 1; at level 3 the finger is tilted about 25 degrees outward, away from her face, and the small yellow accent marks beside it are bigger. '
                       'In the thought bubble the lightning bolt glows brighter with the level and the "!!" grows slightly. The hand on her hip does not move.',
    'claude:reading': LEVEL + 'She flips pages fast: at level 0 the fan of turning pages and the flipping hand are exactly as in image 1; at level 3 the turning pages have swept over to the other side of the book and the flipping hand has followed them. '
                      'The glow rising from the book gets brighter with the level, and the small loose pages flying beside her each rotate a few degrees more with the level. The hand holding the book does not move.',
    'claude:working': BEAT + 'She types very fast with both hands: on beat A the fingers of the hand on the viewer\'s left are pressed down on the keys and the fingers of the other hand are lifted; on beat B the opposite. The keys under the pressed fingers glow brighter. '
                      'The floating golden keyboard pulses (bright on A, dim on B), the small golden code symbols twinkle (different ones bright on A and on B), and the golden hexagons turn a little further in each cell.',
    'gpt:thinking': LEVEL + 'She snaps her fingers: at level 0 the raised hand is exactly as in image 1; at level 3 the thumb and middle finger have snapped apart and the spark at her fingertips is a big star-shaped burst. '
                    'In the big thought bubble the lightning bolt glows brighter with the level and the gears turn a little further in each cell. The small blue cloud creature bobs slightly. The hand on her hip, the wings and the tail do not move.',
    'gpt:reading': LEVEL + 'She swipes through the holographic panels: at level 0 her pointing hand and the three panels are exactly as in image 1; at level 3 her finger has swiped a little to the side and the front panel has slid with it, the two panels behind it fanned a bit wider. '
                   'The panels glow brighter with the level. The small blue cloud creature bobs slightly. The wings and the tail do not move.',
    'gpt:working': BEAT + 'She types very fast on the two green holographic keyboards: on beat A the fingers of the hand on the viewer\'s left are pressed down on the keys and the fingers of the other hand are lifted; on beat B the opposite. The keys under the pressed fingers light up. '
                   'In the stacked green code windows the lines of code scroll a little further in each cell. The small blue cloud creature cheers: tiny fists up on beat A, down on beat B. The wings and the tail do not move.',
}
COLS, ROWS, SHEET_SIZE = 3, 2, '1536x1024'


def feet(alpha):
    """脚底在第几行、下半身（最下面 30%）的中心在第几列，都按占画布的比例算。"""
    import numpy as np
    ys, xs = np.nonzero(alpha > 200)
    top, bot = ys.min(), ys.max()
    low = xs[ys > bot - (bot - top) * 0.3]
    return bot / alpha.shape[0], (low.min() + low.max()) / 2 / alpha.shape[1]


def cut_sheet(sheet, base, out_dir):
    """把一张 3×2 的图切成 6 格（frame_00 … frame_05）。几乎看不见的底雾（alpha 很低的一层）清掉；
    每格先整格平移，让脚底和下半身的中心落在和底图一样的位置（模型画在格子里的位置和底图不一样），之后 fit_keys 再细调。"""
    import numpy as np
    from PIL import Image
    a = np.asarray(Image.open(sheet).convert('RGBA')).copy()
    a[a[..., 3] <= 24] = 0
    by, bx = feet(np.asarray(Image.open(base).convert('RGBA'))[..., 3])
    h, w = a.shape[0] // ROWS, a.shape[1] // COLS
    out = []
    for k in range(COLS * ROWS):
        r, c = divmod(k, COLS)
        cell = Image.fromarray(a[r * h:(r + 1) * h, c * w:(c + 1) * w], 'RGBA')
        n = max(h, w)
        cy, cx = feet(np.asarray(cell)[..., 3])
        sq = Image.new('RGBA', (n, n), (0, 0, 0, 0))
        sq.paste(cell, ((n - w) // 2 + round(bx * n - cx * w - (n - w) / 2), (n - h) // 2 + round(by * n - cy * h - (n - h) / 2)))
        p = out_dir / f'frame_{k:02d}.png'
        sq.save(p)
        out.append(p)
    return out


if __name__ == '__main__':
    cmd, work = sys.argv[1], Path(sys.argv[2])
    if cmd == 'bases':
        variants = 'abcdef'[:int(sys.argv[3]) if len(sys.argv) > 3 else 2]
        run_jobs([{'out': str(work / 'base' / f'{key.replace(":", "_")}_{v}.png'), 'inputs': [str(SPR / SKIN[key.split(":")[0]] / f'{key.split(":")[1]}_g00.png')],
                   'prompt': FORM + pose} for key, pose in BASE_POSE.items() for v in variants], 12)
    elif cmd == 'pick':
        for spec in sys.argv[3:]:
            who, phase, v = spec.split(':')
            out = work / f'{who}_{phase}' / 'base.png'
            out.parent.mkdir(parents=True, exist_ok=True)
            # 参考图先缩到 640（App 里素材最大也就这么大），对齐快得多
            from PIL import Image
            ref = out.parent / 'ref.png'
            Image.open(SPR / SKIN[who] / f'{phase}_g00.png').convert('RGBA').resize((640, 640), Image.LANCZOS).save(ref)
            subprocess.run([sys.executable, '-I', str(HERE / 'fit_keys.py'), str(work / 'base' / f'{who}_{phase}_{v}.png'), str(ref), str(out)], check=True)
            print(out)
    elif cmd == 'sheets':
        variants = 'abcdef'[:int(sys.argv[3]) if len(sys.argv) > 3 else 2]
        jobs = []
        for who in SKIN:
            for phase in PHASES:
                d = work / f'{who}_{phase}'
                if (d / 'base.png').exists():
                    jobs += [{'out': str(d / f'sheet_{v}.png'), 'inputs': [str(d / 'base.png')], 'size': SHEET_SIZE,
                              'prompt': SHEET.format(MOVE=MOVE[f'{who}:{phase}'])} for v in variants]
        run_jobs(jobs, 12)
    elif cmd == 'slice':
        # 切开 → 每格对齐到底图（下半身对齐）→ 6 帧统一颜色 → 头钉在同一个位置 → 写进 web/sprites/<皮肤>/<动作>_fast_g00…g05.png
        py = [sys.executable, '-I']
        for spec in sys.argv[3:]:
            who, phase, v = spec.split(':')
            d = work / f'{who}_{phase}'
            for sub in ('cut', 'fit', 'norm'):
                (d / sub).mkdir(exist_ok=True)
            cells = cut_sheet(d / f'sheet_{v}.png', d / 'base.png', d / 'cut')
            fits = [d / 'fit' / f'{phase}_fast_g{k:02d}.png' for k in range(len(cells))]
            with ThreadPoolExecutor(6) as ex:
                for msg in ex.map(lambda cf: subprocess.run(py + [str(HERE / 'fit_keys.py'), str(cf[0]), str(d / 'base.png'), str(cf[1])],
                                                            capture_output=True, text=True).stdout.strip(), zip(cells, fits)):
                    print(' ', msg, flush=True)
            subprocess.run(py + [str(HERE / 'normcolor.py'), str(d / 'norm')] + [str(f) for f in fits], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(py + [str(HERE / 'pin_head.py'), 'apply', str(SPR / SKIN[who])] + [str(d / 'norm' / f.name) for f in fits], check=True)
            # 马尾、特效伸到画布边上被切掉的地方：边上 3% 渐隐，不留一条齐刷刷的切边
            import numpy as np
            from PIL import Image
            for f in fits:
                out = SPR / SKIN[who] / f.name
                im = np.asarray(Image.open(out).convert('RGBA')).astype(np.float32)
                n = im.shape[0]
                ramp = np.clip(np.minimum(np.arange(n), n - 1 - np.arange(n)) / (n * 0.03), 0, 1)
                im[..., 3] *= ramp[None, :] * ramp[:, None]
                Image.fromarray(im.astype(np.uint8), 'RGBA').save(out, optimize=True)
            print(f'{who} {phase}: 写进 {SKIN[who]}/{phase}_fast_g00…g{len(cells) - 1:02d}.png', flush=True)
