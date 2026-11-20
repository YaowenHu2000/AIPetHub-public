  // 同一份带普通文件和截图的草稿，经过不同回执、换页和重载后都应回到最初的目标。
  for (const agent of ALL_AGENT_IDS) {
    const previous = active, st = S[agent], original = draftAttachments(st);
    const prior = {conversationId:st.conversationId, loadedId:st.loadedId, newView:st.newView,
      workspace:st.workspace, returnedDrafts:st.returnedDrafts};
    setActive(agent,false);
    const open = cid => { st.conversationId = st.loadedId = cid; showEmpty(agent); };
    const reset = () => {
      st.returnedDrafts = {owner:'',parked:{}};
      st.newView = 'new:matrix'; st.workspace = '/fixture/矩阵'; open('矩阵甲'); displayReturnedDraft(agent,null);
    };
    const originalPaths = ['/fixture/首问.zip','/fixture/截图.png'];
    const snapshot = () => [st.draft,...st.attach.map(a=>a.path)];
    const expect = (name, got, want) => check(agent+' 草稿矩阵 '+name,JSON.stringify(got)===JSON.stringify(want),got);
    const eqDraft = (name, text, paths) => expect(name,snapshot(),[text,...paths]);
    const beginPaste = () => {
      const event = new Event('paste',{bubbles:true,cancelable:true});
      Object.defineProperty(event,'clipboardData',{value:{items:[{kind:'file',type:'image/png',
        getAsFile:()=>new Blob(['图'],{type:'image/png'})}]}});
      els.input.dispatchEvent(event);
      return [...pendingPastes.keys()].at(-1);
    };
    const receipt = (key,path) => window.onFilesDropped({pasteId:key,paths:[path],pasted:true});
    try {
      for (const missing of [false,true]) {
        reset(); open(''); startRun(agent,'后台首问');
        const background = [...st.runs.values()].at(-1); open('矩阵乙');
        if (missing) window.onConversationLoaded({agent,conversationId:'矩阵乙',missing:true});
        else window.onConversationsDeleted({agent,deleted:['矩阵乙'],failed:[]});
        const at = requests.length; setDraft(agent,'新问题'); send();
        const outgoing = requests.slice(at).find(r=>['askAgent','steerAgent'].includes(r.action));
        expect(missing?'历史消失后发新问':'删除项目后发新问',outgoing?.action,'askAgent');
        if (outgoing) st.runs.delete(outgoing.reqId);
        st.runs.delete(background.reqId);
      }
      for (const move of ['立即发送','切助手','保存失败']) {
        reset(); setDraft(agent,'看图');
        const first = beginPaste(), second = beginPaste();
        const at = requests.length;
        send(); receipt(second,'/二.png');
        if (move==='切助手') setActive(ALL_AGENT_IDS.find(other=>other!==agent),false);
        if (move==='保存失败') window.onFilesDropped({pasteId:first,error:'无法读取'});
        else receipt(first,'/一.png');
        const ask = requests.slice(at).find(r=>r.action==='askAgent');
        if (move==='立即发送') {
          expect(move,ask?.images,['/一.png','/二.png']);
          if (ask) st.runs.delete(ask.reqId);
          setDraft(agent,'下一份普通草稿'); open('矩阵乙');
          eqDraft('待发稿送走后恢复普通输入','下一份普通草稿',[]);
        } else {
          expect(move+'取消发送',!!ask,false); setActive(agent,false);
          eqDraft(move,'看图',move==='保存失败'?['/二.png']:['/一.png','/二.png']);
        }
      }
      for (const [name, outcome, away, returnAsk, reload] of [
        ['停止','interrupted',false,false,false], ['崩溃','failed',true,false,false],
        ['切走后正常收尾','completed',true,false,false], ['原问和队列一起失败','failed',true,true,false],
        ['网页重载后原问和队列一起失败','failed',true,true,true],
      ]) {
        reset();
        displayReturnedDraft(agent,{text:' 首问 ',paths:originalPaths,pasted:originalPaths.slice(1)});
        send();
        let run = [...st.runs.values()].at(-1);
        const request = requests.filter(x=>x.action==='askAgent').at(-1);
        for (const word of ['一','二']) {
          const path = '/fixture/'+word+'.zip';
          queueMessage(agent,word,[],{text:word,paths:[path]},run);
          setQueuedState(run.queue.at(-1),'waiting');
        }
        if (reload) {
          st.runs.delete(run.reqId); open('矩阵甲');
          window.onRestoreActiveTurn({...request,queue:run.queue.map(q=>({...q.draft, draft:q.draft,steerId:q.sid,state:'waiting',images:[]}))});
          run = st.runs.get(run.reqId);
        }
        if (away) open('矩阵乙');
        window.onAgentResponse({agent,reqId:run.reqId,conversationId:'矩阵甲',reply:'结束',outcome,restoreDraft:returnAsk});
        if (away) { eqDraft(name+'不串入乙','',[]); open('矩阵甲'); }
        eqDraft(name, (returnAsk?' 首问 \n\n':'')+'一\n\n二',[...(returnAsk?originalPaths:[]),'/fixture/一.zip','/fixture/二.zip']);
        if (returnAsk) expect(name+'保留截图清理标记',draftAttachments(st).pasted,originalPaths.slice(1));
      }
      for (const [name,settledFirst] of [['迟到的正式编号',true],['先绑定再收图',false]]) {
        reset(); open(''); startRun(agent,'建立会话');
        const run = [...st.runs.values()].at(-1), key = beginPaste();
        setDraft(agent,'原会话'); open('矩阵乙');
        if (settledFirst) receipt(key,'/甲.png');
        bindRun(agent,run,'正式甲');
        if (!settledFirst) receipt(key,'/甲.png');
        open('正式甲'); eqDraft(name,'原会话',['/甲.png']);
        st.runs.delete(run.reqId);
      }
      for (const order of [[0,1],[1,0]]) {
        reset();
        startRun(agent,'原问');
        const run = [...st.runs.values()].at(-1);
        for (const word of ['一','二','三']) {
          queueMessage(agent,word,[],{text:word,paths:['/'+word+'.zip']},run);
          setQueuedState(run.queue.at(-1),'waiting');
        }
        const items = run.queue.slice(); setDraft(agent,'稍后输入');
        items[order[0]].el.querySelector('.queued-cancel').click();
        window.onAgentSteer({agent,reqId:run.reqId,steerId:items[order[1]].sid,state:'rejected',restoreDraft:true,reason:'缺图'});
        window.onAgentResponse({agent,reqId:run.reqId,conversationId:viewKey(agent),reply:'已停止',cancelled:true});
        eqDraft('先撤回再拒收最后停止 '+order.join(),'一\n\n二\n\n三\n\n稍后输入',['/一.zip','/二.zip','/三.zip']);
      }
      reset(); startRun(agent,'原问');
      const arranged = [...st.runs.values()].at(-1);
      for (const word of ['先撤','一','二','三']) {
        queueMessage(agent,word,[],{text:word,paths:['/'+word+'.zip']},arranged);
        setQueuedState(arranged.queue.at(-1),word==='二'?'sent':'waiting');
      }
      arranged.queue[0].el.querySelector('.queued-cancel').click();
      arranged.queue.at(-1).el.querySelector('.queued-up').click();
      window.onAgentResponse({agent,reqId:arranged.reqId,conversationId:viewKey(agent),reply:'已停止',cancelled:true});
      eqDraft('撤回后跨过已送达项调序再停止','先撤\n\n三\n\n一\n\n二',['/先撤.zip','/三.zip','/一.zip','/二.zip']);
      reset();
      startRun(agent,'记录里的图',['/本地图.png'],[{id:'记录图',index:0}]);
      const retry = [...st.runs.values()].at(-1);
      window.onAgentSentImages({agent,reqId:retry.reqId,paths:{},restoredPaths:['/记录图.png']});
      open('矩阵乙');
      window.onAgentResponse({agent,reqId:retry.reqId,conversationId:'矩阵甲',reply:'⚠️ 未发送',restoreDraft:true});
      open('矩阵甲'); eqDraft('带历史原图的重试失败','记录里的图',['/记录图.png','/本地图.png']);
      for (const why of ['工作目录失效','首问未建会话','补充缺图','再次重试','提交首问前停止','单次协议拒绝询问权限']) {
        if (why==='提交首问前停止' && agent!=='deepseek') continue;
        if (why==='单次协议拒绝询问权限' && !['claude','gpt'].includes(agent)) continue;
        reset();
        const fresh = ['首问未建会话','提交首问前停止'].includes(why);
        if (fresh) open('');
        displayReturnedDraft(agent,{text:'原稿',paths:originalPaths});
        send(); const run = [...st.runs.values()].at(-1);
        if (why==='补充缺图') queueMessage(agent,'补充',[],{text:'补充',paths:originalPaths},run);
        if (why!=='再次重试') open('矩阵乙');
        const data = {agent,reqId:run.reqId,conversationId:fresh?'':'矩阵甲',reply:'⚠️ 失败',
          restoreDraft:why!=='首问未建会话',cancelled:why==='提交首问前停止'};
        if (why==='补充缺图') {
          window.onAgentSteer({...data,steerId:run.queue[0].sid,state:'rejected',reason:'缺图'});
          st.runs.delete(run.reqId);
        } else window.onAgentResponse(data);
        if (why==='再次重试') {
          st.msgEl.querySelector('.retry').click();
          window.onAgentResponse({...data,reqId:[...st.runs.values()].at(-1).reqId});
        } else {
          eqDraft(why+'不串入乙','',[]); open(fresh?'':'矩阵甲');
        }
        eqDraft(why,why==='补充缺图'?'补充':'原稿',originalPaths);
      }
      // 没拿到会话编号就停止或失败的首问，CLI 记录里没有它：不论停下时在看哪一页，切走再回来原话和附件都要在新对话的草稿里，
      // 等待期间新写的话排在后面；仍在看时留着的「重试」再失败一次也不重复退回。
      for (const [why,away,cancelled] of [['首问未建会话就停止',true,true],['首问停止时仍在看',false,true],['首问失败时仍在看',false,false]]) {
        reset(); open('');
        displayReturnedDraft(agent,{text:'原稿',paths:originalPaths});
        send(); const run = [...st.runs.values()].at(-1);
        if (away) open('矩阵乙'); else setDraft(agent,'新输入');
        const data = {agent,reqId:run.reqId,conversationId:'',reply:cancelled?'':'⚠️ 初始化失败',cancelled,...(cancelled?{}:{outcome:'failed'})};
        window.onAgentResponse(data);
        const want = away ? '原稿' : '原稿\n\n新输入';
        if (!away) {
          st.msgEl.querySelector('.retry')?.click();
          const retry = [...st.runs.values()].at(-1);
          if (retry) window.onAgentResponse({...data,reqId:retry.reqId});
          expect(why+'留着重试',!!retry,true);
        }
        open('矩阵乙'); eqDraft(why+'不串入乙','',[]);
        open(''); eqDraft(why,want,originalPaths);
      }
      // 已有会话的追问在交给 CLI 前停止（原生确认没提交，带 restoreDraft）：CLI 记录里没有它，原话和附件回到原会话的草稿，
      // 不论停下时在看哪一页；仍在看时等待期间新写的话排在后面，留着的「重试」点了再停一次也不重复退回。
      for (const away of [true,false]) {
        const why = away ? '追问提交前停止并切走' : '追问提交前停止时仍在看';
        reset();
        displayReturnedDraft(agent,{text:'原稿',paths:originalPaths});
        send(); const run = [...st.runs.values()].at(-1);
        if (away) open('矩阵乙'); else setDraft(agent,'新输入');
        const data = {agent,reqId:run.reqId,conversationId:'矩阵甲',reply:'追问还没发出，已退回草稿。',cancelled:true,restoreDraft:true};
        window.onAgentResponse(data);
        if (!away) {
          st.msgEl.querySelector('.retry')?.click();
          const retry = [...st.runs.values()].at(-1);
          if (retry) window.onAgentResponse({...data,reqId:retry.reqId});
          expect(why+'留着重试',!!retry,true);
        }
        open('矩阵乙'); eqDraft(why+'不串入乙','',[]);
        open('矩阵甲'); eqDraft(why,away?'原稿':'原稿\n\n新输入',originalPaths);
      }
      // 会话在别处被归档或删掉后点了发送：原生拦下、退回原话和附件（restoreDraft），接着的刷新答缺失，空闲的聊天页退出。
      // 那个会话再也打不开，退回的稿子要留在输入框、归到原项目的新对话，切走再回来还在；回答进行中的页面不退出，照常收尾
      {
        reset();
        displayReturnedDraft(agent,{text:'原稿',paths:originalPaths});
        send(); const run = [...st.runs.values()].at(-1);
        window.onAgentResponse({agent,reqId:run.reqId,conversationId:'矩阵甲',reply:'⚠️ 已归档',restoreDraft:true});
        window.onConversationLoaded({agent,conversationId:'矩阵甲',missing:true});
        expect('会话不在了退出空闲的聊天页',st.conversationId,'');
        eqDraft('会话不在了时退回的稿子留在输入框','原稿',originalPaths);
        open('矩阵乙'); eqDraft('会话不在了的退稿不串入乙','',[]);
        open(''); eqDraft('会话不在了的退稿归到原项目新对话','原稿',originalPaths);
        reset(); setDraft(agent,'进行中'); send(); const busy = [...st.runs.values()].at(-1);
        window.onConversationLoaded({agent,conversationId:'矩阵甲',missing:true});
        window.onAgentResponse({agent,reqId:busy.reqId,conversationId:'矩阵甲',reply:'答完了',outcome:'completed'});
        expect('回答进行中时不退出、照常收尾',[st.conversationId,st.runs.has(busy.reqId)],['矩阵甲',false]);
      }
      reset();
      const run = {agent,view:viewKey(agent),workspace:st.workspace,nodes:[]};
      queueMessage(agent,'补充',[],{text:'补充',paths:originalPaths},run);
      const item = run.queue[0]; setQueuedState(item,'waiting');
      displayReturnedDraft(agent,{text:'新稿',paths:['/新.zip']});
      item.el.querySelector('.queued-cancel').click(); open('矩阵乙');
      eqDraft('撤回后切走','',[]); open('矩阵甲');
      eqDraft('撤回先前的附件排在新稿前','补充\n\n新稿',[...originalPaths,'/新.zip']);

      for (const [name,away,count] of [['粘贴再拖入',false,0],['后台超过八个',true,7],['前台超过八个',false,7]]) {
        reset();
        const paths = Array.from({length:count},(_,i)=>'/fixture/'+i+'.zip');
        displayReturnedDraft(agent,{text:'待发',paths});
        const paste = beginPaste();
        window.onFilesDropped({paths:['/后.zip']});
        send();
        const at = requests.length;
        if (away) open('矩阵乙');
        receipt(paste,'/先.png');
        const ask = requests.slice(at).find(x=>x.action==='askAgent');
        if (away) { eqDraft(name+'不串入乙','',[]); open('矩阵甲'); }
        if (count) {
          expect(name+'不缺附件静默发出',!!ask,false);
          eqDraft(name,'待发',[...paths,'/先.png']);
        } else {
          const sent = ask && st.runs.get(ask.reqId);
          expect(name,sent?.draft?.paths,['/先.png','/后.zip']);
        }
        if (ask) st.runs.delete(ask.reqId);
      }
      reset();
      setDraft(agent,'待发');
      beginPaste(); window.onFilesDropped({paths:['/已经拖入.zip']}); send();
      // 模拟页面被销毁，首张仍在读，后一个文件已收到。重载只能用落盘的草稿和路径。
      pendingPastes.clear();
      st.returnedDrafts = lsJson(agent+'_returnedDrafts',{owner:'',parked:{}});
      st.draft = lsGet(agent+'_draft',''); loadAttachments(agent);
      syncReturnedDraft(agent);
      recoverReadyFiles(agent);
      eqDraft('截图等待中重载保留已收到的文件','待发',['/已经拖入.zip']);
      reset();
      open('');
      displayReturnedDraft(agent,{text:'解释',paths:originalPaths});
      const pending = beginPaste(); send();
      setWorkspace(agent,'/fixture/乙',false); receipt(pending,'/晚.png');
      eqDraft('同一临时编号换项目','',[]);
      setWorkspace(agent,'/fixture/矩阵',false);
      eqDraft('原项目取回待发稿','解释',[...originalPaths,'/晚.png']);
      for (const r of st.runs.values()) if (r.view==='new:matrix') st.runs.delete(r.reqId);

      reset(); open(''); startRun(agent,'建立会话');
      const first = [...st.runs.values()].at(-1), firstKey = beginPaste();
      setDraft(agent,'等图'); send(); open('矩阵乙');
      bindRun(agent,first,'正式甲');
      receipt(firstKey,'/晚.png'); open('正式甲');
      eqDraft('切走期间取得正式编号','等图',['/晚.png']);
      st.runs.delete(first.reqId);

      reset();
      attachBtn.click(); const pick = requests.at(-1);
      open('矩阵乙'); window.onFilesDropped({pasteId:pick.pasteId,paths:['/选.zip']});
      eqDraft('选文件期间切走','',[]);
      open('矩阵甲'); eqDraft('选中的文件归原会话','',['/选.zip']);
      reset();
      const edit = (text,paths,refs=[]) => {
        const host = document.createElement('div'); host._retry = {text,images:paths,refs};
        addEditButton(host,agent,text); host.querySelector('button').click();
      };
      displayReturnedDraft(agent,{text:'',paths:['/手动.png']});
      edit('同一附件',['/手动.png']); edit('无图',[]);
      eqDraft('编辑不接管手动加入的同一路径','无图',['/手动.png']);
      reset();
      edit('历史原图',[],[{id:'原图'}]); const editKey = requests.at(-1).reqId;
      open('矩阵乙'); receipt(editKey,'/恢复.png');
      eqDraft('恢复原图时切走','',[]);
      open('矩阵甲'); eqDraft('编辑文字与原图同归','历史原图',['/恢复.png']);
      edit('改选另一问',['/另一问.png']);
      eqDraft('改选只保留本次编辑的图','改选另一问',['/另一问.png']);
    } finally {
      Object.assign(st,prior); displayReturnedDraft(agent,original); saveReturnedDrafts(agent); setActive(previous,false);
    }
  }

  // 各入口都从相同的列表、正文命中和持久未读开始，比较操作后用户还能打开哪一条。
  for (const agent of ALL_AGENT_IDS) {
    const st = S[agent], saved = {...st}, query = histQuery, stored = lsGet(agent+'_unread');
    const current = lsGet(agent+'_conv'), cid = '删除矩阵甲', other = '删除矩阵乙';
    const row = {id:cid, title:'甲', cwd:'/fixture'}, sibling = {...row,id:other,title:'乙'};
    const loaded = (missing, rest={}) => window.onConversationLoaded({agent,conversationId:cid,missing,messages:[],...rest});
    try {
      for (const mode of ['单删','项目部分成功','当前同步','重开','后台确认','暂不可读','在答','失败','恢复后旧核对','恢复后旧搜索']) {
        histQuery = '矩阵搜索';
        Object.assign(st,{conversationId:cid,loadedId:mode==='重开'?null:cid,conversations:[row,sibling],
          unreadConvs:new Set([cid,other]),unread:true,runs:new Map(),unreadChecks:new Map(),unreadChecked:new Map()});
        lsSet(agent+'_conv',cid); lsSet(agent+'_unread',JSON.stringify([cid,other]));
        for (const key of [cid,other]) lsSet(agent+'_unread:'+key,'');
        showEmpty(agent,'矩阵旧页');
        requestHistorySearch(agent,histQuery);
        const batch = {agent,query:histQuery,reqId:st.bodyRequest,ids:[cid,other],items:[row,sibling]};
        window.onConversationsSearched(batch);
        if (mode === '单删') window.onConversationDeleted({agent,ok:true,conversationId:cid});
        if (mode === '项目部分成功') window.onConversationsDeleted({agent,deleted:[cid],failed:[other]});
        if (mode === '当前同步' || mode === '重开') loaded(true);
        if (mode === '暂不可读') loaded(true,{historyError:'暂时无法读取'});
        if (mode === '在答') {
          st.runs.set(1,{view:cid,since:Date.now(),phase:'thinking'});
          const rid = nextRequestId(); st.historyReads = new Map([[rid,'sync']]);
          loaded(true,{reqId:rid}); st.runs.clear();
        }
        if (mode === '失败') window.onConversationDeleted({agent,ok:false,conversationId:cid});
        if (mode === '后台确认' || mode === '恢复后旧核对') {
          st.conversationId = st.loadedId = other;
          window.onConversationsListed({agent,items:[sibling]});
          const reqId = st.unreadChecks.get(cid);
          if (mode === '恢复后旧核对') {
            window.onConversationsListed({agent,items:[row,sibling]});
            window.onConversationsListed({agent,items:[sibling]}); // 恢复后又跌到最近列表之外
          }
          loaded(true,{reqId});
        }
        if (mode === '恢复后旧搜索') {
          window.onConversationDeleted({agent,ok:true,conversationId:cid});
          histSections[agent].sec.querySelector('.hist-refresh').click();
          window.onConversationsSearched({...batch,reqId:st.bodyRequest});
        }
        window.onConversationsSearched(batch);
        const gone = ['单删','项目部分成功','当前同步','重开','后台确认'].includes(mode);
        const state = [st.conversationId,st.bodyHits.has(cid),st.unreadConvs.has(cid),[...readUnreadConversations(agent)].includes(cid)];
        const view = mode==='后台确认'||mode==='恢复后旧核对'?other:gone||mode==='恢复后旧搜索'?'':cid;
        const unread = !gone && mode!=='恢复后旧搜索';
        check(agent+' 删除矩阵 '+mode, JSON.stringify(state)===JSON.stringify([view,!gone,unread,unread])
          && (!gone || !st.conversations.some(i=>i.id===cid)) && st.bodyHits.has(other) && st.unreadConvs.has(other),state);
      }
      st.conversationId = st.loadedId = cid;
      lsSet(agent+'_conv',other); // 另一窗口最后打开的是乙，重启应继续乙。
      window.onConversationDeleted({agent,ok:true,conversationId:cid});
      check(agent+' 删除本页保留另一窗口的启动会话',!st.conversationId && lsGet(agent+'_conv')===other,lsGet(agent+'_conv'));
      // 首次载入读错后 loadedId 仍为空，外部随后删除，也要能通过刷新退出当前页。
      st.conversationId=cid; st.loadedId=null; st.historyReads=new Map(); st.unreadConvs=new Set();
      const at=requests.length;
      window.onConversationsListed({agent,items:[sibling]});
      check(agent+' 首次读取失败后仍能核对外部删除',requests.slice(at).some(r=>r.action==='loadConversation' && r.conversationId===cid),requests.slice(at));
      // 另一窗口在两个回调之间清了甲、添了丙；本窗口操作乙只能改乙自己的持久位。
      for (const action of ['读完','后台答完','删除']) {
        const adding = action==='后台答完';
        st.unreadConvs = new Set(adding ? [cid] : [cid,other]);
        lsSet(agent+'_unread',JSON.stringify(adding ? ['丙'] : [other,'丙']));
        for (const key of [cid,other]) lsSet(agent+'_unread:'+key,'');
        st.conversationId = other;
        if (action==='读完') markSeen(agent);
        else if (adding) setConversationUnread(agent,other,true);
        else window.onConversationDeleted({agent,ok:true,conversationId:other});
        const storedIds = [...readUnreadConversations(agent)].filter(key=>[cid,other,'丙'].includes(key)).sort();
        const expected = (adding ? ['丙',other] : ['丙']).sort();
        check(agent+' 另一实例更新未读后'+action, JSON.stringify(storedIds)===JSON.stringify(expected),storedIds);
      }
      const peerStart=requests.length;
      const wasEnabled=AGENT_IDS.includes(agent);
      if (!wasEnabled) AGENT_IDS.push(agent);
      window.onHistoryChangedElsewhere?.({agent});
      if (!wasEnabled) AGENT_IDS.splice(AGENT_IDS.indexOf(agent),1);
      const peerActions=requests.slice(peerStart).filter(r=>r.agent===agent).map(r=>r.action);
      check(agent+' 另一实例删除时本窗口重查列表和搜索',peerActions.includes('listConversations') && peerActions.includes('searchConversations'),peerActions);
      const oldActive=active;
      setActive(ALL_AGENT_IDS.find(key=>key!==agent),false);
      histQuery='切换助手时的原搜索';
      const switching=requests.length; setActive(agent,false);
      const actions=requests.slice(switching).filter(r=>r.agent===agent).map(r=>r.action);
      check(agent+' 切回助手时核对列表和原搜索',actions.includes('listConversations') && actions.includes('searchConversations'),actions);
      setActive(oldActive,false);
      histQuery = '切回时沿用的搜索词';
      const start = requests.length, enabled = AGENT_IDS.includes(agent);
      if (!enabled) AGENT_IDS.push(agent);
      lastAutoRefresh = 0; window.dispatchEvent(new Event('focus'));
      if (!enabled) AGENT_IDS.splice(AGENT_IDS.indexOf(agent),1);
      check(agent+' 窗口切回后更新原搜索',requests.slice(start).some(r=>r.action==='searchConversations' && r.agent===agent && r.query===histQuery),
        requests.slice(start).filter(r=>r.agent===agent).map(r=>r.action));
    } finally {
      for (const key of [cid,other]) lsSet(agent+'_unread:'+key,'');
      Object.assign(st,saved); lsSet(agent+'_unread',stored); lsSet(agent+'_conv',current);
      histQuery=query; showEmpty(agent); renderHistory(agent);
    }
  }
  // 另一个窗口已把会话移进「任务会话」：分组变化经原生通知同步过来，本窗口的确认框发出删除前按最新分组重新筛选，名单变了先重新显示数量。
  {
    const previous = active;
    ALL_AGENT_IDS.filter(a => !AGENT_IDS.includes(a)).forEach(enableAgent);
    for (const agent of ALL_AGENT_IDS) {
      const st=S[agent], old=projectDelete, overrides=st.taskOverrides, stored=lsGet(agent+'_task_overrides'), key='/fixture/双开删项目';
      const anchor=document.createElement('button'); document.body.appendChild(anchor);
      try {
        st.taskOverrides={}; lsSet(agent+'_task_overrides','{}');
        // 本窗口右键移动时把结果交给其他实例（网页存储不在实例之间实时同步）
        const item={id:'moved-here',title:'本窗口移动',cwd:key,timestamp:1}, posted=requests.length;
        const realOpen=openPopover; openPopover=(row,build)=>build()[0].items[0].onPick();
        try { conversationRow(agent,item).dispatchEvent(new MouseEvent('contextmenu')); } finally { openPopover=realOpen; }
        const told=requests.slice(posted).filter(r=>r.action==='taskGroupChanged');
        check(agent+' 右键移进任务会话后通知其他实例',told.length===1 && told[0].agent===agent && told[0].conversationId==='moved-here' && told[0].task===true,told);
        st.taskOverrides={}; lsSet(agent+'_task_overrides','{}');
        openPopover(anchor,()=>[],{}); askDeleteProject(agent,key);
        window.onProjectConversations({agent,workspace:key,ids:['keep-this','normal'],taskIds:[]});
        window.onTaskGroupChangedElsewhere?.({agent,conversationId:'keep-this',task:'task'});   // 另一实例右键移进任务会话
        check(agent+' 另一实例的分组变化写进本窗口',st.taskOverrides['keep-this']===true && lsJson(agent+'_task_overrides',{})['keep-this']===true,st.taskOverrides);
        const start=requests.length;
        els.popover.querySelector('.confirm-btn.danger').click();
        const first=requests.slice(start).filter(r=>r.action==='deleteConversations').map(r=>r.conversationIds);
        const text=els.popover.querySelector('.confirm-text')?.textContent || '';
        check(agent+' 删项目前按另一窗口的手动分组重新筛选并重新确认',!first.length && pop?.anchor===anchor && /的 1 个会话/.test(text),[first,text]);
        els.popover.querySelector('.confirm-btn.danger')?.click();
        const sent=requests.slice(start).filter(r=>r.action==='deleteConversations');
        check(agent+' 重新确认后只删仍属于项目的会话',sent.length===1 && JSON.stringify(sent[0].conversationIds)==='["normal"]',sent.map(r=>r.conversationIds));
        sent.forEach(r=>deletingProjects.delete(r.reqId));
      } finally {
        closePopover(); anchor.remove(); projectDelete=old; st.taskOverrides=overrides; lsSet(agent+'_task_overrides',stored); renderHistory(agent);
      }
    }
    setActive(previous,false);
  }
  // 正文搜索的首批结果回来之前：标题命中立即显示，只说「正在搜索正文」，不提前宣布没有匹配。
  {
    const previous = active, query = histQuery;
    ALL_AGENT_IDS.filter(a => !AGENT_IDS.includes(a)).forEach(enableAgent);
    const fields = ['conversations','bodyQuery','bodyHits','bodyItems','bodyComplete','bodyUnavailable','bodyRequest','bodyDropped','searchInFlight'];
    const saved = Object.fromEntries(ALL_AGENT_IDS.map(a => [a, Object.fromEntries(fields.map(k => [k, S[a][k]]))]));
    const text = a => histSections[a].list.textContent;
    try {
      ALL_AGENT_IDS.forEach(a => { S[a].conversations = [{id:'cold-'+a,title:'工作笔记',cwd:'/fixture/cold',timestamp:1}]; });
      histSearch.value = '冷门正文词'; histSearch.dispatchEvent(new Event('input'));
      for (const a of ALL_AGENT_IDS) check(a+' 正文搜索还没开始回包时不说没有匹配', !text(a).includes('没有匹配的会话') && text(a).includes('正在搜索正文'), text(a));
      clearTimeout(bodySearchTimer); ALL_AGENT_IDS.forEach(a => requestHistorySearch(a, histQuery));
      for (const a of ALL_AGENT_IDS) check(a+' 请求已发出、首批未回仍在搜索', !text(a).includes('没有匹配的会话') && text(a).includes('正在搜索正文'), text(a));
      for (const a of ALL_AGENT_IDS) {
        window.onConversationsSearched({agent:a, query:histQuery, reqId:S[a].bodyRequest, ids:['cold-'+a], items:[S[a].conversations[0]], complete:true});
        check(a+' 正文结果回来后显示命中', text(a).includes('工作笔记') && !text(a).includes('正在搜索正文'), text(a));
      }
      histSearch.value = '工作'; histSearch.dispatchEvent(new Event('input')); clearTimeout(bodySearchTimer);
      for (const a of ALL_AGENT_IDS) check(a+' 换词后标题命中立即显示、正文仍在搜', text(a).includes('工作笔记') && text(a).includes('正在搜索正文'), text(a));
      histSearch.value = '都不匹配的词'; histSearch.dispatchEvent(new Event('input')); clearTimeout(bodySearchTimer);
      for (const a of ALL_AGENT_IDS) {
        requestHistorySearch(a, histQuery);
        window.onConversationsSearched({agent:a, query:histQuery, reqId:S[a].bodyRequest, ids:[], items:[], complete:true});
        check(a+' 正文搜完才说没有匹配', text(a).includes('没有匹配的会话'), text(a));
      }
    } finally {
      clearTimeout(bodySearchTimer); histSearch.value = ''; histQuery = query;
      ALL_AGENT_IDS.forEach(a => { Object.assign(S[a], saved[a]); renderHistory(a); });
      setActive(previous,false);
    }
  }
  // 模型菜单换页的动画中途又重画同一页（「还原」、用量回包）：动画取消后面板恢复原本的滚动，不留临时的 overflow 和宽高。
  {
    const previous = active;
    ALL_AGENT_IDS.filter(a => !AGENT_IDS.includes(a)).forEach(enableAgent);
    for (const agent of ALL_AGENT_IDS) {
      setActive(agent,false); closePopover();
      try {
        openModelPopover();
        const box = els.popover;
        box.querySelector('.mp-model').click();
        box.querySelector('.mp-back').click();
        const moving = morph !== null && box.style.overflow === 'hidden';
        showModelView('panel');
        const now = [box.style.overflow, box.style.width, box.style.height];
        await sleep(700);   // 判「动画时长过去之后也没被改回去」，只能等一段；机器忙时只会等得更久，不会误报
        const later = [box.style.overflow, box.style.width, box.style.height];
        check(agent+' 模型菜单动画中重画同一页后恢复滚动', moving && morph === null && now.join('|') === '||' && later.join('|') === '||', {moving, now, later});
      } finally { closePopover(); }
    }
    setActive(previous,false);
  }
  // 回答进行中点桌宠「散步」：只记下偏好，动画仍是工作阶段；答完按偏好恢复散步，关掉的不再走。
  {
    const previous = active;
    ALL_AGENT_IDS.filter(a => !AGENT_IDS.includes(a)).forEach(enableAgent);
    for (const agent of ALL_AGENT_IDS) {
      const st = S[agent], pet = pets[agent], roam = st.roam, stored = lsGet(agent+'_roam');
      const run = {reqId:nextRequestId(), since:Date.now(), phase:'thinking', stepKind:'think', stepTitle:'思考中', view:'new:pet-roam'};
      try {
        if (st.roam) pet.toggleRoam();
        st.runs.set(run.reqId, run); pet.setBusy(true); pet.syncBusyState();
        const before = pet.state;
        pet.card.querySelector('[data-act="roam"]').click(); pet.tick();
        check(agent+' 忙时打开散步只记偏好、不打断工作动画', before === 'thinking' && st.roam && pet.state === 'thinking', [before, st.roam, pet.state]);
        st.runs.delete(run.reqId); pet.setBusy(false);
        for (let i = 0; i < 40 && pet.state !== 'walk'; i++) pet.tick();
        check(agent+' 答完按偏好恢复散步', pet.state === 'walk', pet.state);
        st.runs.set(run.reqId, run); pet.setBusy(true);
        pet.card.querySelector('[data-act="roam"]').click(); pet.tick();
        check(agent+' 忙时关掉散步也不打断工作动画', !st.roam && pet.state === 'thinking', [st.roam, pet.state]);
        st.runs.delete(run.reqId); pet.setBusy(false);
        for (let i = 0; i < 40; i++) pet.tick();
        check(agent+' 答完不再散步', pet.state === 'idle', pet.state);
      } finally {
        st.runs.delete(run.reqId); pet.setBusy(false);
        if (st.roam !== roam) pet.toggleRoam();
        lsSet(agent+'_roam', stored); pet.setState('idle'); pet.renderStatus();
      }
    }
    setActive(previous,false);
  }
  // hunt7 uncovered 第 3 条：点了垃圾桶、第二下之前下一批正文搜索结果到了会重建侧栏，同一行的「确认删除」要留着，第二下真的删
  for (const agent of ALL_AGENT_IDS) {
    const st = S[agent], keys = ['conversations','bodyQuery','bodyHits','bodyItems','bodyUnavailable','bodyComplete','searchInFlight','bodyRequest','bodyDropped'];
    const old = [histQuery, keys.map(k => st[k])], cid = '边搜边删-' + agent;
    try {
      histQuery = 'needle'; st.bodyRequest = 7301; st.bodyDropped = null;
      st.conversations = [{id:cid, title:'needle 会话', cwd:'/fixture/边搜边删', timestamp:1}];
      window.onConversationsSearched({agent, query:'needle', reqId:7301, ids:[cid], items:[], complete:false});
      const del = () => histSections[agent].list.querySelector('.conv-row .conv-del');
      del().click();
      window.onConversationsSearched({agent, query:'needle', reqId:7301, ids:[cid], items:[], complete:true});
      const armed = !!del()?.classList.contains('confirm'), before = requests.length;
      del()?.click();
      const sent = requests.slice(before).filter(r => r.action === 'deleteConversation').map(r => r.conversationId);
      check(agent + ' 边搜边删：新一批结果重画后仍是「确认删除」，再点就删', armed && sent.join() === cid, {armed, sent});
    } finally { histQuery = old[0]; keys.forEach((k, i) => { st[k] = old[1][i]; }); renderHistory(agent); }
  }
