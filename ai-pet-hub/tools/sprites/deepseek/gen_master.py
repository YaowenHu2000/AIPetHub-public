"""母版：按用户给的设定图（ref/sheet.png，只在本机当参考）画正面站姿，画风往克劳蒂娜 / 吉佩缇的母版靠。
用法：python3 gen_master.py <输出目录> [备选字母，默认 abc]"""
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / 'tools/rig'))
import imgapi
imgapi.SUFFIX = ' Fully transparent background, no shadow, no ground, no text, no watermark, no logo.'
OUT = Path(sys.argv[1]); N = sys.argv[2] if len(sys.argv) > 2 else 'abc'
REFS = [str(ROOT / 'web/lab/rig/claude/master.png'), str(ROOT / 'web/lab/rig/gpt/master.png'), str(HERE / 'ref/sheet.png')]
PROMPT = ('Image 3 is a character design sheet of a chibi whale-girl maid (front, side and back views, expressions, details). '
          'Images 1 and 2 are two existing chibi desktop-pet mascot girls from the set she is joining. '
          'Draw ONE new illustration of the character from image 3, front view, for this set. '
          'CHARACTER: exactly the character of image 3 (use its "Front View" and "Details"): long wavy very dark navy hair down to her thighs whose lower part fades to bright blue; '
          'slightly messy bangs with one lock falling between the eyes; one big curled ahoge on top; a white frilly maid headband; one small light-blue bow on the side of her head (on the viewer\'s right); '
          'a pair of whale-fin ears sticking out sideways at ear level, dark navy outside and white inside, one on each side; big blue eyes, round face, blush; '
          'a dark navy long-sleeved maid dress with thin gold trim lines and small gold bows on the skirt, white collar, a tiny dark bow at the neck, white frilled cuffs and white frilled petticoat hem; '
          'a white frilled apron with a blue spouting-whale emblem in the middle; white socks; dark navy mary-jane shoes; '
          'a dark navy whale tail with a pale underside and a HORIZONTAL fluke coming out from behind the skirt, visible beside her legs at one side. '
          'STYLE: render her in the art style of images 1 and 2 — the same crisp dark outlines, the same glossy cel shading with bright highlights in the hair, the same saturated colours, '
          'the same big sparkling detailed eyes, the same 2.5-heads-tall proportions (big head, small body, tiny feet) and the same level of detail, so that she looks drawn by the same artist as images 1 and 2. '
          'Not the soft pastel watercolour look of image 3. '
          'POSE: standing straight and naturally, facing the viewer, both arms hanging relaxed at her sides with the hands empty and visible, head upright, a gentle neutral closed-mouth smile, eyes open looking at the viewer. '
          'Hands: small simple chibi hands, one thumb and four fingers each. '
          'CANVAS: one single character only, full body, centered on a square canvas at the same size and position as the character in image 1 '
          '(top of the ahoge about 6% from the top edge, soles of the shoes about 4% from the bottom edge, empty margins left and right; nothing touches or is cut by the canvas edges). '
          'No text, no labels, no panels, no music notes, no other views.')
jobs = [{'out': str(OUT / f'm_{v}.png'), 'inputs': REFS, 'prompt': PROMPT} for v in N]
with ThreadPoolExecutor(6) as ex:
    for m in ex.map(imgapi.run, jobs): print(m, flush=True)
