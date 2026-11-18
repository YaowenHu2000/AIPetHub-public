#!/usr/bin/env python3
"""无模型额度的真实窗口退出回归：./build.sh 后 python3 tools/uitest/check-exit.py。
辅助 CLI 和孙进程故意忽略 TERM；检查自动测试退出和正常 SIGTERM 退出。
只结束本脚本追踪到的 PID，绝不按进程名称杀进程。会话清理由 clean.sh 统一做。
"""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def processes():
    rows = {}
    for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,lstart=,command='], text=True).splitlines():
        fields = line.strip().split(None, 7)
        if len(fields) == 8:
            rows[int(fields[0])] = (int(fields[1]), ' '.join(fields[2:7]), fields[7])
    return rows


def check(mode, fixture, directory):
    env = dict(os.environ, AIPETHUB_CLAUDE=str(fixture))
    pidfile = Path(str(fixture) + '.pids')
    pidfile.unlink(missing_ok=True)
    known = {}
    at = time.monotonic()
    signaled = False
    with (directory / (mode + '.log')).open('w') as log:
        runner = subprocess.Popen(['tools/uitest/run.sh', 'claude', 'e2e-exit-pending.js', 'haiku', '35'],
                                  cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            while runner.poll() is None and time.monotonic() - at < 45:
                rows = processes()
                owned = {runner.pid}
                while True:
                    more = {pid for pid, row in rows.items() if row[0] in owned} - owned
                    if not more:
                        break
                    owned |= more
                for pid in owned - {runner.pid}:
                    if pid in rows:
                        known[pid] = rows[pid]
                fixture_ready = pidfile.exists() and len(pidfile.read_text().split()) >= 2
                if fixture_ready:
                    for value in pidfile.read_text().split():
                        pid = int(value)
                        if pid in rows:
                            known[pid] = rows[pid]
                if mode == 'signal' and not signaled and fixture_ready:
                    for pid, row in known.items():
                        if '/build/AIPetHub.app/Contents/MacOS/AIPetHub --uitest ' in row[2] and rows.get(pid, (None, None))[1] == row[1]:
                            os.kill(pid, signal.SIGTERM)
                            signaled = True
                time.sleep(.1)
            time.sleep(5)
            rows = processes()
            remaining = {pid: row[2] for pid, row in rows.items() if pid in known and row[1] == known[pid][1]}
            exercised = pidfile.exists() and len(pidfile.read_text().split()) >= 2
            log_text = (directory / (mode + '.log')).read_text()
            result = {'mode': mode, 'fixtureStarted': exercised, 'remaining': remaining,
                      'ok': exercised and not remaining and runner.poll() == 0 and
                            (signaled if mode == 'signal' else '"pendingUsageAtExit" : true' in log_text)}
            print(json.dumps(result, ensure_ascii=False))
            return result['ok']
        finally:
            # 失败时也只清理本次的进程，并用启动时间防止 PID 复用。
            rows = processes()
            for pid, row in known.items():
                if rows.get(pid, (None, None))[1] == row[1]:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            if runner.poll() is None:
                runner.kill()
            runner.wait()


def main():
    directory = Path(tempfile.mkdtemp(prefix='aipethub-exit-check.', dir=os.environ.get('TMPDIR')))
    fixture = directory / 'stuck-cli'
    command = shlex.join(['/usr/bin/python3', str(ROOT / 'tools/fixtures/fake-cli.py'), 'exit-pending', str(fixture)])
    fixture.write_text('#!/bin/sh\nexec ' + command + ' "$@"\n')
    fixture.chmod(0o755)
    results = [check(mode, fixture, directory) for mode in ['automatic', 'signal']]
    print('日志：', directory)
    raise SystemExit(0 if all(results) else 1)


if __name__ == '__main__':
    main()
