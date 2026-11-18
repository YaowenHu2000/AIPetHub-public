#!/usr/bin/env python3
"""短时 STOP/CONT 模拟；只向本脚本启动并记录的 selftest/CLI PID 发信号。
先 tools/test.sh，再 python3 tools/test-suspend.py。不会让机器睡眠，不改轮询间隔。
"""
import json, os, pathlib, signal, subprocess, tempfile, time
ROOT = pathlib.Path(__file__).resolve().parent.parent
os.chdir(ROOT)
rows = []
for mode in ['app', 'cli', 'both']:
    with tempfile.TemporaryDirectory(prefix='aipethub-suspend-') as tmp:
        d = pathlib.Path(tmp)
        (d/'exit-after-result').touch()
        with (d/'log').open('w') as log:
            p = subprocess.Popen(['build/selftest', 'suspend-case', tmp], stdout=log, stderr=log)
            owned = {p.pid}
            try:
                until = time.monotonic()+12
                while not (d/'ready.json').exists() and time.monotonic()<until and p.poll() is None:
                    time.sleep(.02)
                info = json.loads((d/'ready.json').read_text())
                assert info['app'] == p.pid
                cli = info['cli']
                # 发送信号前再核对 CLI 确实属于这个自建实例。
                parent = int(subprocess.check_output(['/bin/ps','-o','ppid=','-p',str(cli)], text=True))
                assert parent == p.pid, (info, parent)
                owned.add(cli)
                targets = [p.pid] if mode == 'app' else [cli] if mode == 'cli' else [p.pid,cli]
                for pid in targets: os.kill(pid,signal.SIGSTOP)
                (d/'external-status').write_text('idle')
                time.sleep(4.5)
                state = subprocess.run(['/bin/ps','-o','stat=','-p',str(cli)],capture_output=True,text=True)
                cli_exited = state.returncode != 0 or 'Z' in state.stdout
                for pid in reversed(targets):
                    try: os.kill(pid,signal.SIGCONT)
                    except ProcessLookupError: pass
                (d/'resumed').touch()
                assert p.wait(timeout=20) == 0, (d/'log').read_text()
                r = json.loads((d/'result.json').read_text())
                assert r['reply']=='fixture-ok' and r['usage']>0 and r['timer'] and r['empty'] and r['warmReaped'], r
                assert (r['oldStatus'],r['newStatus'])==('busy','idle'), r
                if mode=='app': assert cli_exited, 'App 暂停期间 CLI 应已退出'
                rows.append({'mode':mode,'paused_seconds':4.5,'cli_exited_while_paused':cli_exited,**r})
            finally:
                if p.poll() is None:
                    for pid in owned:
                        try: os.kill(pid,signal.SIGCONT)
                        except ProcessLookupError: pass
                    # 正常路径由 selftest.terminateAllChildren 收尾；异常路径只清自己的后代。
                    listing = subprocess.check_output(['/bin/ps','-axo','pid=,ppid='],text=True)
                    parents = {int(a):int(b) for a,b in (line.split() for line in listing.splitlines())}
                    changed = True
                    while changed:
                        children = {pid for pid,ppid in parents.items() if ppid in owned}
                        changed = not children.issubset(owned); owned |= children
                    for pid in owned:
                        try: os.kill(pid,signal.SIGKILL)
                        except ProcessLookupError: pass
                    p.wait()
print(json.dumps(rows,ensure_ascii=False,indent=2))
