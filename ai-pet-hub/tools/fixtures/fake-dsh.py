#!/usr/bin/python3
# 假 DeepSeek（dsh web）服务：照 dsh 0.1.0-rc.7 实测的线路模仿 HTTP 接口和两条 WebSocket 事件流，
# 让 DeepSeek 的离线测试不用真实 dsh 和网络。FIXTURE_MODE 选场景（下面按 mode 分支）；
# 使用者：tools/test-deepseek.py 起的 selftest deepseek 各模式，以及窗口测试 e2e-stream 的 DeepSeek 一份（run-suite.py）。
import os,sys,time,json,struct,hashlib,base64,http.server,threading
mode=os.environ.get('FIXTURE_MODE','plain')
modelState={}
sockets=[]
if mode == 'start-fail':
 # 照 dsh 0.1.0-rc.7 读到坏 cordis.patch.yml 时的 stderr：原因行在前，后面是长调用栈和 Node 版本；在写 pid 之前退出，经 dshReady 以主目录为 cwd 启动时也不留文件
 stack=''.join('    at frame%d (file:///fixture/binaries/node/workspace/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js:%d:9)\n'%(i,800+i) for i in range(30))
 os.write(2,("file:///fixture/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js:838\n\t\tthrow new Error(`${binName}: failed to parse ${label} ${file}: ${String(error)}`);\n\t\t      ^\n\n"
  "Error: dsh: failed to parse patches /fixture/dshhome/cordis.patch.yml: YAMLException: missed comma between flow collection entries (2:6)\n\n"
  " 1 | foo: [unclosed\n 2 |   bar: : :\n----------^\n"+stack+"\nNode.js v26.11.1\n").encode())
 sys.exit(1)
open('fake-'+mode+'.pid','w').write(str(os.getpid()))
muxes=[];muxLock=threading.Lock();muxConns=[]
# 照 dsh-host-apiproxy：提问和审批登记在服务端，没有超时；事件流（重新）连上时把还没答的重放一遍
pendingQ={};pendingA={};counts={}
def frame(op,payload):
 n=len(payload)
 head=bytes([128|op,n]) if n<126 else (bytes([128|op,126])+struct.pack('!H',n) if n<65536 else bytes([128|op,127])+struct.pack('!Q',n))
 return head+payload
def push(*payloads,rpc='push',delay=.2):
 # DR 场景：服务主动往 mux 事件流推帧（提问、正文、回合结束），走和真 dsh 一样的线路；
 # 在 HTTP 答复之后按顺序推，和真服务「先回包、后出事件」的时序一样
 def go():
  time.sleep(delay)
  for payload in payloads:
   if mode == 'dr-stream' and payload.get('event',{}).get('type') == 'assistant/chunk':time.sleep(.04)
   payload=dict(payload);rid=payload.pop('_rpc',rpc)   # 要人答的帧各有自己的 rpcId（答复时原样带回）
   data=frame(1,json.dumps({'type':'server-request','rpcId':rid,'method':'events.mux','payload':payload}).encode())
   with muxLock:
    for w in muxes:
     try:w.write(data);w.flush()
     except OSError:pass
 threading.Thread(target=go).start()
def ev(t,data):return {'type':'session/event','sessionId':'probe','event':{'type':t,'data':data}}
def said(text):return ev('assistant/message',{'turn':1,'step':1,'message':{'content':[{'type':'text','text':text}]}})
# dsh 先写 turn/start、step/start，再写这一轮收下的那句话（source.rpcId 是发它的那次 session.prompt 的编号）
def opened(rpc,text='probe'):return [ev('turn/start',{'turn':1}),ev('step/start',{'turn':1,'step':1}),ev('user/message',{'role':'user','source':{'kind':'user','rpcId':rpc},'content':[{'type':'text','text':text}]})]
def ended(kind='completed'):return ev('turn/end',{'turn':1,'reason':{'kind':kind}})
def asked(rpc,questions,sid='probe'):
 pendingQ[rpc]={'sessionId':sid,'questions':questions}
 return {'_rpc':rpc,'type':'question/requested','sessionId':sid,'questions':questions}
