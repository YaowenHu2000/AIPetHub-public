#!/usr/bin/env python3
"""单次真实窗口运行：保留原始结果、校验断言、跟踪且只清理本次 PID。"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import shlex
import signal
import struct
import subprocess
import sys
import tempfile
import time
import zlib

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def suite_source(script):
    # 太长的套件把正文拆进同名目录里带序号的片段：按文件名顺序拼回主文件的 //@parts 处，和没拆时是同一段代码、同一个作用域
    text = (HERE / script).read_text()
    parts = HERE / Path(script).stem
    if parts.is_dir():
        assert '  //@parts\n' in text, script + ' 有片段目录却没有 //@parts 这一行'
        text = text.replace('  //@parts\n', ''.join(p.read_text() for p in sorted(parts.glob('*.js'))), 1)
    return text


def processes():
    rows = {}
    for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,lstart=,command='], text=True).splitlines():
        fields = line.strip().split(None, 7)
        if len(fields) == 8:
            rows[int(fields[0])] = (int(fields[1]), ' '.join(fields[2:7]), fields[7])
    return rows


# 和 App 的 claudeCommand()（ClaudeRun.swift）同一个查找顺序：装了 reclaude 就只用 `reclaude cli`，测试里起的外部会话才和 App 读到的是同一处记录
def real_claude():
    forced = os.environ.get('AIPETHUB_CLAUDE')
    if forced:
        return [forced]
    reclaude = Path.home() / '.local/bin/reclaude'
    if reclaude.is_file():
        return [str(reclaude), 'cli']
    found = shutil.which('claude')
    if not found:
        raise RuntimeError('找不到真实 Claude CLI')
    return [found]


def git_fixture(repo):
    # 只在新临时目录写最小 Git 对象；不执行 git add/commit，不碰用户仓库索引。
    git = repo / '.git'
    (git / 'objects').mkdir(parents=True)
    (git / 'refs/heads').mkdir(parents=True)
    (git / 'HEAD').write_text('ref: refs/heads/main\n')
    (git / 'config').write_text('[core]\n\trepositoryformatversion = 0\n\tbare = false\n')
    def obj(kind, data):
        data = kind.encode() + b' ' + str(len(data)).encode() + b'\0' + data
        sha = hashlib.sha1(data).hexdigest()
        p = git / 'objects' / sha[:2] / sha[2:]
        p.parent.mkdir(exist_ok=True)
        p.write_bytes(zlib.compress(data))
        return sha
    blob = obj('blob', b'hello\n')
    tree = obj('tree', b'100644 keep.txt\0' + bytes.fromhex(blob))
    commit = obj('commit', ('tree ' + tree + '\nauthor uitest <test@localhost> 1 +0000\ncommitter uitest <test@localhost> 1 +0000\n\nfixture\n').encode())
    (git / 'refs/heads/main').write_text(commit + '\n')
    (repo / 'keep.txt').write_text('hello\n')
    subprocess.run(['git', 'read-tree', 'HEAD'], cwd=repo, check=True, capture_output=True)


def run():
    agent, script, model, limit = sys.argv[1:5]
    directory = Path(os.environ.get('UITEST_ARTIFACT_DIR') or tempfile.mkdtemp(prefix='aipethub-uitest.', dir=os.environ.get('TMPDIR'))).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    repo = directory / 'repo'
    repo.mkdir(exist_ok=True)
    if not (repo / '.git').exists():
        git_fixture(repo)
    (ROOT / 'build').mkdir(exist_ok=True)
    # all.py 给每次运行一份自己的清单（UITEST_DIRS_FILE），跑完只清自己的会话；单跑时记在共用清单里，留给 clean.sh
    with Path(os.environ.get('UITEST_DIRS_FILE') or ROOT / 'build/uitest-dirs.txt').open('a') as f:
        f.write(str(repo) + '\n')
    shutil.copy2(HERE / 'page.html', directory / 'page.html')
    large = script == 'e2e-lifecycle.js'
    width = 1024 if large else 64
    raw = (b'\x00' + b'\xff\x00\x00' * width) * width
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    (directory / 'red.png').write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, width, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 0 if large else -1)) + chunk(b'IEND', b''))
    ask = dict(claude='manual', gpt='ask', gemini='default', deepseek='workspace-write')
    full = dict(claude='bypassPermissions', gpt='danger-full-access', gemini='bypassPermissions', deepseek='danger-full-access')
    known, owned, external = {}, set(), None
    started = time.monotonic()
    result = None
    app = None
    def track():
        rows = processes()
        # 已被系统收养的子进程仍是根；不可用已退出或复用的裸 PID 扩展子树。
        descendants = {pid for pid, row in known.items() if rows.get(pid, (None, None))[1] == row[1]}
        descendants |= {p.pid for p in (app, external) if p is not None and p.poll() is None}
        while True:
            new = {pid for pid, row in rows.items() if row[0] in descendants} - descendants
            if not new:
                break
            descendants |= new
        for pid in descendants:
            if pid in rows and pid not in known:
                known[pid] = rows[pid]
        return rows
    def remaining(rows):
        return {pid: row for pid, row in known.items() if rows.get(pid, (None, None))[1] == row[1]}
    try:
        # 测试窗口和从程序坞打开的 App 一样，不带上发起测试的那个会话的代理和会话变量（见 build.sh 的安装一节）；
        # 分叉前置的外部 CLI 也用这份，否则它会把会话写进发起测试那个会话的配置目录，App 的列表里找不到
        host = ('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy', 'NODE_EXTRA_CA_CERTS', 'CLAUDECODE', 'CLAUDE_CONFIG_DIR')
        env = {k: v for k, v in os.environ.items() if k not in host and not k.startswith(('RECLAUDE_', 'CLAUDE_CODE_', 'CLAUDE_AGENT_SDK_', 'ANTHROPIC_', 'ANTIGRAVITY_', 'AGY_'))}
        fork_sid = os.environ.get('FORK_SID', '')
        if agent == 'claude' and script == 'e2e-input-history.js' and not fork_sid:
            fork_log = (directory / 'fork-cli.log').open('w')
            external = subprocess.Popen(real_claude() + ['-p', '--model', model, '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose'], cwd=repo, stdin=subprocess.PIPE, stdout=fork_log, stderr=subprocess.STDOUT, text=True, env=env)
            owned.add(external.pid)
            external.stdin.write(json.dumps({'type': 'user', 'message': {'role': 'user', 'content': '只回复：甲'}}) + '\n')
            external.stdin.flush()
            end = time.monotonic() + 100
            while time.monotonic() < end:
                track()
                for line in (directory / 'fork-cli.log').read_text().splitlines():
                    try:
                        value = json.loads(line)
                    except ValueError:
                        continue
                    if value.get('type') == 'result' and value.get('session_id'):
                        if value.get('is_error'):
                            raise RuntimeError('分叉前置 CLI 失败：' + str(value))
                        fork_sid = value['session_id']
                if fork_sid:
                    break
                if external.poll() is not None:
                    raise RuntimeError('分叉前置 CLI 提前退出：' + (directory / 'fork-cli.log').read_text()[-1000:])
                time.sleep(.1)
            if not fork_sid:
                raise RuntimeError('分叉前置 CLI 未在100秒内完成')
        constants = dict(REPO=str(repo), DIR=str(directory), PAGE=str(directory / 'page.html'), AGENT=agent, MODEL=model, ASK_PERM=ask[agent], FULL_PERM=full[agent], PDF_FILE=os.environ.get('PDF') or str(directory / 'red.png'), FORK_SID=fork_sid, LIFECYCLE_PHASE=os.environ.get('UITEST_LIFECYCLE_PHASE', 'main'), LIFECYCLE_FIXTURE=os.environ.get('UITEST_LIFECYCLE_FIXTURE', ''),
                         WAIT=int(os.environ.get('UITEST_WAIT', 240000)))   # until 等「某件事发生」的统一上限（毫秒），见 assertions.js
        source = 'const ' + ', '.join(k + '=' + json.dumps(v) for k, v in constants.items()) + ';\n'
        source += (HERE / 'prelude.js').read_text() + '\n' + (HERE / 'assertions.js').read_text() + '\n' + suite_source(script)
        (directory / 'run.js').write_text(source)
        executable = os.environ.get('AIPETHUB_TEST_APP') or str(ROOT / 'build/AIPetHub.app/Contents/MacOS/AIPetHub')
        if executable.endswith('.app'):
            executable += '/Contents/MacOS/AIPetHub'
        env['AIPETHUB_UITEST_REAL'] = os.environ.get('REAL', '')
        if script == 'e2e-stream.js':
            helper = directory / 'cli'
            fixtures = ROOT / 'tools/fixtures'
            (directory / 'mode').write_text('stream')
            helper.write_text('#!/bin/sh\ncase "$1" in web) cd ' + shlex.quote(str(directory)) + '\nexec env FIXTURE_MODE=dr-stream ' +
                              shlex.join(['/usr/bin/python3', str(fixtures/'fake-dsh.py')]) + ' "$@";; esac\nexec ' +
                              shlex.join(['/usr/bin/python3', str(fixtures/'fake-cli.py'), 'backend', str(helper)]) + ' "$@"\n')
            helper.chmod(0o755)
            env.update(AIPETHUB_TEST_CLI=str(helper), AIPETHUB_TEST_GEMINI_CLI_DIR=str(directory/'antigravity-cli'), CODEX_HOME=str(directory/'codex'))
        with (directory / 'app.log').open('w') as log:
            app = subprocess.Popen([executable, '--uitest', str(directory / 'run.js'), str(directory / 'raw-result.json')], stdout=log, stderr=subprocess.STDOUT, env=env)
            owned.add(app.pid)
            (directory / 'app.pid').write_text(str(app.pid))
            deadline = time.monotonic() + float(limit)
            while app.poll() is None and time.monotonic() < deadline:
                track()
                time.sleep(.1)
            track()
        raw_file = directory / 'raw-result.json'
        if raw_file.exists():
            raw_result = json.loads(raw_file.read_text())
            inner = raw_result.get('result')
            if not raw_result.get('ok') or not isinstance(inner, dict):
                raise RuntimeError('窗口脚本执行失败：' + str(raw_result.get('error', inner)))
            result = inner
            checks = result.get('checks', [])
            # 每套都至少要执行一个断言：一条都没跑到不算通过
            passed = result.get('ok') is True and not result.get('error') and len(checks) > 0 and all(c.get('ok') is True for c in checks)
            result['ok'] = passed
            result['status'] = 'failed' if not passed else 'skipped' if result.get('skips') else 'passed'
        elif os.environ.get('UITEST_EXPECT_SIGNAL') == '1' and app.returncode in (0, -signal.SIGTERM):
            result = {'ok': True, 'checks': [{'name': '测试实例收到指定 SIGTERM', 'ok': True}], 'skips': [], 'status': 'passed'}
        else:
            raise RuntimeError('没有结果（超时或启动失败），App退出码=' + str(app.poll()))
    except Exception as error:
        result = {'ok': False, 'status': 'failed', 'error': str(error), 'checks': [], 'skips': []}
    finally:
        if external is not None and external.poll() is None:
            try:
                external.stdin.close()
            except (BrokenPipeError, OSError):
                pass
            try:
                external.wait(timeout=5)
            except subprocess.TimeoutExpired:
                external.terminate()
        # dsh web 的包装每 2 秒才看一次父进程，机器忙时几秒不够：条件一成立就往下走，上限同 until
        end = time.monotonic() + int(os.environ.get('UITEST_WAIT', 240000)) / 1000
        while time.monotonic() < end:
            if not remaining(track()):
                break
            time.sleep(.1)
        leftovers = remaining(track())
        if leftovers:
            result['ok'] = False
            result['status'] = 'failed'
            result.setdefault('checks', []).append({'name': '测试结束无自起进程残留', 'ok': False, 'actual': {str(p): r[2] for p, r in leftovers.items()}})
            for sig in (signal.SIGTERM, signal.SIGKILL):
                rows = track()
                for pid in remaining(rows):
                    try:
                        os.kill(pid, sig)
                    except ProcessLookupError:
                        pass
                if sig == signal.SIGTERM:
                    end = time.monotonic() + .8
                    while time.monotonic() < end:
                        track()
                        time.sleep(.05)
        else:
            result.setdefault('checks', []).append({'name': '测试结束无自起进程残留', 'ok': True})
        if app is not None:
            try:
                app.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
        if external is not None:
            try:
                external.wait(timeout=3)
            except subprocess.TimeoutExpired:
                result['ok'] = False
                result['status'] = 'failed'
                result['error'] = '分叉前置 CLI 未在清理后退出'
        final_remaining = remaining(track())
        result['remainingAfterCleanup'] = {str(p): r[2] for p, r in final_remaining.items()}
        if final_remaining:
            result['ok'] = False
            result['status'] = 'failed'
        result['artifactDir'] = str(directory)
        result['seconds'] = round(time.monotonic() - started, 3)
        result['agent'] = agent
        result['script'] = script
        (directory / 'processes.json').write_text(json.dumps({str(k): v for k, v in known.items()}, ensure_ascii=False, indent=2))
        encoded = json.dumps(result, ensure_ascii=False, indent=2, separators=(',', ' : '))
        (directory / 'result.json').write_text(encoded + '\n')
        target = os.environ.get('UITEST_RESULT_PATH')
        if target:
            Path(target).write_text(encoded + '\n')
        print(encoded)
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(run())
