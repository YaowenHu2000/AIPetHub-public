"""鲸鱼娘整套逐帧素材的出图（走 CPA，tools/rig/imgapi.py）。所有图只以 master.png（以及由它画出来的底图 / 整图）为输入。

  python3 gen_set.py bases   <工作目录> [并行数]     各动作的底图（<工作目录>/base/<动作>_a.png、_b.png）和单张（single/<名字>_a.png …）
  python3 gen_set.py sheetsA <工作目录> [并行数]     各循环的前半段 3×2 整图（要先有 <工作目录>/<动作>/base.png，见 post_set.py pick）
  python3 gen_set.py sheetsB <工作目录> [并行数]     后半段：image 1 = 底图，image 2 = 挑好的前半段整图（<动作>/sheet_A.png），线条照着它画，压接缝
已经有的输出会跳过：不满意的挪走再跑。后处理见 post_set.py。
"""
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / 'rig'))
import imgapi  # noqa: E402

MASTER = str(HERE / 'master.png')
WHO = 'a chibi desktop-pet character: a whale-girl maid (dark navy hair fading to blue, white maid headband, light-blue bow, whale-fin ears, navy maid dress, white apron with a blue whale emblem, a whale tail)'
KEEP = (f'Image 1 is {WHO}, standing idle. Redraw her as described — the same character, same outfit, same art style, same chibi proportions, '
        'standing at exactly the same position and size on the canvas. The head position and angle, the hair, the ahoge, the headband, the bow, the whale-fin ears, the dress, the apron, the legs and the feet stay EXACTLY as in image 1 unless stated. '
        'Nothing may be higher than the tip of her ahoge in image 1 and nothing may touch the canvas edges: any effects, bubbles, letters or raised hands go BESIDE her head (upper left / upper right), never above it. '
        'Hands are small simple chibi hands with one thumb and four fingers. Change only this: ')
FAST = ('She is in her "FAST / torrent mode" — clearly the same character and outfit, legs and feet unchanged, but her form changes: her long hair streams out horizontally to the viewer\'s right as if blown by a strong headwind '
        '(it must stay inside the canvas); her eyes are sharp, bright and determined with a confident little smile; her whale-fin ears and the tips of her hair glow aqua; '
        'a thin ring of rushing water with splashes swirls around her waist and a few short horizontal aqua speed lines and droplets trail to the right. ')