def wanted(rpc,payload):
 pendingA[rpc]=payload
 return dict(payload,_rpc=rpc)
def plan(rpc):
 return asked(rpc,[{'id':'plan-review','header':'Plan review','question':'Approve this plan and leave plan mode?','detail':'# 计划\n\n1. 先写测试\n2. 再改代码',
  'options':[{'label':'Approve','description':'Leave plan mode'},{'label':'Keep planning','description':'Stay in plan mode'}],'intent':{'kind':'plan-review','approve':'Approve'}}])
def matches(v,q):
 # dsh-host-apiproxy 的 matchesQuestions：答案和题目等长、按 id 对应；单选不能同时带 selected 和 custom；custom 不能是空白；selected 只能是选项标签
 ans=v.get('answer',{}).get('answers')
 if v.get('sessionId')!=q['sessionId'] or not isinstance(ans,list) or len(ans)!=len(q['questions']):return False
 for a,qq in zip(ans,q['questions']):
  sel=a.get('selected');custom=a.get('custom')
  if a.get('id')!=qq['id'] or not isinstance(sel,list) or len(set(sel))!=len(sel):return False
  if custom is not None and custom.strip()=='':return False
  if not qq.get('multiSelect') and ((custom is not None and sel) or len(sel)>1):return False
  if any(x not in [o['label'] for o in qq.get('options',[])] for x in sel):return False
 return True
def receipt(obj):
 # POST /api/respond 的回执：dsh 不收的答复（bad-response）请求保持待答；没有这个请求（not-pending）多半是在别处答过了
 rid=obj.get('rpcId');res=obj.get('result',{})
 if rid in pendingA:
  a=pendingA[rid];v=res.get('value',{})
  if not res.get('ok') or v.get('approvalId')!=a['approvalId'] or v.get('sessionId')!=a['sessionId'] or v.get('outcome') not in ('allowed-once','rejected'):return {'accepted':False,'reason':'bad-response'},None
  pendingA.pop(rid);return {'accepted':True},('approval',a,v['outcome'])
 if rid not in pendingQ:return {'accepted':False,'reason':'not-pending'},None
 q=pendingQ[rid];n=counts[rid]=counts.get(rid,0)+1
 if rid=='q-bad' or (rid=='q-bad1' and n==1):return {'accepted':False,'reason':'bad-response'},None
 if not res.get('ok'):
  e=res.get('error',{})
  if e.get('code')!='cancelled' or not isinstance(e.get('message'),str) or not isinstance(e.get('details'),dict):return {'accepted':False,'reason':'bad-response'},None
  pendingQ.pop(rid);return {'accepted':True},('cancelled',q,None)
 if not matches(res.get('value',{}),q):return {'accepted':False,'reason':'bad-response'},None
 pendingQ.pop(rid);return {'accepted':True},('answered',q,res['value']['answer']['answers'])
if mode == 'stderr':
 os.write(2,b'x'*262144)
 open('stderr-complete','w').write('yes')
