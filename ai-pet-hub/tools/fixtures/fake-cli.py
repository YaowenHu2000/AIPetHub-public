#!/usr/bin/env python3
"""统一假 CLI：fake-cli.py <行为> <临时入口路径> [行为参数] [CLI 参数…]。

backend / terminal 仍由入口旁的 mode 文件切换协议场景；其余行为见 SHELLS。
所有状态和 PID 文件均相对临时入口；不访问真实 CLI 配置。
原 shell 程序通过 exec 运行，保留 PID、进程树和信号行为。
"""
import os
import shlex
import sys

def backend():
    import json, os, sys, time
    mode_path = os.path.join(os.path.dirname(__file__), 'mode')
    try:
        mode = open(mode_path).read().strip()
    except FileNotFoundError:
        mode = 'ok'
    def emit(o):
        print(json.dumps(o), flush=True)
    a = sys.argv[1:]
    if mode == 'offline':
        print('connection refused (fixture)', file=sys.stderr)
        sys.exit(1)
    if a == ['agents', '--json']:
        try:
            status = open(os.path.join(os.path.dirname(__file__), 'external-status')).read().strip()
        except FileNotFoundError:
            status = 'busy'
        emit([{'sessionId':'elsewhere-fixture','pid':1,'status':status,'name':'fixture'}])
        sys.exit(0)
    if a == ['models']:
        if mode == 'hang-models':
            time.sleep(120)
        if mode == 'standalone-print':
            print('gemini-pro-orchestrator-argon\tOrchestrator (Argon)\ngemini-4-hydrogen-xhigh\tHydrogen (XHigh)')
        else:
            print('fixture-low\tFixture (low)')
        sys.exit(0)
    if '/usage' in a:
        if mode == 'hang-usage':
            time.sleep(120)
        print('Gemini\tFive Hour\t' + ('1e100' if mode == 'huge' else 'NaN' if mode == 'nan' else '80') + '%\t2030-01-01T00:00:00Z')
        sys.exit(0)
    if '--help' in a:
        print('FutureCLI 999 help format changed' + ('' if mode == 'help-missing' else ' --include-partial-messages'))
        sys.exit(0)
    if mode in ('claude-unsupported', 'codex-unsupported'):
        if '--input-format' in a or a == ['app-server']:
            print('unknown option / command (future fixture)', file=sys.stderr)
            sys.exit(2)
        if mode == 'claude-unsupported':
            emit({'type':'future-event','newField':42})
            emit({'type':'result','subtype':'success','result':'compat-ok','session_id':'fixture'})
        else:
            emit({'type':'future-event','newField':42})
            emit({'type':'item.completed','item':{'id':'m','type':'agent_message','text':'compat-ok'}})
            emit({'type':'turn.completed','usage':{}})
        sys.exit(0)
    if mode in ('unsupported', 'standalone-print', 'retry-abandoned') and a and a[0] == 'acp':
        print('unknown option: acp', file=sys.stderr)
        sys.exit(2)
    if a == ['app-server']:
        for line in sys.stdin:
            obj = json.loads(line)
            if obj.get('method') == 'initialize':
                emit({'id':1,'result':{}})
            elif obj.get('method') == 'model/list':
                emit({'id':obj['id'],'result':{'data':[{'id':'new-codex-model'}]}})
            elif obj.get('method') == 'thread/archive':
                cid = obj['params']['threadId']
                with open(__file__ + '.archives', 'a') as log:
                    log.write(f"{os.getpid()}\t{cid}\n")
                emit({'id':obj['id'], **({'error':{'message':'refused'}} if cid == 'refused' else {'result':{}})})
            elif obj.get('method') == 'account/rateLimits/read':
                emit({'id':7,'result':{'rateLimits':{'credits':{'hasCredits':True,'balance':'NaN' if mode == 'credits-nan' else '1e100'}}}})
        sys.exit(0)
    if a and a[0] != 'acp':
        if mode == 'retry-abandoned':
            emit({'event':'step_update','step_update':{'step_index':0,'step_type':'agent_response','state':'DONE','text_delta':'先检查'}})
            for index in (1, 2):
                emit({'event':'step_update','step_update':{'step_index':index,'step_type':'error_message','state':'DONE'}})
            emit({'event':'result','result':{'status':'ERROR','error':'API error (attempt 2)','response':'先检查'}})
            sys.exit(1)
        reply = a[a.index('--model') + 1] if mode == 'standalone-print' else 'fixture-ok'
        emit({'event':'result', 'result':{'response':reply,'status':'SUCCESS'}})
        sys.exit(0)
    initialize_id = None
    for line in sys.stdin:
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        method, rid = obj.get('method'), obj.get('id')
        if method == 'initialize':
            emit({'method':'future/event','params':{'unknown':[1,None]}})
            if mode == 'handshake':
                initialize_id = rid
                emit({'id':'future-handshake','method':'future/handshake','params':{}})
            else:
                emit({'id':rid,'result':{'protocolVersion':1,'future':True}})
        elif rid == 'future-handshake':
            emit({'id':initialize_id,'result':{'protocolVersion':1}})
        elif method in ('session/new','session/resume'):
            emit({'id':rid,'result':{} if mode == 'missing' else {'sessionId':'fixture-session'}})
        elif method == 'session/prompt':
            emit({'method':'session/update','params':{'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'fixture-'}}}})
            if mode == 'drop':
                emit({'method':'session/update','params':{'update':{'sessionUpdate':'tool_call','toolCallId':'c','title':'run_command','status':'in_progress'}}})
                sys.exit(1)
            time.sleep(0.15 if mode != 'slow' else 2)
            emit({'method':'session/update','params':{'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'ok'}}}})
            emit({'id':rid,'result':{'stopReason':'end_turn'}})
            if os.path.exists(os.path.join(os.path.dirname(__file__), 'exit-after-result')):
                sys.exit(0)
        elif method == 'session/cancel':
            sys.exit(0)
        elif rid is not None:
            emit({'id':rid,'result':{}})

def terminal():
    import json
    import pathlib
    import sys
    mode = pathlib.Path(__file__).with_name('mode').read_text().strip()
    def emit(value):
        print(json.dumps(value), flush=True)
    if 'app-server' in sys.argv:
        if mode == 'exec':
            sys.exit(1)
        for line in sys.stdin:
            obj = json.loads(line)
            ident = obj.get('id')
            method = obj.get('method')
            if method == 'initialize':
                emit({'id': ident, 'result': {}})
            elif method in ('thread/start', 'thread/resume'):
                emit({'id': ident, 'result': {'thread': {'id': 'fixture-thread'}}})
            elif method == 'turn/start':
                emit({'id': ident, 'result': {'turn': {'id': 'fixture-turn'}}})
                emit({'method': 'item/started', 'params': {'item': {'id': 'cmd', 'type': 'commandExecution', 'command': 'fixture-command'}}})
                emit({'method': 'item/agentMessage/delta', 'params': {'itemId': 'msg', 'delta': '已有正文'}})
                if mode == 'completed':
                    emit({'method': 'turn/completed', 'params': {'turn': {'status': 'completed'}}})
                break
    else:
        emit({'type': 'item.started', 'item': {'id': 'cmd', 'type': 'command_execution', 'command': 'fixture-command'}})
        emit({'type': 'item.completed', 'item': {'id': 'msg', 'type': 'agent_message', 'text': '已有正文'}})
    print('fatal fixture tail', file=sys.stderr)
    sys.exit(42)

def initialization():
    import json, time
    mode = open(__file__ + '.mode').read().strip()
    codex = 'app-server' in sys.argv[1:]
    interactive = codex or 'acp' in sys.argv[1:]
    log = __file__ + '.log'
    def record(method):
        with open(log, 'a') as out:
            out.write(json.dumps({'pid': os.getpid(), 'method': method}) + '\n')
    def emit(value):
        print(json.dumps(value), flush=True)
    def finish(prompt_id=None):
        if codex:
            emit({'method':'item/completed','params':{'item':{'type':'agentMessage','id':'answer','text':'live-answer','phase':'final_answer'}}})
            emit({'method':'turn/completed','params':{'turn':{'id':'turn','status':'completed'}}})
        else:
            emit({'method':'session/update','params':{'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'live-answer'}}}})
            emit({'id':prompt_id,'result':{'stopReason':'end_turn'}})
    if sys.argv[1:] == ['models']:
        print('model-low\tModel (Low)')
        return
    if not interactive:
        record('oneshot')
        if mode.endswith('-hold'):
            while not os.path.exists(__file__ + '.release'): time.sleep(.01)
        if sys.argv[1:2] == ['exec']:
            emit({'type':'item.completed','item':{'id':'answer','type':'agent_message','text':'fallback-answer'}})
            emit({'type':'turn.completed'})
        else:
            emit({'event':'result','result':{'response':'fallback-answer','status':'SUCCESS'}})
        return
    record('interactive')
    prompt_id = None
    for line in sys.stdin:
        obj = json.loads(line)
        method = obj.get('method', 'reply:' + str(obj.get('id', '')))
        record(method)
        ident = obj.get('id')
        if method == 'initialize':
            if mode.startswith('stall-initialize'):
                emit({'id':700,'method':'future/required-handshake','params':{}})
            else:
                emit({'id':ident,'result':{}})
        elif method in ('thread/start','thread/resume','session/new','session/resume'):
            if mode == 'stall-session':
                emit({'id':700,'method':'future/required-handshake','params':{}})
            else:
                if not codex:
                    emit({'method':'session/update','params':{'update':{'sessionUpdate':'available_commands_update','availableCommands':[{'name':'compact'}]}}})
                emit({'id':ident,'result':{'thread':{'id':'thread'}} if codex else {'sessionId':'session'}})
        elif method in ('session/set_model','session/set_mode'):
            emit({'id':ident,'result':{}})
        elif method in ('turn/start','thread/compact/start','session/prompt'):
            prompt_id = ident
            if codex: emit({'id':ident,'result':{'turn':{'id':'turn'}}})
        elif method == 'fixture/duplicates':
            emit({'id':1,'result':{}})
            emit({'id':1,'result':{}})
            emit({'id':799,'result':{}})
            emit({'id':701,'method':'future/required-handshake','params':{}})
        elif method == 'fixture/finish':
            finish(prompt_id)
    if mode == 'stall-initialize':
        while True: time.sleep(10)

SHELLS = {
    'exit-pending': r'''
#!/bin/sh
trap "" TERM
sleep 120 &
echo "$$ $!" >> "$0.pids"
wait
''',
    'acp-warm': r'''
#!/bin/sh
while IFS= read -r line; do
    line=$(printf '%s' "$line" | /usr/bin/sed 's#\\/#/#g')
    case "$line" in
        *'"initialize"'*) echo '{"id":1,"result":{}}' ;;
        *'"session/new"'*|*'"session/resume"'*) echo '{"id":2,"result":{"sessionId":"fake-session"}}' ;;
        *'"session/set_model"'*) echo '{"id":3,"result":{}}' ;;
        *'"session/set_mode"'*) echo '{"id":4,"result":{}}' ;;
        *'"session/prompt"'*)
            echo '{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"假 CLI 回答"}}}}'
            echo '{"id":5,"result":{"stopReason":"end_turn"}}'
            ;;
    esac
done
''',
    'cold-retry': r'''
#!/bin/sh
echo launch >> "$0.log"
stage=0
while IFS= read -r line; do
    line=$(printf '%s' "$line" | /usr/bin/sed 's#\\/#/#g')
    printf '%s\n' "$line" >> "$0.log"
    case "$line" in
        *'"initialize"'*) stage=1; echo '{"id":1,"result":{}}' ;;
        *'"thread/start"'*)
            [ "$stage" = 1 ] || exit 21
            stage=2; echo '{"id":2,"result":{"thread":{"id":"fake-thread"}}}' ;;
        *'"session/new"'*)
            [ "$stage" = 1 ] || exit 21
            stage=2; echo '{"id":2,"result":{"sessionId":"fake-session"}}' ;;
        *'"session/set_model"'*)
            [ "$stage" = 2 ] || exit 22
            stage=3; echo '{"id":3,"result":{}}' ;;
        *'"session/set_mode"'*)
            [ "$stage" = 3 ] || exit 23
            stage=4; echo '{"id":4,"result":{}}' ;;
        *'"session/prompt"'*)
            [ "$stage" = 4 ] || exit 24
            echo '{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"cold-ok"}}}}'
            echo '{"id":5,"result":{"stopReason":"end_turn"}}' ;;
        *'"turn/start"'*)
            [ "$stage" = 2 ] || exit 24
            echo '{"id":3,"result":{"turn":{"id":"fake-turn"}}}'
            echo '{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"m","text":"cold-ok","phase":"final_answer"}}}'
            echo '{"method":"turn/completed","params":{"turn":{"id":"fake-turn","status":"completed"}}}' ;;
        *'"type":"user"'*)
            [ "$stage" = 1 ] || exit 24
            echo '{"type":"result","subtype":"success","result":"cold-ok","session_id":"fake-session"}'
            exit 0 ;;
    esac
done
''',
    'cancel-orphan': r'''
#!/bin/sh
while IFS= read -r line; do
    line=$(printf '%s' "$line" | /usr/bin/sed 's#\\/#/#g')
    case "$line" in
        *'"initialize"'*) echo '{"id":1,"result":{}}' ;;
        *'"session/new"'*) echo '{"id":2,"result":{"sessionId":"fake-session"}}' ;;
        *'"session/set_model"'*) echo '{"id":3,"result":{}}' ;;
        *'"session/prompt"'*)
            /bin/sh -c 'trap "" TERM; echo $$ > "$1"; exec /bin/sleep 120' fixture "$0.child" & ;;
        *'"session/cancel"'*) exit 0 ;;
    esac
done
''',
    'hung-tree': r'''
#!/bin/sh
trap '' TERM
echo $$ > "$0.pid"
/bin/sh -c 'trap "" TERM; echo $$ > "$1"; exec /bin/sleep 120' fixture "$0.child" &
echo partial-output
wait
''',
    'dsh-starting': r'''
#!/bin/sh
echo started > "$0.started"
sleep 120
''',
    'zstd-read': r'''
#!/bin/sh
echo "$1" >> "$0.calls"
if [ "$1" = -lv ]; then cat "$2.info"; exit $?; fi
[ "$1" = -dc ] || exit 2
cat "$2.plain"
''',
    'preview-document': r'''
#!/bin/sh
mkdir -p "$3/test.qlpreview"
echo '<html><head></head><body>document</body></html>' > "$3/test.qlpreview/Preview.html"
''',
    'git-write-tree-fail': r'''
#!/bin/sh
for arg in "$@"; do if [ "$arg" = write-tree ]; then exit 1; fi; done
exec '__REAL_GIT__' "$@"
''',
    'preview-slow': r'''
#!/bin/sh
echo "$4" >> '__ROOT__/started'
sleep 2 &
echo $! > '__ROOT__/child'
wait
mkdir -p "$3/out.qlpreview"
echo '<html>done</html>' > "$3/out.qlpreview/Preview.html"
''',
    'preview-stubborn': r'''
#!/bin/sh
/bin/sh -c 'trap "" TERM; while :; do sleep 1; done' &
echo $! > '__ROOT__/stubborn-child'
wait
''',
}

if __name__ == '__main__':
    behavior, path, *args = sys.argv[1:]
    # Existing Python fixtures use __file__ and argv[0] for their temporary state directory.
    __file__ = path
    if behavior in ('backend', 'terminal', 'initialization'):
        sys.argv = [path] + args
        globals()[behavior]()
    else:
        script = SHELLS[behavior]
        if behavior == 'git-write-tree-fail':
            script = script.replace("'__REAL_GIT__'", shlex.quote(args.pop(0)))
        elif behavior in ('preview-slow', 'preview-stubborn'):
            root = args.pop(0)
            for name in ('started', 'child', 'stubborn-child'):
                script = script.replace("'__ROOT__/" + name + "'", shlex.quote(root + '/' + name))
        os.execv('/bin/sh', ['/bin/sh', '-c', script, path] + args)
