#!/usr/bin/python3
import os,sys,time,json,struct,hashlib,base64,http.server,threading
mode=os.environ.get('FIXTURE_MODE','plain')
modelState={}
open('fake-'+mode+'.pid','w').write(str(os.getpid()))
if mode == 'stderr':
 os.write(2,b'x'*262144)
 open('stderr-complete','w').write('yes')
class H(http.server.BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*args):pass
 def do_GET(self):
  key=self.headers['Sec-WebSocket-Key']
  self.send_response(101);self.send_header('Upgrade','websocket');self.send_header('Connection','Upgrade');self.send_header('Sec-WebSocket-Accept',base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode());self.end_headers()
  def send(op,payload):
   n=len(payload);self.wfile.write(bytes([128|op,n]) + payload);self.wfile.flush()
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
    if op==9:send(10,p)
    elif op==8:break
  except (BrokenPipeError,ConnectionResetError):pass
 def do_POST(self):
  raw=self.rfile.read(int(self.headers.get('Content-Length',0)))
  obj=json.loads(raw)
  logged=json.loads(json.dumps(obj))
  if self.path == '/api/session.prompt':logged['observedModel']=modelState.get('model')
  if self.path == '/api/probe.recover':modelState['recovered']=True
  if self.path == '/api/probe.history-total':modelState['historyTotal']=obj.get('payload',{}).get('total',5101)
  for block in logged.get('payload',{}).get('content',[]):
   if 'data' in block:block['data']='[base64 chars='+str(len(block['data']))+']'
  with open('rpc-'+mode+'.jsonl','a') as f:f.write(json.dumps(logged)+'\n')
  if mode == 'cancel-race' and obj.get('payload',{}).get('mode') == 'steer':time.sleep(1)
  if mode in ('concurrent-config','transaction') and self.path == '/api/session.selectModel':
   modelState['model']=obj['payload']['model']
   if modelState['model']=='model-a':
    open('model-a.flag','w').write('yes');time.sleep(0.5)
  if mode == 'slow-approval' and self.path == '/api/respond': time.sleep(2)
  if self.path == '/api/session.cancel':open('cancel.flag','w').write('yes')
  if mode == 'compact' and obj.get('payload',{}).get('args',{}).get('line') == '/compact':time.sleep(2)
  data=json.dumps({'type':'server-response','rpcId':obj.get('rpcId'),'result':{'ok':True,'value':{}}}).encode()
  if self.path == '/api/probe.state':data=json.dumps({'result':{'ok':True,'value':modelState}}).encode()
  if mode in ('history-pages','history-cursor') and self.path == '/api/session.history':
   params=obj.get('payload',{});before=params.get('beforeSeq');total=modelState.get('historyTotal',5101)
   if params.get('sessionId') == 'other':total=2
   if mode == 'history-cursor':seqs=[100 if before is None else before+1];more=True
   else:
    end=min(total+1,before if before is not None else total+1)
    seqs=list(range(max(1,end-params.get('maxMessages',80)),end));more=bool(seqs and seqs[0]>1)
   events=[{'event':{'seq':seq,'type':'user/message','time':seq,'data':{'source':{'kind':'user'},'content':[{'type':'text','text':'history-'+str(seq)}]}}} for seq in seqs]
   if params.get('sessionId') in ('active','ended'):
    events=[{'event':{'seq':1,'type':'turn/start','time':int(time.time()*1000),'data':{'turn':1}}}]
    if params['sessionId']=='ended': events.append({'event':{'seq':2,'type':'turn/end','data':{'turn':1,'reason':{'kind':'completed'}}}})
    more=False
   value={'events':events,'hasMore':more}
   if before is None and params.get('sessionId')=='probe':
    value['projections']={'asOfSeq':total,'values':{'contextPressure':{'pressureTokens':13,'projectedTokens':12,'contextWindow':100},'contextBreakdown':{'systemTokens':5,'messageTokens':7}}}
   data=json.dumps({'result':{'ok':True,'value':value}}).encode()
  if mode == 'search' and self.path == '/api/session.list':
   data=json.dumps({'result':{'ok':True,'value':{'items':[{'sessionId':'probe','blank':False,'cwd':os.getcwd(),'updatedAt':2 if modelState.get('recovered') else 1}]}}}).encode()
  if mode == 'search' and self.path == '/api/session.history':
   word='changed-visible-needle' if modelState.get('recovered') else 'original-visible-needle'
   events=[{'event':{'seq':1,'type':'user/message','data':{'source':{'kind':'user'},'content':[{'type':'text','text':'question'}]}}},
           {'event':{'seq':2,'type':'assistant/message','protocol':'protocol-only-needle','data':{'turn':1,'step':1,'message':{'content':[{'type':'text','text':word}]}}}},
           {'event':{'seq':3,'type':'turn/end','data':{'reason':{'kind':'completed'}}}}]
   data=json.dumps({'result':{'ok':True,'value':{'events':events,'hasMore':False}}}).encode()
  if not modelState.get('recovered') and ((mode == 'configure-fail' and self.path == '/api/session.selectModel') or (mode == 'effort-fail' and 'reasoningEffort' in obj.get('payload',{})) or (mode == 'permission-fail' and obj.get('payload',{}).get('args',{}).get('line','').startswith('/permission'))):data=json.dumps({'result':{'ok':False,'error':{'code':'model-unavailable','message':'fixture chosen model unavailable'}}}).encode()
  self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
s=http.server.ThreadingHTTPServer(('127.0.0.1',0),H)
print('dsh web: http://127.0.0.1:'+str(s.server_address[1]),flush=True)
s.serve_forever()
