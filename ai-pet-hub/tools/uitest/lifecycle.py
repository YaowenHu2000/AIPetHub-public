#!/usr/bin/env python3
"""e2e-lifecycle.js 的外部观察器：各阶段独立 App，按 PID 证明停止和退出无残留。"""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
spec = importlib.util.spec_from_file_location('uitest_runner', HERE / 'run-suite.py')
runner_tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner_tools)


def fixture(path, behavior, real=None):
    command = ['/usr/bin/python3', str(ROOT / 'tools/fixtures/fake-cli.py'), behavior, str(path)]
    text = '#!/bin/sh\n'
    if real:
        text += 'case " $* " in *" --help "*) exec ' + shlex.join(command) + ' "$@" ;; esac\n'
        text += 'exec ' + shlex.join(real) + ' "$@"\n'
    else:
        text += 'exec ' + shlex.join(command) + ' "$@"\n'
    path.write_text(text)
    path.chmod(0o755)


def real_claude():
    forced = os.environ.get('AIPETHUB_CLAUDE')
    if forced:
        return [forced]
    reclaude = Path.home() / '.local/bin/reclaude'
    if reclaude.is_file():
        return [str(reclaude), 'cli']
    found = shutil.which('claude')
    if not found:
        raise RuntimeError('找不到真实 Claude CLI，无法验证辅助探测超时')
    return [found]