prompts=[]
def dg(path,obj,p,data):
 # DG 场景：照 dsh 0.1.0-rc.7 的线路模拟要人答的请求（计划评审、dsh 自己开的回合、回执、事件流断开）
 if path == '/api/probe.request':   # 冒充 dsh 自己开的一轮里发来提问 / 审批（没有 App 回合在听）
  f=p['frame'];push(asked(p['rpcId'],f['questions'],f['sessionId']) if f['type']=='question/requested' else wanted(p['rpcId'],f),delay=0)
 if path == '/api/probe.forget':pendingQ.pop(p['rpcId'],None)   # 在别处答掉了、了结帧又没收到
 if path == '/api/probe.resolve':
  pendingQ.pop(p['rpcId'],None);push({'type':'question/resolved','sessionId':'probe','questionRpcId':p['rpcId'],'outcome':'answered'},delay=0)
 if path == '/api/probe.flap':modelState['flap']=p.get('times',0)   # 之后重连上来的 mux 流答完 ping 就断，共这么多次
 if path == '/api/probe.drop-mux':   # 事件流内部出错：先发 stream/error，再关掉这条 socket（dsh 进程还活着）
  bad=frame(1,json.dumps({'type':'server-request','rpcId':'x','method':'events.mux','payload':{'type':'stream/error','error':{'code':'internal','message':'boom','details':{}}}}).encode())
  with muxLock:
   for w,c in zip(muxes,muxConns):
    try:w.write(bad);w.flush();c.shutdown(2)
    except OSError:pass
   muxes.clear();muxConns.clear()
 if mode.startswith('dg-gap-') and path == '/api/session.history':
  # 丢帧期间磁盘已写入本轮定稿，后面还可能有另一轮。
  history=opened(prompts[-1])+[said('完整正文')]
  if mode == 'dg-gap-running':
   if modelState.get('recovered'):history.append(ended())
  else:
   if mode != 'dg-gap-missing':history.append(ended('max-tokens' if mode == 'dg-gap-limit' else 'completed'))
   history+=opened('foreign')+[said('别人的回答'),ended()]
  rows=[{'event':dict(f['event'],seq=i+1)} for i,f in enumerate(history)]
  data=json.dumps({'result':{'ok':True,'value':{'events':rows,'hasMore':False}}}).encode()
 if path == '/api/session.cancel':push(ended('aborted'))
 if path == '/api/session.prompt' and p.get('mode') == 'queue':
  rid=obj.get('rpcId');prompts.append(rid);n=len(prompts)
  if mode.startswith('dg-gap-'):push(*opened(rid),said('半截'))
  if mode == 'dg-plan':push(*opened(rid),plan('q-plan-%d'%n))
  if mode == 'dg-receipt':push(*opened(rid),asked('q-bad1',[{'id':'fmt','question':'导出成哪种格式？','options':[{'label':'PDF'},{'label':'PNG'}]}]))
  if mode == 'dg-own-turn':
   # dsh 自己开的一轮（后台任务结束后唤醒）排在这句前面：它的事件不是这句话的回答
   push(ev('turn/start',{'turn':1}),ev('user/message',{'role':'user','source':{'kind':'job-wakeup'},'content':[{'type':'text','text':'job done'}]}),said('background summary'),ended(),
        *opened(rid),said('own answer'),ended())
 if path == '/api/respond':
  r,what=receipt(obj)
  with open('rpc-'+mode+'.jsonl','a') as f:f.write(json.dumps({'receipt':r,'rpcId':obj.get('rpcId')})+'\n')
  if what and what[0]=='approval':
   a=what[1];push({'type':'approval/resolved','sessionId':a['sessionId'],'approvalId':a['approvalId'],'outcome':what[2]},delay=0)
   if mode == 'dg-unattended' and prompts:push(ended(),*opened(prompts[-1]),said('own answer'),ended())   # 那一轮做完，排着的这句才开始
  elif what:
   rid=obj.get('rpcId');push({'type':'question/resolved','sessionId':what[1]['sessionId'],'questionRpcId':rid,'outcome':'cancelled' if what[0]=='cancelled' else 'answered'},delay=0)
   ans=what[2] or []
   if mode == 'dg-plan' and what[0]=='answered':push(said('approved' if ans[0]['selected']==['Approve'] else 'feedback: '+ans[0].get('custom','')),ended())
   if mode == 'dg-receipt' and rid=='q-bad1':push(asked('q-bad',[{'id':'fmt','question':'再选一次？','options':[{'label':'PDF'},{'label':'PNG'}]}]))
  data=json.dumps(r).encode()
 return data
