  // 点📎后取消：什么都没收到，普通草稿照旧跟着切换；选到文件才把整份草稿留在原会话。
  for (const agent of ALL_AGENT_IDS) {
    const previous=active, id=agent; setActive(id,false);
    const st=S[id], prior={conversationId:st.conversationId,loadedId:st.loadedId,returnedDrafts:st.returnedDrafts};
    const original=draftAttachments(st), open=view => { showEmpty(id,'正在加载历史会话…'); st.conversationId=st.loadedId=view; syncReturnedDraft(id); };
    try {
      open('选框甲'); st.returnedDrafts={owner:'',parked:{}}; saveReturnedDrafts(id); displayReturnedDraft(id,{text:'普通草稿',paths:[]});
      document.getElementById('attach-btn').click();
      const pick=requests.filter(r=>r.action==='pickAttachments').at(-1);
      window.onFilesDropped({paths:[],pasteId:pick?.pasteId});
      const stored=lsGet(id+'_returnedDrafts','');
      open('选框乙'); const cancelled=st.draft;
      check(id+' 取消选文件后普通草稿仍跟随会话切换且不写退回记录',!!pick && cancelled==='普通草稿' && !stored,[cancelled,stored]);
      open('选框甲'); document.getElementById('attach-btn').click();
      const chosen=requests.filter(r=>r.action==='pickAttachments').at(-1);
      window.onFilesDropped({paths:['/fixture/选中.zip'],pasteId:chosen?.pasteId});
      open('选框乙'); const away=draftAttachments(st); open('选框甲'); const back=draftAttachments(st);
      check(id+' 选到文件后整份草稿留在原会话',!away.text && !away.paths.length && back.text==='普通草稿' && back.paths.join()==='/fixture/选中.zip',[away,back]);
    } finally {
      showEmpty(id,'正在加载历史会话…'); Object.assign(st,prior);
      displayReturnedDraft(id,original); saveReturnedDrafts(id); setActive(previous,false);
    }
  }
  // 另一个窗口共用这份退回记录，这里直接改存储来模拟它：它暂存的普通草稿只属于它，不能顶掉本窗口的；它退回到某会话的文字和附件，本窗口离开该会话或同时写入都要留着。
  for (const agent of ALL_AGENT_IDS) {
    const previous=active, id=agent; setActive(id,false);
    const st=S[id], prior={conversationId:st.conversationId,loadedId:st.loadedId,returnedDrafts:st.returnedDrafts};
    const original=draftAttachments(st), open=view => { showEmpty(id,'正在加载历史会话…'); st.conversationId=st.loadedId=view; syncReturnedDraft(id); };
    const other=change => { const book=lsJson(id+'_returnedDrafts',{owner:'',parked:{}}); change(book.parked); lsSet(id+'_returnedDrafts',JSON.stringify(book)); };
    try {
      open('跨窗甲'); st.returnedDrafts={owner:'',parked:{}}; saveReturnedDrafts(id); displayReturnedDraft(id,{text:'本窗口普通',paths:[]});
      mergeDraft(draftTarget(id,{view:'跨窗退回',workspace:st.workspace}),[{text:'跨窗退回的原问',paths:[]}]);
      open('跨窗退回'); other(parked => { parked['']={text:'别的窗口的普通草稿',paths:[]}; });
      open('跨窗乙');
      check(id+' 另一窗口暂存的普通草稿不顶掉本窗口的',st.draft==='本窗口普通',st.draft);
      const held=draftSession('跨窗占用',st.workspace), mine='别的窗口退回的原问\n\n本窗口在占用会话写的';
      open('跨窗占用'); displayReturnedDraft(id,{text:'本窗口在占用会话写的',paths:['/fixture/本窗口.png']}); claimDraft(id);
      other(parked => { parked[held]={text:'别的窗口退回的原问',paths:['/fixture/brief.pdf'],pasted:[]}; });
      open('跨窗丙'); open('跨窗占用'); const back=draftAttachments(st);
      check(id+' 离开占着的会话时留下另一窗口刚退回的文字和附件',back.text===mine && back.paths.join()==='/fixture/brief.pdf,/fixture/本窗口.png',back);
      open('跨窗丙'); const stale=draftTarget(id,{view:'跨窗占用',workspace:st.workspace});
      other(parked => { const p=parked[held]; parked[held]={...p,text:'别的窗口后退回\n\n'+p.text,paths:['/fixture/后.zip',...p.paths]}; });
      mergeDraft(stale,[{text:'本窗口后退回',paths:['/fixture/本窗口后.zip']}]);
      open('跨窗占用'); const both=draftAttachments(st);
      check(id+' 两个窗口同时退回到同一会话都保留',both.text==='别的窗口后退回\n\n本窗口后退回\n\n'+mine
        && both.paths.join()==='/fixture/后.zip,/fixture/本窗口后.zip,/fixture/brief.pdf,/fixture/本窗口.png',both);
    } finally {
      showEmpty(id,'正在加载历史会话…'); Object.assign(st,prior);
      displayReturnedDraft(id,original); saveReturnedDrafts(id); setActive(previous,false);
    }
  }
  // 编辑已发图片：附件栏显示原文件名和原路径，发送仍用当次副本；再附同一原图时内容没变就不重复。
  for (const agent of ALL_AGENT_IDS) {
    const previous=active, id=agent; setActive(id,false);
    const st=S[id], original=draftAttachments(st), start=startRun, sends=[];
    const front='/fixture/封面.png', back='/fixture/背面.png', snap=c=>'/fixture/aipethub-sent-images/'+c.repeat(64)+'.png';
    const last=action=>requests.filter(r=>r.action===action).at(-1);
    const chips=()=>[...document.querySelectorAll('.attach-row .attach-chip')].map(c=>[c.querySelector('.attach-name').textContent,c.title]);
    try {
      displayReturnedDraft(id,null);
      startRun(id,'看两张',[front,back],[],{text:'看两张',paths:[front,back]}); const run=[...st.runs.values()].at(-1);
      window.onAgentSentImages({agent:id,reqId:run.reqId,paths:{[front]:snap('a'),[back]:snap('b')},restoredPaths:[]});
      run.nodes[0].querySelector('.msg-edit').click();
      window.onAgentResponse({agent:id,reqId:run.reqId,reply:'好'});
      const edited=chips();
      loadAttachments(id); renderAttachments();
      check(id+' 编辑已发图片显示原文件名和原路径、重载后不变',JSON.stringify(edited)===JSON.stringify([['封面.png',front],['背面.png',back]]) &&
        JSON.stringify(chips())===JSON.stringify(edited) && draftAttachments(st).paths.join()===[snap('a'),snap('b')].join(),[edited,chips()]);
      window.onFilesDropped({paths:[front]});
      const freeze=last('editChatImages');
      window.onFilesDropped({pasteId:freeze?.reqId,paths:[snap('a')]});
      document.getElementById('attach-btn').click();
      const pick=last('pickAttachments');
      window.onFilesDropped({pasteId:pick?.pasteId,paths:[front]});
      const pickFreeze=last('editChatImages');
      window.onFilesDropped({pasteId:pickFreeze?.reqId,paths:[snap('a')]});
      check(id+' 拖入或选中内容没变的同一原图不重复附上',freeze?.freeze===true && freeze.paths.join()===front && pickFreeze!==freeze && pickFreeze?.reqId===pick?.pasteId &&
        draftAttachments(st).paths.join()===[snap('a'),snap('b')].join(),{freeze,pickFreeze,paths:draftAttachments(st).paths});
      window.onFilesDropped({paths:[front]});
      window.onFilesDropped({pasteId:last('editChatImages')?.reqId,paths:[snap('c')]});
      startRun=(...args)=>sends.push(args);
      const shownBeforeSend=chips(); send();
      check(id+' 原图改过后作为另一份附上，发送仍用各自的副本',JSON.stringify(shownBeforeSend.map(c=>c[0]))===JSON.stringify(['封面.png','背面.png','封面.png']) &&
        sends[0]?.[2]?.join()===[snap('a'),snap('b'),snap('c')].join(),{shownBeforeSend,sent:sends[0]?.[2]});
    } finally { startRun=start; displayReturnedDraft(id,original); setActive(previous,false); }
  }
  // 图片查看器看的是发送时那一份，「用默认应用打开」也交同一份；「在访达中显示」仍定位原路径。
  for (const agent of ALL_AGENT_IDS) {
    const previous=active; setActive(agent,false);
    const st=S[agent], src='data:image/png;base64,AA==', ref={agent,conversationId:'看图会话',id:'图二'};
    // 第三张：重开带内嵌图的会话时只有记录引用、没有路径（hunt7 recheck 第 1 条），仍能交给默认应用；没有路径就没有访达按钮
    const images=[{path:'/fixture/原图.png',snapshot:'/fixture/发送时.png',src},{path:'/fixture/记录图.png',ref,src},{ref:{...ref,id:'图三'},src}];
    const outside=[];
    try {
      renderMessages(agent,[{role:'user',text:'看两张',images},{role:'bot',text:'好'}]);
      for (const node of st.msgEl.querySelectorAll('.msg-img')) {
        node.click();
        const buttons=[...document.querySelectorAll('.img-viewer .img-viewer-btn')], before=requests.length;
        buttons.forEach(b=>b.click());
        outside.push(requests.slice(before).map(r=>({action:r.action,path:r.path,ref:r.ref?.id})));
        closeImageViewer();
      }
      check(agent+' 查看器外部打开发送时那一份、访达仍定位原路径',JSON.stringify(outside)===JSON.stringify([
        [{action:'revealFile',path:'/fixture/原图.png'},{action:'openFile',path:'/fixture/发送时.png'}],
        [{action:'revealFile',path:'/fixture/记录图.png'},{action:'openFile',ref:'图二'}],
        [{action:'openFile',ref:'图三'}]]),outside);
    } finally { closeImageViewer(); showEmpty(agent); setActive(previous,false); }
  }
  for (const agent of ALL_AGENT_IDS) {
    const previous=active; setActive(agent,false);
    const st=S[agent], path='/fixture/review.png', copy='/fixture/发送副本.png', user='看图';
    const saved={conversationId:st.conversationId,loadedId:st.loadedId,ownAt:st.ownAt,ownTurnUnsynced:st.ownTurnUnsynced};
    showEmpty(agent,'正在加载历史会话…'); st.conversationId=st.loadedId='图片重试夹具';
    try {
      startRun(agent,user,[path]); const run=[...st.runs.values()].at(-1);
      window.onAgentSentImages?.({agent,reqId:run.reqId,paths:{[path]:copy}});
      const request=requests.filter(r=>r.action==='chatThumbs').at(-1);
      window.onChatThumbs({reqId:request.reqId,images:[{path,src:'data:image/png;base64,AA=='}]});
      const priorDraft=draftAttachments(st);
      displayReturnedDraft(agent,{text:'',paths:[]});
      run.nodes[0].querySelector('.msg-edit').click();
      check(agent+' 图片矩阵 当前编辑取当次副本',draftAttachments(st).paths.join()===copy,draftAttachments(st));
      displayReturnedDraft(agent,priorDraft);
      run.nodes[0].querySelector('.msg-img').click();
      const opened=requests.filter(r=>r.action==='chatImage').at(-1)?.path; closeImageViewer();
      window.onAgentResponse({agent,reqId:run.reqId,conversationId:st.conversationId,cancelled:true,outcome:'interrupted'});
      st.msgEl.querySelector('.retry').click();
      const sent=requests.filter(r=>r.action==='askAgent').at(-1);
      check(agent+' 当前气泡看原图和重试都取发送时的副本',opened===copy && sent.images.join()===copy,[opened,sent.images]);
      window.onAgentResponse({agent,reqId:sent.reqId,conversationId:st.conversationId,reply:'好'});
    } finally { showEmpty(agent,'正在加载历史会话…'); Object.assign(st,saved); setActive(previous,false); }
  }
  for (const agent of ALL_AGENT_IDS) {
    const previous=active, st=S[agent], original=draftAttachments(st);
    const path='/fixture/原图.png', copy='/fixture/快照.png', restored='/fixture/记录图.png';
    const ref={agent,conversationId:'旧会话',id:'图二'}, src='data:image/png;base64,AA==';
    const images=[{path,snapshot:copy,src},{path:'/fixture/显示名.png',ref,src},{path:'/fixture/正文.png',mentioned:true,src}];
    const last = action => requests.filter(r => r.action===action).at(-1);
    setActive(agent,false);
    try {
      for (const outcome of ['failed','interrupted']) {
        displayReturnedDraft(agent,null);
        renderMessages(agent,[{role:'user',text:'混合',images},{role:'bot',text:'结束',outcome}]);
        st.msgEl.querySelector('.msg-edit').click();
        const edit=last('editChatImages');
        if (edit) window.onFilesDropped({pasteId:edit.reqId,paths:[copy,restored]});
        st.msgEl.querySelector('.retry').click();
        const ask=last('askAgent'), run=st.runs.get(ask.reqId);
        check(agent+' 图片矩阵 重开'+outcome+'后编辑与重试保留顺序和缩略图',
          edit?.paths.join()===copy && edit.refs[0]?.index===1 && edit.refs[0]?.id===ref.id &&
          draftAttachments(st).paths.join()===[copy,restored].join() && ask.images.join()===copy &&
          ask.imageRefs[0]?.index===1 && ask.imageRefs[0]?.id===ref.id && run.nodes[0].querySelectorAll('.msg-img').length===3,
          {edit:edit?.paths,images:ask.images,refs:ask.imageRefs});
        displayReturnedDraft(agent,null);
        run.nodes[0].querySelector('.msg-edit').click();
        window.onAgentSentImages({agent,reqId:ask.reqId,paths:{[copy]:copy},restoredPaths:[restored]});
        window.onAgentResponse({agent,reqId:ask.reqId,outcome:'interrupted',cancelled:true});
        st.msgEl.querySelectorAll('.retry').item(st.msgEl.querySelectorAll('.retry').length-1).click();
        const again=last('askAgent');
        check(agent+' 图片矩阵 再重试也能在旧记录移走后取已恢复的图',again.imageRefs[0]?.snapshot===restored,again.imageRefs);
        const retryRun=st.runs.get(again.reqId);
        retryRun.nodes[0].querySelector('.msg-edit').click();
        window.onAgentSentImages({agent,reqId:again.reqId,paths:{[copy]:copy},restoredPaths:[restored]});
        check(agent+' 图片矩阵 连续重试回执前编辑每张只出现一次',
          draftAttachments(st).paths.join()===[copy,restored].join(),draftAttachments(st));
        window.onAgentResponse({agent,reqId:again.reqId,reply:'好'});
      }
      const reopenedId=nextRequestId();
      window.onRestoreActiveTurn({agent,reqId:reopenedId,conversationId:st.conversationId,workspace:st.workspace,text:'接回图片',
        sourceImages:[path],images:[copy],sentPaths:{[path]:copy},restoredPaths:[],draft:{text:'接回图片',paths:[path,'/fixture/资料.zip']}});
      displayReturnedDraft(agent,null);
      st.runs.get(reopenedId).nodes[0].querySelector('.msg-edit').click();
      check(agent+' 图片矩阵 网页重载后编辑接回的活动提问',draftAttachments(st).paths.join()===[copy,'/fixture/资料.zip'].join(),draftAttachments(st));
      window.onAgentResponse({agent,reqId:reopenedId,reply:'好'});
      // 前一轮拒收两条补充，第二条会先重新入队，之后再成为独立提问。
      startRun(agent,'开头'); const firstRun=[...st.runs.values()].at(-1);
      for (const text of ['补充甲','补充乙']) {
        queueMessage(agent,text,[path],{text,paths:[path,'/fixture/资料.zip']},firstRun);
        const sid=firstRun.queue.at(-1).sid;
        window.onAgentSentImages({agent,reqId:firstRun.reqId,steerId:sid,paths:{[path]:copy}});
        window.onAgentSteer({agent,reqId:firstRun.reqId,steerId:sid,state:'rejected'});
      }
      window.onAgentResponse({agent,reqId:firstRun.reqId,reply:'好'});
      const promoted=last('askAgent'), next=last('steerAgent');
      // 原生按实际送到的路径回报本次副本。
      window.onAgentSentImages({agent,reqId:promoted.reqId,steerId:next.steerId,paths:{[next.images[0]]:copy}});
      window.onAgentSteer({agent,reqId:promoted.reqId,steerId:next.steerId,state:'rejected'});
      window.onAgentResponse({agent,reqId:promoted.reqId,reply:'好'});
      const second=last('askAgent'), queuedRun=st.runs.get(second.reqId);
      window.onAgentSentImages({agent,reqId:second.reqId,paths:{[copy]:copy},restoredPaths:[]});
      displayReturnedDraft(agent,null);
      queuedRun.nodes[0].querySelector('.msg-edit').click();
      check(agent+' 图片矩阵 第二条补充排队两次后编辑仍取原副本',second.text==='补充乙' && second.images.join()===copy &&
        draftAttachments(st).paths.join()===[copy,'/fixture/资料.zip'].join(),{text:second.text,images:second.images,draft:draftAttachments(st)});
      window.onAgentResponse({agent,reqId:second.reqId,reply:'好'});
      displayReturnedDraft(agent,null);
      startRun(agent,'早编辑',[path],[],{text:'早编辑',paths:[path,'/fixture/资料.zip']});
      const run=[...st.runs.values()].at(-1);
      run.nodes[0].querySelector('.msg-edit').click();
      window.onAgentSentImages({agent,reqId:run.reqId,paths:{[path]:copy},restoredPaths:[]});
      check(agent+' 图片矩阵 回执前编辑保留原图和普通文件',draftAttachments(st).paths.join()===[copy,'/fixture/资料.zip'].join(),draftAttachments(st));
      window.onAgentResponse({agent,reqId:run.reqId,reply:'好'});
    } finally {
      displayReturnedDraft(agent,original);
      showEmpty(agent); setActive(previous,false);
    }
  }
  for (const agent of ALL_AGENT_IDS) {
    const previous=active, id=agent; setActive(id,false);
    const st=S[id], original=draftAttachments(st), key=nextRequestId(), start=startRun, sends=[];
    try {
      const paths=Array.from({length:8},(_,i)=>'/fixture/'+i+'.zip');
      displayReturnedDraft(id,{text:'请看截图',paths});
      startRun=(...args)=>sends.push(args[1]);
      pendingPastes.set(key,{key,id,view:viewKey(id),workspace:st.workspace});
      send(); window.onFilesDropped({pasted:true,pasteId:key,paths:['/fixture/第九张.png']});
      check(id+' 截图因超限未附上时保留整份待发草稿',!sends.length && st.draft==='请看截图' && st.attach.length===8,[sends,st.draft,st.attach.length]);
    } finally { pendingPastes.delete(key); startRun=start; displayReturnedDraft(id,original); setActive(previous,false); }
  }
  {
    const data = {kind:'question',requestId:'回执503',questions:[{id:'text',question:'要求'},{id:'format',question:'格式',options:[{label:'PNG'}]}],
      message:'答复尚未确认（503），请重试。',answerParts:{text:{selected:[],custom:'保留附录'},format:{selected:['PNG'],custom:''}}};
    const card = questionCard({agent:'deepseek',reqId:0},data);
    const values = [card.querySelector('.req-input').value,card.querySelector('.req-option')?.classList.contains('on')];
    check('DeepSeek 重摆提问卡恢复已填文字和选项',values[0]==='保留附录' && values[1],values);
  }
  for (const agent of ['gemini','deepseek']) {
    const st=S[agent], nodes=[...st.msgEl.childNodes], previous=active;
    setActive(agent,false);
    const original={role:'user',text:'检查文件',images:[{path:'/fixture/首问.png'}]};
    const step={kind:'user',title:'你补充说',detail:'改文件'};
    const last={role:'bot',text:'完成一半',steps:[step],outcome:'failed',retryUser:original};
    const history=[original,{role:'bot',text:'先检查'},...(agent==='gemini'?[{role:'user',text:'改文件'}]:[]),last];
    const data={reply:last.text,steps:[step],files:[{path:'answer.txt'}]};
    const extra=rememberTurn(agent,{text:original.text,prompt:original.text,historyStart:0},data,'');
    const at=[...matchExtras([extra],history).keys()];
    const start=startRun, sent=[]; startRun=(...args)=>sent.push(args);
    try {
      st.msgEl.replaceChildren();
      for (const row of history) renderOneMessage(agent,row,null,'');
      st.msgEl.querySelector('.retry')?.click();
      check(agent+' 补充分段后改动挂在末段且重试带原问原图',at[0]===history.length-1 && sent[0]?.[1]===original.text && sent[0]?.[2]?.[0]===original.images[0].path,[at,sent[0]?.slice(1,3)]);
    } finally { startRun=start; st.msgEl.replaceChildren(...nodes); setActive(previous,false); }
  }
  {
    const initial = active;
    for (const agent of ALL_AGENT_IDS) {
      const st = S[agent], a = 'unread-old', b = 'unread-selected';
      const prior = { conversationId:st.conversationId, loadedId:st.loadedId, unreadConvs:st.unreadConvs, unread:st.unread, loadedSig:st.loadedSig, pendingTitle:st.pendingTitle, applyCwdOnLoad:st.applyCwdOnLoad };
      const previousUnread = lsGet(agent+'_unread',''), previousConv = lsGet(agent+'_conv','');
      setActive(ALL_AGENT_IDS.find(x => x !== agent), false);
      showEmpty(agent, '正在加载历史会话…');
      st.conversationId = a; st.loadedId = a; st.unreadConvs = new Set();
      setConversationUnread(agent, a, true); setConversationUnread(agent, b, true);
      openConversation(agent, {id:b});
      const persisted = [...readUnreadConversations(agent)];
      check(agent+' 跨助手打开 B 保留未查看的 A', st.unreadConvs.has(a) && !st.unreadConvs.has(b) && persisted.includes(a) && !persisted.includes(b), persisted);
      showEmpty(agent, '正在加载历史会话…');
      for (const cid of [a,b]) lsSet(agent+'_unread:'+cid,'');
      Object.assign(st, prior); lsSet(agent+'_unread', previousUnread); lsSet(agent+'_conv', previousConv);
    }
    setActive(initial, false);
  }
  for (const agent of ALL_AGENT_IDS) {
    const priorAgent = active, st = S[agent];
    const prior = {conversationId:st.conversationId, loadedId:st.loadedId, ownAt:st.ownAt, ownTurnUnsynced:st.ownTurnUnsynced};
    setActive(agent,false); showEmpty(agent,'正在加载历史会话…');
    st.conversationId = st.loadedId = '同文重问夹具';
    try {
      startRun(agent,'核对前缀',[]);
      const partial = [...st.runs.values()].at(-1);
      window.onAgentResponse({agent,reqId:partial.reqId,conversationId:st.conversationId,reply:'半',outcome:'failed'});
      const written = [{role:'user',text:'核对前缀'},{role:'bot',text:'半句',outcome:'failed',endingReqId:partial.reqId}];
      syncAppend(agent,written,'',0);
      check(agent+' 切回时接上同一次请求才落盘的后半句',st.msgEl.querySelector('.turn')?._text==='半句' &&
        !!st.msgEl.querySelector('.retry'),st.msgEl.querySelector('.turn')?._text);
      for (const outcome of ['interrupted','failed','incomplete','completed']) {
        for (const [next,text] of [['completed','另一次完整正文'],['completed','原半截'],['failed','另一轮出错']]) {
          showEmpty(agent);
          startRun(agent,'继续',[]); const run = [...st.runs.values()].at(-1);
          window.onAgentResponse({agent,reqId:run.reqId,conversationId:st.conversationId,reply:'原半截',cancelled:outcome==='interrupted',outcome});
          const rows = (text,outcome) => [{role:'user',text:'继续'},{role:'bot',text,outcome}];
          const state = () => {
            const bot = st.msgEl.querySelector('.turn'), retry = bot?.querySelector('.retry');
            return [bot?._text,!!retry && !retry.hidden];
          };
          const live = state();
          syncAppend(agent,rows('原半截',outcome),'',0);
          const confirmed = state();
          syncAppend(agent,rows(text,next),'',0);
          const switched = state(), stopped = [...st.msgEl.querySelectorAll('.sys')].some(n=>n.textContent==='已停止');
          renderMessages(agent,rows(text,next),'',0);
          const reopened = state();
          check(agent+' '+outcome+' → '+next+' '+text+' 实时/对账/切回/重开',
            live[0]==='原半截' && live[1]===(outcome!=='completed') && String(live)===String(confirmed) &&
            switched[0]===text && switched[1]===(next!=='completed') && String(switched)===String(reopened) && !stopped,
            {live,confirmed,switched,reopened,stopped});
        }
      }
    } finally { showEmpty(agent,'正在加载历史会话…'); Object.assign(st,prior); setActive(priorAgent,false); }
  }
  for (const agent of ALL_AGENT_IDS) {
    const st=S[agent], priorQuery=histQuery, prior={bodyDropped:st.bodyDropped,bodyQuery:st.bodyQuery,bodyItems:st.bodyItems,bodyHits:st.bodyHits,bodyComplete:st.bodyComplete,bodyUnavailable:st.bodyUnavailable};
    histQuery='恢复夹具'; const cid='恢复后的会话', refresh=histSections[agent].sec.querySelector('.hist-refresh');
    const search=()=>{ refresh.click(); return requests.filter(r=>r.agent===agent && r.action==='searchConversations').at(-1)?.reqId; };
    const deliver=reqId=>window.onConversationsSearched({agent,query:histQuery,reqId,ids:[cid],items:[{id:cid,title:'历史'}]});
    try {
      const old=search(); deliver(old); window.onConversationDeleted({agent,ok:true,conversationId:cid}); deliver(old);
      const hidden=!st.bodyHits.has(cid), fresh=search(); deliver(fresh);
      check(agent+' 同词新搜索重新显示已恢复的会话',hidden && st.bodyHits.has(cid),[...st.bodyHits]);
    } finally { histQuery=priorQuery; Object.assign(st,prior); renderHistory(agent); }
  }
  for (const agent of ALL_AGENT_IDS) {
    const st=S[agent], q=histQuery, prior={bodyQuery:st.bodyQuery,bodyItems:st.bodyItems,bodyHits:st.bodyHits,bodyComplete:st.bodyComplete,bodyUnavailable:st.bodyUnavailable};
    const item={id:'验证用夹具',cwd:'/tmp/aipethub-verify',title:'只回复 OK'};
    try {
      histQuery='ok'; window.onConversationsSearched({agent,query:'ok',ids:[item.id],items:[item]});
      const row=histSections[agent].list.querySelector('[data-k="c:'+item.id+'"]');
      check(agent+' 搜索隐藏添加助手时的验证会话',!row,row?.textContent);
    } finally { histQuery=q; Object.assign(st,prior); renderHistory(agent); }
  }
  for (const agent of ['gemini','deepseek']) {
    const st = S[agent], prior = active;
    const saved = {conversationId:st.conversationId,loadedId:st.loadedId,ownAt:st.ownAt,ownTurnUnsynced:st.ownTurnUnsynced};
    setActive(agent,false); showEmpty(agent,'正在加载历史会话…');
    st.conversationId = st.loadedId = '拆段后停止';
    try {
      const step = {kind:'user',title:'你补充说',detail:'补图'};
      const end = (text,data) => {
        startRun(agent,text,[]); const run = [...st.runs.values()].at(-1);
        window.onAgentResponse({agent,reqId:run.reqId,conversationId:st.conversationId,...data});
      };
      end('原问',{reply:'看到了',steps:[step]});
      end('数数',{reply:'一二三',cancelled:true,outcome:'interrupted'});
      const stopped = st.msgEl.querySelector('.retry').closest('.turn');
      const history = [{role:'user',text:'原问'},{role:'bot',text:''},{role:'user',text:'补图'},{role:'bot',text:'看到了'},
        {role:'user',text:'数数'},{role:'bot',text:'一二三',outcome:'interrupted'}];
      syncAppend(agent,history,'',0); syncAppend(agent,history,'',0);
      const turns = [...st.msgEl.querySelectorAll('.turn')];
      check(agent+' 前轮补充分段后停止回答仍在原问下', turns.length===3 && turns.at(-1)===stopped && st.msgEl.querySelectorAll('.retry').length===1,turns.map(n=>n._text));
    } finally { showEmpty(agent,'正在加载历史会话…'); Object.assign(st,saved); setActive(prior,false); }
  }
  for (const agent of ALL_AGENT_IDS) {
    const st=S[agent], previous=active, q=histQuery, old={conversationId:st.conversationId,loadedId:st.loadedId,bodyHits:st.bodyHits,bodyQuery:st.bodyQuery};
    setActive(agent,false); showEmpty(agent,'正在加载历史会话…');
    try {
      st.conversationId=st.loadedId='跨高亮节点'; histQuery=st.bodyQuery='const finalmarker'; st.bodyHits=new Set([st.conversationId]);
      renderMessages(agent,[{role:'bot',text:'```js\n'+'// line\n'.repeat(300)+'const finalMarker = 9;\n```'}],'');
      st.msgEl.scrollTop=0; jumpToSearchHit(agent);
      const marker=[...st.msgEl.querySelectorAll('code span')].findLast(el=>el.textContent==='const');
      const rect=marker?.getBoundingClientRect(), view=st.msgEl.getBoundingClientRect();
      check(agent+' 跨高亮节点的命中行进入可视区',rect && rect.top>=view.top && rect.bottom<=view.bottom,[rect?.top,view.top,view.bottom]);
    } finally { showEmpty(agent,'正在加载历史会话…'); histQuery=q; Object.assign(st,old); setActive(previous,false); }
  }
  {
    const agent='deepseek', st=S[agent], prior=st.unattendedSince, rows=st.conversations, q=histQuery;
    const cid='后台审批夹具', row={id:cid,title:'审批夹具',cwd:'',timestamp:1};
    try {
      histQuery=''; st.conversations=[row]; st.unattendedSince=new Map([['后台卡',{cid,since:1}]]);
      renderHistory(agent);
      const label=()=>histSections[agent].list.querySelector('[data-k="c:'+cid+'"] .conv-time')?.textContent;
      const pending=label(); window.onAgentRequestClosed({agent,reqId:0,requestId:'后台卡'});
      check('DeepSeek 后台审批行标出等待并随撤卡更新',pending==='等你处理' && label()!=='等你处理',[pending,label()]);
    } finally { histQuery=q; st.conversations=rows; st.unattendedSince=prior; renderHistory(agent); }
  }
  for (const agent of ['gemini','claude']) {
    const st=S[agent], previous=active, old={conversationId:st.conversationId,loadedId:st.loadedId,loadedSig:st.loadedSig};
    setActive(agent,false); showEmpty(agent,'正在加载历史会话…'); st.conversationId='压缩重试夹具'; st.loadedId='';
    try {
      window.onConversationLoaded({agent,conversationId:st.conversationId,messages:[{role:'user',text:'/compact'},{role:'bot',text:'已中断',outcome:'interrupted'}]});
      const start=startRun, asks=[]; startRun=(...args)=>asks.push(args[1]);
      try { st.msgEl.querySelector('.retry')?.click(); } finally { startRun=start; }
      check(agent+' 重开压缩失败后重试只发送压缩命令',asks.join()==='/compact',asks);
    } finally { showEmpty(agent,'正在加载历史会话…'); Object.assign(st,old); setActive(previous,false); }
  }
  {
    const agent='claude', st=S[agent], old={model:st.model,effort:st.effort,effortByModel:st.effortByModel}, models=AGENTS.claude.models, at=modelReportedAt.claude;
    const keys=['models','model','effort','efforts'].map(s=>'claude_'+s), values=keys.map(k=>lsGet(k));
    try {
      st.model='claude-opus-5-5'; st.effort='low'; st.effortByModel={[st.model]:'low'};
      window.onAgentModels({agent,models:[{v:'opus',name:'Opus',efforts:['low','high']}]});
      check('Claude 旧 Opus 型号迁移后保留刚选的 Low',st.model==='opus' && st.effort==='low',[st.model,st.effort]);
    } finally { Object.assign(st,old); AGENTS.claude.models=models; modelReportedAt.claude=at; keys.forEach((k,i)=>lsSet(k,values[i])); renderComposer(); }
  }
  for (const agent of ALL_AGENT_IDS) {
    const st=S[agent], old=projectDelete, added=st.addedWs, key='/fixture/删除甲', cid='删除甲会话';
    const saved=lsGet(agent+'_added_ws');
    try {
      st.addedWs=[{path:key,ts:1}]; projectDelete={id:agent,key,ids:[cid]}; confirmDeleteProject();
      const req=requests.filter(r=>r.action==='deleteConversations').at(-1);
      projectDelete={id:agent,key:'/fixture/取消乙',ids:[]}; closePopover();
      window.onConversationsDeleted({agent,deleted:[cid],failed:[],reqId:req?.reqId});
      check(agent+' 取消另一个项目的确认框后仍清理已删项目',!st.addedWs.some(w=>w.path===key),st.addedWs.map(w=>w.path));
    } finally { projectDelete=old; st.addedWs=added; lsSet(agent+'_added_ws',saved); renderHistory(agent); }
  }
  showEmpty(id);
  S[id].taskOverrides = savedOverrides; S[id].groupState = savedGroupState;
  S[id].conversations = savedConversations; S[id].conversationId = savedConversationId; S[id].loadedId = savedLoadedId;
  renderHistory(id); showEmpty(id);
