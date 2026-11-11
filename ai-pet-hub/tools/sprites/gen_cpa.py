"""通过本地 CPA 反代（tools/rig/imgapi.py，gpt-image-2.6，/v1/images/edits）并发画逐帧素材：一帧一个请求，一起发。
比 gen_loop.sh / gen_keys.sh（codex exec 开对话一帧一帧要，约一分钟一帧）快得多，默认用这个。

用法：python gen_cpa.py <并行数> <任务> [<任务> …]
  任务写成  <皮肤目录>:<动作>:<工作目录>   动作 = sleep | happy | keys
  例：python gen_cpa.py 14 gpt/v2:happy:/tmp/gpt_happy claude/v2:keys:/tmp/claude_keys
  sleep / happy：底图是 sleep.png / happy.png，画 frame_00 … frame_11；之后用 process_loop.sh 处理。
  keys：底图是 idle.png，画 yawn_0、yawn_1、wake_0、wake_1；之后用 process_keys.sh 处理。
  工作目录里已经有的帧跳过（不满意的帧挪走再跑一遍就只重画那几张）。
  睡觉循环如果前面几帧已经有了（比如之前在一个对话里连续画的），缺的帧按「上一张已有的帧 → 第 0 帧」之间的过渡来画，能接回去。

每帧都是在底图上做整图修改：头、身体、位置不动，只改写明的那一点；帧和帧之间靠提示词里写的「第几帧、动到哪」来连贯。
"""
import shutil
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'rig'))
import imgapi  # noqa: E402

SPR = HERE.parent.parent / 'web' / 'sprites'
KEEP = ('Edit image 1. Keep the head position and angle, hair, body, clothes, legs, feet, and the position and size of the whole character '
        'on the canvas EXACTLY the same as image 1 — no nodding, no tilting, no bobbing, no shifting. Change only what is described. ')

# 开心：每位底图的姿势不一样，动的地方分别写。{L} = 这一帧动到几成（0 = 和底图一样，3 = 最大）
HAPPY_MOVE = {
    'gpt': 'She hugs a little blue cloud. Motion level {L} of 3: at level 0 the cloud and her hands are exactly as in image 1; at level 3 she squeezes the cloud '
           '— it is squished about 15% flatter and wider with puffed cheeks, and her hands press slightly inward. In between, proportionally.',
    'claude': 'One hand is raised beside her head. Motion level {L} of 3: at level 0 that hand is exactly as in image 1; at level 3 the hand is open, '
              'palm forward, tilted outward about 25 degrees away from her hair, waving. In between, proportionally. The other hand and the book do not move.',
    'gemini': 'Both fists are raised. Motion level {L} of 3: at level 0 the fists are exactly as in image 1; at level 3 both fists are pumped a little higher '
              '(about 5% of the image height) with the arms straighter, and the tips of her cat ears flick slightly outward. In between, proportionally.',
}
LEVELS = [0, 1, 2, 3, 2, 1, 0, 1, 2, 3, 2, 1]
EYES = ['exactly as in image 1'] * 5 + ['half-way between image 1 and the alternate look'] + \
       ['the alternate look (if her eyes are open in image 1: closed into happy smiling arcs; if they are closed arcs in image 1: wide open and sparkling)'] * 4 + \
       ['half-way between the alternate look and image 1', 'exactly as in image 1']

KEYS = {
    'yawn_0': 'She is sleepy and just starting to yawn: eyes half closed with drooping eyelids, mouth half open, one hand raised to her mouth.',
    'yawn_1': 'The yawn at its biggest: eyes squeezed shut with a tiny teardrop at the corner of one eye, mouth wide open and round, one hand covering in front of her mouth.',
    'wake_0': 'She just woke up and rubs her eye: one hand in a small fist rubbing one eye (that eye closed), the other eye half open and drowsy, mouth small and closed.',
    'wake_1': 'A big stretch: both arms raised straight above her head, eyes closed into happy arcs, mouth slightly open, looking very comfortable.',
}


