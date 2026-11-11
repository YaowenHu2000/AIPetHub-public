"""鲸鱼娘的循环动作（目前只有 thinking）：照 tools/sprites/gen_fast.py 的做法，走 CPA 并发出图。
12 帧 = 两段各 6 帧，每段让模型一次画在一张 3×2 的图里（帧和帧之间细节一致），两段都从同一张底图起头、都回到底图，所以能接上。

  python gen_loop.py base   <工作目录> [几张备选]      以 master.png 为参考画这个动作的底图（<工作目录>/base/thinking_a.png …）
  python gen_loop.py pick   <工作目录> a               挑一张，对齐到母版（下半身对齐），存成 <工作目录>/thinking/base.png（640）
  python gen_loop.py sheets <工作目录> [几张备选]      画两段的整图 <工作目录>/thinking/sheet_A_a.png、sheet_B_a.png …
  python gen_loop.py slice  <工作目录> A:a B:b <输出目录>   切开、对齐、统一颜色、钉头，写 <输出目录>/thinking_g00…g11.png
pick / slice 要 pillow、numpy、scipy。
"""
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOLS = HERE.parent
sys.path.insert(0, str(TOOLS.parent / 'rig'))
sys.path.insert(0, str(TOOLS))
import imgapi  # noqa: E402

PHASE = 'thinking'
BASE = ('Image 1 is a chibi desktop-pet character: a whale-girl maid. Redraw her THINKING — the same character, same outfit, same art style, same chibi proportions, '
        'standing at exactly the same position and size on the canvas, with the head position and angle, hair, headband, bow, whale-fin ears, dress, apron, whale tail, legs and feet unchanged. '
        'Change only these: her right hand (on the viewer\'s left) is raised with the index finger touching her chin, the other arm rests across her waist; '
        'her eyes look up and to one side with a curious little pout; '
        'and next to the ahoge on top of her head, like a whale\'s blowhole, a small light-blue water spout squirts straight up (short, about one sixth of the head height) and splits into two little droplets, '
        'with three small round soap-bubble-like water bubbles of different sizes floating beside it above her head; the biggest bubble has a tiny "?" inside. '
        'Everything stays fully inside the canvas with a margin at the top.')
SHEET = ('Image 1 is a chibi desktop-pet character, a whale-girl maid, in her thinking pose. Make a SPRITE SHEET of a 6-frame looping animation of her thinking: '
         'a strict grid of 3 columns x 2 rows of equal square cells on a fully transparent background — no grid lines, no borders, no text, no numbers, no shadows, no background glow. '
         'Every cell shows the SAME character as image 1, at the same size and at the same position inside its cell, fully inside the cell with a margin: '
         'the hair, the whale tail, the water spout and the bubbles must not touch or cross into neighbouring cells. '
         'The head position and angle, the face shape, the hair, the ahoge, the maid headband, the bow, the whale-fin ears, the body, the dress, the apron, the whale tail, the legs and the feet are IDENTICAL in all six cells. '
         'Only these things change from cell to cell: {MOVE} '
         'Cells are numbered in reading order: left to right, top row first.')
