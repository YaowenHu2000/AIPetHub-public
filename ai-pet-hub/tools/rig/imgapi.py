"""通过本地的 OpenAI 兼容生图代理（比如 CLIProxyAPI，下面简称 CPA）并行出图：在整张图上做修改（分层美术、表情、姿势）。

用法（命令行）：python imgapi.py jobs.json [并行数]
  jobs.json：[{"out": "输出.png", "inputs": ["输入1.png", …], "prompt": "…", "check": "master.png"(可选), "size": "2048x2048"(可选，默认 1024x1024)}, …]
  已经有输出文件的任务跳过；每张最多重试 4 次。

质量：每次都要 quality=high（目前上游实际都返回 medium、1254 像素，实际质量记在每张图旁边的 .json 里）。
模型：默认 gpt-image-2.6-sunburst（速度最快）；可用 CPA_IMAGE_MODEL 换成 gpt-image-2.6-flare 等。
检查（给了 check 时）：用特征点把结果对齐到 check 图，内点太少（画走样、换了构图）就重画。
环境变量：CPA_URL、CPA_KEY、CPA_MODEL（Responses 用的对话模型）、CPA_IMAGE_MODEL（images 接口的生图模型）。
也可以写在同目录的 cpa.local 里（每行 名字=值，不进仓库）。没有 CPA_KEY 时不能用。
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

def _local_setting(name, default=''):
    """先看环境变量，再看本机的 tools/rig/cpa.local（每行 名字=值，已加进 .gitignore，不进仓库）。"""
    if os.environ.get(name):
        return os.environ[name]
    f = Path(__file__).with_name('cpa.local')
    if f.exists():
        for line in f.read_text().splitlines():
            k, _, v = line.partition('=')
            if k.strip() == name and v.strip():
                return v.strip()
    return default


URL = _local_setting('CPA_URL', 'http://127.0.0.1:8317')
KEY = _local_setting('CPA_KEY')
CHAT_MODEL = os.environ.get('CPA_MODEL', 'gpt-5.6-sol')
IMAGE_MODEL = os.environ.get('CPA_IMAGE_MODEL', 'gpt-image-2.6-sunburst')
SUFFIX = ' Keep exactly the same art style, line art, coloring, character design and canvas composition. Transparent background, no shadow, no ground.'


def _post(path, body, headers, timeout=900):
    req = urllib.request.Request(URL + path, data=body, headers={'Authorization': 'Bearer ' + KEY, **headers})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def via_responses(inputs, prompt):
    content = [{'type': 'input_text', 'text': 'Use the image generation tool. ' + prompt + SUFFIX}]
    for p in inputs:
        content.append({'type': 'input_image', 'image_url': 'data:image/png;base64,' + base64.b64encode(open(p, 'rb').read()).decode()})
    body = {'model': CHAT_MODEL, 'input': [{'role': 'user', 'content': content}],
            'tools': [{'type': 'image_generation', 'quality': 'high', 'size': '1024x1024', 'background': 'transparent', 'output_format': 'png'}],
            'tool_choice': {'type': 'image_generation'}, 'stream': False}
    d = _post('/v1/responses', json.dumps(body).encode(), {'Content-Type': 'application/json'})
    for o in d.get('output', []):
        if o.get('type') == 'image_generation_call' and o.get('result'):
            return base64.b64decode(o['result']), {'path': 'responses', 'quality': o.get('quality'), 'size': o.get('size')}
    raise RuntimeError('responses 没有返回图片: ' + json.dumps(d)[:300])


def via_images(inputs, prompt, mask=None, size='1024x1024'):
    b = uuid.uuid4().hex
    parts = []
    def field(name, value):
        parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    def file(name, path):
        parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{name}"; filename="{Path(path).name}"\r\nContent-Type: image/png\r\n\r\n'.encode() + open(path, 'rb').read() + b'\r\n')
    for k, v in (('model', IMAGE_MODEL), ('quality', 'high'), ('background', 'transparent'), ('size', size), ('output_format', 'png'), ('prompt', prompt + SUFFIX)):
        field(k, v)
    for p in inputs:
        file('image[]', p)
    if mask:
        file('mask', mask)
    parts.append(f'--{b}--\r\n'.encode())
    d = _post('/v1/images/edits', b''.join(parts), {'Content-Type': f'multipart/form-data; boundary={b}'})
    if 'data' not in d:
        raise RuntimeError('images 没有返回图片: ' + json.dumps(d)[:300])
    return base64.b64decode(d['data'][0]['b64_json']), {'path': 'images', 'quality': d.get('quality'), 'size': d.get('size')}


def check(out, ref):
    sys.path.insert(0, str(Path(__file__).parent))
    from segment import register, rgba
    M = rgba(ref)
    _, n = register(rgba(out, M.shape[0]), M, min_inliers=1)
    return n


def run(job):
    out = Path(job['out'])
    if out.exists() and out.stat().st_size > 0:
        return f'{out.name}: 已有，跳过'
    out.parent.mkdir(parents=True, exist_ok=True)
    log = []
    for attempt in range(4):
        t = time.time()
        # CPA 更新后 Responses 路线不能再强制出图，只走 images/edits；每次都要 quality=high（上游实际给什么会记在 .json 里）
        for fn in (via_images,):
            try:
                img, info = fn(job['inputs'], job['prompt']) if fn is via_responses else fn(job['inputs'], job['prompt'], job.get('mask'), job.get('size', '1024x1024'))
                break
            except Exception as e:  # noqa: BLE001
                msg = e.read()[:200].decode('utf8', 'ignore') if isinstance(e, urllib.error.HTTPError) else str(e)[:200]
                log.append(f'{fn.__name__} 失败：{msg}')
                img = None
        if img is None:
            time.sleep(20 * (attempt + 1))
            continue
        tmp = out.with_suffix('.tmp.png')
        tmp.write_bytes(img)
        if job.get('check'):
            n = check(tmp, job['check'])
            if n < job.get('min_inliers', 120):
                log.append(f'第 {attempt + 1} 次对不上原图（内点 {n}），重画')
                continue
            info['inliers'] = n
        tmp.rename(out)
        json.dump({**info, 'seconds': round(time.time() - t), 'prompt': job['prompt'], 'log': log}, open(out.with_suffix('.json'), 'w'), ensure_ascii=False, indent=1)
        return f"{out.name}: ok（{info['path']}，质量 {info.get('quality')}，{info.get('size')}，内点 {info.get('inliers', '-')}，{round(time.time() - t)}s）"
    return f'{out.name}: 失败 ' + ' | '.join(log[-3:])


if __name__ == '__main__':
    jobs = json.load(open(sys.argv[1]))
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 8
    with ThreadPoolExecutor(n) as ex:
        for msg in ex.map(run, jobs):
            print(msg, flush=True)