def jobs_for(skin, action, work):
    work = Path(work)
    work.mkdir(parents=True, exist_ok=True)
    who = skin.split('/')[0]
    base = work / 'base.png'
    shutil.copy(SPR / skin / ('idle.png' if action == 'keys' else f'{action}.png'), base)
    jobs = []
    if action == 'keys':
        for name, what in KEYS.items():
            jobs.append({'out': str(work / f'{name}.png'), 'inputs': [str(base)],
                         'prompt': 'Image 1 is a chibi desktop-pet character standing idle. ' + KEEP + 'Change only the arms, eyes and mouth (plus a tiny emote mark if it fits): ' + what})
    elif action == 'happy':
        for k in range(12):
            jobs.append({'out': str(work / f'frame_{k:02d}.png'), 'inputs': [str(base)],
                         'prompt': f'Image 1 is a chibi desktop-pet character being happy. Draw frame {k} of a 12-frame seamless looping animation of her cheering. ' + KEEP
                                   + HAPPY_MOVE[who].format(L=LEVELS[k]) + f' Eyes: {EYES[k]}. Mouth: smiling, '
                                   + ('open as in image 1' if k % 2 == 0 else 'slightly less open than in image 1')
                                   + f'. The small sparkles / stars / petals around her stay where they are but twinkle: in this frame the {"1st, 3rd, 5th" if k % 2 == 0 else "2nd, 4th, 6th"} ones are bigger and brighter, the others smaller.'})
    elif action == 'sleep':
        have = [k for k in range(12) if (work / f'frame_{k:02d}.png').exists()]
        last = max(have) if 0 in have else None
        for k in range(12):
            if k in have:
                continue
            if last is not None and k > last:
                # 接着已有的帧往回画：第 0 帧和最后一张已有帧之间的过渡
                n = 12 - last
                pct = round((k - last) / n * 100)
                jobs.append({'out': str(work / f'frame_{k:02d}.png'), 'inputs': [str(work / 'frame_00.png'), str(work / f'frame_{last:02d}.png')],
                             'prompt': f'Image 1 is frame 0 and image 2 is frame {last} of a 12-frame seamless looping animation of a sleeping chibi character. '
                                       f'Draw frame {k}: the in-between that is {pct}% of the way from image 2 back to image 1 (the loop returns to frame 0 after frame 11). '
                                       'She stays asleep with eyes closed. ' + KEEP
                                       + 'Only the floating zZZ letters (size, position, opacity), the mouth, and tiny details like the ahoge, the creature on her head, ear tips or tail tip '
                                         f'differ between image 1 and image 2 — move each of those {pct}% of the way from its state in image 2 to its state in image 1.'})
            else:
                t = k / 12
                jobs.append({'out': str(work / f'frame_{k:02d}.png'), 'inputs': [str(base)],
                             'prompt': f'Image 1 is a sleeping chibi desktop-pet character. Draw frame {k} of a 12-frame seamless looping animation of her sleeping peacefully, eyes closed the whole time. ' + KEEP
                                       + f'Only these change: the zZZ letters near her head rise and fade one after another (this frame is {round(t * 100)}% through the cycle: '
                                         'at 0% they are exactly as in image 1; towards 50% each letter has grown a little and drifted slightly up and to the side, the largest one fading; '
                                         'towards 100% they return to image 1); her mouth is '
                                       + ('closed as in image 1' if k < 5 or k > 8 else 'very slightly open, breathing')
                                       + '; the ahoge / ear tips / tail tip / small creature on her head (whichever exist) move a tiny bit. Hands and whatever she holds do not move.'})
    return jobs


if __name__ == '__main__':
    n = int(sys.argv[1])
    jobs = [j for spec in sys.argv[2:] for j in jobs_for(*spec.split(':'))]
    print(f'{len(jobs)} 张，并行 {n}', flush=True)
    with ThreadPoolExecutor(n) as ex:
        for msg in ex.map(imgapi.run, jobs):
            print(msg, flush=True)
