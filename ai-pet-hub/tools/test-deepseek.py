#!/usr/bin/env python3
"""运行无窗口 Swift 自测，清理仅限本次假服务 PID；可传模式名单。
各模式同时跑：每个模式有自己的临时目录、假服务（端口由系统分配）、pid 文件和进程，互不相干。
输出先攒着，跑完按模式顺序整块打印，日志不会交错。SELFTEST 可指定别的测试程序（默认 build/selftest）。"""
import os, pathlib, signal, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor
modes = sys.argv[1:] or ['state', 'balance-home', 'early-event', 'stderr', 'slow-approval', 'cancel-first', 'cancel-held', 'cancel-idle', 'completed-lost', 'cancel-attachment', 'cancel-race', 'compact', 'configure-fail', 'concurrent-config', 'transaction', 'permission-fail', 'effort-fail', 'fallback', 'search', 'history-pages', 'history-cursor', 'disk-moved', 'image-submit-lost', 'image-submit-storage', 'image-submit-path-full', 'image-submit-unsupported', 'dr-question', 'dr-steer-lost', 'dr-service-drop', 'dr-steer-image', 'dr-steer-path-full', 'dr-steer-accepted', 'dr-max-tokens', 'dr-upstream-error', 'dr-blocked', 'deleted', 'list-external', 'start-fail', 'dg-plan', 'dg-receipt', 'dg-stream', 'dg-flap', 'dg-gap-complete', 'dg-gap-limit', 'dg-gap-running', 'dg-gap-missing', 'dg-unattended', 'dg-own-turn']
selftest = os.environ.get('SELFTEST', 'build/selftest')
# 和 tools/tests/support.swift 的 testWaitLimit 读同一个环境变量：单个等待的上限；一个模式里有好几段等待，整体给三倍
WAIT = float(os.environ.get('AIPETHUB_TEST_WAIT', 60))

def run(mode):
    out, failed, t0 = [], [], time.monotonic()
    with tempfile.TemporaryDirectory(prefix='aipethub-deepseek-') as root:
        env = os.environ.copy()
        if mode == 'balance-home':
            env.update(CFFIXED_USER_HOME=root, DSH_HOME=root + '/selected')
        p = subprocess.Popen([selftest, 'deepseek', mode, root], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
        try:
            output, _ = p.communicate(timeout=3 * WAIT)
            out.append(output)
            if p.returncode: failed.append(mode)
        except subprocess.TimeoutExpired:
            failed.append(mode); p.kill(); out.append(p.communicate()[0])
        finally:
            # 夹具由本次测试启动并写 PID；绝不搜索/终止用户的 dsh。
            for f in pathlib.Path(root).glob('fake-*.pid'):
                pid = int(f.read_text())
                try: os.kill(pid, signal.SIGTERM)
                except ProcessLookupError: pass
            deadline = time.monotonic() + WAIT
            pids = [int(f.read_text()) for f in pathlib.Path(root).glob('fake-*.pid')]
            def alive(pid):
                try: os.kill(pid, 0); return True
                except ProcessLookupError: return False
            while any(alive(pid) for pid in pids) and time.monotonic() < deadline:
                time.sleep(.05)
            remaining = [pid for pid in pids if alive(pid)]
            if remaining:
                failed.append(mode + ': leaked fixture ' + str(remaining))
            out.append(f'CLEAN {mode} {"fixture PIDs exited" if not remaining else remaining}（{time.monotonic() - t0:.1f}s）\n')
    return ''.join(out), failed

with ThreadPoolExecutor(max_workers=len(modes)) as pool:
    results = list(pool.map(run, modes))
failed = []
for text, bad in results:
    print(text, end='', flush=True)
    failed += bad
# test.sh 的汇总只取最后一行，这一行要自己说清结果
print(f'没通过：{failed}' if failed else f'全部通过（{len(modes)} 个模式）')
sys.exit(bool(failed))
