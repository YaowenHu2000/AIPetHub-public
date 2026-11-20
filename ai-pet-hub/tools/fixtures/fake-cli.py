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
    started = time.localtime()   # agy 的日志名是启动后第一次写日志的本地时刻（App 按这个找本进程的日志）
    mode_path = os.path.join(os.path.dirname(__file__), 'mode')
    try:
        mode = open(mode_path).read().strip()
    except FileNotFoundError:
        mode = 'ok'
    def emit(o):
        print(json.dumps(o), flush=True)
    a = sys.argv[1:]
    def chunks():
        for _ in range(32):
            time.sleep(.04)
            yield '甲乙丙丁戊己庚辛'
    if mode == 'stream' and '--input-format' in a:
        for line in sys.stdin:
            if json.loads(line).get('type') != 'user': continue
            def event(kind, **fields):
                emit({'type':'stream_event','event':dict(type=kind,index=0,**fields)})
            event('content_block_start',content_block={'type':'text'})
            body = ''
            for part in chunks():
                body += part
                event('content_block_delta',delta={'type':'text_delta','text':part})
            event('content_block_stop')
            emit({'type':'result','subtype':'success','result':body})
            return
    if mode == 'offline':
        # 记下每次启动：用量测试据此数重试了几次、确认这些进程都已退出
        with open(__file__ + '.starts', 'a') as log:
            log.write(f"{os.getpid()}\t{a[0] if a else ''}\n")
        print('connection refused (fixture)', file=sys.stderr)
        sys.exit(1)
    if a == ['agents', '--json']:
        listing = os.path.join(os.path.dirname(__file__), 'agents.json')
        if os.path.exists(listing):
            print(open(listing).read())
            sys.exit(0)
        try:
            status = open(os.path.join(os.path.dirname(__file__), 'external-status')).read().strip()
        except FileNotFoundError:
            status = 'busy'
        emit([{'sessionId':'elsewhere-fixture','pid':1,'status':status,'name':'fixture'}])
        sys.exit(0)
    if a == ['models']:
        if mode == 'hang-models':
            time.sleep(600)
        if mode == 'standalone-print':
            print('gemini-pro-orchestrator-argon\tOrchestrator (Argon)\ngemini-4-hydrogen-xhigh\tHydrogen (XHigh)')
        else:
            print('fixture-low\tFixture (low)')
        sys.exit(0)
    if '/usage' in a:
        if mode == 'hang-usage':
            time.sleep(600)
        print('Gemini\tFive Hour\t' + ('1e100' if mode == 'huge' else 'NaN' if mode == 'nan' else '80') + '%\t2030-01-01T00:00:00Z')
        sys.exit(0)
    if '--help' in a:
        if mode == 'help-failed': sys.exit(42)
        print('FutureCLI 999 help format changed' + ('' if mode == 'help-missing' else ' --include-partial-messages'))
        sys.exit(0)
    if mode in ('mixed-edits','undo-edits') and '--input-format' in a:
        for line in sys.stdin:
            if json.loads(line).get('type') != 'user': continue
            if os.path.islink('mixed-link'):
                os.unlink('mixed-link')
                os.symlink('mixed.txt', 'mixed-link')
            path = os.path.abspath('mixed.txt')
            with open(path, 'w') as f: f.write('EDIT\n')
            emit({'type':'assistant','message':{'content':[{'type':'tool_use','id':'e','name':'Edit','input':{'file_path':path,'old_string':'start','new_string':'EDIT'}}]}})
            emit({'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':'e','content':'updated'}]}})
            if mode == 'undo-edits':
                with open(path,'w') as f:f.write('start\n')
                emit({'type':'assistant','message':{'content':[{'type':'tool_use','id':'undo','name':'Edit','input':{'file_path':path,'old_string':'EDIT','new_string':'start'}}]}})
                emit({'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':'undo','content':'updated'}]}})
            else:
                with open(path, 'a') as f: f.write('shell\n')
            emit({'type':'result','subtype':'success','result':'ok'})
            return
    if mode in ('claude-unsupported', 'codex-unsupported', 'exec-crash'):
        if '--input-format' in a or a == ['app-server']:
            print('unknown option / command (future fixture)', file=sys.stderr)
            sys.exit(2)
        if mode == 'exec-crash':
            emit({'type':'thread.started','thread_id':'fixture-thread'})
            for state, key, text in [('completed','a','先说明'),('updated','b','末段')]:
                emit({'type':'item.'+state,'item':{'id':key,'type':'agent_message','text':text}})
            sys.exit(42)
        if mode == 'claude-unsupported':
            emit({'type':'future-event','newField':42})
            emit({'type':'result','subtype':'success','result':'compat-ok','session_id':'fixture'})
        else:
            emit({'type':'future-event','newField':42})
            emit({'type':'item.completed','item':{'id':'m','type':'agent_message','text':'compat-ok'}})
            emit({'type':'turn.completed','usage':{}})
        sys.exit(0)
    if mode in ('unsupported', 'standalone-print', 'print-partial', 'retry-abandoned') and a and a[0] == 'acp':
        print('unknown option: acp', file=sys.stderr)
        sys.exit(2)
    if a == ['app-server']:
        for line in sys.stdin:
            obj = json.loads(line)
            if obj.get('method') == 'initialize':
                emit({'id':1,'result':{}})
            elif obj.get('method') == 'model/list':
                emit({'id':obj['id'],'result':{'data':[{'id':'new-codex-model'}]}})
            elif mode == 'skills':
                # 每个工作目录各有一份同名技能 fixture；收到的每一行按顺序记进 <入口>.log，测试据此看先查技能还是先提交
                with open(__file__ + '.log', 'a') as log:
                    log.write(line if line.endswith('\n') else line + '\n')
                method = obj.get('method')
                if method in ('thread/start', 'thread/resume'):
                    emit({'id':obj['id'],'result':{'thread':{'id':'fixture-skill'}}})
                elif method == 'skills/list':
                    cwd = obj['params']['cwds'][0]
                    emit({'id':obj['id'],'result':{'data':[{'cwd':cwd,'errors':[],'skills':[
                        {'name':'fixture','path':cwd + '/.codex/skills/fixture/SKILL.md','enabled':True,'description':'夹具技能'}]}]}})
                elif method == 'turn/start':
                    emit({'id':obj['id'],'result':{'turn':{'id':'fixture-turn'}}})
                    emit({'method':'turn/completed','params':{'turn':{'id':'fixture-turn','status':'completed'}}})
            elif mode == 'stream' and obj.get('method') in ('thread/start','thread/resume'):
                emit({'id':obj['id'],'result':{'thread':{'id':'fixture-stream'}}})
            elif mode == 'stream' and obj.get('method') == 'turn/start':
                emit({'id':obj['id'],'result':{'turn':{'id':'fixture-turn'}}})
                body = ''
                for part in chunks():
                    body += part
                    emit({'method':'item/agentMessage/delta','params':{'itemId':'msg','delta':part}})
                emit({'method':'item/completed','params':{'item':{'type':'agentMessage','id':'msg','phase':'final_answer','text':body}}})
                emit({'method':'turn/completed','params':{'turn':{'id':'fixture-turn','status':'completed'}}})
            elif obj.get('method') == 'thread/read' and obj['params'].get('includeTurns'):
                items = [{'type':'userMessage','content':[{'type':'text','text':'有效提问'}]},
                         {'type':'agentMessage','phase':'final_answer','text':'有效回答'}]
                # read-interrupted：只读观察进程把别的客户端正在写的末轮报成 interrupted（Codex 0.167 实测）
                status = 'interrupted' if mode == 'read-interrupted' else 'completed'
                emit({'id':obj['id'],'result':{'thread':{'id':obj['params']['threadId'],'turns':[{'id':'t','status':status,'items':items}]}}})
            elif obj.get('method') == 'thread/archive':
                cid = obj['params']['threadId']
                with open(__file__ + '.archives', 'a') as log:
                    log.write(f"{os.getpid()}\t{cid}\n")
                emit({'id':obj['id'], **({'error':{'message':'refused'}} if cid == 'refused' else {'result':{}})})
            elif obj.get('method') == 'account/rateLimits/read':
                emit({'id':7,'result':{'rateLimits':{'credits':{'hasCredits':True,'balance':'NaN' if mode == 'credits-nan' else '1e100'}}}})
                if mode == 'usage-exit':   # 答完立刻退出：退出通知可能先于这几行被读到
                    sys.exit(0)
        sys.exit(0)
    if a and a[0] != 'acp':
        if mode == 'print-partial':
            for text in ('半', '句'):
                emit({'event':'step_update','conversation_id':'print-partial',
                      'step_update':{'step_index':0,'step_type':'agent_response','state':'RUNNING','text_delta':text}})
            return
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
        elif method == 'session/new' and mode.startswith('store-locked'):
            # 建库被挡：agy 照样答复会话 ID，库留成 0 字节，日志里先写一行失败（行文照 agy 2026-11-19 的真实日志）。
            # store-locked-always 每次都被挡，用来测 App 重试有上限。
            home = os.path.join(os.path.dirname(__file__), 'antigravity-cli')
            tries = len(open(__file__ + '.sessions').read().split()) if os.path.exists(__file__ + '.sessions') else 0
            sid = 'fixture-session' if mode == 'store-locked' and tries > 0 else f'locked-{tries}'
            if sid != 'fixture-session':
                os.makedirs(os.path.join(home, 'conversations'), exist_ok=True)
                os.makedirs(os.path.join(home, 'log'), exist_ok=True)
                db = os.path.join(home, 'conversations', sid + '.db')
                open(db, 'w').close()
                with open(os.path.join(home, 'log', f'acp-server-{time.strftime("%Y%m%d_%H%M%S", started)}-{os.getpid()}.log'), 'a') as log:
                    log.write(f'E1119 00:00:00.000000      44 errorreport.go:285] failed to create persistent trajectory in store 1: open backend {db}: trajectory db schema init: database is locked\n')
            with open(__file__ + '.sessions', 'a') as log:
                log.write(sid + '\n')
            emit({'id':rid,'result':{'sessionId':sid}})
        elif method in ('session/new','session/resume'):
            emit({'id':rid,'result':{} if mode == 'missing' else {'sessionId':'fixture-session'}})
        elif method == 'session/set_model' and mode == 'model-refused':   # agy 不认所选模型：提问前就报错，这句话没交给它
            emit({'id':rid,'error':{'code':-32602,'message':'model not available'}})
        elif method == 'session/prompt':
            if mode.startswith('store-locked'):
                with open(__file__ + '.prompts', 'a') as log:
                    log.write(obj['params']['sessionId'] + '\n')
            if mode == 'stream':
                for part in chunks():
                    emit({'method':'session/update','params':{'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':part}}}})
                emit({'id':rid,'result':{'stopReason':'end_turn'}})
                continue
            if mode == 'early-crash':
                print('ENOSPC: project volume full', file=sys.stderr, flush=True)
                sys.exit(42)
            if mode == 'early-stop':
                emit({'id':'q','method':'elicitation/create','params':{'mode':'form','requestedSchema':{'type':'object','properties':{'a':{'type':'string'}}}}})
                continue
            if mode == 'tool-wait-cancel':
                # 工具之后的第二段正文写到一半被停下：agy 不再回 prompt 的答复，正文只在流里。
                for update in ({'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'先检查文件。'}},
                               {'sessionUpdate':'tool_call','toolCallId':'c1','name':'run_command','status':'completed','rawInput':{'CommandLine':'cat notes.txt'}},
                               {'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'真正的答案写到这里'}}):
                    emit({'method':'session/update','params':{'update':update}})
                continue
            emit({'method':'session/update','params':{'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'fixture-'}}}})
            if mode == 'wait-for-cancel':
                continue
            if mode == 'drop':
                emit({'method':'session/update','params':{'update':{'sessionUpdate':'tool_call','toolCallId':'c','title':'run_command','status':'in_progress'}}})
                sys.exit(1)
            if mode == 'text-error':   # 正文写到一半上游断开：agy 用错误答复这条 prompt
                emit({'id':rid,'error':{'code':-32603,'message':'upstream connection reset'}})
                continue
            time.sleep(0.15 if mode != 'slow' else 2)
            emit({'method':'session/update','params':{'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'ok'}}}})
            emit({'id':rid,'result':{'stopReason':'max_tokens' if mode == 'max-tokens' else mode if mode in ('max_turn_requests','refusal','cancelled','unknown_stop') else 'end_turn'}})
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
                if mode.startswith('note-'):
                    # Codex 常见的回合形状：先说一句已完成的说明，再流式输出正文。
                    emit({'method': 'item/completed', 'params': {'item': {'id': 'note', 'type': 'agentMessage', 'text': '我先看一下'}}})
                emit({'method': 'item/agentMessage/delta', 'params': {'itemId': 'msg', 'delta': '已有正文'}})
                if mode == 'completed':
                    emit({'method': 'turn/completed', 'params': {'turn': {'status': 'completed'}}})
                if mode not in ('interrupt', 'note-interrupt'):
                    break
                # 正文已发出、回合未结束：测试见到这个文件再点停止，模拟流式回答中途被用户停下。
                pathlib.Path(__file__).with_name('streamed').write_text('1')
            elif method == 'turn/interrupt':
                emit({'id': ident, 'result': {}})
                emit({'method': 'turn/completed', 'params': {'turn': {'id': 'fixture-turn', 'status': 'interrupted'}}})
                sys.exit(0)
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
            elif mode == 'writer-busy' and method == 'thread/resume':
                # 另一个 Codex 客户端（终端、桌面版）占着这个会话的写锁：真 CLI 的报错原文
                emit({'id':ident,'error':{'code':-32600,'message':'thread thread already has an active writer'}})
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

def question():
    # 三家向用户提问的协议：Claude 的 can_use_tool(AskUserQuestion)、Codex 的 item/tool/requestUserInput、
    # agy 的 elicitation/create（表单，客户端声明了 elicitation.form 才发；没声明时照真 agy 把问题写进正文就结束）。
    # <入口>.mode：ask 等答复再收尾；elsewhere 问完就由 CLI 自己了结；interrupt（agy）等 App 停止。收到的每一行记进 <入口>.log。
    # plan（Claude）：交来 ExitPlanMode 计划卡；批准后切到 bypassPermissions 时照真 CLI（2.1.316 实测）：启动参数里没有
    # --allow-dangerously-skip-permissions / --dangerously-skip-permissions 就回 bypass_not_launched。plan-refuse 一律拒绝切换。
    import json
    mode = open(__file__ + '.mode').read().strip()
    argv = sys.argv[1:]
    with open(__file__ + '.argv', 'w') as f:
        json.dump(argv, f)
    claude, codex = '--input-format' in argv, 'app-server' in argv
    def emit(value):
        print(json.dumps(value, ensure_ascii=False), flush=True)
    color = '你最喜欢的颜色是什么？'
    fruit = '你喜欢哪些水果？'
    prompt_id, can_form = None, False
    def finish_agy(reason='end_turn'):
        emit({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'session','update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'answered'}}}})
        emit({'jsonrpc':'2.0','id':prompt_id,'result':{'stopReason':reason}})
    for line in sys.stdin:
        with open(__file__ + '.log', 'a') as log:
            log.write(line if line.endswith('\n') else line + '\n')
        obj = json.loads(line)
        method, ident = obj.get('method'), obj.get('id')
        if claude:
            request = obj.get('request') or {}
            response = obj.get('response') or {}
            if obj.get('type') == 'control_request' and request.get('subtype') in ('initialize', 'get_context_usage'):
                emit({'type':'control_response','response':{'subtype':'success','request_id':obj['request_id'],'response':{}}})
            elif obj.get('type') == 'user' and mode.startswith('plan'):
                emit({'type':'system','subtype':'init','session_id':'session'})
                emit({'type':'user','isReplay':True,'uuid':'原问编号','message':obj['message']})
                emit({'type':'control_request','request_id':'q-1','request':{'subtype':'can_use_tool','tool_name':'ExitPlanMode','input':{'plan':'1. 建目录'}}})
            elif obj.get('type') == 'control_response' and response.get('request_id') == 'q-1' and mode.startswith('plan') \
                    and (response.get('response') or {}).get('behavior') == 'allow':
                pass   # 等 App 切权限（批准时选了「每步来问我」就不会来，那条路这里不测）
            elif obj.get('type') == 'control_request' and request.get('subtype') == 'set_permission_mode':
                launched = mode != 'plan-refuse' and any(f in argv for f in ('--allow-dangerously-skip-permissions', '--dangerously-skip-permissions'))
                with open(__file__ + '.switched', 'w') as f:
                    f.write('yes' if request.get('mode') != 'bypassPermissions' or launched else 'no')
                if request.get('mode') != 'bypassPermissions' or launched:
                    emit({'type':'control_response','response':{'subtype':'success','request_id':obj['request_id'],'response':{'mode':request.get('mode')}}})
                else:
                    emit({'type':'control_response','response':{'subtype':'error','request_id':obj['request_id'],
                          'error':'Cannot set permission mode to bypassPermissions because the session was not launched with --dangerously-skip-permissions',
                          'error_code':'bypass_not_launched'}})
                emit({'type':'result','subtype':'success','result':'answered','session_id':'session'})
            elif obj.get('type') == 'user':
                emit({'type':'system','subtype':'init','session_id':'session'})
                emit({'type':'user','isReplay':True,'uuid':'原问编号','message':obj['message']})
                emit({'type':'control_request','request_id':'q-1','request':{'subtype':'can_use_tool','tool_name':'AskUserQuestion','input':{'questions':[
                    {'question':color,'header':'颜色','multiSelect':False,'options':[{'label':'红色','description':'暖色'},{'label':'蓝色','description':'冷色'}]},
                    {'question':fruit,'header':'水果','multiSelect':True,'options':[{'label':'苹果','description':''},{'label':'香蕉','description':''},{'label':'橙子','description':''}]}]}}})
                if mode == 'elsewhere':
                    emit({'type':'control_cancel_request','request_id':'q-1'})
                    emit({'type':'result','subtype':'success','result':'answered','session_id':'session'})
            elif obj.get('type') == 'control_response' and response.get('request_id') == 'q-1':
                emit({'type':'result','subtype':'success','result':'answered','session_id':'session'})
        elif codex:
            if method == 'initialize':
                emit({'id':ident,'result':{}})
            elif method in ('thread/start', 'thread/resume'):
                emit({'id':ident,'result':{'thread':{'id':'thread'}}})
            elif method == 'turn/start':
                emit({'id':ident,'result':{'turn':{'id':'turn'}}})
                emit({'id':0,'method':'item/tool/requestUserInput','params':{'threadId':'thread','turnId':'turn','itemId':'call','isBlocking':True,'autoResolutionMs':None,'questions':[
                    {'id':'color','header':'颜色','question':color,'isOther':True,'isSecret':False,'options':[{'label':'红色','description':'暖色'},{'label':'蓝色','description':'冷色'}]},
                    {'id':'fruit','header':'水果','question':fruit,'isOther':True,'isSecret':False,'options':None}]}})
                if mode == 'elsewhere':
                    emit({'method':'serverRequest/resolved','params':{'threadId':'thread','requestId':0}})
            if mode == 'elsewhere' and method == 'turn/start' or ident == 0 and method is None:
                emit({'method':'item/completed','params':{'item':{'type':'agentMessage','id':'answer','text':'answered','phase':'final_answer'}}})
                emit({'method':'turn/completed','params':{'turn':{'id':'turn','status':'completed'}}})
        else:
            if method == 'initialize':
                can_form = isinstance(((obj.get('params') or {}).get('clientCapabilities') or {}).get('elicitation', {}).get('form'), dict)
                emit({'jsonrpc':'2.0','id':ident,'result':{'protocolVersion':1}})
            elif method in ('session/new', 'session/resume'):
                emit({'jsonrpc':'2.0','id':ident,'result':{'sessionId':'session'}})
            elif method in ('session/set_model', 'session/set_mode'):
                emit({'jsonrpc':'2.0','id':ident,'result':{}})
            elif method == 'session/prompt':
                prompt_id = ident
                if not can_form:   # 真 agy 没有表单可用时：问题写进正文，这一轮就结束了
                    emit({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'session','update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':color + '\n- [1] 红色\n- [2] 蓝色'}}}})
                    emit({'jsonrpc':'2.0','id':prompt_id,'result':{'stopReason':'end_turn'}})
                    continue
                emit({'jsonrpc':'2.0','id':'q-1','method':'elicitation/create','params':{'sessionId':'session','toolCallId':'call','mode':'form','message':'The agent has 2 questions.','requestedSchema':{'type':'object','properties':{
                    'q2':{'type':'array','title':color,'items':{'anyOf':[{'const':'1','title':'苹果'},{'const':'2','title':'香蕉、梨'},{'const':'3','title':'橙子'}]}},
                    'q2_other':{'type':'string','title':'Other','description':'Optional free-form answer to: ' + fruit},
                    'q1':{'type':'string','title':color,'oneOf':[{'const':'1','title':'红色'},{'const':'2','title':'蓝色'}]}}}}})
                if mode == 'elsewhere':
                    finish_agy()
            elif ident == 'q-1' and method is None and mode != 'interrupt':
                finish_agy()
            elif method == 'session/cancel':
                finish_agy('cancelled')

def mcp():
    # Claude 和 Codex 转来的 MCP 交互和几种少见的回调，帧格式照 claude 2.1.322、codex app-server 0.167.1 的实测抓包。
    # <入口>.mode 选场景：tool-approval（Codex 的 MCP 工具审批，答了「都允许」再问一个别的工具）、form、form-interrupt（等 App 停止）、
    # complex（认不出的字段）、url、permissions、rui（requestUserInput）、dynamic（item/tool/call）、hook（hook_callback）、unknown。
    # App 答复了请求（或停止）就收尾这一轮；收到的每一行记进 <入口>.log。
    import json
    mode = open(__file__ + '.mode').read().strip()
    argv = sys.argv[1:]
    claude, codex = '--input-format' in argv, 'app-server' in argv
    def emit(value):
        print(json.dumps(value, ensure_ascii=False), flush=True)
    schema = {'type':'object','properties':{
        'name':{'type':'string','title':'名字'},
        'colour':{'type':'string','title':'颜色','oneOf':[{'const':'red','title':'红色'},{'const':'blue','title':'蓝色'}]},
        'size':{'type':'string','title':'尺寸','enum':['s','l'],'enumNames':['小','大']},
        'agree':{'type':'boolean','title':'同意吗'},
        'count':{'type':'integer','title':'数量'},
        'tags':{'type':'array','title':'标签','items':{'anyOf':[{'const':'a','title':'甲、上'},{'const':'b','title':'乙'},{'const':'c','title':'丙'}]}}},
        'required':['name']}
    order = ['name', 'colour', 'size', 'agree', 'count', 'tags']
    if mode == 'complex':
        schema = {'type':'object','properties':{'address':{'type':'object','properties':{'city':{'type':'string'}}}}}
        order = ['address']
    url = 'https://example.com/auth?x=1'
    def tool_approval(rid, server, tool):
        # codex 0.167.1 在「每次询问」（approvalPolicy untrusted）下调 MCP 工具前发的审批，原样照抓包
        emit({'method':'mcpServer/elicitation/request','id':rid,'params':{'threadId':'thread','turnId':'turn','serverName':server,'mode':'form',
              '_meta':{'codex_approval_kind':'mcp_tool_call','persist':['session','always'],'tool_name':tool,'tool_description':'Returns a fixed word.',
                       'tool_params':{'url':'https://example.com'},'tool_params_display':[{'name':'url','display_name':'url','value':'https://example.com'}]},
              'message':'Allow the %s MCP server to run tool "%s"?' % (server, tool),'requestedSchema':{'type':'object','properties':{}}}})
    def finish_codex(status='completed'):
        emit({'method':'item/completed','params':{'item':{'type':'agentMessage','id':'answer','text':'answered','phase':'final_answer'}}})
        emit({'method':'turn/completed','params':{'turn':{'id':'turn','status':status}}})
    def finish_claude():
        emit({'type':'result','subtype':'success','result':'answered','session_id':'session'})
    for line in sys.stdin:
        with open(__file__ + '.log', 'a') as log:
            log.write(line if line.endswith('\n') else line + '\n')
        obj = json.loads(line)
        method, ident = obj.get('method'), obj.get('id')
        if claude:
            request = obj.get('request') or {}
            response = obj.get('response') or {}
            if obj.get('type') == 'control_request' and request.get('subtype') in ('initialize', 'get_context_usage'):
                emit({'type':'control_response','response':{'subtype':'success','request_id':obj['request_id'],'response':{}}})
            elif obj.get('type') == 'control_request' and request.get('subtype') == 'interrupt':
                emit({'type':'control_response','response':{'subtype':'success','request_id':obj['request_id'],'response':{}}})
                finish_claude()
            elif obj.get('type') == 'user':
                emit({'type':'system','subtype':'init','session_id':'session'})
                if mode in ('form', 'form-interrupt', 'complex'):
                    emit({'type':'control_request','request_id':'e-1','request':{'subtype':'elicitation','mcp_server_name':'probe','message':'请填写资料',
                          'mode':'form','requested_schema':schema,'property_order':order}})
                elif mode == 'url':
                    emit({'type':'control_request','request_id':'e-1','request':{'subtype':'elicitation','mcp_server_name':'probe','message':'请登录授权',
                          'mode':'url','url':url,'elicitation_id':'el-1'}})
                elif mode == 'hook':
                    emit({'type':'control_request','request_id':'e-1','request':{'subtype':'hook_callback','callback_id':'hook-0','input':{'hook_event_name':'PreToolUse'}}})
                else:
                    emit({'type':'control_request','request_id':'e-1','request':{'subtype':'future_dialog','anything':1}})
            elif obj.get('type') == 'control_response' and response.get('request_id') == 'e-1' and mode != 'form-interrupt':
                finish_claude()
        elif codex:
            if method == 'initialize':
                emit({'id':ident,'result':{}})
            elif method in ('thread/start', 'thread/resume'):
                emit({'id':ident,'result':{'thread':{'id':'thread'}}})
            elif method == 'turn/start':
                emit({'id':ident,'result':{'turn':{'id':'turn'}}})
                if mode == 'tool-approval':
                    tool_approval(0, 'probe', 'plain_tool')
                elif mode in ('form', 'form-interrupt', 'complex'):
                    # MCP 服务器自己发起的表单：_meta 为 null（实测）
                    emit({'method':'mcpServer/elicitation/request','id':0,'params':{'threadId':'thread','turnId':'turn','serverName':'probe','mode':'form',
                          '_meta':None,'message':'请填写资料','requestedSchema':schema}})
                elif mode == 'url':
                    emit({'method':'mcpServer/elicitation/request','id':0,'params':{'threadId':'thread','turnId':'turn','serverName':'probe','mode':'url',
                          '_meta':None,'message':'请登录授权','url':url,'elicitationId':'el-1'}})
                elif mode == 'permissions':
                    emit({'method':'item/permissions/requestApproval','id':0,'params':{'threadId':'thread','turnId':'turn','itemId':'exec-1','environmentId':'local',
                          'startedAtMs':1795021117226,'cwd':'/tmp','reason':'Requesting network access as instructed for this turn.',
                          'permissions':{'network':{'enabled':True},'fileSystem':{'read':None,'write':['/tmp/out']}}}})
                elif mode == 'rui':
                    # 两题文字相同：答案必须按题目 id 对应；第一题不许自由输入、可多选，第二题是密码
                    emit({'method':'item/tool/requestUserInput','id':0,'params':{'threadId':'thread','turnId':'turn','itemId':'call','isBlocking':False,'autoResolutionMs':None,'questions':[
                          {'id':'first','header':'甲','question':'选哪个？','isOther':False,'isSecret':False,'multiSelect':True,'options':[{'label':'左、上','description':''},{'label':'右','description':''}]},
                          {'id':'second','header':'乙','question':'选哪个？','isOther':True,'isSecret':True,'options':None}]}})
                elif mode == 'dynamic':
                    emit({'method':'item/tool/call','id':0,'params':{'threadId':'thread','turnId':'turn','callId':'c-1','namespace':None,'tool':'lookup','arguments':{}}})
                else:
                    emit({'method':'future/request','id':0,'params':{'threadId':'thread'}})
            elif method == 'turn/interrupt':
                emit({'id':ident,'result':{}})
                finish_codex('interrupted')
            elif method is None and ident == 0 and mode != 'form-interrupt':
                result = obj.get('result') or {}
                if mode == 'tool-approval' and (result.get('_meta') or {}).get('persist') == 'session':
                    tool_approval(1, 'aipethub_browser', 'browser_open')   # 别的工具：codex 照样会问，「这一轮都允许」由 App 代答
                else:
                    finish_codex()
            elif method is None and ident == 1:
                finish_codex()

def steer():
    # agy acp 的中途补充（帧格式照 agy 1.5.11 实测）：一轮进行中再发一条 session/prompt，agy 立刻用 end_turn 答复上一条 prompt，
    # 这一轮接着跑，最后由最新的那条 prompt 的答复结束；等审批或提问时再发，这条被拒（-32603），原来那条照常跑。
    # <入口>.mode：「steer N」收到 N 条补充后收尾（N 默认 1）；permission / question 先发审批 / 提问，答复后收尾；
    # cancel 收到补充后等 session/cancel，由最新的 prompt 答 cancelled。收到的每一行记进 <入口>.log。
    import json
    words = open(__file__ + '.mode').read().split()
    mode, want = words[0], int(words[1]) if len(words) > 1 else 1
    def emit(value):
        print(json.dumps(value, ensure_ascii=False), flush=True)
    def update(u):
        emit({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':'session','update':u}})
    sleep = {'toolCallId':'call-sleep','name':'run_command','args':{'CommandLine':'sleep 15'},'kind':'execute','title':'sleep 15','rawInput':{'CommandLine':'sleep 15'}}
    running, steers, waiting = None, [], False
    def finish():
        update(dict(sleep, sessionUpdate='tool_call_update', status='completed'))
        update({'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':' '.join(['DONE'] + steers)}})
        emit({'jsonrpc':'2.0','id':running,'result':{'stopReason':'end_turn'}})
    for line in sys.stdin:
        with open(__file__ + '.log', 'a') as log:
            log.write(line if line.endswith('\n') else line + '\n')
        obj = json.loads(line)
        method, ident, params = obj.get('method'), obj.get('id'), obj.get('params') or {}
        if method == 'initialize':
            emit({'jsonrpc':'2.0','id':ident,'result':{'protocolVersion':1}})
        elif method in ('session/new', 'session/resume'):
            emit({'jsonrpc':'2.0','id':ident,'result':{'sessionId':'session'}})
        elif method in ('session/set_model', 'session/set_mode'):
            emit({'jsonrpc':'2.0','id':ident,'result':{}})
        elif method == 'session/prompt' and running is None:
            running = ident
            update(dict(sleep, sessionUpdate='tool_call', status='in_progress'))
            if mode == 'permission':
                waiting = True
                emit({'jsonrpc':'2.0','id':'p-1','method':'session/request_permission','params':{'sessionId':'session','toolCall':dict(sleep, sessionUpdate='tool_call', status='pending'),
                      'options':[{'optionId':'allow','name':'Allow','kind':'allow_once'},{'optionId':'reject','name':'Reject','kind':'reject_once'}]}})
            elif mode == 'question':
                waiting = True
                emit({'jsonrpc':'2.0','id':'q-1','method':'elicitation/create','params':{'sessionId':'session','toolCallId':'call','mode':'form','message':'The agent has a question.','requestedSchema':{'type':'object','properties':{
                      'q1':{'type':'string','title':'颜色？','oneOf':[{'const':'1','title':'红色'},{'const':'2','title':'蓝色'}]}}}}})
        elif method == 'session/prompt' and waiting:
            emit({'jsonrpc':'2.0','id':ident,'error':{'code':-32603,'message':"Can't add this prompt to session session: the running prompt is waiting for a permission or question answer; answer it or send session/cancel, then send this prompt again"}})
        elif method == 'session/prompt':
            emit({'jsonrpc':'2.0','id':running,'result':{'stopReason':'end_turn','usage':{'inputTokens':11940,'outputTokens':38,'totalTokens':11978}}})
            running = ident
            steers.append(''.join(b.get('text', '') for b in params.get('prompt', []) if b.get('type') == 'text'))
            if mode == 'steer' and len(steers) >= want:
                finish()
        elif ident in ('p-1', 'q-1') and method is None:
            waiting = False
            finish()
        elif method == 'session/cancel':
            update(dict(sleep, sessionUpdate='tool_call_update', status='failed'))
            emit({'jsonrpc':'2.0','id':running,'result':{'stopReason':'cancelled'}})

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
            /bin/sh -c 'trap "" TERM; echo $$ > "$1.tmp"; mv "$1.tmp" "$1"; exec /bin/sleep 600' fixture "$0.child" & ;;
        *'"session/cancel"'*) exit 0 ;;
    esac
done
''',
    'cancel-tail': r'''
#!/bin/sh
# 像 agy 跑 `sleep 120; echo unexpected > f`：zsh 前台等 sleep，sleep 一结束就写尾部标记。停止时回 cancelled，输入关掉再退出。
while IFS= read -r line; do
    line=$(printf '%s' "$line" | /usr/bin/sed 's#\\/#/#g')
    case "$line" in
        *'"initialize"'*) echo '{"id":1,"result":{}}' ;;
        *'"session/new"'*) echo '{"id":2,"result":{"sessionId":"fake-session"}}' ;;
        *'"session/set_model"'*) echo '{"id":3,"result":{}}' ;;
        *'"session/prompt"'*)
            /bin/zsh -c 'echo $$ > "$1.tmp"; mv "$1.tmp" "$1"; /bin/sleep 600; echo unexpected > "$1.tail"' fixture "$0.child" </dev/null >/dev/null 2>&1 & ;;
        *'"session/cancel"'*) echo '{"id":4,"result":{"stopReason":"cancelled"}}' ;;
    esac
done
''',
    'stop-orphan': r'''
#!/bin/sh
# Claude（stream-json）和 Codex（app-server）两种协议：提问后起一个普通的 sleep，收到中断时根进程先退出，sleep 留在后台。
# sleep 不占输出管道，App 很快拿到停止结果，测试只看宽限期后它有没有被收走。
while IFS= read -r line; do
    line=$(printf '%s' "$line" | /usr/bin/sed 's#\\/#/#g')
    case "$line" in
        *'"subtype":"interrupt"'*|*'"turn/interrupt"'*) exit 0 ;;
        *'"method":"initialize"'*) echo '{"id":1,"result":{}}' ;;
        *'"thread/start"'*) echo '{"id":2,"result":{"thread":{"id":"fake-thread"}}}' ;;
        *'"turn/start"'*|*'"type":"user"'*)
            case "$line" in *'"turn/start"'*) echo '{"id":3,"result":{"turn":{"id":"fake-turn"}}}' ;; esac
            /bin/sh -c 'echo $$ > "$1.tmp"; mv "$1.tmp" "$1"; exec /bin/sleep 600' fixture "$0.child" </dev/null >/dev/null 2>&1 & ;;
    esac