# 循环动作：底图怎么画 + 两段各动什么（按幅度 0-3 或 A/B 拍）
LEVEL = 'The cells use motion level 0, 1, 2, 3, 2, 1 in reading order — level 0 is exactly image 1 and level 3 is the extreme, so the animation loops seamlessly. '
BEAT = 'The cells alternate beat A, B, A, B, A, B in reading order (beat A is exactly image 1), so the animation loops seamlessly. '
LOOPS = {
    'thinking': {
        'base': None,   # 已有（第一步试做的）
        'A': None,
        'B': LEVEL + 'The little water spout beside her ahoge: at level 0 exactly as in image 1; at level 3 it has shrunk to a tiny dribble, almost gone. '
                     'The three bubbles: at level 0 exactly as in image 1; at level 3 the smallest bubble has popped into three tiny sparkle marks and the other two have drifted slightly sideways (NOT upward); the "?" in the biggest bubble becomes a "!" at level 3 only. '
                     'Her eyes: at level 0 exactly as in image 1; at level 3 they look to the opposite side. Her mouth: at level 3 a tiny open "o". The finger on her chin and the arm across her waist do not move. No blink.',
    },
    'reading': {
        'base': 'she holds an open navy-blue hardcover book with both hands in front of her chest and reads it, eyes looking down at the pages with a small interested smile; '
                'two small round light-blue water bubbles float beside her head at the upper right, the bigger one with three tiny text lines inside.',
        'A': LEVEL + 'She turns a page: at level 0 the book and hands are exactly as in image 1; at level 3 the right-hand page is lifted half-way, standing up in the middle of the book, with her fingertip under it. '
                     'Her eyes: at level 0 looking at the left page, at level 3 looking at the right page. The two bubbles drift sideways by up to half their diameter with the level. Eyes closed in a quick blink in cell 5 only.',
        'B': LEVEL + 'She reads on: the book and her hands do not move. Her eyes: at level 0 exactly as in image 1; at level 3 wide and sparkling with a tiny open-mouth "oh!". '
                     'A third tiny bubble appears beside the two bubbles at level 1 and grows until level 3, and a small "!" appears inside the bigger bubble at level 3 only (replacing the text lines). No blink.',
    },
    'working': {
        'base': 'she types with both hands on a translucent light-blue holographic keyboard floating at waist height in front of her, fingers on the keys, looking down at it with a focused, slightly determined face; '
                'a small translucent light-blue holographic code window with a few lines floats beside her at the upper left, and three small water droplets splash up from the keyboard.',
        'A': BEAT + 'She types fast: on beat A the fingers of the hand on the viewer\'s left are pressed down on the keys and the fingers of the other hand are lifted; on beat B the opposite. The keys under the pressed fingers glow brighter. '
                    'The water droplets above the keyboard are in different places on beat A and beat B. In the code window one more line of code appears in each cell. Eyes closed in a quick blink in cell 5 only.',
        'B': BEAT + 'She types fast: on beat A the fingers of the hand on the viewer\'s left are pressed down on the keys and the fingers of the other hand are lifted; on beat B the opposite. The keys under the pressed fingers glow brighter. '
                    'The water droplets above the keyboard are in different places on beat A and beat B. The code window scrolls: its lines shift up a little in each cell. In cells 3 and 4 she glances up at the code window; otherwise her eyes are as in image 1. No blink.',
    },
    'happy': {
        'base': 'she is very happy: one arm (on the viewer\'s right) is raised with the open hand waving beside her head, the other hand is a small fist held at her chest; her eyes are closed into happy arcs, mouth open in a big smile; '
                'her whale tail is lifted up at her side, wagging; two small blue music notes and three small sparkles float at her sides.',
        'A': LEVEL + 'She waves: at level 0 the raised hand is exactly as in image 1; at level 3 the open hand is tilted about 25 degrees outward, away from her head. '
                     'The whale tail wags: at level 0 as in image 1, at level 3 its fluke is swung a little further outward and up. The music notes and sparkles twinkle: bigger in cells 1, 3, 5, smaller in cells 2, 4, 6. Eyes stay closed in happy arcs.',
        'B': LEVEL + 'She cheers: at level 0 the raised hand and the fist are exactly as in image 1; at level 3 the fist at her chest is pumped up to shoulder height and the raised hand is tilted about 15 degrees outward. '
                     'Her eyes: happy closed arcs in cells 1, 2, 6; wide open and sparkling in cells 3, 4, 5. The whale tail wags a little with the level. The music notes and sparkles twinkle: bigger in cells 2, 4, 6, smaller in cells 1, 3, 5.',
    },
    'sleep': {
        'base': 'she is asleep standing: eyes closed peacefully, a tiny relaxed smile, hugging a small round blue whale plush toy with a white belly to her chest with both arms; '
                'three letters "z Z Z" of increasing size float beside her head at the upper right.',
        'A': LEVEL + 'She sleeps, eyes closed in every cell. The "z Z Z" letters: at level 0 exactly as in image 1; at level 3 each letter has grown slightly and drifted a little sideways and the largest one is half faded. '
                     'Her mouth: closed at levels 0 and 1, very slightly open at levels 2 and 3. The whale plush is squeezed a tiny bit flatter at level 3. Arms do not move.',
        'B': LEVEL + 'She sleeps, eyes closed in every cell. The "z Z Z" letters: at level 0 exactly as in image 1; at level 3 the smallest letter is gone and the other two have drifted a little sideways. '
                     'A small round snot-bubble-like water bubble at the tip of her ahoge: absent at level 0, tiny at level 1, medium at level 2, biggest at level 3 (it stays beside the ahoge, not above it). Mouth closed. Arms and plush do not move.',
    },
    'dragged': {
        'base': 'she dangles in the air as if lifted by an invisible string (do NOT draw any hand, finger, string or anything holding her; her head and hair are exactly as in image 1): both arms are raised outward to the sides at shoulder height with open hands, flailing; her eyes are squeezed shut like "> <" with a wavy, whimpering mouth and a small teardrop at the corner of one eye; '
                'her feet hang with the toes pointing down; her whale tail sticks out stiffly to the side; two small sweat drops fly off beside her head.',
        'A': BEAT + 'She flails: on beat A the arm on the viewer\'s left is higher and the arm on the viewer\'s right is lower; on beat B the opposite (each moves about 20 degrees). '
                    'On beat A the foot on the viewer\'s left is lifted slightly; on beat B the other foot. The sweat drops are in different places on beat A and beat B. The eyes stay squeezed shut.',
        'B': BEAT + 'She flails: on beat A the arm on the viewer\'s left is higher and the arm on the viewer\'s right is lower; on beat B the opposite (each moves about 20 degrees). '
                    'On beat A the foot on the viewer\'s left is lifted slightly; on beat B the other foot. The whale tail flaps: up on beat A, down on beat B. In cells 3 and 4 one eye peeks half open; otherwise the eyes stay squeezed shut.',
    },
    'thinking_fast': {
        'base': FAST + 'Pose: one hand raised beside her head with the index finger pointing up in a quick "got it!" gesture, the other hand on her hip. A round water bubble beside her head at the upper left contains a bold "!!".',
        'A': LEVEL + 'Her raised index finger wags: at level 0 exactly as in image 1; at level 3 the finger is tilted about 25 degrees outward. The "!!" in the bubble grows slightly with the level. '
                     'The ring of water spins: its splashes are in a different place in every cell. The speed lines flicker (long in cells 1, 3, 5; short in cells 2, 4, 6) and only the far tips of the streaming hair flutter. Eyes closed in a quick blink in cell 5 only.',
    },
    'reading_fast': {
        'base': FAST + 'Pose: she speed-reads an open navy-blue book held in one hand at chest height while the other hand flips a page so fast that three or four pages fan out in mid-turn; her eyes look down at the book. Three small loose pages whip past in the wind to the right.',
        'A': LEVEL + 'She flips pages fast: at level 0 the fan of turning pages and the flipping hand are exactly as in image 1; at level 3 the turning pages have swept over to the other side of the book and the flipping hand has followed them. '
                     'The loose pages flying beside her each rotate a few degrees more with the level. The ring of water spins: its splashes are in a different place in every cell. Only the far tips of the streaming hair flutter. Eyes closed in a quick blink in cell 5 only.',
    },
    'working_fast': {
        'base': FAST + 'Pose: she types at high speed with both hands, arms spread a little, on TWO translucent aqua holographic keyboards, one under each hand, at waist height; four small aqua code windows are stacked beside her at the upper left; water droplets splash up from the keys.',
        'A': BEAT + 'She types very fast: on beat A the fingers of the hand on the viewer\'s left are pressed down and the fingers of the other hand are lifted; on beat B the opposite. The keys under the pressed fingers light up. '
                    'In the code windows the lines scroll a little further in each cell. The droplets and the splashes of the water ring are in different places on beat A and beat B. Only the far tips of the streaming hair flutter. Eyes closed in a quick blink in cell 5 only.',
    },
}
SINGLES = {
    'idle_blink_half': 'her eyes are half closed, the upper eyelids lowered half-way (a blink in progress). Nothing else changes at all.',
    'idle_blink_closed': 'her eyes are fully closed, drawn as two gentle downward-curved lash lines (a blink). Nothing else changes at all.',
    'crouch': 'she ducks a little as if settling down: her eyes are half closed and sleepy, her shoulders drop slightly and both hands come together in front of her apron. The head, legs and feet do not move.',
    'yawn_0': 'only the arms, eyes and mouth: she is sleepy and just starting to yawn — eyes half closed with drooping eyelids, mouth half open, one hand raised to her mouth.',
    'yawn_1': 'only the arms, eyes and mouth: the yawn at its biggest — eyes squeezed shut with a tiny teardrop at the corner of one eye, mouth wide open and round, one hand covering in front of her mouth.',
    'wake_0': 'only the arms, eyes and mouth: she just woke up and rubs her eye — one hand in a small fist rubbing one eye (that eye closed), the other eye half open and drowsy, mouth small and closed.',
    'wake_1': 'only the arms, eyes and mouth: a big stretch — both arms raised up and outward in a V beside her head (the fists stay below the tip of her ahoge), eyes closed into happy arcs, mouth slightly open, looking very comfortable.',
}
WALK = (f'Image 1 is {WHO}, standing idle, front view. Make a SPRITE SHEET of her walking on the spot towards the viewer: '
        'a strict grid of 3 columns x 2 rows of equal square cells on a fully transparent background — no grid lines, no borders, no text, no numbers, no shadows. '
        'Every cell shows the SAME character as image 1, front view, at the same size and at the same position inside its cell, fully inside the cell with a margin; nothing touches or crosses into neighbouring cells. '
        'The head, face, hair, headband, bow, whale-fin ears, dress and apron are IDENTICAL in all six cells. Only the feet, the arms and the whale tail change: '
        'cell 1: both feet on the ground, arms at her sides, exactly image 1. '
        'cell 2: the foot on the viewer\'s LEFT is lifted a little (heel up), the arm on the viewer\'s right swings slightly forward. '
        'cell 3: the foot on the viewer\'s LEFT is lifted highest (clearly off the ground, knee slightly bent), the arm swing at its largest, the whale tail swung slightly to one side. '
        'cell 4: both feet on the ground, arms at her sides, exactly image 1. '
        'cell 5: the foot on the viewer\'s RIGHT is lifted a little, the arm on the viewer\'s left swings slightly forward. '
        'cell 6: the foot on the viewer\'s RIGHT is lifted highest, the arm swing at its largest, the whale tail swung slightly to the other side. '
        'Cells are numbered in reading order: left to right, top row first.')