promptRelease = threading.Event()
class H(http.server.BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*args):pass
 def do_GET(self):
  if mode == 'balance-home' and self.path.endswith('/user/balance'):
   account=self.path.split('/')[1]
   amount={'default':'11.00','selected':'22.00'}.get(account) if self.headers['Authorization']=='Bearer '+account else None
   data=json.dumps({'balance_infos':[{'currency':'CNY','total_balance':amount}]} if amount else {}).encode()
   self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
   return
  key=self.headers['Sec-WebSocket-Key']
  self.send_response(101);self.send_header('Upgrade','websocket');self.send_header('Connection','Upgrade');self.send_header('Sec-WebSocket-Accept',base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode());self.end_headers()
  def send(op,payload):
   with muxLock:self.wfile.write(frame(op,payload));self.wfile.flush()
  sockets.append(send)
  if self.path.endswith('events.mux'):
   with muxLock:muxes.append(self.wfile);muxConns.append(self.connection)
   if mode in ('dg-gap-limit', 'dg-gap-missing') and prompts:
    push({'type':'host/session-status','sessionId':'probe','running':False},delay=0)
   # 照 dsh-host-apiproxy 的 events.mux：先给每个已载入的会话发 session/subscribed（有待答请求的会话必然已载入），再重放待答的提问和审批
   for sid in dict.fromkeys([q['sessionId'] for q in list(pendingQ.values())]+[a.get('sessionId') for a in list(pendingA.values())]):
    send(1,json.dumps({'type':'server-request','rpcId':'sub-'+str(time.time()),'method':'events.mux','payload':{'type':'session/subscribed','sessionId':sid,'lastSeq':0}}).encode())
   for rid,q in list(pendingQ.items()):send(1,json.dumps({'type':'server-request','rpcId':rid,'method':'events.mux','payload':{'type':'question/requested','sessionId':q['sessionId'],'questions':q['questions']}}).encode())
   for rid,a in list(pendingA.items()):send(1,json.dumps({'type':'server-request','rpcId':rid,'method':'events.mux','payload':a}).encode())
  if mode == 'early-event':
   send(1,b'{"payload":{"sessionId":"probe","type":"host/session-status","running":false}}')
   time.sleep(.1)
  try:
   while True:
    h=self.rfile.read(2)
    if len(h)<2:break
    op=h[0]&15;n=h[1]&127
    if n==126:n=struct.unpack('!H',self.rfile.read(2))[0]
    elif n==127:n=struct.unpack('!Q',self.rfile.read(8))[0]
    mask=self.rfile.read(4) if h[1]&128 else None
    p=self.rfile.read(n)
    if mask:p=bytes(x^mask[i%4] for i,x in enumerate(p))
    if op==9:
     send(10,p)
     # 连得上、立刻又断（流内部出错）：App 的重连确认（ping）已经成功，随后这条流马上没了
     if self.path.endswith('events.mux') and modelState.get('flap',0)>0:
      modelState['flap']-=1
      with muxLock:
       if self.wfile in muxes:i=muxes.index(self.wfile);muxes.pop(i);muxConns.pop(i)
      send(1,json.dumps({'type':'server-request','rpcId':'x','method':'events.mux','payload':{'type':'stream/error','error':{'code':'internal','message':'flap','details':{}}}}).encode())
      self.connection.shutdown(2);break
    elif op==8:break
  except (BrokenPipeError,ConnectionResetError):pass
 def do_POST(self):
  raw=self.rfile.read(int(self.headers.get('Content-Length',0)))
  obj=json.loads(raw)
  logged=json.loads(json.dumps(obj))
  if self.path == '/api/session.prompt':logged['observedModel']=modelState.get('model')
  if mode=='dr-service-drop' and self.path=='/api/probe.crash':
   os.write(2,b'ENOSPC: journal full\n'); os._exit(42)
  if self.path == '/api/probe.recover':modelState['recovered']=True
  if self.path == '/api/probe.history-total':modelState['historyTotal']=obj.get('payload',{}).get('total',5101)
  for block in logged.get('payload',{}).get('content',[]):
   if 'data' in block:block['data']='[base64 chars='+str(len(block['data']))+']'
  with open('rpc-'+mode+'.jsonl','a') as f:f.write(json.dumps(logged)+'\n')
  if mode == 'completed-lost':
   if self.path == '/api/session.prompt':
    push(*opened(obj['rpcId']),said('已确认的完整回答'),ended(),delay=0)
    promptRelease.wait(600)
    self.close_connection=True
    return
   if self.path == '/api/probe.release':promptRelease.set()
  if mode in ('cancel-held','cancel-idle'):
   if self.path == '/api/session.prompt':
    modelState['ownRpc']=obj['rpcId']
    push(*opened(obj['rpcId']),said('半截'),delay=0)
    promptRelease.wait(600)
   if self.path == '/api/session.cancel':
    push(ended('aborted') if mode=='cancel-held' else {'type':'host/session-status','sessionId':'probe','running':False},delay=0)
   if self.path == '/api/probe.release':promptRelease.set()
  if mode == 'cancel-race' and obj.get('payload',{}).get('mode') == 'steer':time.sleep(1)
  if mode in ('concurrent-config','transaction') and self.path == '/api/session.selectModel':
   modelState['model']=obj['payload']['model']
   if modelState['model']=='model-a':
    open('model-a.flag','w').write('yes');time.sleep(0.5)
  if mode == 'dg-unattended' and self.path == '/api/respond' and obj.get('rpcId') == 'q-w' and not modelState.get('retried'):
   modelState['retried']=True;self.send_error(503);return
  if mode == 'slow-approval':   # respond 扣到测试放行：停止在放行前就做完，才说明它没等 respond
   if self.path == '/api/respond':
    promptRelease.wait(600)
    with open('rpc-'+mode+'.jsonl','a') as f:f.write('{"respond":"released"}\n')
   if self.path == '/api/probe.release':promptRelease.set()
  if self.path == '/api/session.cancel':open('cancel.flag','w').write('yes')
  if self.path == '/api/probe.emit':   # 冒充服务自己往会话里写了一条（事件流上出现这个会话的事件）；带 frame 就原样推这一帧
   frame=json.dumps({'payload':obj['payload'].get('frame') or {'sessionId':obj['payload']['sessionId'],'type':'session/event','event':{'seq':1,'type':'probe/write'}}}).encode()
   for s in sockets:
    try:s(1,frame)
    except OSError:pass
  if mode == 'compact' and obj.get('payload',{}).get('args',{}).get('line') == '/compact':time.sleep(2)
  data=json.dumps({'type':'server-response','rpcId':obj.get('rpcId'),'result':{'ok':True,'value':{}}}).encode()
  if mode == 'compact' and obj.get('payload',{}).get('args',{}).get('line') == '/compact':
   data=json.dumps({'result':{'ok':True,'value':{'result':{'kind':'success','sourceEventSeq':5,'text':'Compacted 2 history items (~80 tokens).'}}}}).encode()
  args=obj.get('payload',{}).get('args',{})
  if args.get('agentId')=='inner-denied' and args.get('line','').startswith('/permission'):
   data=json.dumps({'result':{'ok':True,'value':{'result':{'kind':'error','text':'preset refused'}}}}).encode()
  if mode=='compact' and modelState.get('recovered') and args.get('line')=='/compact':
   data=json.dumps({'result':{'ok':True,'value':{'result':{'kind':'success','text':'Compaction cancelled.'}}}}).encode()
  if args.get('agentId')=='short-history' and args.get('line')=='/compact':
   data=json.dumps({'result':{'ok':True,'value':{'result':{'kind':'error','text':'Compaction could not produce a useful summary. The conversation is unchanged.'}}}}).encode()
  if mode == 'cancel-first' and self.path == '/api/session.create':
   data=json.dumps({'result':{'ok':True,'value':{'sessionId':'session-new'}}}).encode()
  # 新会话的首问：建出来的会话也叫 probe，推的事件（固定发给 probe）才能被这一轮收到
  if (mode == 'configure-fail' or mode.startswith('image-submit-')) and self.path == '/api/session.create':
   data=json.dumps({'result':{'ok':True,'value':{'sessionId':'probe'}}}).encode()
  if mode == 'dr-stream' and self.path == '/api/session.create':
   data=json.dumps({'result':{'ok':True,'value':{'sessionId':'probe'}}}).encode()
  if self.path == '/api/probe.state':data=json.dumps({'result':{'ok':True,'value':modelState}}).encode()
  if mode in ('history-pages','history-cursor') and self.path == '/api/session.history':
   params=obj.get('payload',{});before=params.get('beforeSeq');total=modelState.get('historyTotal',5101)
   if params.get('sessionId') == 'other':total=2
   if mode == 'history-cursor':seqs=[100 if before is None else before+1];more=True
   else:
    end=min(total+1,before if before is not None else total+1)
    seqs=list(range(max(1,end-params.get('maxMessages',80)),end));more=bool(seqs and seqs[0]>1)
   events=[{'event':{'seq':seq,'type':'user/message','time':seq,'data':{'source':{'kind':'user'},'content':[{'type':'text','text':'history-'+str(seq)}]}}} for seq in seqs]
   if params.get('sessionId')=='long-fixture':
    # 流式片段多的长会话：每轮 1 句提问 + 49 个正文片段 + 结束，60 页原始事件凑不满 300 条可见消息
    for row in events:
     event=row['event'];seq=event['seq'];phase=(seq-1)%51
     if phase==0: event['data']['content'][0]['text']='old-body-needle' if seq==1 else '普通提问'
     elif phase==50: event.update(type='turn/end',data={'turn':seq//51,'reason':{'kind':'completed'}})
     else: event.update(type='assistant/chunk',data={'turn':(seq-1)//51+1,'step':1,'chunk':{'type':'text-delta','text':'a'}})
   if params.get('sessionId') in ('active','ended','session-active'):
    events=[{'event':{'seq':1,'type':'turn/start','time':int(time.time()*1000),'data':{'turn':1}}}]
    if params['sessionId']=='ended': events.append({'event':{'seq':2,'type':'turn/end','data':{'turn':1,'reason':{'kind':'completed'}}}})
    more=False
   if params.get('sessionId','').startswith('session-peer-'):
    events=[{'event':{'seq':i+1,'time':int(time.time()*1000),**frame['event']}} for i,frame in enumerate(opened('peer')+[said('正在处理'),ended('aborted')])]
    more=False
   value={'events':events,'hasMore':more}
   if before is None and params.get('sessionId')=='probe':
    value['projections']={'asOfSeq':total,'values':{'contextPressure':{'pressureTokens':13,'projectedTokens':12,'contextWindow':100},'contextBreakdown':{'systemTokens':5,'messageTokens':7}}}
   data=json.dumps({'result':{'ok':True,'value':value}}).encode()
  if mode == 'disk-moved' and self.path == '/api/session.history':
   if 'diskBody' not in modelState:
    with open('sessions/grp/probe/session.jsonl.zstd','rb') as archived:
     modelState['diskBody']='new-body' if b'new-body' in archived.read() else 'old-body'
   event=said(modelState['diskBody'])
   data=json.dumps({'result':{'ok':True,'value':{'events':[event],'hasMore':False}}}).encode()
  if mode in ('search','disk-moved') and self.path == '/api/session.list':
   data=json.dumps({'result':{'ok':True,'value':{'items':[{'sessionId':'probe','blank':False,'cwd':os.getcwd(),'updatedAt':2 if modelState.get('recovered') else 1}]}}}).encode()
  if mode == 'deleted' and self.path == '/api/session.list':
   data=json.dumps({'result':{'ok':True,'value':{'items':[{'sessionId':sid,'blank':False,'cwd':os.getcwd(),'updatedAt':1} for sid in ('probe','kept')]}}}).encode()
  if mode == 'list-external':
   # 照 dsh 0.1.0-rc.7：session.list 的标题和时间来自本服务的投影缓存，别的 dsh 写过磁盘后它不更新、缺缓存时没有标题；
   # session.history 末页的投影按磁盘现算。probe.fresh 冒充别处续写或改名，只改后者；probe.add 冒充别处新建、列表给的是旧标题的会话（fields 是列表行的其他字段）。
   # 「磁盘」存在 cwd 的文件里，重起服务后的新进程接着用；probe.hold 冒充本服务内存里接手过的会话：这个进程之后给它的末页一直是接手时的样子。
   p=obj.get('payload',{})
   state=json.load(open('list-external.json')) if os.path.exists('list-external.json') else {
    'list':{'ext-a':['甲旧标题',3000],'ext-b':['乙旧标题',2000],'untitled':['',1000]},
    'truth':{'ext-a':['甲旧标题',3000],'ext-b':['乙旧标题',2000],'untitled':['补上的标题',1000]}}
   if self.path in ('/api/probe.fresh','/api/probe.add'):
    state['truth'][p['sessionId']]=[p['title'],p['lastPromptAt']]
    if self.path == '/api/probe.add':state['list'][p['sessionId']]=[p['listTitle'],p['lastPromptAt'],p.get('fields',{})]
    json.dump(state,open('list-external.json','w'))
   if self.path == '/api/probe.hold':modelState.setdefault('held',{})[p['sessionId']]=state['truth'][p['sessionId']]
   if self.path == '/api/session.list':
    rows=[{**dict(sessionId=sid,blank=False,cwd=os.getcwd(),origin='web',updatedAt=row[1],**({'projections':{'values':{'title':row[0]}}} if row[0] else {})),**(row[2] if len(row)>2 else {})}
          for sid,row in state['list'].items()]
    data=json.dumps({'result':{'ok':True,'value':{'items':rows}}}).encode()
   if self.path == '/api/session.history':
    title,at=modelState.get('held',{}).get(p['sessionId']) or state['truth'][p['sessionId']]
    data=json.dumps({'result':{'ok':True,'value':{'events':[],'hasMore':False,'projections':{'values':{'title':title,'sessionListMetadata':{'blank':False,'lastPromptAt':at}}}}}}).encode()
  if mode in ('search','deleted') and self.path == '/api/session.history':
   word='changed-visible-needle' if modelState.get('recovered') else 'original-visible-needle'
   events=[{'event':{'seq':1,'type':'user/message','data':{'source':{'kind':'user'},'content':[{'type':'text','text':'question'}]}}},
           {'event':{'seq':2,'type':'assistant/message','protocol':'protocol-only-needle','data':{'turn':1,'step':1,'message':{'content':[{'type':'text','text':word}]}}}},
           {'event':{'seq':3,'type':'turn/end','data':{'reason':{'kind':'completed'}}}}]
   if mode=='deleted' and obj['payload']['sessionId']=='kept': events[0]['event']['data']['source']['rpcId']='web-1'
   data=json.dumps({'result':{'ok':True,'value':{'events':events,'hasMore':False}}}).encode()
  if not modelState.get('recovered') and ((mode == 'configure-fail' and self.path == '/api/session.selectModel') or (mode == 'effort-fail' and 'reasoningEffort' in obj.get('payload',{})) or (mode == 'permission-fail' and obj.get('payload',{}).get('args',{}).get('line','').startswith('/permission'))):data=json.dumps({'result':{'ok':False,'error':{'code':'model-unavailable','message':'fixture chosen model unavailable'}}}).encode()
  p=obj.get('payload',{})
  if mode.startswith('image-submit-') and self.path == '/api/session.prompt':
   if any(b.get('type') == 'image' for b in p['content']):
    if mode == 'image-submit-lost':
     # 服务已入队，只截断 HTTP 回执。
     self.send_response(200);self.send_header('Content-Length','100');self.end_headers()
     self.wfile.write(b'{');self.wfile.flush();self.connection.shutdown(2);return
    why='Model does not support image input.' if mode in ('image-submit-unsupported','image-submit-path-full') else 'ENOSPC: attachment store full'
    data=json.dumps({'result':{'ok':False,'error':{'code':'attachment-error','message':why}}}).encode()
   elif mode == 'image-submit-path-full':data=json.dumps({'result':{'ok':False,'error':{'code':'storage','message':'ENOSPC: journal full'}}}).encode()
   else:push(*opened(obj['rpcId']),said('路径已收到'),ended())
  if mode=='compact' and self.path=='/api/session.history':
   prior=opened('previous')+[said('之前的回答'),ended()]
   later=opened('next')+[said('之后的回答'),ended()]
   rows=[{'event':dict(frame['event'],seq=i+1,time=(1000 if i<len(prior) else 4102444800000)+i)} for i,frame in enumerate(prior+later)]
   data=json.dumps({'result':{'ok':True,'value':{'events':rows,'hasMore':False}}}).encode()
  if mode == 'cancel-idle' and self.path == '/api/session.history':
   # 重读时服务给缺结束事件的回合补出中断，磁盘日志里没有这条。
   history=opened(modelState['ownRpc'])+[said('半截'),ended('aborted')]
   if modelState.get('recovered'):history+=opened('foreign')
   rows=[{'event':dict(f['event'],seq=i+1,time=int(time.time()*1000)+i)} for i,f in enumerate(history)]
   data=json.dumps({'result':{'ok':True,'value':{'events':rows,'hasMore':False}}}).encode()
  if mode == 'dr-service-drop' and self.path == '/api/session.history':
   with open('drop-rpc') as saved:history=opened(saved.read())+[ended('aborted')]+opened('foreign')+[ended('aborted')]
   rows=[{'event':dict(f['event'],seq=i+1)} for i,f in enumerate(history)]
   data=json.dumps({'result':{'ok':True,'value':{'events':rows,'hasMore':False}}}).encode()
  if mode.startswith('dr-') and self.path == '/api/session.prompt' and p.get('mode') == 'queue':
   start=opened(obj.get('rpcId'))
   if mode == 'dr-stream':
    part='甲乙丙丁戊己庚辛'
    delta=ev('assistant/chunk',{'turn':1,'step':1,'chunk':{'type':'text-delta','index':0,'text':part}})
    push(*start,*([delta]*32),said(part*32),ended())
   elif mode == 'dr-service-drop':
    with open('drop-rpc','w') as saved:saved.write(obj['rpcId'])
   elif mode == 'dr-question':push(*start,{'_rpc':'q-1','type':'question/requested','sessionId':'probe','questions':[{'id':'fmt','question':'导出成哪种格式？','options':[{'label':'PDF'},{'label':'PNG'}]}]})
   elif mode in ('dr-max-tokens','dr-upstream-error','dr-blocked'):
    reason={'kind':'max-tokens'} if mode == 'dr-max-tokens' else {'kind':'error','error':{'message':'fetch failed: other side closed','code':'NETWORK'}}
    if mode=='dr-blocked':reason={'kind':'blocked'}
    push(*start,said('begin OK'),ev('turn/end',{'turn':1,'reason':reason}))
   else:push(*start)
  if mode == 'dr-steer-lost' and self.path == '/api/session.prompt' and p.get('mode') == 'steer':
   self.close_connection=True
   return
  if mode in ('dr-steer-image','dr-steer-accepted','dr-steer-path-full') and self.path == '/api/session.prompt' and p.get('mode') == 'steer':
   if mode != 'dr-steer-accepted' and any(b.get('type') == 'image' for b in p.get('content',[])):data=json.dumps({'result':{'ok':False,'error':{'code':'attachment-error','message':'Model "deepseek-v4-flash" does not support image input.'}}}).encode()
   elif mode == 'dr-steer-path-full':
    data=json.dumps({'result':{'ok':False,'error':{'code':'storage','message':'ENOSPC: journal full'}}}).encode()
   else:
    push(ev('user/message',{'role':'user','source':{'kind':'user','rpcId':obj.get('rpcId')},'content':p.get('content',[])}),said('got it'),ev('turn/end',{'turn':1,'reason':{'kind':'completed'}}))
  if mode == 'dr-question' and self.path == '/api/respond' and obj.get('rpcId') == 'q-1':
   # 和 dsh 的校验一致：答案按题目 id、selected 只能是选项标签，单选不能同时带 custom
   v=obj.get('result',{}).get('value',{});ans=v.get('answer',{}).get('answers',[])
   if v.get('sessionId') == 'probe' and len(ans) == 1 and ans[0].get('id') == 'fmt' and ans[0].get('selected') in (['PDF'],['PNG']) and 'custom' not in ans[0]:
    push({'type':'question/resolved','sessionId':'probe','questionRpcId':'q-1','outcome':'answered'},said('chose '+ans[0]['selected'][0]),ev('turn/end',{'turn':1,'reason':{'kind':'completed'}}))
   else:open('bad-response','w').write(json.dumps(v))
  if mode.startswith('dg-'):data=dg(self.path,obj,p,data)
  self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
s=http.server.ThreadingHTTPServer(('127.0.0.1',0),H)
if mode == 'balance-home':open('balance-port','w').write(str(s.server_address[1]))
print('dsh web: http://127.0.0.1:'+str(s.server_address[1]),flush=True)
s.serve_forever()