done
''',
    'unsent-stop': r'''
#!/bin/sh
# 已有会话里追问时点停止。<入口>.mode 为 unsent：Claude 收到这句但没记进会话记录，Codex 不答 thread/resume（回合没开始）；
# sent：Claude 往 <入口>.journal 指的会话记录写一行 user，Codex 开始回合。走到这一步写 <入口>.started；收到中断或输入关闭就退出。
[ "$1" = agents ] && { echo '[]'; exit 0; }
mode=$(cat "$0.mode")
while IFS= read -r line; do
    line=$(printf '%s' "$line" | /usr/bin/sed 's#\\/#/#g')
    case "$line" in
        *'"subtype":"interrupt"'*|*'"turn/interrupt"'*) exit 0 ;;
        *'"method":"initialize"'*) echo '{"id":1,"result":{}}' ;;
        *'"thread/resume"'*)
            if [ "$mode" = sent ]; then echo '{"id":2,"result":{"thread":{"id":"fake-thread"}}}'; else echo started > "$0.started"; fi ;;
        *'"turn/start"'*) echo '{"id":3,"result":{"turn":{"id":"fake-turn"}}}'; echo started > "$0.started" ;;
        *'"type":"user"'*)
            [ "$mode" = sent ] && echo '{"type":"user","message":{"role":"user","content":"追问"}}' >> "$(cat "$0.journal")"
            echo started > "$0.started" ;;
    esac
