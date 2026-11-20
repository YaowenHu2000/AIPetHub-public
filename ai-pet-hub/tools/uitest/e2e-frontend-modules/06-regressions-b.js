  {
    const st = S[id], old = [st.conversationId, st.loadedId];
    showEmpty(id, '正在加载历史会话…');
    st.loadedId = st.conversationId = 'b4-history';
    appendMessage(id, 'bot', '已载入的回答');
    const payload = {agent:id, conversationId:st.conversationId, messages:[], historyError:'服务启动失败：端口不可用'};
    window.onConversationLoaded(payload);
    const retry = [...st.msgEl.querySelectorAll('button')].find(b => b.textContent.includes('重新加载'));
    const before = requests.length;
    retry?.click();
    check('B4-1 读取失败保留正文、具体原因并可重读', st.msgEl.textContent.includes('已载入的回答') &&
      st.msgEl.textContent.includes(payload.historyError) && requests.slice(before).some(r=>r.action==='loadConversation' && r.conversationId==='b4-history'), st.msgEl.textContent);
    showEmpty(id, '正在加载历史会话…');
    for (const errorField of ['historyError','readError']) {
      showEmpty(id, '正在加载历史会话…'); st.loadedId = '';
      window.onConversationLoaded({agent:id, conversationId:'b4-history', messages:[{role:'user',text:'已读到的部分'}], [errorField]:'正文不可读'});
      check('B4-1 部分正文和错误同时可见 '+errorField, st.msgEl.textContent.includes('已读到的部分') &&
        st.msgEl.textContent.includes('正文不可读') && !!st.msgEl.querySelector('.history-error'), st.msgEl.textContent);
    }
    showEmpty(id, '正在加载历史会话…');
    [st.conversationId, st.loadedId] = old;
  }
  {
    const card = planCard({agent:'deepseek'}, {plan:'检查测试'});
    const labels = [...card.querySelectorAll('button')].map(b => b.textContent);
    check('B4-5 DeepSeek 计划卡只给两种可执行决定', labels.join() === '批准计划,先改计划', labels);
  }
  {
    for (const reqId of [0, 162]) {
      const card = permissionCard({agent:'deepseek', reqId}, {});
      const labels = [...card.querySelectorAll('button')].map(b => b.textContent);
      check('B4-6 审批范围跟随实际回合 ' + reqId, labels.join() === (reqId ? '允许,这一轮都允许,拒绝' : '允许一次,拒绝'), labels);
    }
  }
  {
    const st = S[id], old = [st.conversationId, st.loadedId], cid = 'b4-context';
    showEmpty(id, '正在加载历史会话…'); st.conversationId = st.loadedId = cid;
    const commands = agentCommands[id]; agentCommands[id] = [{name:'compact'}];
    startRun(id, '测试上下文');
    const run = [...st.runs.values()].at(-1);
    closePopover(); openModelPopover();
    const disabled = els.popover.querySelector('.ctx-compact')?.disabled;
    window.onAgentContext({agent:id, conversationId:cid, used:37, max:100});
    const value = els.popover.querySelector('.ctx-box .usage-label')?.textContent;
    window.onAgentResponse({agent:id, reqId:run.reqId, conversationId:cid, reply:'完成'});
    const after = els.popover.querySelector('.ctx-compact')?.disabled;
    check('B4-8 面板实时显示用量并在答完后恢复压缩', disabled && value === '已用 37%' && after === false, [disabled,value,after]);
    closePopover(); agentCommands[id] = commands; delete agentContext[id+':'+cid]; lsSet('context_usage',JSON.stringify(agentContext));
    showEmpty(id, '正在加载历史会话…'); [st.conversationId,st.loadedId] = old;
  }
  {
    startRun(id, '等待作答');
    const run = [...S[id].runs.values()].at(-1);
    const d = {agent:id,reqId:run.reqId,requestId:'b4-wait',kind:'permission'};
    window.onAgentRequest(d);
    const waiting = pets[id].statusEl.textContent;
    window.onAgentRequestClosed(d);
    check('B4-9 待答期间显示等待、撤卡后恢复', waiting.includes('等你回答／确认') && !pets[id].statusEl.textContent.includes('等你回答／确认'), waiting);
    window.onAgentResponse({agent:id,reqId:run.reqId,reply:'完成'});
  }
  {
    const st = S[id], old = [histQuery,st.conversations,st.groupState], groups = lsGet(id+'_groups');
    histQuery = 'needle'; st.groupState = {};
    st.conversations = Array.from({length:GROUP_PREVIEW+2},(_,i)=>({id:'b4-'+i,title:'needle '+i,cwd:'/b4',timestamp:i}));
    renderHistory(id);
    const list = histSections[id].list, more = list.querySelector('.see-all')?.textContent;
    list.querySelector('.grp-head')?.click();
    check('B4-10 搜索没有收起入口、点击组头不污染折叠设置', !more && st.groupState['/b4'] == null,[more,st.groupState['/b4']]);
    [histQuery,st.conversations,st.groupState] = old; lsSet(id+'_groups',groups); renderHistory(id);
  }
  {
    const before = [pane.tabs, pane.active], action = pane.el.querySelector('.ed-open');
    pane.tabs = [{id:731,kind:'changes'},{id:732,kind:'browser'}]; pane.active = 731;
    updatePaneActions(); const hidden = getComputedStyle(action).display === 'none';
    pane.active = 732; updatePaneActions();
    check('B4-11 改动页隐藏打开按钮、网页仍可打开', hidden && getComputedStyle(action).display !== 'none',hidden);
    [pane.tabs,pane.active] = before; updatePaneActions();
  }
  {
    const previous = active;
    active = 'deepseek'; closePopover(); openPermPopover();
    const labels = [...els.popover.querySelectorAll('.pop-name')].map(n=>n.textContent);
    check('B4-14 DeepSeek 权限菜单说明暂不支持且不能切换', els.popover.textContent.includes('暂不支持') && !labels.includes('带上') && !labels.includes('不带'), labels);
    closePopover(); active = previous;
  }
  {
    const say = pets[active].say;
    let reason = '';
    pets[active].say = s => { reason = s; };
    window.onFilesDropped({pasted:true,error:'磁盘空间不足'});
    pets[active].say = say;
    check('B4-17 截图写入失败显示原因', reason.includes('磁盘空间不足'), reason);
  }
  {
    const st = S[id], old = st.attach;
    st.attach = [];
    addAttachments(id,['/tmp/粘贴的图片/截图-20261118-010203.png'],true);
    addAttachments(id,['/tmp/原图.png'],false);
    loadAttachments(id); renderAttachments();
    const book = st.returnedDrafts, draft = st.draft;
    st.returnedDrafts = {owner:'', parked:{}};
    mergeDraft(draftTarget(id,{view:viewKey(id),workspace:st.workspace}),[{text:'',paths:[]}]);
    const before = requests.length;
    attachRow().querySelector('.attach-x').click(); attachRow().querySelector('.attach-x').click();
    const discarded = requests.slice(before).filter(r=>r.action==='discardPastedImage').map(r=>r.path);
    check('B4-18 重读草稿再移除只清理粘贴生成的文件', discarded.join()==='/tmp/粘贴的图片/截图-20261118-010203.png', discarded);
    st.returnedDrafts = book; saveReturnedDrafts(id); setDraft(id,draft);
    st.attach = old; saveAttachments(id); renderAttachments();
  }
  {
    const prior = [pane.tabs,pane.active,pane.el.hidden];
    pane.tabs = []; pane.active = null;
    openBrowser(); const web = browserTab(), before = requests.length;
    openPreview({path:'/tmp/b4.md'});
    const closes = () => requests.slice(before).filter(r=>r.action==='browserCommand' && r.cmd==='close').length;
    const hiddenOnly = closes(); closeTab(web.id);
    check('B4-19 切换标签保留网页、关闭浏览器标签释放页面', !hiddenOnly && closes()===1, [hiddenOnly,closes()]);
    closePreview(); [pane.tabs,pane.active] = prior; setPaneVisible(!prior[2]); renderPaneTabs(); renderPaneBody();
  }
  {
    // hunt7 uncovered 第 1 条：网页本身改了才直接刷新；别的文件改了交给原生按页面实际加载的资源判断，不按所在文件夹直接重载（会清空表单）
    const prior = [pane.tabs,pane.active,browser.file];
    pane.tabs = [{id:741,kind:'browser'}]; pane.active = 741; browser.file = '/fixture/site/pages/index.html';
    const sent = paths => {
      const before = requests.length;
      refreshPreviews(paths.map(path=>({path,kind:'edit'})),'/fixture/site');
      return requests.slice(before).map(r=>r.action==='browserCommand' ? r.cmd : r.action+':'+(r.paths||[]).join());
    };
    const got = [sent(['pages/README.md']), sent(['assets/styles.css']), sent(['pages/index.html','pages/README.md'])];
    check('本地网页预览只在网页本身改了时直接刷新，其他改动交原生按实际加载的资源判断', JSON.stringify(got)===JSON.stringify([
      ['browserReloadIfUses:/fixture/site/pages/README.md'],['browserReloadIfUses:/fixture/site/assets/styles.css'],['reload']]), got);
    [pane.tabs,pane.active,browser.file] = prior;
  }
  {
    // hunt10 recheck 不建议修第 2 条：本地网页停在 #章节 时地址栏带上章节，复制地址不丢；文件名里本来的「#」（网址里是 %23）照字面显示一次
    const prior = [browser.file,browser.url];
    const shown = (file,url) => { browser.file = file; browser.url = url; return browserAddress(); };
    const got = [shown('/fixture/guide.html','file:///fixture/guide.html#detail'), shown('/fixture/guide.html','file:///fixture/guide.html'),
                 shown('/fixture/日报#1.html','file:///fixture/%E6%97%A5%E6%8A%A5%231.html'), shown('/fixture/guide.html','file:///fixture/guide.html#%E4%B8%AD%E6%96%87'),
                 shown('','http://localhost:5173/#/settings')];
    check('本地网页地址栏带上 #章节', JSON.stringify(got)===JSON.stringify(['/fixture/guide.html#detail','/fixture/guide.html','/fixture/日报#1.html','/fixture/guide.html#中文','http://localhost:5173/#/settings']), got);
    [browser.file,browser.url] = prior;
  }
  {
    const prior = [pane.tabs,pane.active,pane.el.hidden];
    pane.tabs = []; pane.active = null;
    const files = Array.from({length:48}, (_,i)=>({path:'/tmp/b4-'+i,added:1}));
    const a = {files}, b = {files}; openChanges(a);
    const body = pane.el.querySelector('.ed-body');
    body.scrollTop = 400; const saved = body.scrollTop;
    openChanges(b); body.scrollTop=15; openChanges(a);
    check('B4-20 改动页恢复自己的阅读位置', saved>15 && body.scrollTop===saved, [saved,body.scrollTop]);
    closePreview(); [pane.tabs,pane.active] = prior; setPaneVisible(!prior[2]); renderPaneTabs(); renderPaneBody();
  }
  {
    const st=S[id], prior={unread:st.unread,unreadConvs:st.unreadConvs,conversations:st.conversations,conversationId:st.conversationId,loadedId:st.loadedId,newView:st.newView}, key=lsGet(id+'_conv'), unread=lsGet(id+'_unread');
    for (const mode of ['single','batch','missing']) {
      showEmpty(id, '正在加载历史会话…'); st.conversationId=st.loadedId='b4-seen';
      st.conversations=[{id:'b4-gone',cwd:'/b4',title:'测试'}]; st.unreadConvs=new Set(['b4-gone']); st.unread=true;
      if (mode==='single') window.onConversationDeleted({agent:id,conversationId:'b4-gone',ok:true});
      if (mode==='batch') window.onConversationsDeleted({agent:id,deleted:['b4-gone']});
      if (mode==='missing') {
        showEmpty(id, '正在加载历史会话…'); st.conversationId='b4-gone';
        window.onConversationLoaded({agent:id,conversationId:'b4-gone',missing:true});
      }
      check('B4-21 最后一条未读消失后标题清点 '+mode, !st.unread && !histSections[id].sec.classList.contains('unread'),st.unread);
    }
    showEmpty(id, '正在加载历史会话…'); Object.assign(st,prior); lsSet(id+'_conv',key); lsSet(id+'_unread',unread); renderHistory(id); updateIndicators(id);
  }
  {
    const st = S[id], run = {view:viewKey(id), queue:[], nodes:[]};
    const item = {sid:'回执中断', text:'只执行一次', images:[], state:'sending', run, el:document.createElement('div')};
    item.el.innerHTML = '<span class="queued-state"></span>';
    run.queue.push(item); st.runs.set(-71, run);
    window.onAgentSteer({agent:id,reqId:-71,steerId:item.sid,state:'uncertain'});
    st.runs.delete(-71);
    const before = requests.length, start = startRun, sends = [];
    startRun = (...args) => sends.push(args);
    try { flushQueue(id,run,{conversationId:run.view,reply:'好'}); } finally { startRun = start; }
    check('补充回执不明时不会自动重发', sends.length === 0 && !requests.slice(before).some(r => r.action === 'askAgent'), sends);
  }
  {
    for (const agent of ALL_AGENT_IDS) {
      const st = S[agent], prior = {conversationId:st.conversationId, returnedDrafts:st.returnedDrafts};
      const original = draftAttachments(st), origin = '排队甲';
      showEmpty(agent, '正在加载历史会话…');
      st.conversationId = '排队乙'; st.returnedDrafts = {owner:'', parked:{}};
      displayReturnedDraft(agent, {text:'乙草稿', paths:[]});
      const draft = {text:'甲补充', paths:['/tmp/甲.zip','/tmp/甲.png'], pasted:['/tmp/甲.png']};
      const run = {view:origin, workspace:st.workspace, nodes:[], queue:[{state:'waiting', text:'甲补充和文件路径', images:['/tmp/甲.png'], draft, el:document.createElement('div')}]};
      flushQueue(agent, run, {conversationId:origin});
      const parked = st.returnedDrafts.parked[draftSession(origin,st.workspace)];
      check(agent+' 排队补充退回原会话并保留附件顺序', st.draft === '乙草稿' && !st.attach.length && JSON.stringify(parked)===JSON.stringify(draft), [st.draft,parked]);
      showEmpty(agent, '正在加载历史会话…');
      Object.assign(st,prior); displayReturnedDraft(agent, original); saveReturnedDrafts(agent);
    }
  }
  {
    const st = S[id], before = draftAttachments(st), oldOther = draftAttachments(S[other]), start = startRun;
    const sends = [];
    startRun = (...args) => sends.push(args);
    const paste = () => {
      const event = new Event('paste', {bubbles:true,cancelable:true});
      Object.defineProperty(event, 'clipboardData', {value:{items:[{kind:'file',type:'image/png',getAsFile:()=>new Blob(['截图'],{type:'image/png'})}]}});
      els.input.dispatchEvent(event);
    };
    try {
      displayReturnedDraft(id,{text:'解释截图',paths:[]});
      const at = requests.length;
      paste(); send();
      await until(()=>requests.slice(at).some(r=>r.action==='savePastedImage'), '截图读完');
      const first = requests.slice(at).find(r=>r.action==='savePastedImage');
      window.onFilesDropped({pasted:true,pasteId:first.pasteId,paths:['/tmp/甲截图.png']});
      await Promise.resolve(); await Promise.resolve();
      check('粘贴后立即发送只发一次且带截图', sends.length===1 && sends[0][2].join()==='/tmp/甲截图.png', sends);
      const next = requests.length;
      paste(); setActive(other,false);
      await until(()=>requests.slice(next).some(r=>r.action==='savePastedImage'),'切换后截图读完');
      const second = requests.slice(next).find(r=>r.action==='savePastedImage');
      window.onFilesDropped({pasted:true,pasteId:second.pasteId,paths:['/tmp/乙截图.png']});
      await Promise.resolve(); await Promise.resolve();
      check('粘贴后切 AI 仍附给原草稿', st.attach.some(a=>a.path==='/tmp/乙截图.png') && !S[other].attach.some(a=>a.path==='/tmp/乙截图.png'), [st.attach,S[other].attach]);
    } finally {
      startRun = start; setActive(id,false);
      displayReturnedDraft(id,before); displayReturnedDraft(other,oldOther);
    }
  }
  {
    const st=S[id], cid='重载队列', prior=[st.conversationId,st.loadedId], reqId=nextRequestId();
    showEmpty(id, '正在加载历史会话…'); st.conversationId=st.loadedId=cid;
    const draft={text:'队列原文',paths:['/tmp/a.zip','/tmp/a.png'],pasted:['/tmp/a.png']};
    const queued={steerId:'重载补充',text:'队列原文和路径',images:['/tmp/a.png'],draft,state:'rejected'};
    const at=requests.length;
    window.onRestoreActiveTurn({agent:id,reqId,conversationId:cid,workspace:st.workspace,text:'原问',queue:[queued]});
    const run=st.runs.get(reqId), item=run?.queue?.[0];
    check('网页重载恢复原补充及附件，不重新投递', item?.sid===queued.steerId && item.state==='waiting' && JSON.stringify(item.draft)===JSON.stringify(draft) && !requests.slice(at).some(r=>r.action==='steerAgent'), item?.draft || null);
    st.runs.delete(reqId); run?.nodes.forEach(n=>n.remove());
    showEmpty(id, '正在加载历史会话…'); [st.conversationId,st.loadedId]=prior; updateIndicators(id); updateSendUI();
  }
  {
    const original=answerRequest; let reply;
    answerRequest=(_run,_card,body)=>{reply=body;};
    try {
      const single=questionCard({}, {questions:[{id:'q',options:[{label:'精简'}]}]});
      single.querySelector('input').value='手写'; single.querySelector('.req-option').click();
      check('单选改点选项只交最后选中的答案',reply?.answers?.q==='精简',reply?.answers);
      const multi=questionCard({}, {questions:[{id:'q',multiSelect:true,options:[{label:'文档、示例'},{label:'测试'}]}]});
      multi.querySelectorAll('.req-option').forEach(b=>b.click()); multi.querySelector('input').value='手写、补充';
      multi.querySelector('.primary').click();
      const parts=reply?.answerParts?.q;
      check('含顿号的选项和自填文字分别交回',JSON.stringify(parts?.selected)===JSON.stringify(['文档、示例','测试']) && parts?.custom==='手写、补充',reply);
    } finally {answerRequest=original;}
  }
  {
    for (const agent of ['claude','gemini']) {
      const st=S[agent], prior=AGENTS[agent].models, model=st.model, effort=st.effort, reported=modelReportedAt[agent];
      const keys=['models','model','effort'].map(k=>agent+'_'+k), values=keys.map(lsGet);
      const selected='fixture-selected', first='fixture-other';
      const full=[{v:selected,name:'原型号'},{v:first,name:'另一个型号'}];
      try {
        AGENTS[agent].models=full; st.model=selected; lsSet(agent+'_model',selected);
        window.onAgentModels({agent,complete:false,models:[full[1]]});
        const interim=[st.model,lsGet(agent+'_model'),AGENTS[agent].models.some(m=>m.v===selected)];
        window.onAgentModels({agent,complete:true,models:full});
        check(agent+' 部分目录保留选中型号直到完整目录返回',interim[0]===selected && interim[1]===selected && interim[2] && st.model===selected,{interim,final:st.model});
      } finally {
        AGENTS[agent].models=prior; st.model=model; st.effort=effort;
        if (reported===undefined) delete modelReportedAt[agent]; else modelReportedAt[agent]=reported;
        keys.forEach((k,i)=>lsSet(k,values[i])); renderComposer();
      }
    }
  }
  // Gemini Orchestrator 只公布一个型号：面板和输入框写「模型默认」、滑杆不能拖；以前给它存的 High 不报错、不再当成档位；Flash 照旧按档位。
  {
    const agent='gemini', previous=active, st=S[agent], prior=AGENTS[agent].models, model=st.model, effort=st.effort, byModel={...st.effortByModel};
    const keys=['models','model','effort','efforts'].map(k=>agent+'_'+k), values=keys.map(k=>lsGet(k));
    const orch='gemini-pro-orchestrator', flash='gemini-3.8-flash';
    if (!AGENT_IDS.includes(agent)) enableAgent(agent);
    setActive(agent,false); closePopover();
    const panel=()=>{ openModelPopover(); const box=els.popover, r=[box.querySelector('.mp-effort')?.textContent, box.querySelector('.mp-slider')?.classList.contains('fixed'), els.chipModel.querySelector('.chip-sub')?.textContent, st.effort]; closePopover(); return r; };
    try {
      st.effortByModel={...byModel,[orch]:'high',[flash]:'high'};
      window.onAgentModels({agent,models:[{v:orch,name:'Orchestrator (Carbon)',efforts:['default']},{v:flash,name:'Gemini 3.8 Flash',efforts:['low','medium','high']}]});
      chooseModel(agent,orch);
      const fixed=panel();
      check('Orchestrator 显示模型默认、滑杆固定，存过的 High 不再发出',JSON.stringify(fixed)===JSON.stringify(['模型默认',true,'模型默认','default']),fixed);
      chooseModel(agent,flash);
      const flashPanel=panel();
      check('Flash 仍按记住的档位、滑杆可拖',JSON.stringify(flashPanel)===JSON.stringify(['High',false,'High','high']),flashPanel);
    } finally {
      closePopover(); AGENTS[agent].models=prior; st.model=model; st.effort=effort; st.effortByModel=byModel;
      keys.forEach((k,i)=>lsSet(k,values[i])); setActive(previous,false); renderComposer();
    }
  }
  {
    const st=S[id], start=startRun, celeb=pets[id].celebrate, draft=draftAttachments(st), book=structuredClone(st.returnedDrafts);
    let celebrates=0; const sends=[];
    try {
      startRun(id,'未完成的原问'); const run=[...st.runs.values()].at(-1);
      queueMessage(id,'稍后再做');
      pets[id].celebrate=()=>celebrates++; startRun=(_,text)=>sends.push(text);
      window.onAgentResponse({agent:id,reqId:run.reqId,outcome:'incomplete',reply:'只写了一半'});
      const retry=!![...st.msgEl.querySelectorAll('.turn')].at(-1)?.querySelector('.retry');
      check('未完成保留重试，后问退回且桌宠不庆祝',retry && !celebrates && !sends.length && st.draft.includes('稍后再做'),{retry,celebrates,sends,draft:st.draft});
    } finally { startRun=start; pets[id].celebrate=celeb; st.returnedDrafts=book; saveReturnedDrafts(id); displayReturnedDraft(id,draft); }
  }
  for (const agent of ALL_AGENT_IDS) {
    const st = S[agent], prior = [st.conversationId, st.loadedId, st.shownOmitted, st.shownHasMore];
    showEmpty(agent, '正在加载历史会话…'); st.conversationId = st.loadedId = '同问分支';
    const branch = v => [{role:'user',text:'继续'}, {role:'bot',text:v+'版答案'},
      {role:'user',text:'核对'+v+'版'}, {role:'bot',text:v+'版核对'}];
    renderMessages(agent, branch('一'));
    syncAppend(agent, branch('二'), '', 0);
    const answers = [...st.msgEl.querySelectorAll('.turn .answer')].map(n=>n.textContent);
    check(agent+' 同文回退同步两轮新答案', st.msgEl.textContent.includes('二版答案') && !st.msgEl.textContent.includes('一版答案') && st.msgEl.textContent.includes('二版核对'), answers);
    showEmpty(agent, '正在加载历史会话…'); [st.conversationId, st.loadedId, st.shownOmitted, st.shownHasMore] = prior;
  }
  for (const [agent, mode] of [['gpt','ask'], ['claude','manual']]) {
    const saved = S[agent].perm, stored = lsGet(agent+'_perm');
    setActive(agent, false); closePopover(); els.chipPerm.click();
    const options = [...els.popover.querySelectorAll('.pop-item')];
    const names = options.map(row=>row.querySelector('.pop-name').textContent);
    options[names.indexOf('每次询问')]?.click();
    check(agent+' 从权限菜单选每次询问', names.includes('每次询问') && S[agent].perm === mode && lsGet(agent+'_perm') === mode, names);
    closePopover(); S[agent].perm = saved; lsSet(agent+'_perm',stored);
  }
  setActive(id, false);
  {
    const files = [{path:'/tmp/tool.txt'}, {path:'/tmp/saved.txt',workspaceOnly:true}];
    const rows = [...renderFilesCard(files).querySelectorAll('.file-row')];
    const body = document.createElement('div');
    renderChanges(document.createElement('div'),body,{extra:{files}});
    const labels = [...rows,...body.querySelectorAll('.chg-file-head')].map(row=>row.textContent.includes('同期工作区改动'));
    check('四位共用的文件卡和全部改动区分仅由快照发现的文件', labels.join() === 'false,true,false,true', labels);
  }
  for (const agent of ALL_AGENT_IDS) {
    const cid='仅图改动', key=agent+':'+cid, path='/tmp/仅图.png';
    const old=lsGet('turn_extras'), prior=turnExtras.get(key);
    try {
      rememberTurn(agent,{text:'',prompt:'请看这张图片。',images:[path],historyStart:0},{conversationId:cid,files:[{path:'script.sh'}]},'');
      const list=readTurnExtras().get(key);
      const matches=matchExtras(list,[{role:'user',text:'请看这张图片。',images:[{path}]},{role:'bot',text:'好'}]);
      check(agent+' 仅图提问重开保留命令改动',matches.get(1)?.files[0].path==='script.sh',[...matches.keys()]);
    } finally {if(prior) turnExtras.set(key,prior); else turnExtras.delete(key); lsSet('turn_extras',old);}
  }
  {
    const st=S[id], prior=[st.conversationId,st.loadedId,st.returnedDrafts], original=draftAttachments(st);
    showEmpty(id, '正在加载历史会话…'); st.conversationId=st.loadedId='重复重试'; st.returnedDrafts={owner:'',parked:{}};
    displayReturnedDraft(id,{text:'',paths:[]});
    const draft={text:'请检查',paths:['/tmp/缺图.png','/tmp/资料.zip'],pasted:[]};
    const args=attachmentsForSend(draft.text,draft.paths);
    startRun(id,args.text,args.images,[],draft);
    const reject=()=>window.onAgentResponse({agent:id,reqId:[...st.runs.values()].at(-1).reqId,conversationId:st.conversationId,reply:'⚠️ 缺图',outcome:'failed',restoreDraft:true});
    reject(); setDraft(id,st.draft+'，后来输入');
    for(let n=0;n<2;n++){st.msgEl.querySelectorAll('.retry').item(st.msgEl.querySelectorAll('.retry').length-1).click(); reject();}
    check('缺图后重复重试只退回一次原草稿和附件',st.draft==='请检查，后来输入' && st.attach.map(a=>a.path).join()===draft.paths.join(),draftAttachments(st));
    showEmpty(id, '正在加载历史会话…'); [st.conversationId,st.loadedId,st.returnedDrafts]=prior;
    displayReturnedDraft(id,original); saveReturnedDrafts(id);
  }
  for (const agent of ALL_AGENT_IDS) {
    const path='/tmp/大图.png', run={agent,historyStart:0,since:2000,prompt:'解释这张图',text:'解释这张图',images:[path],imageKeys:['发送字节']};
    const embedded=['gemini','claude'].includes(agent);
    const image=embedded?{ref:{agent,id:'step#0'},imageKey:'缩放后的字节'}:{path};
    const msg={role:'user',text:run.prompt,images:[image],createdAt:2.2};
    const cut=liveHistoryCut(run,[msg]);
    check(agent+' 对齐本轮存档大图并排除同文旧图',cut===0 && (!embedded || liveHistoryCut(run,[{...msg,createdAt:1}])===-1),cut);
  }
  {
    const cid='已撤销', old=lsGet('turn_extras'), key=id+':'+cid, file={path:'/tmp/撤销.txt'}, st=S[id];
    const prior=[st.conversationId,st.loadedId];
    showEmpty(id, '正在加载历史会话…'); st.conversationId=st.loadedId=cid;
    rememberTurn(id,{text:'试改',historyStart:0},{conversationId:cid,files:[],unchangedPaths:[file.path]},'/tmp');
    renderMessages(id,[{role:'user',text:'试改'},{role:'bot',text:'撤销了',files:[file]}]);
    check('确认已撤销的编辑在重开后仍无改动卡',!st.msgEl.querySelector('.files-card'),st.msgEl.querySelectorAll('.file-row').length);
    turnExtras.delete(key); lsSet('turn_extras',old);
    showEmpty(id, '正在加载历史会话…'); [st.conversationId,st.loadedId]=prior;
  }