SHEET = ('Image 1 is {WHO_POSE}. Make a SPRITE SHEET of a 6-frame looping animation of her: '
         'a strict grid of 3 columns x 2 rows of equal square cells on a fully transparent background — no grid lines, no borders, no text, no numbers, no shadows, no background glow. '
         'Every cell shows the SAME character as image 1, at the same size and at the same position inside its cell, fully inside the cell with a clear margin on all four sides: '
         'the hair, the whale tail, the props and the effects must not touch or cross into neighbouring cells, and nothing is ever higher in its cell than the highest point of image 1. '
         'The head position and angle, the face shape, the hair, the ahoge, the maid headband, the bow, the whale-fin ears, the body, the dress, the apron and the whale tail (unless stated) are IDENTICAL in all six cells. '
         '{REF}Only these things change from cell to cell: {MOVE} '
         'Cells are numbered in reading order: left to right, top row first.')
REF_B = ('Image 2 is the sprite sheet of the FIRST half of this same animation, already finished. Draw the character with exactly the same line art, the same hair curls, the same colours, '
         'the same size and the same position inside each cell as in image 2, so that the two sheets can be played one after the other without any visible change. ')


def who_pose(name):
    return f'{WHO}, in her {name.replace("_", " ")} pose'


if __name__ == '__main__':
    cmd, work = sys.argv[1], Path(sys.argv[2])
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 8
    jobs = []
    if cmd == 'bases':
        for name, spec in LOOPS.items():
            if spec['base']:
                jobs += [{'out': str(work / 'base' / f'{name}_{v}.png'), 'inputs': [MASTER], 'prompt': KEEP + spec['base']} for v in 'ab']
        for name, what in SINGLES.items():
            jobs += [{'out': str(work / 'single' / f'{name}_{v}.png'), 'inputs': [MASTER], 'prompt': KEEP + what} for v in 'ab']
        jobs += [{'out': str(work / 'walk' / f'sheet_{v}.png'), 'inputs': [MASTER], 'size': '1536x1024', 'prompt': WALK} for v in 'ab']
    elif cmd in ('sheetsA', 'sheetsB'):
        seg = cmd[-1]
        for name, spec in LOOPS.items():
            d = work / name
            if not spec.get(seg) or not (d / 'base.png').exists():
                continue
            if seg == 'B' and not (d / 'sheet_A.png').exists():
                continue
            jobs += [{'out': str(d / f'sheet_{seg}_{v}.png'), 'inputs': [str(d / 'base.png')] + ([str(d / 'sheet_A.png')] if seg == 'B' else []), 'size': '1536x1024',
                      'prompt': SHEET.format(WHO_POSE=who_pose(name), REF=REF_B if seg == 'B' else '', MOVE=spec[seg])} for v in 'ab']
    print(f'{len(jobs)} 个请求，并行 {n}', flush=True)
    with ThreadPoolExecutor(n) as ex:
        for msg in ex.map(imgapi.run, jobs):
            print(msg, flush=True)
