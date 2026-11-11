"""用 APIMart 生成 GIF 动画（只用来出 GIF；单张图走本地 CPA 的 imgapi.py）。

用法：APIMART_KEY=… python gifapi.py jobs.json [并行数]
  jobs.json：[{"out": "x.gif", "prompt": "…", "refs": ["参考图.png", …], "frames": 12, "size": "768x768"}, …]
模型 gpt-image-2.6-flare，quality=high，透明背景。
GIF 是模型先在一张图上画好所有帧（12 帧 4×3、8 帧 4×2…，整张每边不超过 3840），再切成帧，所以帧和帧之间很一致；
但 GIF 本身只有 256 色、透明只有全透明 / 不透明两种。
"""
import base64
import json
import os
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

KEY = os.environ['APIMART_KEY']
H = {'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json'}


def call(url, data=None):
    try:
        return json.load(urllib.request.urlopen(urllib.request.Request(url, data=data, headers=H), timeout=180))
    except urllib.error.HTTPError as e:
        return {'http': e.code, 'body': e.read()[:600].decode('utf8', 'ignore')}
    except Exception as e:  # noqa: BLE001
        return {'error': str(e)}


def run(job):
    out = Path(job['out'])
    if out.exists() and out.stat().st_size:
        return f'{out.name}: 已有'
    body = {'model': 'gpt-image-2.6-flare', 'prompt': job['prompt'], 'quality': 'high', 'n': 1,
            'output_format': 'gif', 'background': 'transparent', 'size': job.get('size', '768x768'),
            'frame_count': job.get('frames', 12)}
    if job.get('refs'):
        body['image_urls'] = ['data:image/png;base64,' + base64.b64encode(open(p, 'rb').read()).decode() for p in job['refs']]
    for attempt in range(3):
        t0 = time.time()
        d = call('https://api.apimart.ai/v1/images/generations', json.dumps(body).encode())
        try:
            tid = d['data'][0]['task_id']
        except Exception:  # noqa: BLE001
            msg = json.dumps(d, ensure_ascii=False)[:200]
            time.sleep(10)
            continue
        r, st = {}, None
        while time.time() - t0 < 1200:
            time.sleep(8)
            r = call(f'https://api.apimart.ai/v1/tasks/{tid}')
            st = (r.get('data') or {}).get('status')
            if st in ('completed', 'failed', 'cancelled'):
                break
        if st != 'completed':
            msg = f'任务 {st}'
            continue
        urls = []
        for im in (r['data'].get('result') or {}).get('images', []):
            u = im.get('url')
            urls += u if isinstance(u, list) else [u]
        if not urls:
            msg = '没有结果'
            continue
        out.parent.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(urls[0], out)
        cost = r['data'].get('cost')
        return f'{out.name}: ok（{round(time.time() - t0)}s，${cost}）'
    return f'{out.name}: 失败 {msg}'


if __name__ == '__main__':
    jobs = json.load(open(sys.argv[1]))
    with ThreadPoolExecutor(int(sys.argv[2]) if len(sys.argv) > 2 else 7) as ex:
        for m in ex.map(run, jobs):
            print(m, flush=True)
