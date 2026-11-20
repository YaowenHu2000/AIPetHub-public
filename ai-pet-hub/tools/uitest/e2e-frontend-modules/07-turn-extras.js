  // 另一个窗口已存下较新一轮的改动卡，本页缓存里没有；本页只读历史时补记旧卡位置，不能拿缓存整份盖掉共享存储。
  for (const agent of ALL_AGENT_IDS) {
    const st=S[agent], cid='r6-双窗改动卡', key=agent+':'+cid, old=lsGet('turn_extras'), prior=[st.conversationId,turnExtras.get(key)];
    try {
      st.conversationId=cid; turnExtras.delete(key);
      rememberTurn(agent,{text:'第一问'},{conversationId:cid,reply:'第一答',files:[{path:'/tmp/一.txt'}]},'');
      const newer={agent,conversationId:cid,files:[{path:'/tmp/二.txt'}],cwd:'',text:'第二问',at:2,turnKey:'k2',replyKey:replyFingerprint('第二答')};
      saveTurnExtras(key,[...readTurnExtras().get(key),newer]);
      matchTurnExtras(agent,[{role:'user',text:'第一问',turnKey:'k1'},{role:'bot',text:'第一答'},{role:'user',text:'第二问',turnKey:'k2'},{role:'bot',text:'第二答'}]);
      const matched=readTurnExtras().get(key)||[];
      check(agent+' 只读历史补记旧卡位置，不覆盖别的窗口新存的改动卡',matched.length===2 && matched[0].at===0 && matched[0].turnKey==='k1' && matched[1].turnKey==='k2',matched.map(ex=>[ex.text,ex.at,ex.turnKey]));
      shiftTurnExtras(agent,cid,2);
      const shifted=readTurnExtras().get(key)||[];
      check(agent+' 续取更早一页后移位置，也不覆盖别的窗口新存的改动卡',shifted.length===2 && shifted[0].at===2,shifted.map(ex=>[ex.text,ex.at]));
    } finally { turnExtras.delete(key); if(prior[1]) turnExtras.set(key,prior[1]); st.conversationId=prior[0]; lsSet('turn_extras',old); }
  }
  // 本页自己答完一轮时也只追加这一条，不拿缓存整份盖掉别的窗口之后存的轮次。
  for (const agent of ALL_AGENT_IDS) {
    const cid='r6-双窗答完', key=agent+':'+cid, old=lsGet('turn_extras'), prior=turnExtras.get(key);
    try {
      turnExtras.delete(key);
      rememberTurn(agent,{text:'第一问',historyStart:0},{conversationId:cid,reply:'第一答',files:[{path:'/tmp/一.txt'}]},'');
      const newer={agent,conversationId:cid,files:[{path:'/tmp/二.txt'}],cwd:'',text:'第二问',at:2,turnKey:'k2',replyKey:replyFingerprint('第二答')};
      saveTurnExtras(key,[...readTurnExtras().get(key),newer]);
      rememberTurn(agent,{text:'第三问',historyStart:4},{conversationId:cid,reply:'第三答',files:[{path:'/tmp/三.txt'}]},'');
      const kept=readTurnExtras().get(key)||[];
      check(agent+' 本页答完一轮只追加自己那条，不覆盖别的窗口新存的改动卡',kept.map(ex=>ex.text).join()==='第一问,第二问,第三问' && turnExtras.get(key).length===2,kept.map(ex=>ex.text));
    } finally { turnExtras.delete(key); if(prior) turnExtras.set(key,prior); lsSet('turn_extras',old); }
  }
  // Git 快照记绝对路径，CLI 历史可能记相对路径：同一文件只算一次，显示仍用快照的路径。
  for (const agent of ALL_AGENT_IDS) {
    for (const abs of ['/tmp/r6-卡片/src/foo.txt','/private/tmp/r6-卡片/src/foo.txt']) {
      const diff='@@ -1 +1 @@\n-a\n+b', ex={agent,conversationId:'r6-路径',files:[{path:abs,kind:'edit',added:1,removed:1,diff}],cwd:'/tmp/r6-卡片'};
      const turn=renderChangeTurn(agent,{role:'bot',text:'改好了',files:[{path:'src/foo.txt',kind:'edit',added:1,removed:1,diff},
        {path:'./src/../src/foo.txt',kind:'edit',added:1,removed:1,diff},{path:'src/bar.txt',kind:'edit',added:1,removed:0}]},ex,'/tmp/r6-卡片');
      const rows=[...turn.querySelectorAll('.file-row')];
      check(agent+' 相对和绝对路径的同一文件在改动卡只算一次',rows.length===2 && rows[0].title.startsWith(abs+'\n') && rows[1].title.startsWith('src/bar.txt\n'),rows.map(r=>r.title.split('\n')[0]));
    }
  }
  {
    const original=answerRequest, sent=[];
    answerRequest=(_run,_card,body)=>sent.push(body);
    try {
      const card=questionCard({}, {questions:[{id:'quantity',question:'份数',valueType:'integer',required:true}]});
      const input=card.querySelector('input'), submit=card.querySelector('.primary');
      input.value='两份'; submit.click();
      const invalid=sent.length; input.value='2'; submit.click();
      check('MCP 输错整数可以在原卡修改再提交',invalid===0 && sent.length===1 && sent[0].answers.quantity==='2',{invalid,sent});
    } finally {answerRequest=original;}
  }
  for (const agent of ['claude','gpt']) {
    const card=permissionCard({agent,reqId:1},{onceOnly:true,tool:'mcp'});
    check(agent+' MCP 单次确认只提供本次允许和拒绝',card.querySelectorAll('.req-btn').length===2 && !card.textContent.includes('这一轮都允许'),card.textContent);
  }
  {
    const prevQuery = histQuery;
    histQuery = '外部删除回归';
    for (const agent of ALL_AGENT_IDS) {
      const st = S[agent], cid = 'external-missing-fixture';
      const saved = Object.fromEntries(['conversationId','loadedId','bodyQuery','bodyHits','bodyItems','bodyDropped','conversations','newView'].map(k=>[k,st[k]]));
      const row = {id:cid,title:histQuery,cwd:''};
      showEmpty(agent, '正在加载历史会话…');
      st.conversationId = cid; st.loadedId = cid; st.conversations = [row];
      const batch = {agent,query:histQuery,ids:[cid],items:[row]};
      window.onConversationsSearched(batch);
      window.onConversationLoaded({agent,conversationId:cid,missing:true});
      window.onConversationsSearched(batch);
      check(agent+' 外部删除后在途搜索也不能恢复会话', !st.bodyHits.has(cid) && !st.bodyItems.length && !st.conversations.some(c=>c.id===cid), [...st.bodyHits]);
      showEmpty(agent, '正在加载历史会话…'); Object.assign(st,saved); lsSet(agent+'_conv',saved.conversationId || ''); renderHistory(agent);
    }
    histQuery = prevQuery;
  }
  {
    const enabled = AGENT_IDS.slice(), previousActive = active, previousQuery = histQuery;
    histQuery = '已有正文';
    for (const agent of ALL_AGENT_IDS) {
      const idx = AGENT_IDS.indexOf(agent); if (idx >= 0) AGENT_IDS.splice(idx,1);
      const start = requests.length; enableAgent(agent);
      const sent = requests.slice(start).filter(r=>r.action === 'searchConversations');
      check(agent+' 启用时补搜当前关键词', sent.length === 1 && sent[0].agent === agent && sent[0].query === histQuery, sent);
    }
    histQuery = previousQuery; AGENT_IDS.splice(0,AGENT_IDS.length,...enabled); afterAgentsChanged(); setActive(previousActive,false);
  }
  {
    const probes = {...agentProbe}, hidden = welcome.hidden; openWelcome();
    const before = requests.length; welcome.querySelector('.wl-recheck').click();
    const probe = requests.slice(before).find(r=>r.action==='probeAgents');
    check('手动重新检测四位 CLI 绕过未安装缓存', probe?.refresh === true && probe.agents.length === 4, probe);
    ALL_AGENT_IDS.forEach(a=>delete agentProbe[a]); Object.assign(agentProbe,probes);
    welcome.hidden = hidden; els.input.focus();
  }
  {
    const f = {path:'/fixture/truncated.js',diff:'@@ -0,0 +1,7000 @@\n+short',added:7000,removed:0,truncated:true};
    const bar = document.createElement('div'), body = document.createElement('div');
    renderChanges(bar,body,{extra:{files:[f],cwd:''}});
    const oldRead = readLocalFile;
    readLocalFile = async () => ({path:f.path,content:'short'});
    body.querySelector('button')?.click(); await Promise.resolve();
    check('全部改动与单文件都标明截断并显示完整行数', body.textContent.includes('截断') && body.textContent.includes('+7000') && pane.el.textContent.includes('截断') && pane.el.querySelector('.ed-diffinfo')?.textContent.includes('+7000'), [body.textContent,pane.el.querySelector('.ed-diffinfo')?.textContent]);
    const older = {...f}; delete older.truncated;
    const oldBar = document.createElement('div'), oldBody = document.createElement('div');
    renderChanges(oldBar,oldBody,{extra:{files:[older],cwd:''}}); oldBody.querySelector('button')?.click();
    await Promise.resolve();
    check('旧会话缺少截断标记时仍显示真实的增删统计',oldBody.textContent.includes('截断') && pane.el.querySelector('.ed-diffinfo')?.textContent.includes('+7000'),[oldBody.textContent,pane.el.querySelector('.ed-diffinfo')?.textContent]);
    closePreview(); readLocalFile = oldRead;
  }
  {
    const st = S[id], oldQuery = histQuery, keep = Object.fromEntries(['conversationId','loadedId','bodyHits','bodyQuery','histLimit','shownLimit','keepFromBottom','loadedSig','pendingSearchHit'].map(k=>[k,st[k]]));
    const cid = 'manual-page-search'; showEmpty(id, '正在加载历史会话…');
    histQuery = '定位关键词'; st.bodyQuery = histQuery; st.bodyHits = new Set([cid]); st.conversationId = cid;
    const current = {role:'user',text:histQuery}, load = {agent:id,conversationId:cid,messages:[current],omitted:2};
    window.onConversationLoaded(load);
    const firstHit = !!st.msgEl.querySelector('.search-hit'); st.msgEl.querySelector('.load-earlier').click();
    const req = requests.at(-1); (st.historyReads ??= new Map()).set(req.reqId,'open');
    window.onConversationLoaded({...load,reqId:req.reqId,omitted:0,messages:[{role:'user',text:'更早内容'},current]});
    check('手动显示更早后不再跳回原搜索命中',firstHit && !st.msgEl.querySelector('.search-hit'),[firstHit,!!st.msgEl.querySelector('.search-hit')]);
    showEmpty(id, '正在加载历史会话…'); histQuery = oldQuery; Object.assign(st,keep);
  }
  {
    for (const agent of ALL_AGENT_IDS) {
      const st = S[agent], saved = Object.fromEntries(['conversations','unreadConvs','unread','unreadChecks','unreadChecked','projectlessIds'].map(k=>[k,st[k]])), stored = lsGet(agent+'_unread','');
      const gone = 'unread-gone', old = 'unread-older'; st.unreadConvs = new Set([gone,old]); st.unread = true;
      const before = requests.length;
      window.onConversationsListed({agent,items:[]});
      const probes = requests.slice(before).filter(r=>r.unreadProbe);
      for (const req of probes) window.onConversationLoaded({agent,reqId:req.reqId,conversationId:req.conversationId,missing:req.conversationId===gone});
      check(agent+' 后台删除清除未读且保留列表以外的旧会话', !st.unreadConvs.has(gone) && st.unreadConvs.has(old) && st.unread, [...st.unreadConvs]);
      st.unreadConvs = new Set([gone]); st.unread = true; st.unreadChecked?.delete(gone);
      const finalStart = requests.length; window.onConversationsListed({agent,items:[]});
      const finalProbe = requests.slice(finalStart).find(r=>r.unreadProbe);
      if (finalProbe) window.onConversationLoaded({agent,reqId:finalProbe.reqId,conversationId:gone,missing:true});
      check(agent+' 最后一个后台未读被删除后红点熄灭',!st.unread && !st.unreadConvs.size,[st.unread,...st.unreadConvs]);
      Object.assign(st,saved); lsSet(agent+'_unread',stored); updateIndicators(agent); renderHistory(agent);
    }
  }
  {
    const agent = 'deepseek', st = S[agent], cid = 'unattended-pet', previous = [st.conversationId,st.loadedId,st.unread,new Set(st.unreadConvs),st.elsewherePet];
    const previousActive = active; setActive(agent,false);
    showEmpty(agent, '正在加载历史会话…'); st.conversationId = st.loadedId = cid; st.elsewherePet = null;
    st.unreadConvs = new Set(); st.unread = false; pets[agent].renderStatus();
    const card = {agent,conversationId:cid,reqId:-94,requestId:'pending-pet',kind:'permission',title:'执行命令'};
    window.onAgentRequest(card); const waiting = pets[agent].statusEl.textContent;
    window.onAgentRequestClosed(card); const closed = pets[agent].statusEl.textContent;
    check('DeepSeek 无本地回合的审批持续显示等待，关闭后恢复空闲', waiting.includes('等你') && closed.includes('空闲'),[waiting,closed]);
    showEmpty(agent, '正在加载历史会话…'); [st.conversationId,st.loadedId,st.unread,st.unreadConvs,st.elsewherePet] = previous;
    lsSet(agent+'_unread',previous[3].size ? JSON.stringify([...previous[3]]) : ''); updateIndicators(agent); renderHistory(agent); pets[agent].renderStatus(); setActive(previousActive,false);
  }
  {
    const st = S[id], attach = st.attach, draft = st.draft;
    const shot = '/fixture/pasted-queue.png', original = '/fixture/user-owned.png';
    st.attach = []; const run = {agent:id,view:viewKey(id),workspace:st.workspace,reqId:-92,nodes:[],queue:[]};
    queueMessage(id,'排队图片',[shot,original],{text:'排队图片',paths:[shot,original],pasted:[shot]},run);
    const item = run.queue[0]; setQueuedState(item,'waiting'); item.el.querySelector('.queued-cancel').click();
    const before = requests.length;
    document.querySelector('.attach-row .attach-x')?.click(); document.querySelector('.attach-row .attach-x')?.click();
    const discarded = requests.slice(before).filter(r=>r.action==='discardPastedImage').map(r=>r.path);
    check('排队撤回后移除附件只清理粘贴的截图',discarded.length===1 && discarded[0]===shot,discarded);
    st.attach = attach; saveAttachments(id); renderAttachments(); setDraft(id,draft);
  }
  for (const agent of ALL_AGENT_IDS) {
    const st = S[agent], keep = st.attach, prior = st.draft;
    const paths = ['/fixture/撤回.zip','/fixture/撤回.png'];
    const run = {agent,view:viewKey(agent),workspace:st.workspace,reqId:-102,nodes:[],queue:[]};
    st.attach = Array.from({length:8}, (_,i)=>({path:'/fixture/'+i}));
    queueMessage(agent,'含附件路径',paths.slice(1),{text:'补充',paths,pasted:paths.slice(1)},run);
    const item = run.queue[0]; setQueuedState(item,'waiting');
    const before = requests.length;
    item.el.querySelector('.queued-cancel').click();
    check(agent+' 附件栏放不下时保留整条排队补充',run.queue.length===1 && !requests.slice(before).some(r=>r.action==='discardPastedImage'),run.queue.length);
    st.attach=[]; setDraft(agent,''); item.el.querySelector('.queued-cancel').click();
    check(agent+' 撤回时普通文件和截图一起回到附件栏',st.draft==='补充' && st.attach.map(a=>a.path).join()===paths.join() && st.attach[1]?.pasted,st.attach);
    st.attach=keep; setDraft(agent,prior); saveAttachments(agent); if (agent===active) renderAttachments();
  }
  for (const agent of ALL_AGENT_IDS) {
    const st = S[agent], keep = {returnedDrafts:st.returnedDrafts,draft:st.draft,attach:st.attach,unread:st.unread,ownAt:st.ownAt,ownTurnUnsynced:st.ownTurnUnsynced};
    st.returnedDrafts={owner:'',parked:{}}; st.attach=[]; setDraft(agent,'乙稿');
    const draft={text:'甲问',paths:['/fixture/a.png','/fixture/a.zip'],pasted:[]};
    const run={agent,reqId:-751,view:'new:751',workspace:'/fixture/甲',text:'甲问',images:draft.paths.slice(0,1),draft};
    st.runs.set(run.reqId,run);
    window.onAgentResponse({agent,reqId:run.reqId,reply:'⚠️ 启动失败',outcome:'failed'});
    check(agent+' 首问失败只退回原项目',st.draft==='乙稿' && !st.attach.length && st.returnedDrafts.parked['workspace:/fixture/甲']?.paths.length===2,[st.draft,st.attach]);
    Object.assign(st,keep); setDraft(agent,keep.draft); saveReturnedDrafts(agent); saveAttachments(agent); if (agent===active) renderAttachments();
  }
  {
    const start = startChatIn, add = addWorkspace, calls = [];
    startChatIn = (a,p) => calls.push(p); addWorkspace = () => {};
    try {
      for (const agent of ALL_AGENT_IDS) {
        window.onWorkspacePicked({agent,path:'/Users/Shared'});
        check(agent+' 选中的共享目录是实际工作空间',calls.at(-1)==='/Users/Shared' && wsKey('/Users/Shared')==='/Users/Shared',calls.at(-1));
      }
    } finally { startChatIn=start; addWorkspace=add; }
  }
  for (const agent of ALL_AGENT_IDS) {
    const box=S[agent].msgEl, nodes=[...box.childNodes], start=startRun, sent=[];
    try {
      box.replaceChildren(); startRun=(_agent,text)=>sent.push(text);
      renderOneMessage(agent,{role:'user',text:'创建副本'},null,'');
      renderOneMessage(agent,{role:'bot',text:'完成'},null,'');
      for (const retryPrompt of [undefined,'/compact']) {
        const turn=renderOneMessage(agent,{role:'bot',text:'出错',outcome:'failed',retryPrompt},null,'');
        const btn=turn.querySelector('.retry'); btn?.click();
        check(agent+' 无人提问的失败轮只重试已知命令 '+(retryPrompt || '后台'),retryPrompt ? !!btn && (agent!==active || sent.at(-1)===retryPrompt) : !btn,sent.slice());
      }
    } finally { startRun=start; box.replaceChildren(...nodes); }
  }
  // 默认分页恰好从可重试的回答开始：点「显示更早」补回原问后，这条回答和一次载入全部时一样有重试，文字和附件取自原问。
  for (const agent of ALL_AGENT_IDS) {
    const st=S[agent], box=st.msgEl, nodes=[...box.childNodes], start=startRun, sent=[], wasActive=active;
    const keys=['conversationId','loadedId','loadedSig','keepFromBottom','shownLimit','shownOmitted','shownHasMore','histLimit'];
    const keep=Object.fromEntries(keys.map(k=>[k,st[k]]));
    const load=(messages,omitted,reqId=nextRequestId()) => {
      (st.historyReads ??= new Map()).set(reqId,'open');
      window.onConversationLoaded({agent,conversationId:st.conversationId,cwd:'',limit:300,omitted,messages,reqId});
    };
    try {
      setActive(agent,false); startRun=(_agent,text,images)=>sent.push({text,images});
      // 命令气泡隐藏后，压缩失败的重试仍发原问的实际拼法。
      for (const command of ['/compact','/compress']) {
        st.conversationId='compress-'+agent; st.loadedId=''; showEmpty(agent);
        load([{role:'user',text:'前问'},{role:'bot',text:'前答',outcome:'completed'},{role:'user',text:command},{role:'bot',text:'压缩失败',outcome:'failed'}],0);
        const before=sent.length; box.querySelector('.retry')?.click();
        check(agent+' 压缩失败重开后重试发原命令 '+command,sent.length===before+1 && sent.at(-1).text===command,sent.slice(before));
      }
      const rows=[{role:'user',text:'需要重试的原问',images:[{path:'/fixture/分页原图.png'}]},{role:'bot',text:'半截',outcome:'interrupted'},{role:'compact',text:'已压缩上下文'}];
      for (let i=1;i<=149;i++) rows.push({role:'user',text:'问'+i},{role:'bot',text:'答'+i,outcome:'completed'});
      st.conversationId='page-retry-'+agent; st.loadedId=''; showEmpty(agent);
      load(rows.slice(-300),rows.length-300);
      const before=requests.length; box.querySelector('.load-earlier')?.click();
      const page=requests.slice(before).find(r=>r.action==='loadConversation');
      load(rows,0,page?.reqId);
      const first=box.querySelector('.turn');
      first?.querySelector('.retry')?.click();
      check(agent+' 显示更早补回原问后分页交界的回答可重试',box.querySelector('.msg.user')?.textContent.includes('需要重试的原问') && first?._text==='半截' &&
        sent.at(-1)?.text==='需要重试的原问' && JSON.stringify(sent.at(-1)?.images)==='["/fixture/分页原图.png"]',sent);
    } finally { startRun=start; box.replaceChildren(...nodes); Object.assign(st,keep); setActive(wasActive,false); }
  }
  for (const agent of ALL_AGENT_IDS) {
    const st=S[agent], keep=st.attach, stored=lsGet(agent+'_attach','');
    st.attach=Array.from({length:10},(_,i)=>({path:'/fixture/'+i+'.zip',pasted:i===9}));
    saveAttachments(agent); loadAttachments(agent);
    addAttachments(agent,['/fixture/额外.zip'],false);
    check(agent+' 重载保留十个已接收附件且新增仍受限',st.attach.length===10 && st.attach[9]?.pasted && st.attach[9]?.path==='/fixture/9.zip',st.attach.map(a=>a.path));
    st.attach=keep; lsSet(agent+'_attach',stored); if (agent===active) renderAttachments();
  }
  for (const agent of ALL_AGENT_IDS) {
    const st = S[agent], prior = draftAttachments(st), buttonHost = document.createElement('div');
    const wasActive = active, text = '查看附件', path = '/fixture/编辑.png';
    try {
      setActive(agent, false); displayReturnedDraft(agent, null);
      const bubble = appendMessage(agent, 'user', text + '\n' + path, [], buttonHost);
      bubble._run = {text, images:[path]};
      bubble.querySelector('.msg-edit').click();
      const outgoing = attachmentsForSend(els.input.value, st.attach.map(a => a.path));
      check(agent + ' 编辑后发送仍带原图', outgoing.text === text && outgoing.images.join() === path, outgoing);
    } finally { displayReturnedDraft(agent, prior); setActive(wasActive, false); }
  }
  {
    const models = {gemini:'claude-sonnet-5-5', claude:'haiku', gpt:'gpt-6-luna', deepseek:'deepseek-v4-flash'};
    const frame = document.createElement('iframe');
    frame.hidden = true;
    const fixture = Object.fromEntries(Object.entries(models).map(([agent, model]) => ['aihub_'+agent+'_model',model]));
    fixture.aihub_claude_default_v2 = '1';
    frame.srcdoc = '<script>const localStorage = {getItem:k=>('+JSON.stringify(fixture)+')[k] ?? null, setItem(){}, removeItem(){}};<\/script>'
      + ['config','state'].map(name => '<script src="'+new URL('js/core/'+name+'.js',location.href)+'"><\/script>').join('')
      + '<script>window.selected = Object.fromEntries(ALL_AGENT_IDS.map(id=>[id,S[id].model]));<\/script>';
    document.body.appendChild(frame);
    try {
      const selected = await until(() => frame.contentWindow.selected, '载入已保存的模型');
      for (const [agent, model] of Object.entries(models)) check(agent+' 重开保留所选模型', selected[agent] === model, selected[agent]);
    } finally { frame.remove(); }
  }
  for (const agent of ALL_AGENT_IDS) {
    const st = S[agent], prior = st.returnedDrafts, stored = lsGet(agent+'_returnedDrafts');
    st.returnedDrafts = {owner:'',parked:{}};
    try {
      const original = 'r4b-截图来源', paths = ['/fixture/第一张.png','/fixture/第二张.png'];
      const pending = paths.map(() => {
        const p = {key:nextRequestId(),id:agent,view:original,workspace:st.workspace};
        pendingPastes.set(p.key,p); return p;
      });
      window.onFilesDropped({pasteId:pending[1].key,paths:[paths[1]]});
      window.onFilesDropped({pasteId:pending[0].key,paths:[paths[0]]});
      const draft = st.returnedDrafts.parked[draftSession(original,st.workspace)];
      check(agent+' 后台截图按粘贴顺序恢复', draft?.paths.join() === paths.join(), draft?.paths);
    } finally { st.returnedDrafts = prior; lsSet(agent+'_returnedDrafts',stored); }
  }
  for (const agent of ALL_AGENT_IDS) {
    const st = S[agent], nodes = [...st.msgEl.childNodes], omitted = st.shownOmitted, more = st.shownHasMore;
    try {
      st.msgEl.replaceChildren(); st.shownOmitted = 0; st.shownHasMore = false;
      const user = {role:'user',text:'继续'}, original = {role:'bot',text:'本地旧答案',outcome:'completed'};
      renderOneMessage(agent,user,null,'');
      const local = renderTurn(original,'');
      local._answeredHere = true; st.msgEl.appendChild(local);
      syncAppend(agent,[user,original],'',0);
      const sameNode = local.parentNode === st.msgEl;
      const branch = [user,{...original,text:'外部新答案'}];
      syncAppend(agent,branch,'',0); syncAppend(agent,branch,'',0);
      check(agent+' 本地回答对账后跟随同文新分支', sameNode && st.msgEl.querySelector('.turn')._text === '外部新答案', st.msgEl.querySelector('.turn')._text);
    } finally { st.msgEl.replaceChildren(...nodes); st.shownOmitted = omitted; st.shownHasMore = more; }
  }
  for (const agent of ALL_AGENT_IDS) {
    const st = S[agent], cid = st.conversationId, key = agent+':'+cid;
    const prior = turnExtras.get(key), stored = lsGet('turn_extras');
    try {
      turnExtras.delete(key);
      rememberTurn(agent,{text:'继续',historyStart:0},{conversationId:cid || 'r4b-diff',reply:'旧回答',files:[{path:'old.txt'}]},'');
      const entries = turnExtras.get(agent+':'+(cid || 'r4b-diff'));
      const cards = answer => matchExtras(entries,[{role:'user',text:'继续'},{role:'bot',text:answer}]).get(1)?.files.map(f=>f.path) || [];
      check(agent+' 同位置同文新分支不继承旧改动',cards('旧回答').join() === 'old.txt' && !cards('新回答').length, cards('新回答'));
    } finally {
      turnExtras.delete(agent+':'+(cid || 'r4b-diff'));
      if (prior) turnExtras.set(key,prior); lsSet('turn_extras',stored);
    }
  }
  for (const agent of ['claude','gpt']) {
    const run = {agent,reqId:nextRequestId()};
    const card = questionCard(run,{questions:[
      {id:'name',question:'项目名称',valueType:'string',required:true,options:[]},
      {id:'kind',question:'选一种',valueType:'string',required:true,isOther:false,options:[{label:'甲'}]},
      {id:'count',question:'数量',valueType:'integer',options:[]}
    ]});
    document.body.appendChild(card);
    try {
      const [name, count] = card.querySelectorAll('input'), option = card.querySelector('.req-option'), submit = card.querySelector('.primary');
      const sent = () => requests.filter(r=>r.reqId === run.reqId && r.action === 'answerAgentRequest');
      count.value = '3'; submit.click();
      const heldName = !name.disabled && !sent().length && document.activeElement === name;
      name.value = '示例'; submit.click();
      const heldOption = !option.disabled && !sent().length && document.activeElement === option;
      option.click(); submit.click();
      check(agent+' 补全必填项后才提交表单',heldName && heldOption && sent().length === 1 && sent()[0].answers.count === '3', {heldName,heldOption,answers:sent()[0]?.answers});
    } finally {card.remove();}
  }
  for (const agent of ALL_AGENT_IDS) {
    const st = S[agent], nodes = [...st.msgEl.childNodes], external = st.externalTurn, runs = st.runs;
    try {
      st.msgEl.replaceChildren(); st.runs = new Map();
      renderOneMessage(agent,{role:'user',text:'继续'},null,'');
      const turn = renderOneMessage(agent,{role:'bot',text:'半截',outcome:'incomplete'},null,'');
      const visible = () => { const b = turn.querySelector('.retry'); return !!b && getComputedStyle(b).display !== 'none'; };
      st.externalTurn = {cid:st.conversationId,running:true,updatedAt:Date.now()/1000};
      markElsewhere(agent); const running = visible();
      st.externalTurn.running = false; markElsewhere(agent);
      check(agent+' 重开未完成回答在运行结束后可重试',!running && visible(),{running,ended:visible()});
    } finally {st.msgEl.replaceChildren(...nodes); st.externalTurn = external; st.runs = runs; markElsewhere(agent);}
  }
  for (const agent of ALL_AGENT_IDS) {
    const st = S[agent], saved = [st.runs,st.conversations,st.unread,histQuery], section = histSections[agent];
    if (!section) buildHistorySection(agent);
    const a = {agent,reqId:nextRequestId(),view:'r4b-wait-a',text:'r4b-wait-a',since:Date.now(),live:{el:document.createElement('div')}};
    const b = {...a,reqId:nextRequestId(),view:'r4b-wait-b',text:'r4b-wait-b'};
    try {
      st.runs = new Map([[a.reqId,a],[b.reqId,b]]); st.conversations = []; histQuery = 'r4b-wait';
      const row = run => histSections[agent].list.querySelector('[data-k="c:'+run.view+'"]')?.textContent || '';
      renderHistory(agent);
      const request = {agent,reqId:a.reqId,kind:'permission',requestId:'r4b-approval'};
      window.onAgentRequest(request);
      const waiting = [row(a),row(b)];
      window.onAgentRequestClosed(request);
      check(agent+' 侧栏仅标出等待处理的会话',waiting[0].includes('等你处理') && !waiting[1].includes('等你处理') && !row(a).includes('等你处理'),waiting);
    } finally {
      [st.runs,st.conversations,st.unread,histQuery] = saved;
      if (section) renderHistory(agent); else delete histSections[agent];
    }
  }
  for (const agent of ALL_AGENT_IDS) {
    const st = S[agent], prior = histQuery, section = histSections[agent];
    const keys = ['bodyQuery','bodyHits','bodyItems','bodyUnavailable','bodyComplete','conversations'];
    const saved = keys.map(k => st[k]);
    try {
      histQuery = '外部清理'; st.conversations = [];
      const head = section?.sec || buildHistorySection(agent), cid = 'r4b-externally-deleted';
      window.onConversationsSearched({agent,query:histQuery,ids:[cid],items:[{id:cid,title:'原来的结果'}]});
      const list = histSections[agent].list, wasShown = list.textContent.includes('原来的结果');
      const marker = requests.length;
      head.querySelector('.hist-refresh').click();
      const actions = requests.slice(marker).filter(r=>r.agent === agent);
      if (actions.some(r=>r.action==='searchConversations' && r.query===histQuery))
        window.onConversationsSearched({agent,query:histQuery,ids:[],items:[]});
      check(agent+' 手动刷新重查当前正文搜索',wasShown && actions.some(r=>r.action==='listConversations') && !list.textContent.includes('原来的结果'),actions.map(r=>r.action));
    } finally {
      histQuery = prior; keys.forEach((k,i)=>{st[k]=saved[i];});
      if (section) renderHistory(agent); else delete histSections[agent];
    }
  }
  for (const agent of ALL_AGENT_IDS) {
    const open = openPreview, file = {path:'/fixture/large.txt',added:7000,removed:0,diff:'@@\n+第一行',truncated:true};
    const turn = renderTurn({files:[file]},'/fixture');
    S[agent].msgEl.appendChild(turn);
    let tab;
    try {
      openPreview = data => {tab = data;};
      turn.querySelector('.file-row').click();
      check(agent+' 聊天卡点击文件行保留完整统计和截断标记',tab?.change?.added === 7000 && tab.change.truncated, tab);
    } finally {turn.remove(); openPreview = open;}
  }
  // hunt9 uncovered：这一轮改了 pages/README.md，回答链接根目录的 ./README.md，点开的要是根目录那份、不带子目录的改动；
  // 写明位置的相对路径（./、../、a/b）按本轮工作目录比完整路径，只写文件名的仍按结尾找到改动
  for (const agent of ALL_AGENT_IDS) {
    const open = openPreview, nested = {path:'/fx-proj/pages/README.md',added:1,removed:0,diff:'@@\n+NESTED'};
    const links = ['./README.md', 'README.md', 'pages/README.md', './pages/README.md', '../fx-proj/pages/README.md', 'other/README.md', '/fx-proj/README.md'];
    const turn = renderTurn({text:links.map((p,i) => `[链接${i}](${p})`).join(' '), files:[nested]}, '/fx-proj');
    S[agent].msgEl.appendChild(turn);
    const at = requests.length;
    let tab;
    try {
      verifyFileChips(turn);
      const asked = requests.slice(at).filter(r => r.action === 'checkFiles').flatMap(r => r.items.map(it => it.paths[0]));
      check(agent+' 根目录 ./README.md 不当成改过的子目录文件，照常核对', asked.includes('./README.md') && !asked.includes('pages/README.md') && !asked.includes('README.md'), asked);
      openPreview = data => {tab = data;};
      const got = links.map(p => { tab = null; previewFromTurn(p, turn); return [tab?.path, !!tab?.diff]; });
      check(agent+' 点开回答里的链接对上正确的文件和改动', JSON.stringify(got) === JSON.stringify([['./README.md',false],[nested.path,true],[nested.path,true],[nested.path,true],[nested.path,true],['other/README.md',false],['/fx-proj/README.md',false]]), got);
    } finally {turn.remove(); openPreview = open;}
  }
  // 回答里常写相对某个子目录的路径（工作目录 ai-pets-workspace，写 tools/rig/README.md，改的是 ai-pet-hub/ 下那份）：
  // 按工作目录配不上时仍按结尾找到改动，标签照旧可点、点开带 diff，不送去核对
  for (const agent of ALL_AGENT_IDS) {
    const open = openPreview, sub = {path:'/fx-proj/app/tools/rig/README.md',added:1,removed:0,diff:'@@\n+SUB'};
    const turn = renderTurn({text:'改了 `tools/rig/README.md`', files:[sub]}, '/fx-proj');
    S[agent].msgEl.appendChild(turn);
    const at = requests.length;
    let tab;
    try {
      verifyFileChips(turn);
      const asked = requests.slice(at).filter(r => r.action === 'checkFiles').flatMap(r => r.items.map(it => it.paths[0]));
      check(agent+' 子目录下的相对路径配上本轮改动，不送去核对', !asked.includes('tools/rig/README.md'), asked);
      openPreview = data => {tab = data;};
      previewFromTurn('tools/rig/README.md', turn);
      check(agent+' 点开子目录下的相对路径带上它的改动', tab?.path === sub.path && tab?.diff === sub.diff, tab);
    } finally {turn.remove(); openPreview = open;}
  }
  {
    const saved = [pane.tabs,pane.active,readLocalFile,renderPaneBody], old = {path:'/fixture/run.sh',diff:'@@\n-old\n+new',added:1,removed:1};
    const data = {path:old.path, content:'new'}, tab = {id:987,path:old.path,resolved:old.path,change:old,diff:old.diff,data};
    let drawn;
    try {
      pane.tabs = [tab]; pane.active = tab.id; readLocalFile = async () => data;
      renderPaneBody = () => {drawn = activeTab().change;};
      refreshPreviews([{path:old.path,kind:'edit',added:0,removed:0,diff:''}],'');
      await Promise.resolve();
      check('仅权限变化清掉已开预览的旧增删',tab.diff === '' && drawn?.added === 0 && drawn.removed === 0, {diff:tab.diff, drawn:drawn?.added});
    } finally {[pane.tabs,pane.active,readLocalFile,renderPaneBody] = saved; renderPaneTabs();}
  }
  {
    const files = [{path:'/fixture/mixed.txt',kind:'edit',added:2,removed:2,toolTotal:true}];
    const detail = document.createElement('div'), card = renderFilesCard(files);
    renderChanges(document.createElement('div'),detail,{extra:{files}});
    check('普通目录的工具累计编辑在聊天和全部改动里均有标注',
      [card,detail].every(node => node.textContent.includes('工具累计编辑')),card.textContent);
  }
  for (const kind of ['permission','plan','question']) {
    const reason = '答复尚未确认（dsh 返回了 HTTP 503），请重试。';
    const card = requestCard({agent:'deepseek',reqId:0},{kind,title:'写入',plan:'计划正文',message:reason,questions:[]});
    check('DeepSeek 重新出卡显示回执原因 '+kind,card.textContent.includes(reason) && !card.querySelector('button:disabled'),card.textContent);
  }
  for (const agent of ALL_AGENT_IDS) {
    const st = S[agent], prior = active, nodes = [...st.msgEl.childNodes], previousRuns = st.runs;
    const section = histSections[agent], ask = st.ownAt, pending = st.pendingTitle;
    const reads = st.historyReads, sig = warmSig, pet = pets[agent], mood = pet.moodEvent, busy = pet.setBusy;
    if (!section) buildHistorySection(agent);
    try {
      showEmpty(agent,'正在加载历史会话…'); active = agent; st.msgEl.replaceChildren(); st.runs = new Map();
      st.historyReads = new Map(); pet.moodEvent = pet.setBusy = () => {};
      const image = {src:'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',w:1,h:1,ref:{agent,conversationId:'r4b',id:'original'}};
      renderOneMessage(agent,{role:'user',text:'看图',images:[image]},null,'');
      const marker = requests.length;
      renderOneMessage(agent,{role:'bot',text:'失败',outcome:'failed'},null,'').querySelector('.retry').click();
      const run = [...st.runs.values()].at(-1), thumbs = run?.nodes[0].querySelectorAll('.msg-img') || [];
      check(agent+' 历史带图重试的新气泡保留原缩略图',thumbs.length === 1 && thumbs[0]._image.ref.id === 'original' && requests.slice(marker).some(r => r.action === 'askAgent' && r.imageRefs?.[0]?.id === 'original'),thumbs.length);
    } finally {
      st.runs = previousRuns; st.msgEl.replaceChildren(...nodes); st.ownAt = ask; st.pendingTitle = pending;
      active = prior; warmSig = sig; st.historyReads = reads; pet.setBusy = busy; pet.moodEvent = mood;
      if (section) renderHistory(agent); else delete histSections[agent];
      updateIndicators(agent); updateSendUI();
    }
  }
  {
    const agent = 'deepseek', st = S[agent], pet = pets[agent];
    const saved = [st.conversationId,st.loadedId,st.runs,st.elsewherePet,st.unread,pet.state], nodes = [...st.msgEl.childNodes];
    const section = histSections[agent], cid = 'r4b-wake', wasUnread = st.unreadConvs.has(cid);
    const other = 'r4b-wake-background', otherUnread = st.unreadConvs.has(other), priorPending = st.unattendedSince;
    if (!section) buildHistorySection(agent);
    try {
      showEmpty(agent,'正在加载历史会话…'); st.conversationId = st.loadedId = cid;
      st.runs = new Map(); st.unattendedSince = undefined; st.elsewherePet = null; pet.setState('sleep');
      const request = {agent,reqId:0,conversationId:cid,requestId:'r4b-wake-card',kind:'permission',title:'写文件'};
      window.onAgentRequest(request);
      pet.tick(); const during = {state:pet.state,busy:petBusy(agent)};
      window.onAgentRequestClosed(request);
      check('DeepSeek 外部审批唤醒桌宠，撤卡后恢复空闲',during.state === 'thinking' && during.busy && !petBusy(agent) && pet.state === 'idle',during);
      const pending = {...request,conversationId:other,requestId:'r4b-wake-background-approval'};
      pet.setState('sleep'); window.onAgentRequest(pending); window.onAgentRequest(pending);
      const background = petBusy(agent) && pet.state === 'thinking';
      window.onAgentRequestClosed(pending);
      check('DeepSeek 后台会话的同一审批只需撤卡一次',background && !petBusy(agent),background);
    } finally {
      showEmpty(agent,'正在加载历史会话…');
      [st.conversationId,st.loadedId,st.runs,st.elsewherePet,st.unread] = saved;
      st.unattendedSince = priorPending; setConversationUnread(agent,other,otherUnread); setConversationUnread(agent,cid,wasUnread); st.msgEl.replaceChildren(...nodes); pet.setState(saved[5]);
      if (section) renderHistory(agent); else delete histSections[agent];
    }
  }
  for (const agent of ALL_AGENT_IDS) {
    const run = {agent, reqId:-501, nodes:[], queue:[], live:{steps:[{kind:'command',status:'running'}]}};
    const item = {sid:'乙', text:'补充乙', state:'sent', run, el:document.createElement('div')};
    item.el.innerHTML = '<span class="queued-state"></span>';
    run.queue.push(item); S[agent].runs.set(run.reqId,run);
    try {
      window.onAgentSteer({agent,reqId:run.reqId,steerId:item.sid,state:'consumed'});
      const steps = [{kind:'user',detail:item.text}];
      check(agent+' 先收到补充再插队时认得已回答正文', answeredBeforeStop(item,[...steps,{kind:'text',detail:'已处理'}]), !!item.consumed);
      check(agent+' 系统中断不算已回答补充', !answeredBeforeStop({...item,consumed:true},[...steps,{kind:'error',title:'已中断'}]));
    } finally { S[agent].runs.delete(run.reqId); }
  }
  for (const agent of ALL_AGENT_IDS) {
    const st = S[agent], before = projectDelete, key = '/fixture/保留目录';
    const keep = st.addedWs;
    st.addedWs = [{path:key,ts:1}]; projectDelete = {id:agent,key,ids:['refused']}; confirmDeleteProject();
    const reqId = requests.filter(r=>r.action==='deleteConversations').at(-1)?.reqId;
    window.onConversationsDeleted({agent,reqId,deleted:[],failed:['refused']});
    check(agent+' 归档失败保留工作目录',st.addedWs.some(w=>w.path===key),st.addedWs.slice());
    projectDelete = before; st.addedWs = keep; lsSet(agent+'_added_ws',JSON.stringify(keep)); renderHistory(agent);
  }
  {
    const previous = active;
    for (const agent of ALL_AGENT_IDS) {
      setActive(agent,false);
      const st = S[agent], original = draftAttachments(st);
      try {
        displayReturnedDraft(agent,{text:'',paths:['/fixture/手动.png']});
        const edit = (text,paths,refs=[]) => {
          const div = document.createElement('div');
          div._retry = {text,images:paths,refs}; addEditButton(div,agent,text);
          div.querySelector('.msg-edit').click();
        };
        edit('甲',['/fixture/甲.png']);
        edit('稍后恢复',[],[{id:'old'}]);
        const pending = requests.at(-1).reqId;
        edit('乙',['/fixture/乙.png']);
        window.onFilesDropped({pasteId:pending,paths:['/fixture/迟到.png']});
        const draft = draftAttachments(st);
        check(agent+' 连续编辑只带手动附件和最后一问的图片',draft.text==='乙' && draft.paths.join()==='/fixture/手动.png,/fixture/乙.png', draft);
      } finally { displayReturnedDraft(agent,original); }
    }
    setActive(previous,false);
  }
  for (const agent of ALL_AGENT_IDS) {
    const previous=active, id=agent; setActive(id,false);
    const st=S[id], prior={conversationId:st.conversationId,loadedId:st.loadedId,returnedDrafts:st.returnedDrafts};
    const original=draftAttachments(st), key=nextRequestId();
    try {
      showEmpty(id,'正在加载历史会话…'); st.conversationId=st.loadedId='粘贴甲';
      st.returnedDrafts={owner:'',parked:{}}; displayReturnedDraft(id,{text:'解释甲图',paths:['/fixture/原附件.zip']});
      pendingPastes.set(key,{key,id,view:viewKey(id),workspace:st.workspace}); send();
      showEmpty(id,'正在加载历史会话…'); st.conversationId=st.loadedId='粘贴乙'; syncReturnedDraft(id);
      window.onFilesDropped({pasted:true,pasteId:key,paths:['/fixture/甲截图.png']});
      const otherDraft=draftAttachments(st);
      showEmpty(id,'正在加载历史会话…'); st.conversationId=st.loadedId='粘贴甲'; syncReturnedDraft(id);
      const draft=draftAttachments(st);
      check(id+' 等截图发送时整份草稿跟随原会话',!otherDraft.text && !otherDraft.paths.length && draft.text==='解释甲图' && draft.paths.join()==='/fixture/原附件.zip,/fixture/甲截图.png',[otherDraft,draft]);
    } finally {
      pendingPastes.delete(key); showEmpty(id,'正在加载历史会话…'); Object.assign(st,prior);
      displayReturnedDraft(id,original); saveReturnedDrafts(id); setActive(previous,false);
    }
  }
