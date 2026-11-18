#!/usr/bin/env python3
"""核心矩阵与可机器读取的汇总。八套同时跑，最长的先开（总时长约等于最慢的一套）。
每次运行用自己的 App 副本、会话清单和结果目录，跑完只清自己的测试会话；
两个 agent 同时跑，或跑的时候有人重新 ./build.sh，都不会互相踩。"""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
FINAL = ROOT / 'build/uitest-results'   # 跑完把这次的结果整份放到这里
OUT = FINAL                              # main() 里换成这次运行自己的临时目录
CORE = ['e2e-frontend-modules', 'e2e-session-sync', 'e2e-ui']
LIVE = ['e2e-live', 'e2e-input-history', 'e2e-images-stop', 'e2e-compact', 'e2e-lifecycle', 'e2e-browser']


def run(job):
    agent, script = job
    name = script if script in CORE else agent + '-' + script
    output = OUT / (name + '.json')
    output.unlink(missing_ok=True)
    env = dict(os.environ, UITEST_RESULT_PATH=str(output))
    with (OUT / (name + '.log')).open('w') as log:
        p = subprocess.run([str(HERE / 'run.sh'), agent, script + '.js'], env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        result = json.loads(output.read_text())
    except (OSError, ValueError):
        result = {'ok': False, 'status': 'failed', 'error': '未产生合法 JSON，见 ' + str(FINAL / (name + '.log')), 'checks': []}
    if p.returncode:
        result['ok'] = False
        result['status'] = 'failed'
    print(('✗ ' if not result.get('ok') else '↷ ' if result.get('skips') else '✓ ') + name, flush=True)
    return name, result


def main():
    agents = list(dict.fromkeys(sys.argv[1:] or ['claude']))
    if any(a not in ('claude', 'gpt', 'gemini') for a in agents):
        print('用法：all.sh [claude|gpt|gemini ...]（DeepSeek 整套始终运行）', file=sys.stderr)
        return 2
    global OUT
    app = ROOT / 'build/AIPetHub.app'
    if not app.is_dir():
        print('先 ./build.sh（不安装）', file=sys.stderr)
        return 2
    run_dir = Path(tempfile.mkdtemp(prefix='aipethub-uitest-run.', dir=os.environ.get('TMPDIR')))
    OUT = run_dir / 'results'
    OUT.mkdir()
    # App 副本：APFS 上 cp -c 是写时复制，几乎不花时间；跑的过程中有人重新 ./build.sh 也不影响这次
    copy = run_dir / 'AIPetHub.app'
    if subprocess.run(['cp', '-cR', str(app), str(copy)]).returncode:
        shutil.copytree(app, copy, symlinks=True)
    os.environ['AIPETHUB_TEST_APP'] = str(copy / 'Contents/MacOS/AIPetHub')
    dirs_file = run_dir / 'uitest-dirs.txt'
    os.environ['UITEST_DIRS_FILE'] = str(dirs_file)
    start = time.monotonic()
    # 全部同时开，最长的排在前面；真实 CLI 的套件共 6×主流程 CLI 数 + 1 个 DeepSeek
    jobs = [(a, s) for s in ['e2e-live', 'e2e-compact', 'e2e-lifecycle', 'e2e-input-history', 'e2e-images-stop', 'e2e-browser'] for a in agents]
    jobs += [('deepseek', 'e2e-deepseek')] + [('claude', s) for s in CORE]
    results = {}
    with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
        results.update(pool.map(run, jobs))
    elapsed = round(time.monotonic() - start, 2)
    # 只清这次运行建的测试会话
    cleaned = subprocess.run([str(HERE / 'clean.sh')], cwd=ROOT, env=dict(os.environ, UITEST_DIRS_FILE=str(dirs_file)),
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if cleaned.returncode:
        print('清测试会话没成功：' + cleaned.stdout.strip()[-300:])
    print('\n套件                         状态       断言     秒')
    for name, r in results.items():
        print(f"{name:30} {r.get('status', 'failed'):9} {len(r.get('checks', [])):4} {r.get('seconds', 0):7.1f}")
        for c in r.get('checks', []):
            if not c.get('ok'):
                print('  失败：' + c['name'] + '；' + json.dumps(c.get('actual'), ensure_ascii=False))
        if r.get('error'):
            print('  错误：' + r['error'])
    skips = [(name, s) for name, r in results.items() for s in r.get('skips', [])]
    print('\n跳过（单独统计，不算通过或失败）：')
    for name, s in skips:
        print('  ↷ ' + name + ' / ' + s['name'] + '：' + s.get('reason', '') + '\n    实际：' + json.dumps(s.get('actual'), ensure_ascii=False))
    if not skips:
        print('  无')
    ok = all(r.get('ok') is True for r in results.values())
    summary = dict(ok=ok, seconds=elapsed, passed=sum(r.get('status') == 'passed' for r in results.values()), failed=sum(not r.get('ok') for r in results.values()), skipped=len(skips), results=results)
    (OUT / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    shutil.rmtree(FINAL, ignore_errors=True)
    shutil.copytree(OUT, FINAL)
    shutil.rmtree(run_dir, ignore_errors=True)
    print(f'\n总耗时 {elapsed:.1f}s；结果：{FINAL}')
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
