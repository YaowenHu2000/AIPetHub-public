  // SR：发送和本轮归属。新对话、历史读取未回、压缩提示、带图失败四种情况下，消息发给对的会话、留在对的位置。
  {
    const st = S[id], keep = { cid: st.conversationId, loaded: st.loadedId, newView: st.newView, pendingTitle: st.pendingTitle,
      lastPrompt: st.lastPrompt, prompts: st.prompts, lsPrompts: lsGet(`${id}_prompts`), lsConv: lsGet(`${id}_conv`), draft: st.draft,
      lsDraft: lsGet(`${id}_draft`), attach: st.attach, input: els.input.value, say: pets[id].say, sig: st.loadedSig,
      unread: st.unread, own: st.ownTurnUnsynced, ownAt: st.ownAt, elsewhereAt: st.elsewhereAt, omitted: st.shownOmitted, hasMore: st.shownHasMore };
    const said = []; pets[id].say = text => { said.push(text); };
    const mine = new Set(st.runs.keys());
    const dropRuns = () => { [...st.runs.keys()].filter(k => !mine.has(k)).forEach(k => st.runs.delete(k)); pets[id].setBusy(isBusy(id)); };
    const startAt = text => { const at = requests.length; startRun(id, text, []); return requests.slice(at).find(r => r.action === 'askAgent'); };
    // (1) 新对话 A 还在回答、没拿到会话 ID 时打开 B 再删掉 B 所在项目：回到的新对话不能沿用 A 的临时编号
    st.conversationId = ''; st.loadedId = ''; st.newView = `new:${++viewSeq}`; showEmpty(id);
    const askA = startAt('SR 新会话 A');
    st.conversationId = 'sr-proj-b'; st.loadedId = 'sr-proj-b'; showEmpty(id);
    window.onConversationsDeleted({ agent: id, deleted: ['sr-proj-b'], failed: [] });
    const beforeEnter = requests.length; type('SR 删项目后的新问题'); send();
    const enterSent = requests.slice(beforeEnter).find(r => r.action === 'askAgent' || r.action === 'steerAgent');
    check('SR 删除当前项目后的新对话发出新提问，不补充给后台会话', enterSent?.action === 'askAgent' && enterSent.reqId !== askA?.reqId,
      { action: enterSent?.action, reqId: enterSent?.reqId, runA: askA?.reqId, view: viewKey(id) });
    dropRuns(); showEmpty(id);
    // (2) 打开历史、读取还没回来就发问并立即失败：迟到的历史回包只补在前面，不抹掉提问、错误和「重试」
    st.conversationId = 'sr-held'; st.loadedId = null; st.loadedSig = ''; showEmpty(id, '正在加载历史会话…');
    const heldReq = nextRequestId(); (st.historyReads ??= new Map()).set(heldReq, 'open');
    const askHeld = startAt('SR 读取期间的提问');
    window.onAgentResponse({ agent: id, reqId: askHeld.reqId, reply: '⚠️ 工作空间不存在：/sr-moved', conversationId: '', outcome: 'failed' });
    window.onConversationLoaded({ agent: id, reqId: heldReq, conversationId: 'sr-held', cwd: '', limit: 300, omitted: 0,
      messages: [{ role: 'user', text: 'SR 旧提问' }, { role: 'bot', text: 'SR 旧回答' }] });
    const heldUsers = [...st.msgEl.querySelectorAll('.msg.user')].map(n => n.textContent);
    const heldLast = [...st.msgEl.querySelectorAll('.msg.bot.turn')].at(-1);
    check('SR 迟到的历史回包保留读取期间的提问、错误和重试', heldUsers.join('|') === 'SR 旧提问|SR 读取期间的提问'
      && !!heldLast?.textContent.includes('工作空间不存在') && !!heldLast?.querySelector('.answer-copy.retry'),
      { users: heldUsers, last: heldLast?.textContent.slice(0, 80), retry: !!heldLast?.querySelector('.answer-copy.retry') });
    dropRuns(); st.historyReads?.clear(); showEmpty(id);
    // (2b) 读取排在同一队列后面，回来时本轮已答完并写进记录：按记录只显示一遍，不再另接本地那份
    const doneHistory = [{ role: 'user', text: 'SR 旧提问' }, { role: 'bot', text: 'SR 旧回答' }];
    st.conversationId = 'sr-done'; st.loadedId = null; st.loadedSig = ''; showEmpty(id, '正在加载历史会话…');
    const doneReq = nextRequestId(); st.historyReads.set(doneReq, 'open');
    const askDone = startAt('SR 已写入的提问');
    window.onAgentResponse({ agent: id, reqId: askDone.reqId, reply: 'SR 已写入的回答', conversationId: 'sr-done' });
    window.onConversationLoaded({ agent: id, reqId: doneReq, conversationId: 'sr-done', cwd: '', limit: 300, omitted: 0,
      messages: [...doneHistory, { role: 'user', text: 'SR 已写入的提问' }, { role: 'bot', text: 'SR 已写入的回答' }] });
    const doneUsers = [...st.msgEl.querySelectorAll('.msg.user')].map(n => n.textContent);
    check('SR 迟到的历史回包已含本地答完的一轮时只显示一遍', doneUsers.join('|') === 'SR 旧提问|SR 已写入的提问'
      && st.msgEl.querySelectorAll('.msg.bot.turn').length === 2, { users: doneUsers, turns: st.msgEl.querySelectorAll('.msg.bot.turn').length });
    dropRuns(); st.historyReads.clear(); showEmpty(id);
    // (2c) 回来时本轮还在回答、提问已写进记录：截在这句提问前，接上进行中的回答，提问只显示一遍
    st.conversationId = 'sr-going'; st.loadedId = null; st.loadedSig = ''; showEmpty(id, '正在加载历史会话…');
    const goingReq = nextRequestId(); st.historyReads.set(goingReq, 'open');
    startAt('SR 进行中的提问');
    const goingRun = runsOf(id, 'sr-going')[0];
    window.onConversationLoaded({ agent: id, reqId: goingReq, conversationId: 'sr-going', cwd: '', limit: 300, omitted: 0,
      messages: [...doneHistory, { role: 'user', text: 'SR 进行中的提问' }, { role: 'bot', text: 'SR 写了一半' }] });
    const goingAsks = [...st.msgEl.querySelectorAll('.msg.user')].filter(n => n.textContent === 'SR 进行中的提问').length;
    check('SR 迟到的历史回包已含进行中的提问时只显示一遍并接上实时回答', goingRun?.historyStart === 2 && goingAsks === 1
      && !!goingRun?.live?.el.isConnected && st.msgEl.lastElementChild === goingRun?.live?.el,
      { historyStart: goingRun?.historyStart, asks: goingAsks, live: !!goingRun?.live?.el.isConnected });
    dropRuns(); st.historyReads.clear(); showEmpty(id);
    // (2d) 新对话 A 还在回答，打开的历史 B 文件已经不在：回到的新对话不能沿用 A 的临时编号
    st.conversationId = ''; st.loadedId = ''; st.newView = `new:${++viewSeq}`; showEmpty(id);
    const askMissingA = startAt('SR 新会话 A2');
    st.conversationId = 'sr-missing'; st.loadedId = null; showEmpty(id, '正在加载历史会话…');
    window.onConversationLoaded({ agent: id, conversationId: 'sr-missing', missing: true, messages: [] });
    const beforeMissing = requests.length; type('SR 历史不在后的新问题'); send();
    const missingSent = requests.slice(beforeMissing).find(r => r.action === 'askAgent' || r.action === 'steerAgent');
    check('SR 打开的历史不在后回到的新对话发出新提问，不补充给后台会话', missingSent?.action === 'askAgent' && missingSent.reqId !== askMissingA?.reqId,
      { action: missingSent?.action, reqId: missingSent?.reqId, runA: askMissingA?.reqId, view: viewKey(id) });
    dropRuns(); showEmpty(id);
    // (3) 读入的历史里有压缩提示：本轮起点和历史条目同一口径，切走再切回时截掉记录里已写入的本轮，不显示两遍
    const compactHistory = [{ role: 'user', text: 'SR 压缩前提问' }, { role: 'bot', text: 'SR 压缩前回答' }, { role: 'compact', text: '前面的对话已经压缩成摘要' }];
    st.conversationId = 'sr-compact'; st.loadedId = null; st.loadedSig = '';
    window.onConversationLoaded({ agent: id, conversationId: 'sr-compact', cwd: '', limit: 300, omitted: 0, messages: compactHistory });
    startAt('SR 压缩后提问');
    const compactRun = runsOf(id, 'sr-compact')[0];
    st.loadedSig = '';
    window.onConversationLoaded({ agent: id, conversationId: 'sr-compact', cwd: '', limit: 300, omitted: 0,
      messages: [...compactHistory, { role: 'user', text: 'SR 压缩后提问' }, { role: 'bot', text: 'SR 部分回答' }] });
    const compactAsks = [...st.msgEl.querySelectorAll('.msg.user')].filter(n => n.textContent === 'SR 压缩后提问').length;
    check('SR 压缩过的会话切回时本轮提问只显示一遍', compactRun?.historyStart === 3 && compactAsks === 1,
      { historyStart: compactRun?.historyStart, asks: compactAsks });
    dropRuns(); showEmpty(id);
    // (3b) 在这里点的压缩、还没按记录重画就接着问：Claude 和 Gemini 的记录里压缩也占一条，本轮起点要把实时那条提示算进去。
    // 四位各走一遍（不只是当前这位），状态用完放回
    for (const a of AGENT_IDS) {
      const sa = S[a], box = sa.msgEl, kept = { nodes: [...box.childNodes], cid: sa.conversationId, loaded: sa.loadedId, sig: sa.loadedSig,
        omitted: sa.shownOmitted, hasMore: sa.shownHasMore, unread: sa.unread, own: sa.ownTurnUnsynced, ownAt: sa.ownAt,
        elsewhereAt: sa.elsewhereAt, unreadConvs: new Set(sa.unreadConvs), runs: new Set(sa.runs.keys()), say: pets[a].say };
      pets[a].say = () => {};
      const liveHistory = [{ role: 'user', text: 'SR 压缩前提问' }, { role: 'bot', text: 'SR 压缩前回答' }];
      sa.conversationId = 'sr-live-compact'; sa.loadedId = null; sa.loadedSig = '';
      window.onConversationLoaded({ agent: a, conversationId: 'sr-live-compact', cwd: '', limit: 300, omitted: 0, messages: liveHistory });
      startRun(a, '/compact', []);
      const compactRun = runsOf(a, 'sr-live-compact')[0];
      const logged = ['claude', 'gemini', 'gpt'].includes(a) ? [{ role: 'compact', text: '已压缩上下文' }] : [];
      // 原生对 Claude、Gemini、Codex 报 compacted（按记录里有没有多出这一条；Codex 的 /compact 回合在记录里读成压缩提示）；DeepSeek 的记录里没有
      window.onAgentResponse({ agent: a, reqId: compactRun.reqId, reply: '前面的对话已经压缩成摘要', conversationId: 'sr-live-compact',
        ...(logged.length ? { compacted: true } : {}) });
      startRun(a, 'SR 实时压缩后提问', []);
      const liveRun = runsOf(a, 'sr-live-compact')[0];
      sa.loadedSig = '';
      window.onConversationLoaded({ agent: a, conversationId: 'sr-live-compact', cwd: '', limit: 300, omitted: 0,
        messages: [...liveHistory, ...logged, { role: 'user', text: 'SR 实时压缩后提问' }, { role: 'bot', text: 'SR 部分回答' }] });
      const asks = [...box.querySelectorAll('.msg.user')].filter(n => n.textContent === 'SR 实时压缩后提问').length;
      check(`SR 刚在这里压缩完接着问，切回时本轮提问只显示一遍（${a}）`, liveRun?.historyStart === 2 + logged.length && asks === 1,
        { historyStart: liveRun?.historyStart, asks });
      [...sa.runs.keys()].filter(k => !kept.runs.has(k)).forEach(k => sa.runs.delete(k)); pets[a].setBusy(isBusy(a));
      box.replaceChildren(...kept.nodes); sa.conversationId = kept.cid; sa.loadedId = kept.loaded; sa.loadedSig = kept.sig;
      sa.shownOmitted = kept.omitted; sa.shownHasMore = kept.hasMore; sa.unread = kept.unread; sa.ownTurnUnsynced = kept.own;
      sa.ownAt = kept.ownAt; sa.elsewhereAt = kept.elsewhereAt; sa.unreadConvs = kept.unreadConvs; pets[a].say = kept.say;
      updateIndicators(a); renderHistory(a);
    }
    // (4) 带图的新对话在拿到 ID 前失败、已经切走：文字和图片都放回输入框
    st.conversationId = ''; st.loadedId = ''; st.newView = `new:${++viewSeq}`; st.attach = []; renderAttachments(); setDraft(id, ''); showEmpty(id);
    const lostAt = requests.length; startRun(id, '看看', ['/tmp/sr-look.png']);
    const lostAsk = requests.slice(lostAt).find(r => r.action === 'askAgent');
    st.conversationId = 'sr-other'; st.loadedId = 'sr-other'; showEmpty(id);
    window.onAgentResponse({ agent: id, reqId: lostAsk.reqId, reply: '⚠️ 工作空间不存在：/sr-moved', conversationId: '', outcome: 'failed' });
    const key = 'workspace:' + (st.workspace || ''), returned = st.returnedDrafts.parked[key];
    check('SR 带图首问原样退回新对话', returned?.text === '看看' && returned.paths.join() === '/tmp/sr-look.png' && /没发出去/.test(said.at(-1) || ''), returned);
    delete st.returnedDrafts.parked[key]; saveReturnedDrafts(id);
    dropRuns(); takeAttachments(id);
    st.conversationId = keep.cid; st.loadedId = keep.loaded; st.newView = keep.newView; st.pendingTitle = keep.pendingTitle; st.loadedSig = keep.sig;
    st.lastPrompt = keep.lastPrompt; st.prompts = keep.prompts; lsSet(`${id}_prompts`, keep.lsPrompts); lsSet(`${id}_conv`, keep.lsConv);
    st.attach = keep.attach; saveAttachments(id); renderAttachments();
    setDraft(id, keep.draft); lsSet(`${id}_draft`, keep.lsDraft); els.input.value = keep.input;
    st.unread = keep.unread; st.ownTurnUnsynced = keep.own; st.ownAt = keep.ownAt; st.elsewhereAt = keep.elsewhereAt;
    st.shownOmitted = keep.omitted; st.shownHasMore = keep.hasMore; pets[id].say = keep.say; updateSendUI();
  }
  // 用实际发送和结束回调造本地节点；每次同步都与同一份记录重开核对。
  for (const agent of ALL_AGENT_IDS) {
    const st = S[agent], box = st.msgEl, cid = '分叉矩阵';
    const saved = Object.fromEntries(['conversationId','loadedId','loadedSig','shownOmitted','shownHasMore','ownAt','ownTurnUnsynced'].map(k=>[k,st[k]]));
    const nodes = [...box.childNodes];
    const ask = text => ({role:'user',text}), bot = (text,outcome='completed') => ({role:'bot',text,outcome});
    const read = (rows,mode, options = {}) => {
      const reqId = nextRequestId();
      (st.historyReads ??= new Map()).set(reqId,mode);
      window.onConversationLoaded({agent,conversationId:cid,reqId,messages:rows,readAt:Date.now(),...options});
    };
    const end = (question,answer,outcome,extra = {}) => {
      startRun(agent,question);
      const run = [...st.runs.values()].at(-1);
      window.onAgentResponse({agent,reqId:run.reqId,conversationId:cid,reply:answer,outcome,cancelled:outcome==='interrupted',...extra});
    };
    const visible = () => [...box.querySelectorAll('.msg.user:not(.queued), .turn, .msg.sys:not(.chat-empty)')]
      .map(n=>n.matches('.turn') ? [n._text,!!n.querySelector('.retry')] : n.textContent);
    const base = [ask('前问'),bot('前答')];
    try {
      for (const [name,original,next,confirmed,outcome] of [
        ['外部终端换末问','旧问','新问',false,'failed'],
        ['另一实例编辑末问','旧问','新问',false,'interrupted'],
        ['另一实例同文重问','继续','继续',true,'completed'],
        ['停止后同文再问','继续','继续',true,'interrupted'],
        ['崩溃后同文再问','继续','继续',true,'failed'],
        ['只回退已确认本地轮','继续',null,true,'interrupted'],
      ]) {
        st.conversationId = st.loadedId = cid; read(base,'open');
        end(original,'旧答',outcome);
        if (confirmed) read([...base,ask(original),bot('旧答',outcome)],'sync');
        const first = box.firstElementChild;
        const record = next===null ? base : [...base,ask(next),bot('新答')];
        read(record,'sync'); read(record,'sync');
        const synced = visible(), prefixHeld = first===box.firstElementChild;
        read(record,'open');
        check(agent+' '+name+' 同步与重开一致且前缀保留',prefixHeld && JSON.stringify(synced)===JSON.stringify(visible()),{synced,reopened:visible(),prefixHeld});
      }
      st.conversationId = cid; st.loadedId = ''; showEmpty(agent);
      end('继续','甲答','completed'); end('继续','乙答','interrupted');
      read([...base,ask('继续'),bot('甲答'),ask('继续'),bot('乙答','interrupted')],'open');
      const repeated = [...box.querySelectorAll('.turn')].map(n=>n._text);
      check(agent+' 打开期间同文重试两次，各接回一轮',repeated.join('|')==='前答|甲答|乙答',repeated);
      for (const stable of [true,false]) {
        read(base,'open'); end('继续','本地停止','interrupted');
        const question = key => ({...ask('继续'),turnKey:agent==='gemini' ? key : String(key)});
        read([...base,question(1),bot('迟到的半句')],'sync');
        end('本地末问','尾答','failed');
        read([...base,question(stable ? 1 : 2),bot('迟到的半句')],'sync');
        const actual = [...box.querySelectorAll('.turn')].map(n=>n._text);
        check(agent+' 同文同正文按提问身份'+(stable?'保留未确认的本地轮':'丢弃旧支及其停止提示'),
          actual.join('|')===(stable?'前答|本地停止|尾答':'前答|迟到的半句') &&
          (stable || !visible().includes('已停止')),actual);
      }
      for (const later of [false,true]) {
        read(base,'open');
        const clock = Date.now, now = clock();
        try { Date.now = () => now - 60000; end('继续','刚停止','interrupted'); }
        finally { Date.now = clock; }
        const question = {...ask('继续'),createdAt:(now - (later ? 1000 : 60000)) / 1000};
        read([...base,question,bot('落库正文')],'sync');
        const actual = [...box.querySelectorAll('.turn')].at(-1);
        check(agent+' 首次对账前同文提问创建于本轮'+(later?'结束后':'进行中'),
          actual._text===(later?'落库正文':'刚停止') && !!actual.querySelector('.retry')===!later,[actual._text,!!actual.querySelector('.retry')]);
      }
      for (const included of [true,false]) {
        st.loadedId = ''; showEmpty(agent);
        const clock = Date.now, now = clock();
        try { Date.now = () => now - 60000; end('继续','本地答','completed'); }
        finally { Date.now = clock; }
        const local = included ? [ask('继续'),bot('本地答')] : [];
        read([...base,...local,{...ask('继续'),createdAt:(now-1000)/1000},bot('外部答')],'open');
        const actual = [...box.querySelectorAll('.turn')].map(n=>n._text);
        check(agent+' 首次回包赶上外部同文后问，'+(included?'保留已写入的本地轮':'清除被替换的本地轮'),
          actual.join('|')===(included?'前答|本地答|外部答':'前答|外部答'),actual);
      }
      read(base,'open'); end('继续','原定稿','completed');
      read([...base,ask('继续'),bot('原定稿')],'sync');
      end('本地末问','尾答','interrupted');
      read([...base,ask('继续'),bot('外部重写')],'sync');
      check(agent+' 旧格式已确认的定稿换支，未落盘的旧尾一起撤下',
        box.querySelectorAll('.turn').length===2 && !box.querySelector('.retry') && !visible().includes('已停止'),visible());

      showEmpty(agent); st.loadedId = '';
      end('先问','先答','completed'); startRun(agent,'后问');
      const live = [...st.runs.values()].at(-1);
      read(base,'open');
      read([...base,ask('先问'),bot('先答'),ask('后问'),bot('正在写')],'open');
      const count = box.querySelectorAll('.msg.user').length;
      check(agent+' 首次读取漏了连续本地轮，切回接在第二轮的位置',count===3 && live.historyStart===4 && live.live.el.isConnected,{count,at:live.historyStart});
      st.runs.delete(live.reqId);

      read(base,'open',{omitted:2}); end('留着这轮','半句','interrupted');
      const stopped = box.querySelector('.retry').closest('.turn');
      const earlier = [ask('更早'),bot('早答'),...base];
      read(earlier,'sync');
      check(agent+' 分页起点变化仍保留同支未落盘的本地轮',stopped.isConnected && box.querySelectorAll('.turn').length===3,visible());
      read(base,'open');
      const extrasKey = agent+':'+cid, oldExtras = turnExtras.get(extrasKey), stored = lsGet('turn_extras');
      try {
        const files = [{path:'.gitignore',kind:'edit',added:3,removed:1},
          {path:'licensed_tools/README.md',kind:'create',added:2,removed:0},{path:'Makefile',kind:'create',added:4,removed:0}];
        end('核对行数','好了','completed',{files});
        const counts = () => [...box.querySelectorAll('.turn:last-child .files-card .diff-count')].map(el=>el.textContent);
        const expected = ['+9 −1','+3 −1','+2 −0','+4 −0'];
        const rows = [...base,ask('核对行数'),{...bot('好了'),files:files.map(({path,kind})=>({path,kind}))}];
        for (const stage of ['实时','切回','重开']) {
          if (stage === '重开') turnExtras.set(extrasKey,readTurnExtras().get(extrasKey));
          if (stage !== '实时') { showEmpty(agent); read(rows,'open'); }
          check(agent+' '+stage+'保留总数及三条文件行数',JSON.stringify(counts())===JSON.stringify(expected),counts());
        }
        read(base,'open');
        end('继续','完成','completed',{files:[{path:'本地.txt',kind:'edit'}]});
        const record = key => [...base,{...ask('继续'),turnKey:key},bot('完成')];
        read(record('本地'),'sync');
        const original = !!box.querySelector('.files-all');
        read(record('另一实例'),'sync');
        const synced = !!box.querySelector('.files-all');
        read(record('另一实例'),'open');
        check(agent+' 同文同答但回合编号改变，新分支不认领旧改动卡',original && !synced && !box.querySelector('.files-all'),[original,synced,!!box.querySelector('.files-all')]);

        // 切走后才收尾时没有本地回答节点可供绑定；从持久化副本打开和前台收尾应有同样的轮次身份。
        for (const outcome of ['completed','interrupted','failed']) {
          const file = {path:'命令.txt',kind:'create',diff:'+文件'};
          const run = {agent,text:'后台问',prompt:'后台问',images:[],reqId:nextRequestId(),historyStart:2,since:9000,endedAt:11000};
          rememberTurn(agent,run,{reqId:run.reqId,conversationId:cid,reply:'后台答',outcome,files:[file]},'');
          turnExtras.set(extrasKey,readTurnExtras().get(extrasKey));
          const rows = key => [...base,{...ask('后台问'),turnKey:key,createdAt:10},bot('后台答',outcome)];
          read(rows('原问'),'open');
          const atOpen = !!box.querySelector('.files-all');
          read(rows('改问'),'sync');
          const atSync = !!box.querySelector('.files-all');
          read(rows('改问'),'open');
          check(agent+' 后台'+outcome+'冷开绑定原问，再切回或重开新分支不带旧卡',
            atOpen && !atSync && !box.querySelector('.files-all'),[atOpen,atSync,!!box.querySelector('.files-all')]);
          turnExtras.delete(extrasKey);
        }
      } finally {
        if (oldExtras) turnExtras.set(extrasKey,oldExtras); else turnExtras.delete(extrasKey);
        lsSet('turn_extras',stored);
      }
      st.loadedId = ''; showEmpty(agent);
      startRun(agent,'恢复中的请求'); const restored = [...st.runs.values()].at(-1);
      showEmpty(agent); read([...base,ask('恢复中的请求'),bot('部分')],'open');
      check(agent+' 网页重载接回无起点的活动请求，只显示一份',restored.historyStart===2 &&
        box.querySelectorAll('.msg.user').length===2 && restored.live.el.isConnected,{at:restored.historyStart,count:box.querySelectorAll('.msg.user').length});
      st.runs.delete(restored.reqId);

      st.loadedId = ''; showEmpty(agent);
      end('先问','停在这','interrupted'); end('后问','后答','completed');
      read([...base,ask('先问'),ask('后问'),bot('后答')],'open');
      const partialRows = [...box.querySelectorAll('.turn')].map(n=>[n._text,!!n.querySelector('.retry')]);
      check(agent+' 首次回包漏掉中间的停止回答，仍按各自提问接回',JSON.stringify(partialRows)===
        JSON.stringify([['前答',false],['停在这',true],['后答',false]]),partialRows);
      if (agent==='gemini' || agent==='deepseek') {
        st.loadedId = ''; showEmpty(agent);
        end('原问','末段','completed',{steps:[{kind:'user',title:'你补充说',detail:'补一句'}]});
        end('再问','重试正文','failed');
        const split = [...base,ask('原问'),bot('开头'),ask('补一句'),bot('末段'),ask('再问'),bot('重试正文','failed')];
        read(split,'open');
        check(agent+' 首次读取也逐段对齐补充及后问',box.querySelectorAll('.msg.user').length===4 &&
          box.querySelectorAll('.turn').length===4 && box.querySelectorAll('.retry').length===1,visible());
      }
      for (const [outcome,follow] of [['completed',false],['completed',true],['failed',false],['failed',true]]) {
        st.loadedId = ''; showEmpty(agent);
        end('/compact','压缩结果',outcome,{compacted:outcome==='completed'});
        if (follow) end('压缩后问','压缩后答','completed');
        const command = outcome==='completed' ? [{role:'compact',text:'已压缩'}] :
          [ask('/compact'),bot('压缩结果','failed')];
        read([...base,...command,...(follow ? [ask('压缩后问'),bot('压缩后答')] : [])],'open');
        const actual = [box.querySelectorAll('.compact-note').length,box.querySelectorAll('.turn').length,
          box.querySelectorAll('.msg.user').length,box.querySelectorAll('.retry').length];
        const users = follow ? 2 : 1;
        const expected = outcome==='completed' ? [1,users,users,0] : [0,users+1,users,1];
        check(agent+' 首次回包中压缩'+outcome+(follow?'及后问':'')+'各显示一次',String(actual)===String(expected),actual);
      }
      const image = {path:'/fixture/图.png',missing:true};
      const illustrated = [ask('继续'),{...bot('图答')},ask('旧尾'),bot('尾答')];
      illustrated[0].images = [image]; read(illustrated,'open');
      end('本地未落盘','仍可重试','interrupted');
      const local = box.querySelectorAll('.turn')[2];
      read([{...illustrated[0],images:[{...image,name:'图.png'}]},...illustrated.slice(1)],'sync');
      check(agent+' 图片显示字段更新保留未落盘的停止轮',local.isConnected && !!local.querySelector('.retry'),visible());
    } finally { box.replaceChildren(...nodes); Object.assign(st,saved); }
  }
  // SY：外部回退重聊后的同步、后台载入的长会话首次显示、翻页途中换会话——正文和滚动位置都要和单独打开时一样。
  {
    const syKeys = ['conversationId','loadedId','loadedSig','keepFromBottom','pendingScroll','elsewhereAt','watchUntil','ownAt','shownLimit','shownOmitted','shownHasMore','histLimit','seenStamp','externalTurn','applyCwdOnLoad'];
    const syState = a => Object.fromEntries(syKeys.map(k => [k, S[a][k]]));
    const sySaved = syState(id), syOtherSaved = syState(other), syConvKey = lsGet(`${id}_conv`);
    const syLoad = (agent, mode, data, reqId = nextRequestId()) => {
      (S[agent].historyReads ??= new Map()).set(reqId, mode);
      window.onConversationLoaded({agent, cwd:'', limit:300, omitted:0, ...data, reqId});
    };
    const round = (q, a) => [{role:'user',text:q},{role:'bot',text:a,steps:[]}];
    const long = (tag, n) => Array.from({length:n}, (_, i) => round(`${tag}第${i}问`, `${tag}第${i}答，足够长的正文。\n\n`.repeat(4))).flat();
    const box = S[id].msgEl, shownText = () => box.textContent;
    // 换会话的 open 回包前先像 openConversation 那样换成「正在加载」：页面上还留着的节点会被当成读取期间发的提问接在历史后面（native-callbacks.js 的 fresh）
    showEmpty(id, '正在加载历史会话…');
    S[id].conversationId = 'sy-fork';
    syLoad(id, 'open', {conversationId:'sy-fork', messages:[...round('SY甲问','SY甲答'), ...round('SY旧乙问','SY旧乙答'), ...round('SY旧丙问','SY旧丙答')]});
    const firstAsk = box.querySelector('.msg.user');
    syLoad(id, 'sync', {conversationId:'sy-fork', messages:[...round('SY甲问','SY甲答'), ...round('SY新乙问','SY新乙答'), ...round('SY新丙问','SY新丙答')]});
    check('SY 外部回退重聊后按记录显示新分支，不拼接旧分支', shownText().includes('SY新乙答') && shownText().includes('SY新丙答') && !shownText().includes('SY旧乙') && !shownText().includes('SY旧丙'),
      [...box.querySelectorAll('.msg.user, .msg.bot.turn')].map(n => n.textContent.trim().slice(0, 12)));
    check('SY 分叉之前的消息不重画', box.querySelector('.msg.user') === firstAsk && firstAsk.isConnected);
    syLoad(id, 'sync', {conversationId:'sy-fork', messages:[...round('SY甲问','SY甲答'), ...round('SY改乙问','SY改乙答'), ...round('SY新丙问','SY新丙答')]});
    check('SY 只有前面的轮次变了也会同步', shownText().includes('SY改乙答') && !shownText().includes('SY新乙'),
      [...box.querySelectorAll('.msg.user, .msg.bot.turn')].map(n => n.textContent.trim().slice(0, 12)));
    // 没有分叉：这里答的那一轮和它的重试按钮、前面轮次的节点都留着
    const keptTurn = [...box.querySelectorAll('.msg.bot.turn')][1];
    appendMessage(id, 'user', 'SY这里问');
    const hereTurn = renderTurn({text:'SY这里答', steps:[], files:[]}, '');
    hereTurn._answeredHere = true; box.appendChild(hereTurn); addRetry(hereTurn, id, 'SY这里问', []);
    syLoad(id, 'sync', {conversationId:'sy-fork', messages:[...round('SY甲问','SY甲答'), ...round('SY改乙问','SY改乙答'), ...round('SY新丙问','SY新丙答'), ...round('SY这里问','SY记录里的答')]});
    check('SY 没分叉时这里答的轮次和重试按钮不重画', hereTurn.isConnected && !!hereTurn.querySelector('.retry') && keptTurn.isConnected && firstAsk.isConnected,
      {here:hereTurn.isConnected, retry:!!hereTurn.querySelector('.retry'), kept:keptTurn.isConnected});
    // 前一轮在记录写全之前就按记录画了，这里又答了一轮；之后读到写全的记录，前面的回答变了但没有分叉
    S[id].conversationId = 'sy-partial'; showEmpty(id, '正在加载历史会话…');
    syLoad(id, 'open', {conversationId:'sy-partial', messages:round('SY半问','SY半答')});
    const liveHere = () => {
      appendMessage(id, 'user', 'SY后问');
      const t = renderTurn({text:'SY后答(这里)', steps:[{tool:'Bash',input:'ls'}], files:[]}, '');
      t._answeredHere = true; box.appendChild(t); addRetry(t, id, 'SY后问', []);
      return t;
    };
    let laterTurn = liveHere();
    syLoad(id, 'sync', {conversationId:'sy-partial', messages:[...round('SY半问','SY半答，后来写全了'), ...round('SY后问','SY后答(记录)')]});
    check('SY 前面的回答写全了不算分叉，这里答的轮次和重试按钮留着', laterTurn.isConnected && !!laterTurn.querySelector('.retry') && !shownText().includes('SY后答(记录)'),
      [...box.querySelectorAll('.msg.user, .msg.bot.turn')].map(n => n.textContent.trim().slice(0, 12)));
    syLoad(id, 'open', {conversationId:'sy-partial', messages:round('SY半问','SY半答')});
    laterTurn = liveHere();
    syLoad(id, 'sync', {conversationId:'sy-partial', messages:round('SY半问','SY半答，后来写全了')});
    check('SY 前面的回答写全了不算分叉，记录里没有的这一问和停下的回答不删', laterTurn.isConnected && !!laterTurn.querySelector('.retry') && shownText().includes('SY后问'),
      [...box.querySelectorAll('.msg.user, .msg.bot.turn')].map(n => n.textContent.trim().slice(0, 12)));
    // 后台（隐藏的面板里）载入的长会话：第一次切过去要在底部；之后用户翻到哪儿，切走再切回来还在哪儿
    const ob = S[other].msgEl;
    S[other].conversationId = 'sy-background'; showEmpty(other, '正在加载历史会话…');
    syLoad(other, 'open', {conversationId:'sy-background', messages:long('SY后台', 65)});
    setActive(other, false);
    check('SY 后台载入的长会话首次切过去停在底部', ob.scrollHeight > ob.clientHeight + 200 && nearBottom(ob), {top:ob.scrollTop, height:ob.scrollHeight, client:ob.clientHeight});
    ob.scrollTop = 300; setActive(id, false); setActive(other, false);
    check('SY 用户翻过的页面切回来保持原位', Math.abs(ob.scrollTop - 300) < 5, ob.scrollTop);
    setActive(id, false);
    // 长会话 A 点「显示更早的」，回包前换到 B：B 按自己的回包停在底部；B 自己翻页时仍停在原来看的那条
    S[id].conversationId = 'sy-page-a'; showEmpty(id, '正在加载历史会话…');
    syLoad(id, 'open', {conversationId:'sy-page-a', messages:long('SY甲会话', 80), omitted:300});
    box.scrollTop = 0;
    let beforePage = requests.length;
    box.querySelector('.load-earlier')?.click();
    const pageA = requests.slice(beforePage).find(r => r.action === 'loadConversation');
    openConversation(id, {id:'sy-page-b', title:'SY乙会话', cwd:'', timestamp:1});
    S[id].applyCwdOnLoad = false;
    syLoad(id, 'open', {conversationId:'sy-page-a', messages:long('SY甲会话', 120)}, pageA?.reqId ?? nextRequestId());
    syLoad(id, 'open', {conversationId:'sy-page-b', messages:long('SY乙会话', 30), omitted:300});
    check('SY 翻页途中换会话，新会话按自己的回包停在底部', box.scrollHeight > box.clientHeight + 200 && nearBottom(box), {top:box.scrollTop, height:box.scrollHeight, client:box.clientHeight});
    box.scrollTop = 0;
    const keepB = box.scrollHeight - box.scrollTop;
    beforePage = requests.length;
    box.querySelector('.load-earlier')?.click();
    const pageB = requests.slice(beforePage).find(r => r.action === 'loadConversation');
    syLoad(id, 'open', {conversationId:'sy-page-b', messages:long('SY乙会话', 60), limit:600}, pageB?.reqId ?? nextRequestId());
    check('SY 自己的翻页回包仍停在原来看的那条', Math.abs(box.scrollHeight - box.scrollTop - keepB) < 5 && !nearBottom(box), {keep:keepB, now:box.scrollHeight - box.scrollTop});
    // 打开长会话的整页初绘：35d6eb0 起只在末尾结算一次布局，WebKit 比逐条结算多停约半秒。同页与逐条结算对照，不比绝对耗时。
    {
      const rows = Array.from({length:120}, (_, i) => ({role:i % 2 ? 'bot' : 'user',
        text:(i % 2 ? '这个函数在收到输入以后，先读取当前配置，再按顺序处理每条记录。'.repeat(45) : '请说明这个函数的行为。') + i}));
      const draw = async each => {
        const cid = 'sy-long-' + nextRequestId(), original = renderOneMessage;
        openConversation(id, {id:cid, title:cid, cwd:'', timestamp:1});
        S[id].applyCwdOnLoad = false;
        // 等一帧让 openConversation 的布局落定；窗口被系统判为不可见时 rAF 不触发，最多等 100ms，不能让整套挂到总上限
        await Promise.race([new Promise(r => requestAnimationFrame(r)), sleep(100)]);
        if (each) renderOneMessage = (...args) => { const node = original(...args); void box.offsetHeight; return node; };
        try { const at = performance.now(); syLoad(id, 'open', {conversationId:cid, messages:rows}); return Math.round(performance.now() - at); }
        finally { renderOneMessage = original; }
      };
      // 量三对、先后交替（第 1、3 对先量整页，第 2 对先量逐条），抵消先量的那个吃亏；各取最小值再比。
      // 正常比值约 0.95–1.13，0765512 修之前约 1.9，门槛 1.5 两边都有余量
      const plain = [], each = [];
      for (let k = 0; k < 3; k++) {
        if (k % 2 === 0) { plain.push(await draw(false)); each.push(await draw(true)); }
        else { each.push(await draw(true)); plain.push(await draw(false)); }
      }
      check('SY 长会话整页初绘画完全部消息', box.querySelectorAll(':scope > .msg').length === rows.length, box.querySelectorAll(':scope > .msg').length);
      check('性能断言：SY 长会话整页初绘不比逐条结算布局慢', Math.min(...plain) < Math.min(...each) * 1.5, {plain, each});
    }
    showEmpty(id); showEmpty(other);
    Object.assign(S[id], sySaved); Object.assign(S[other], syOtherSaved);
    lsSet(`${id}_conv`, syConvKey ?? ''); markElsewhere(id); renderHistory(id);
  }
  // SS：搜索结果、未读标记、改动卡片在重开 / 删除 / 后台答完之后仍指向对的会话和轮次
  {
    const st = S[id], ssSay = pets[id].say; pets[id].say = () => {};
    const ssSaved = { bodyQuery: st.bodyQuery, bodyHits: st.bodyHits, bodyItems: st.bodyItems, bodyComplete: st.bodyComplete, bodyUnavailable: st.bodyUnavailable,
      bodyDropped: st.bodyDropped, unread: st.unread, unreadConvs: st.unreadConvs, conversations: st.conversations, ownTurnUnsynced: st.ownTurnUnsynced, ownAt: st.ownAt,
      conv: lsGet(`${id}_conv`, '') };
    st.unreadConvs = new Set(); st.unread = false;
    // (1) 连续两次「继续」，只有第一轮改了文件：重开后改动卡片按轮次位置接回第一轮，不挂到同句的第二轮
    const contId = 'ss-continue-fixture';
    st.conversationId = contId; st.loadedId = contId;
    rememberTurn(id, { text: '继续', historyStart: 2 }, { conversationId: contId, files: [{ path: '/tmp/ss-fixture/prior.txt', kind: 'edit', added: 1, removed: 0, diff: '' }] }, '/tmp/ss-fixture');
    rememberTurn(id, { text: '继续', historyStart: 4 }, { conversationId: contId, files: [] }, '/tmp/ss-fixture');
    window.onConversationLoaded({ agent: id, conversationId: contId, cwd: '/tmp/ss-fixture', limit: 300, omitted: 0, messages: [
      { role: 'user', text: '开始' }, { role: 'bot', text: '好的', steps: [] },
      { role: 'user', text: '继续' }, { role: 'bot', text: '改好了', steps: [] },
      { role: 'user', text: '继续' }, { role: 'bot', text: '检查完毕，无改动', steps: [] }] });
    const contCards = [...st.msgEl.querySelectorAll('.msg.bot.turn')].map(t => !!t.querySelector('.files-all'));
    check('SS 两轮同句继续：改动卡片接回改了文件的第一轮', contCards.join() === 'false,true,false', contCards);
    turnExtras.delete(`${id}:${contId}`);
    // (1) 压缩过的会话：真的在页面上发两轮「继续」（位置由页面计数得来），再按 CLI 记录重开。
    // 记录里每次手动压缩是一条 role:'compact'（Claude、Gemini 记；Codex、DeepSeek 不记），页面计数要和它对得上
    const recordsCompact = id === 'claude' || id === 'gemini';
    const compactCase = (filesAt, historyCompacts, liveCompact) => {
      const cid = `ss-compact-${filesAt}-${historyCompacts}`, cwd = '/tmp/ss-fixture';
      const record = [{ role: 'user', text: '开始' }, { role: 'bot', text: '好的', steps: [] }];
      for (let k = 0; k < historyCompacts; k++) record.push({ role: 'compact', text: '已压缩上下文' }, { role: 'user', text: `再来 ${k}` }, { role: 'bot', text: '好', steps: [] });
      // 打开和重开都像 openConversation 那样先换成「正在加载」：页面上还留着的节点会被当成读取期间发的提问接在历史后面，计数就多了
      st.conversationId = cid; st.loadedId = ''; showEmpty(id, '正在加载历史会话…');
      window.onConversationLoaded({ agent: id, conversationId: cid, cwd, limit: 300, omitted: 0, messages: record });
      const ask = (text, files) => {
        startRun(id, text);
        const run = [...st.runs.values()].at(-1);
        window.onAgentResponse({ agent: id, reqId: run.reqId, conversationId: cid, reply: files.length ? '改好了' : '检查完毕，无改动', steps: [], files, cwd,
          ...(isCompactCommand(text) && recordsCompact ? { compacted: true } : {}) });
        return run.historyStart;
      };
      if (liveCompact) { ask('/compact', []); if (recordsCompact) record.push({ role: 'compact', text: '已压缩上下文' }); }
      const prior = { path: '/tmp/ss-fixture/prior.txt', kind: 'edit', added: 1, removed: 0, diff: '' };
      const atA = ask('继续', filesAt === 0 ? [prior] : []), idxA = record.length;
      record.push({ role: 'user', text: '继续' }, { role: 'bot', text: filesAt === 0 ? '改好了' : '检查完毕，无改动', steps: [] });
      const atB = ask('继续', filesAt === 1 ? [prior] : []), idxB = record.length;
      record.push({ role: 'user', text: '继续' }, { role: 'bot', text: filesAt === 1 ? '改好了' : '检查完毕，无改动', steps: [] });
      st.loadedId = ''; showEmpty(id, '正在加载历史会话…');
      window.onConversationLoaded({ agent: id, conversationId: cid, cwd, limit: 300, omitted: 0, messages: record });
      const cards = [...st.msgEl.querySelectorAll('.msg.bot.turn')].map(t => !!t.querySelector('.files-all')).slice(-2);
      turnExtras.delete(`${id}:${cid}`);
      return { at: [atA, atB], idx: [idxA, idxB], cards: cards.join() };
    };
    const cmpTwice = compactCase(1, 2, true), cmpOnce = compactCase(0, 1, false);
    check('SS 压缩过的会话：页面记下的轮次位置和 CLI 记录的下标一致，改动卡片接回改了文件的那一轮',
      cmpTwice.at.join() === cmpTwice.idx.join() && cmpTwice.cards === 'false,true' && cmpOnce.at.join() === cmpOnce.idx.join() && cmpOnce.cards === 'true,false',
      { cmpTwice, cmpOnce });
    // (2) 在正文搜索结果里归档：单条和批量删除成功后结果行消失，在途的同词旧结果也不补回
    histQuery = 'ss-archive-needle'; st.conversations = [];
    const gone = { id: 'ss-archived', title: '要归档的', cwd: '/ss-fixture', timestamp: 1, searchLimit: 300 };
    const gone2 = { ...gone, id: 'ss-archived-2', title: '批量归档的' }, kept = { ...gone, id: 'ss-kept', title: '留着的', timestamp: 2 };
    const ssRow = cid => histSections[id].list.querySelector(`[data-k="c:${cid}"]`);
    const ssSearch = complete => window.onConversationsSearched({ agent: id, query: histQuery, ids: [gone.id, gone2.id, kept.id], items: [gone, gone2, kept], complete });
    ssSearch(false);
    const rowsBefore = [!!ssRow(gone.id), !!ssRow(gone2.id), !!ssRow(kept.id)];
    window.onConversationDeleted({ agent: id, ok: true, conversationId: gone.id });
    const singleAfter = !!ssRow(gone.id);
    window.onConversationsDeleted({ agent: id, deleted: [gone2.id], failed: [] });
    const batchAfter = !!ssRow(gone2.id);
    ssSearch(true);
    const lateRows = [!!ssRow(gone.id), !!ssRow(gone2.id), !!ssRow(kept.id)];
    check('SS 搜索中归档的会话从结果里消失，在途旧结果不补回', rowsBefore.join() === 'true,true,true' && !singleAfter && !batchAfter && lateRows.join() === 'false,false,true',
      { rowsBefore, singleAfter, batchAfter, lateRows });
    histQuery = ''; st.bodyQuery = ''; st.bodyHits = new Set(); st.bodyItems = []; st.bodyDropped = null;
    // (3) 搜索命中长回答末尾：点进去后关键词所在段落在消息区可见范围内
    const longId = 'ss-long-fixture';
    histQuery = 'ssdeepneedle'; st.conversationId = longId; st.loadedId = ''; st.bodyQuery = histQuery; st.bodyHits = new Set([longId]); st.bodyItems = [{ id: longId }];
    const paras = Array.from({ length: 80 }, (_, i) => `第 ${i + 1} 段填充文字，把这条回答撑得足够长。`).concat('最后一段才有 ssdeepneedle 这个关键词。');
    window.onConversationLoaded({ agent: id, conversationId: longId, cwd: '', limit: 300, omitted: 0, messages: [{ role: 'user', text: '写长一点' }, { role: 'bot', text: paras.join('\n\n'), steps: [] }] });
    // 定位在载入之后异步做：等到关键词段落进了可视范围（或到上限）再量，不在固定的 50ms 后看一眼
    const ssNeedleShown = () => { const b = st.msgEl.getBoundingClientRect(), r = [...st.msgEl.querySelectorAll('.answer p')].find(p => p.textContent.includes('ssdeepneedle'))?.getBoundingClientRect();
      return !!r && r.top >= b.top && r.bottom <= b.bottom; };
    await until(ssNeedleShown, 'SS 长回答搜索定位').catch(() => null);
    const longBox = st.msgEl.getBoundingClientRect();
    const needleRect = [...st.msgEl.querySelectorAll('.answer p')].find(p => p.textContent.includes('ssdeepneedle'))?.getBoundingClientRect();
    check('SS 长回答的搜索定位滚到关键词所在段落', !!st.msgEl.querySelector('.msg.bot.search-hit') && longBox.height > 100 && !!needleRect
      && needleRect.top >= longBox.top && needleRect.bottom <= longBox.bottom, { box: [longBox.top, longBox.bottom], needle: needleRect && [needleRect.top, needleRect.bottom] });
    histQuery = ''; st.bodyQuery = ''; st.bodyHits = new Set(); st.bodyItems = [];
    // (4) 后台答完的会话读到以后：会话行、AI 级未读和桌宠一起清掉
    const convA = { id: 'ss-unread-a', title: '后台答完的', cwd: '', timestamp: 3 }, convB = { id: 'ss-unread-b', title: '另一个会话', cwd: '', timestamp: 2 };
    st.conversations = [convA, convB];
    const unreadRow = cid => !!histSections[id].list.querySelector(`[data-k="c:${cid}"]`)?.classList.contains('unread');
    const bgRun = (reqId, view, el) => { const run = { agent: id, reqId, view, text: '后台问', prompt: '后台问', images: [], nodes: [], queue: [], live: { el, steps: [] } }; st.runs.set(reqId, run); return run; };
    // a：切到别的 AI，原会话在后台答完，再直接点回这个已载入的会话
    st.conversationId = convA.id; st.loadedId = convA.id; showEmpty(id);
    const liveA = document.createElement('div'); st.msgEl.appendChild(liveA);
    bgRun('ss-bg-a', convA.id, liveA);
    setActive(other, false);
    window.onAgentResponse({ agent: id, reqId: 'ss-bg-a', conversationId: convA.id, reply: '答完了', steps: [], files: [] });
    const markedA = st.unreadConvs.has(convA.id) && st.unread;
    openConversation(id, convA);
    check('SS 切走 AI 后台答完、点回已载入的会话：会话行未读点清掉', markedA && !unreadRow(convA.id) && !st.unreadConvs.has(convA.id) && !st.unread,
      { markedA, row: unreadRow(convA.id), convs: [...st.unreadConvs], unread: st.unread });
    // b：同一 AI 看着 B 时 A 在后台答完，点开 A 读完
    st.conversationId = convB.id; st.loadedId = convB.id; showEmpty(id);
    bgRun('ss-bg-b', convA.id, document.createElement('div'));
    window.onAgentResponse({ agent: id, reqId: 'ss-bg-b', conversationId: convA.id, reply: '又答完了', steps: [], files: [] });
    const markedB = st.unreadConvs.has(convA.id) && st.unread;
    openConversation(id, convA);
    const petText = pets[id].statusEl.textContent;
    check('SS 同一 AI 两个会话间切换：读完后会话行和桌宠都不再显示有新回复', markedB && !unreadRow(convA.id) && !st.unread && !petText.includes('有新回复'),
      { markedB, row: unreadRow(convA.id), unread: st.unread, petText });
    // c：同一 AI 从 B 点回正在回答的 A，正文还没读回来这一轮就答完了：读回来摆出回复时就算读过
    st.conversationId = convB.id; st.loadedId = convB.id; showEmpty(id);
    openConversation(id, convA);
    bgRun('ss-bg-c', convA.id, document.createElement('div'));
    window.onAgentResponse({ agent: id, reqId: 'ss-bg-c', conversationId: convA.id, reply: '第三次答完', steps: [], files: [] });
    const markedC = st.unreadConvs.has(convA.id) && st.unread;
    window.onConversationLoaded({ agent: id, conversationId: convA.id, cwd: '', limit: 300, omitted: 0,
      messages: [{ role: 'user', text: '后台问' }, { role: 'bot', text: '第三次答完', steps: [] }] });
    const shownC = st.msgEl.textContent.includes('第三次答完'), petC = pets[id].statusEl.textContent;
    check('SS 同一 AI 点回正在答的会话、读回来时已答完：会话行和桌宠都清掉', markedC && shownC && !unreadRow(convA.id) && !st.unreadConvs.has(convA.id) && !st.unread && !petC.includes('有新回复'),
      { markedC, shownC, row: unreadRow(convA.id), convs: [...st.unreadConvs], unread: st.unread, petC });
    // d：已载入并显示着的会话还挂着未读时，再点它的行也清掉
    st.unreadConvs.add(convA.id); st.unread = true; updateIndicators(id);
    renderHistory(id); const rowD = unreadRow(convA.id);
    openConversation(id, convA);
    check('SS 点已载入的当前会话行：未读一起清掉', rowD && !unreadRow(convA.id) && !st.unreadConvs.has(convA.id) && !st.unread, { rowD, row: unreadRow(convA.id), convs: [...st.unreadConvs], unread: st.unread });
    // e：没读的会话被批量删除（删整个项目）、在别处删掉后列表里没了、或读回来是 missing：AI 级未读不因它一直挂着
    const convX = { id: 'ss-unread-x', title: '项目里没读的', cwd: '/ss-fixture-proj', timestamp: 4 }, convY = { ...convX, id: 'ss-unread-y', title: '别处删掉的' };
    const convZ = { ...convX, id: 'ss-unread-z', title: '读回来没了的' };
    st.conversations = [convX, convY, convZ, convA, convB];
    st.conversationId = convB.id; st.loadedId = convB.id;
    ['x', 'y', 'z'].forEach(k => st.unreadConvs.add(`ss-unread-${k}`)); st.unread = true;
    window.onConversationsDeleted({ agent: id, deleted: [convX.id], failed: [] });
    window.onConversationsListed({ agent: id, items: [convZ, convA, convB] });
    const checkY = requests.findLast(r => r.unreadProbe && r.conversationId === convY.id);
    if (checkY) window.onConversationLoaded({agent:id,conversationId:convY.id,reqId:checkY.reqId,missing:true});
    showEmpty(id, '正在加载历史会话…'); st.conversationId = convZ.id; st.loadedId = convZ.id;
    window.onConversationLoaded({ agent: id, conversationId: convZ.id, missing: true });
    setActive(other, false); setActive(id, false);
    const petE = pets[id].statusEl.textContent;
    check('SS 没读的会话删掉或没了以后，点回这位 AI 时左栏标题和桌宠的未读清掉', !st.unread && !petE.includes('有新回复') && !st.unreadConvs.has(convX.id) && !st.unreadConvs.has(convY.id) && !st.unreadConvs.has(convZ.id),
      { unread: st.unread, convs: [...st.unreadConvs], petE });
    st.runs.delete('ss-bg-a'); st.runs.delete('ss-bg-b'); st.runs.delete('ss-bg-c');
    Object.assign(st, { bodyQuery: ssSaved.bodyQuery, bodyHits: ssSaved.bodyHits, bodyItems: ssSaved.bodyItems, bodyComplete: ssSaved.bodyComplete, bodyUnavailable: ssSaved.bodyUnavailable,
      bodyDropped: ssSaved.bodyDropped, unread: ssSaved.unread, unreadConvs: ssSaved.unreadConvs, conversations: ssSaved.conversations, ownTurnUnsynced: ssSaved.ownTurnUnsynced, ownAt: ssSaved.ownAt });
    st.conversationId = ''; st.loadedId = ''; st.applyCwdOnLoad = false; lsSet(`${id}_conv`, ssSaved.conv);
    pets[id].say = ssSay; histQuery = ''; updateIndicators(id);
  }