done
''',
    'hung-tree': r'''
#!/bin/sh
trap '' TERM
echo $$ > "$0.pid"
/bin/sh -c 'trap "" TERM; echo $$ > "$1"; exec /bin/sleep 600' fixture "$0.child" &
echo partial-output
wait
''',
    'dsh-starting': r'''
#!/bin/sh
echo started > "$0.started"
sleep 600
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
# 要被取消的那个睡得比测试的期限长得多：没被取消就还活着，测试才分得出来，负载高时也不会靠自然结束蒙混过关
case "$4" in *running.docx|*timeout.docx) sleep 600 & ;; *) sleep 2 & ;; esac
echo $! > '__ROOT__/child'
wait
mkdir -p "$3/out.qlpreview"
echo '<html>done</html>' > "$3/out.qlpreview/Preview.html"
''',
    'preview-stubborn': r'''
#!/bin/sh
# 装好忽略 TERM 之后才记下 pid：测试看到 pid 就能马上取消，不用猜要等多久
/bin/sh -c 'trap "" TERM; echo $$ > "$0"; while :; do sleep 1; done' '__ROOT__/stubborn-child' &
wait
''',
}

if __name__ == '__main__':
    behavior, path, *args = sys.argv[1:]
    # Existing Python fixtures use __file__ and argv[0] for their temporary state directory.
    __file__ = path
    if behavior in ('backend', 'terminal', 'initialization', 'question', 'mcp', 'steer'):
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