def phase(directory, name, agent, model, seconds, helper=None):
    directory.mkdir(parents=True)
    output = directory / 'result.json'
    env = dict(os.environ, UITEST_ARTIFACT_DIR=str(directory), UITEST_RESULT_PATH=str(output),
               UITEST_LIFECYCLE_PHASE=name, UITEST_LIFECYCLE_FIXTURE=str(helper or ''))
    if helper:
        env['AIPETHUB_CLAUDE'] = str(helper)
    if name == 'exit-signal':
        env['UITEST_EXPECT_SIGNAL'] = '1'
    tracked = {}
    command_seen = False
    signal_sent = False
    monitor_error = None
    began = time.monotonic()
    with (directory / 'runner.log').open('w') as log:
        proc = subprocess.Popen([str(HERE / 'run.sh'), agent, 'e2e-lifecycle.js', model, str(seconds)], env=env,
                                cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        try:
            while proc.poll() is None and time.monotonic() - began < seconds + 20:
                rows = runner_tools.processes()
                own = {proc.pid}
                while True:
                    children = {pid for pid, row in rows.items() if row[0] in own} - own
                    if not children:
                        break
                    own |= children
                marker = (Path(str(helper) + '.pid') if name == 'helper' else directory / 'repo/lifecycle-command.pid')
                marked = []
                if marker.exists():
                    try:
                        marked = [int(n) for n in marker.read_text().split()]
                    except ValueError:
                        pass
                if name == 'helper' and Path(str(helper) + '.child').exists():
                    try:
                        marked.extend(int(n) for n in Path(str(helper) + '.child').read_text().split())
                    except ValueError:
                        pass
                # 标记本身不足以授权信号/跟踪：PID 必须先属于本次启动的子树。
                for pid in marked:
                    if pid in own and pid in rows:
                        tracked[pid] = rows[pid]
                        command_seen = True
                descendants = set(tracked)
                while True:
                    children = {pid for pid, row in rows.items() if row[0] in descendants} - descendants
                    if not children:
                        break
                    descendants |= children
                for pid in descendants:
                    if pid in rows and (pid not in tracked or rows[pid][1] == tracked[pid][1]):
                        tracked[pid] = rows[pid]
                remaining = {str(pid): row[2] for pid, row in tracked.items() if rows.get(pid, (None, None))[1] == row[1]}
                state = {'started': command_seen, 'remaining': list(remaining), 'commands': remaining, 'observed': list(tracked), 'commandReady': any(Path(row[2].split()[0]).name == 'sleep' and row[2].split()[1:2] == ['120'] for row in tracked.values())}
                temporary = directory / 'command-state.tmp'
                temporary.write_text(json.dumps(state))
                temporary.replace(directory / 'command-state.json')
                if name == 'exit-signal' and not signal_sent:
                    pidfile = Path(str(helper) + '.pids')
                    app_pidfile = directory / 'app.pid'
                    if pidfile.exists() and len(pidfile.read_text().split()) >= 2 and app_pidfile.exists():
                        fixture_pids = [int(pid) for pid in pidfile.read_text().split()]
                        app_pid = int(app_pidfile.read_text())
                        if app_pid in own and all(pid in own for pid in fixture_pids) and ' --uitest ' in rows[app_pid][2]:
                            os.kill(app_pid, signal.SIGTERM)
                            signal_sent = True
                time.sleep(.1)
            if proc.poll() is None:
                monitor_error = '生命周期观察器等待超时'
        finally:
            if proc.poll() is None:
                # 单次 runner 自己已负责子树清理；这里只终止本次明确持有的 runner PID。
                proc.terminate()
                try:
                    proc.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    proc.kill()
            proc.wait()
    if output.exists():
        result = json.loads(output.read_text())
    else:
        result = {'ok': False, 'checks': [], 'skips': [], 'error': monitor_error or '生命周期阶段未产生结果'}
    if name == 'exit-signal':
        result.setdefault('checks', []).append({'name': '只向本次测试App发送SIGTERM', 'ok': signal_sent})
    if name.startswith('exit'):
        marker = Path(str(helper) + '.pids')
        fixture_pids = marker.read_text().split() if marker.exists() else []
        traced_file = directory / 'processes.json'
        traced = json.loads(traced_file.read_text()) if traced_file.exists() else {}
        rows = runner_tools.processes()
        recorded = len(fixture_pids) >= 2 and all(pid in traced for pid in fixture_pids)
        remaining = [pid for pid in fixture_pids if pid in traced and rows.get(int(pid), (None, None))[1] == traced[pid][1]]
        result.setdefault('checks', []).append({'name': '退出夹具父孙PID均被跟踪且已退出',
                                               'ok': recorded and not remaining,
                                               'actual': {'fixturePids': fixture_pids, 'allTracked': recorded, 'remaining': remaining}})
    if monitor_error:
        result['error'] = monitor_error
    result['ok'] = result.get('ok') is True and not result.get('error') and all(c['ok'] for c in result.get('checks', []))
    result['status'] = 'failed' if not result['ok'] else 'skipped' if result.get('skips') else 'passed'
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    return result


def main():
    exit_only = '--exit-only' in sys.argv
    args = [a for a in sys.argv[1:] if a != '--exit-only']
    agent = args[0] if args else 'claude'
    model = args[1] if len(args) > 1 else 'haiku'
    seconds = args[2] if len(args) > 2 else '560'
    seconds = int(seconds)
    directory = Path(tempfile.mkdtemp(prefix='aipethub-lifecycle.', dir=os.environ.get('TMPDIR'))).resolve()
    started = time.monotonic()
    results = {}
    try:
        if not exit_only:
            results['main'] = phase(directory / 'aipethub-uitest.main', 'main', agent, model, seconds)
            helper = directory / 'hung-help'
            fixture(helper, 'hung-tree', real_claude())
            results['helper'] = phase(directory / 'aipethub-uitest.helper', 'helper', 'claude', 'haiku', 130, helper)
        for name in ['exit-automatic', 'exit-signal']:
            helper = directory / (name + '-cli')
            fixture(helper, 'exit-pending')
            results[name] = phase(directory / ('aipethub-uitest.' + name), name, 'claude', 'haiku', 40, helper)
        checks = [{**item, 'name': name + '/' + item['name']} for name, value in results.items() for item in value.get('checks', [])]
        skips = [{**item, 'name': name + '/' + item['name']} for name, value in results.items() for item in value.get('skips', [])]
        result = {'suite': '进程生命周期', 'ok': all(r['ok'] for r in results.values()), 'checks': checks,
                  'skips': skips, 'phases': results}
    except Exception as error:
        result = {'suite': '进程生命周期', 'ok': False, 'checks': [], 'skips': [], 'error': str(error), 'phases': results}
    result.update(artifactDir=str(directory), seconds=round(time.monotonic() - started, 3), agent=agent, script='e2e-lifecycle.js')
    result['status'] = 'failed' if not result['ok'] else 'skipped' if result['skips'] else 'passed'
    encoded = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
    (directory / 'result.json').write_text(encoded)
    target = os.environ.get('UITEST_RESULT_PATH')
    if target:
        Path(target).write_text(encoded)
    print(encoded, end='')
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