LEVEL = 'The cells use motion level 0, 1, 2, 3, 2, 1 in reading order — level 0 is exactly image 1 and level 3 is the extreme, so the animation loops seamlessly. '
MOVE = {
    'A': LEVEL + 'The little water spout beside her ahoge: at level 0 it is exactly as in image 1; at level 3 its two droplets have spread wider apart sideways and a third tiny droplet has appeared between them — the spout does NOT get taller. '
                 'The three bubbles above her head: at level 0 exactly as in image 1; at level 3 each has drifted sideways, away from the spout, by about half its own diameter and grown slightly — they do NOT move upward. The "?" stays in the biggest bubble. '
                 'Nothing may ever be higher in the cell than the top of the biggest bubble in image 1. '
                 'Her index finger taps her chin: at level 0 it touches the chin as in image 1; at level 3 the fingertip is lifted slightly away from the chin. The arm across her waist does not move. '
                 'Eyes: exactly as in image 1 in cells 1, 2, 3, 4 and 6; closed in a quick blink in cell 5.',
    'B': LEVEL + 'The little water spout beside her ahoge: at level 0 it is exactly as in image 1; at level 3 it has shrunk to a tiny dribble, almost gone. '
                 'The three bubbles above her head: at level 0 exactly as in image 1; at level 3 the smallest bubble has popped into three tiny sparkle marks and the other two have drifted slightly to the side; the "?" in the biggest bubble has become a "!" at level 3 only. '
                 'Her eyes: at level 0 exactly as in image 1; at level 3 they look to the opposite side. Her mouth: at level 3 a tiny open "o". '
                 'The finger on her chin and the arm across her waist do not move. No blink in this sheet.',
}
COLS, ROWS, SHEET_SIZE = 3, 2, '1536x1024'


def run_jobs(jobs, n=12):
    with ThreadPoolExecutor(n) as ex:
        for msg in ex.map(imgapi.run, jobs):
            print(msg, flush=True)


if __name__ == '__main__':
    cmd, work = sys.argv[1], Path(sys.argv[2])
    d = work / PHASE
    py = [sys.executable, '-I']
    if cmd == 'base':
        variants = 'abcdef'[:int(sys.argv[3]) if len(sys.argv) > 3 else 2]
        run_jobs([{'out': str(work / 'base' / f'{PHASE}_{v}.png'), 'inputs': [str(HERE / 'master.png')], 'prompt': BASE} for v in variants])
    elif cmd == 'pick':
        from PIL import Image
        d.mkdir(parents=True, exist_ok=True)
        Image.open(HERE / 'master.png').convert('RGBA').resize((640, 640), Image.LANCZOS).save(d / 'ref.png')
        subprocess.run(py + [str(TOOLS / 'fit_keys.py'), str(work / 'base' / f'{PHASE}_{sys.argv[3]}.png'), str(d / 'ref.png'), str(d / 'base.png')], check=True)
    elif cmd == 'sheets':
        variants = 'abcdef'[:int(sys.argv[3]) if len(sys.argv) > 3 else 2]
        run_jobs([{'out': str(d / f'sheet_{seg}_{v}.png'), 'inputs': [str(d / 'base.png')], 'size': SHEET_SIZE, 'prompt': SHEET.format(MOVE=MOVE[seg])}
                  for seg in MOVE for v in variants])   # 已有的跳过：不满意的挪走再跑
    elif cmd == 'slice':
        from gen_fast import cut_sheet  # 切格 + 整格平移到底图的脚底位置
        picks, out = sys.argv[3:-1], Path(sys.argv[-1])
        out.mkdir(parents=True, exist_ok=True)
        fits = []
        for i, spec in enumerate(picks):
            seg, v = spec.split(':')
            for sub in (f'cut_{seg}', 'fit', 'norm'):
                (d / sub).mkdir(exist_ok=True)
            cells = cut_sheet(d / f'sheet_{seg}_{v}.png', d / 'base.png', d / f'cut_{seg}')
            seg_fits = [d / 'fit' / f'{PHASE}_g{i * 6 + k:02d}.png' for k in range(len(cells))]
            with ThreadPoolExecutor(6) as ex:
                for msg in ex.map(lambda cf: subprocess.run(py + [str(TOOLS / 'fit_keys.py'), str(cf[0]), str(d / 'base.png'), str(cf[1])],
                                                            capture_output=True, text=True).stdout.strip(), zip(cells, seg_fits)):
                    print(' ', msg, flush=True)
            fits += seg_fits
        subprocess.run(py + [str(TOOLS / 'normcolor.py'), str(d / 'norm')] + [str(f) for f in fits], check=True)
        subprocess.run(py + [str(TOOLS / 'pin_head.py'), 'apply', str(out)] + [str(d / 'norm' / f.name) for f in fits], check=True)
