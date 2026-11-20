  // SV2：打开最后一问是「继续」的历史，读取期间又发了「继续」：记录里旧的那句不能认成本页发的；/compact 没压成时提示不算历史条目
  {
    const st = S[id], sv2Say = pets[id].say; pets[id].say = () => {};
    const keep = { cid: st.conversationId, loaded: st.loadedId, sig: st.loadedSig, conv: lsGet(`${id}_conv`, ''), unread: st.unread,
      unreadConvs: new Set(st.unreadConvs), own: st.ownTurnUnsynced, ownAt: st.ownAt, elsewhereAt: st.elsewhereAt, omitted: st.shownOmitted, hasMore: st.shownHasMore };
    const mine = new Set(st.runs.keys());
    const dropRuns = () => { [...st.runs.keys()].filter(k => !mine.has(k)).forEach(k => st.runs.delete(k)); pets[id].setBusy(isBusy(id)); };
    // 像 openConversation 那样先换成「正在加载」，再记一次打开历史的读取
    const open = cid => { st.conversationId = cid; st.loadedId = null; st.loadedSig = ''; showEmpty(id, '正在加载历史会话…');
      const req = nextRequestId(); (st.historyReads ??= new Map()).set(req, 'open'); return req; };
    const load = (req, cid, readAt, messages, cwd = '') => window.onConversationLoaded({ agent: id, reqId: req, conversationId: cid, cwd, limit: 300, omitted: 0, readAt, messages });
    const users = () => [...st.msgEl.querySelectorAll('.msg.user')].map(n => n.textContent);
    const turns = () => [...st.msgEl.querySelectorAll('.msg.bot.turn')];
    const history = [{ role: 'user', text: '开始' }, { role: 'bot', text: 'SV2 旧答一' }, { role: 'user', text: '继续' }, { role: 'bot', text: 'SV2 旧答二' }];
    // (a) 读取在发问之前就开始了，回来时这一轮还在答、记录里还没有它
    const goingReq = open('sv2-going'), goingRead = Date.now() - 1000;
    startRun(id, '继续', []);
    const going = runsOf(id, 'sv2-going')[0];
    load(goingReq, 'sv2-going', goingRead, history);
    check('SV2 读取期间又发「继续」、还在答：旧的那一问一答留着，本轮接在后面', users().join('|') === '开始|继续|继续'
      && turns().some(t => t.textContent.includes('SV2 旧答二')) && going?.historyStart === 4 && st.msgEl.lastElementChild === going?.live?.el,
      { users: users(), historyStart: going?.historyStart, liveLast: st.msgEl.lastElementChild === going?.live?.el });
    // 切走再切回：记录里已写进这一轮，截在它的提问前接上进行中的回答，「继续」不多出一句
    const backReq = open('sv2-going');
    load(backReq, 'sv2-going', Date.now(), [...history, { role: 'user', text: '继续' }, { role: 'bot', text: 'SV2 写了一半' }]);
    check('SV2 还在答时切走再切回：提问只显示一遍并接上实时回答', users().join('|') === '开始|继续|继续' && st.msgEl.lastElementChild === going?.live?.el,
      { users: users(), historyStart: going?.historyStart });
    dropRuns(); st.historyReads.clear();
    // (b) 读回之前这一轮已经答完（出错、改了文件）：本页答出的回答、重试按钮和改动卡片都留着，旧的那一轮不挂改动卡片
    const cwd = '/tmp/sv2-fixture', file = { path: '/tmp/sv2-fixture/a.txt', kind: 'edit', added: 1, removed: 0, diff: '' };
    const doneReq = open('sv2-done'), doneRead = Date.now() - 1000;
    startRun(id, '继续', []);
    const done = runsOf(id, 'sv2-done')[0];
    window.onAgentResponse({ agent: id, reqId: done.reqId, conversationId: 'sv2-done', reply: '⚠️ SV2 新答出错', outcome: 'failed', steps: [], files: [file], cwd });
    load(doneReq, 'sv2-done', doneRead, history, cwd);
    const doneCards = turns().map(t => !!t.querySelector('.files-all'));
    check('SV2 读取期间发的「继续」读回前已答完：回答、重试和改动卡片留在本轮，旧的那一轮不挂卡片', users().join('|') === '开始|继续|继续'
      && !!turns().at(-1)?.textContent.includes('SV2 新答出错') && !!turns().at(-1)?.querySelector('.answer-copy.retry') && doneCards.join() === 'false,false,true',
      { users: users(), cards: doneCards, last: turns().at(-1)?.textContent.slice(0, 60) });
    // 重开：记录里两句「继续」，改动卡片挂在本页答的那一轮
    const reopenReq = open('sv2-done');
    load(reopenReq, 'sv2-done', Date.now(), [...history, { role: 'user', text: '继续' }, { role: 'bot', text: 'SV2 新答出错', outcome: 'failed' }], cwd);
    const reopenCards = turns().map(t => !!t.querySelector('.files-all'));
    check('SV2 重开后改动卡片挂在本页答的那一轮', reopenCards.join() === 'false,false,true', reopenCards);
    turnExtras.delete(`${id}:sv2-done`); dropRuns(); st.historyReads.clear();
    // (c) 对照：读取在发问之后才开始、记录里已写进这一轮：按记录只显示一遍
    const lateReq = open('sv2-late');
    startRun(id, '继续', []);
    const late = runsOf(id, 'sv2-late')[0];
    load(lateReq, 'sv2-late', late.since + 50, [...history, { role: 'user', text: '继续' }, { role: 'bot', text: 'SV2 写了一半' }]);
    check('SV2 读取晚于发问、记录已含这一轮：提问只显示一遍', users().join('|') === '开始|继续|继续' && late.historyStart === 4 && st.msgEl.lastElementChild === late.live?.el,
      { users: users(), historyStart: late.historyStart });
    dropRuns(); st.historyReads.clear();
    // (d) /compact 没压成（如 Claude 的「Not enough messages」）：记录里没有压缩条目，提示也不算；压成了才算一条
    for (const compacted of [false, true]) {
      const cid = `sv2-compact-${compacted}`, base = [{ role: 'user', text: 'SV2 压缩前' }, { role: 'bot', text: 'SV2 压缩前答' }];
      load(open(cid), cid, Date.now(), base);
      startRun(id, '/compact', []);
      const cmd = runsOf(id, cid)[0];
      window.onAgentResponse({ agent: id, reqId: cmd.reqId, conversationId: cid, outcome: 'completed', compacted,
        reply: compacted ? '前面的对话已经压缩成摘要，腾出了上下文空间。' : '没有压缩：对话还太短，没有可以压缩的内容。' });
      startRun(id, 'SV2 压缩后提问', []);
      const next = runsOf(id, cid)[0];
      st.loadedSig = '';
      window.onConversationLoaded({ agent: id, conversationId: cid, cwd: '', limit: 300, omitted: 0, messages: [...base,
        ...(compacted ? [{ role: 'compact', text: '已压缩上下文' }] : []), { role: 'user', text: 'SV2 压缩后提问' }, { role: 'bot', text: 'SV2 部分回答' }] });
      const asks = users().filter(t => t === 'SV2 压缩后提问').length;
      check(`SV2 /compact ${compacted ? '压成了' : '没压成'}：切回时本轮提问只显示一遍`, next?.historyStart === 2 + (compacted ? 1 : 0) && asks === 1,
        { historyStart: next?.historyStart, asks });
      dropRuns();
    }
    Object.assign(st, { conversationId: keep.cid, loadedId: keep.loaded, loadedSig: keep.sig, unread: keep.unread, unreadConvs: keep.unreadConvs,
      ownTurnUnsynced: keep.own, ownAt: keep.ownAt, elsewhereAt: keep.elsewhereAt, shownOmitted: keep.omitted, shownHasMore: keep.hasMore });
    lsSet(`${id}_conv`, keep.conv); pets[id].say = sv2Say; updateIndicators(id); renderHistory(id);
  }
  {
    const st = S[id], workspace = st.workspace, conv = lsGet(id + '_conv', '');
    const savedState = {conversationId:st.conversationId, loadedId:st.loadedId, loadedSig:st.loadedSig,
      pendingTitle:st.pendingTitle, applyCwdOnLoad:st.applyCwdOnLoad};
    showEmpty(id, '正在加载历史会话…');
    setWorkspace(id, '/fixture/project-A', false);
    openConversation(id, {id:'no-cwd-history', cwd:'', title:'未绑定', timestamp:1});
    const before = requests.length;
    startRun(id, '继续', []);
    const ask = requests.slice(before).find(r => r.action === 'askAgent');
    check('B1 空目录历史加载中续问清掉上一项目', ask?.workspace === '' && ask.conversationId === 'no-cwd-history', ask?.workspace);
    window.onAgentResponse({agent:id, reqId:ask.reqId, conversationId:ask.conversationId, reply:'好'});
    setWorkspace(id, workspace, false); Object.assign(st, savedState); lsSet(id + '_conv', conv);
  }
  {
    const draft = els.input.value, welcomed = lsGet('welcomed'), enabled = lsGet('enabled_agents');
    lsSet('enabled_agents', JSON.stringify(AGENT_IDS));
    els.input.focus(); openWelcome();
    renderWelcome(); // 检测回包也会重画按钮。
    els.input.focus();
    const focus = document.activeElement, before = requests.length;
    type('引导中误按回车');
    els.input.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', bubbles:true, cancelable:true}));
    const ask = requests.slice(before).find(r => r.action === 'askAgent');
    check('B2 引导期间焦点留在页内且回车不发送', welcome.contains(focus) && !ask && els.input.value === '引导中误按回车',
      {focus:focus.id || focus.className, sent:!!ask});
    if (ask) window.onAgentResponse({agent:id, reqId:ask.reqId, reply:'好'});
    welcome.querySelector('.wl-go').click();
    check('B2 关闭引导后恢复输入焦点', document.activeElement === els.input, document.activeElement.id);
    setDraft(id, draft); lsSet('welcomed', welcomed); lsSet('enabled_agents', enabled);
  }
  {
    const ids = AGENT_IDS.slice(), probed = {...agentProbe}, enabled = lsGet('enabled_agents'), welcomed = lsGet('welcomed');
    const weights = sectionWeights.slice(), storedWeights = lsGet('section_weights');
    for (const late of [false, true]) {
      AGENT_IDS.splice(0, AGENT_IDS.length, 'gemini', 'claude', 'gpt'); afterAgentsChanged(); setActive('gemini', false);
      delete histSections.deepseek;
      ALL_AGENT_IDS.forEach(a => delete agentProbe[a]); lsSet('enabled_agents', '');
      openWelcome();
      const found = late ? ['gpt', 'deepseek'] : ['deepseek'];
      const items = ALL_AGENT_IDS.map(agent => ({agent, found:found.includes(agent)}));
      let error = '';
      try {
        if (late) closeWelcome();
        window.onAgentsProbed({items});
        if (!late) closeWelcome();
      } catch (e) { error = String(e); }
      const sections = [...els.sections.querySelectorAll('.hist-section')].map(n => n.dataset.agent);
      check('B3 首次检测' + (late ? '晚到' : '先到') + '时左栏、当前 AI 和名单一致',
        !error && welcome.hidden && active === found[0] && sections.join() === found.join() && lsGet('enabled_agents') === JSON.stringify(found),
        {error, sections, active});
    }
    AGENT_IDS.splice(0, AGENT_IDS.length, ...ids); afterAgentsChanged(); setActive(id, false);
    if (!welcome.hidden) closeWelcome();
    ALL_AGENT_IDS.forEach(a => delete agentProbe[a]); Object.assign(agentProbe, probed);
    sectionWeights = weights; applySectionWeights(); lsSet('section_weights', storedWeights);
    lsSet('enabled_agents', enabled); lsSet('welcomed', welcomed);
  }
  {
    const st = S[id], saved = [st.shownOmitted, st.shownHasMore], start = startRun, sent = [];
    startRun = (_, text, paths) => sent.push([text, ...paths]);
    const branch = label => [1,2].flatMap(i => [{role:'user', text:label+i, images:[{path:'/'+label+i+'.png'}]},
      {role:'bot', text:label+i+'答', outcome:'failed'}]);
    showEmpty(id, '正在加载历史会话…');
    renderMessages(id, branch('旧'));
    syncAppend(id, branch('新'), '', 0);
    st.msgEl.querySelector('.retry').click();
    const last = st.msgEl.querySelectorAll('.turn')[1]; last._answeredHere = true;
    syncAppend(id, [...branch('新').slice(0,2), ...branch('末').slice(2)], '', 0);
    st.msgEl.querySelectorAll('.retry')[1].click();
    check('B2-01 分叉后每处重试带本轮文字和附件', JSON.stringify(sent) === JSON.stringify([['新1','/新1.png'],['末2','/末2.png']]), sent);
    startRun = start; [st.shownOmitted, st.shownHasMore] = saved;
  }
  {
    const st = S[id], saved = [st.shownOmitted, st.shownHasMore], start = startRun;
    const ref = {agent:'gpt', conversationId:'history', id:'/tmp/a.png#0@turn', path:'/tmp/a.png'};
    let sent;
    startRun = (_, text, paths, refs) => { sent = {paths, refs}; };
    showEmpty(id, '正在加载历史会话…');
    renderMessages(id, [{role:'user', text:'图', images:[{path:ref.path, ref}]}, {role:'bot', text:'停', outcome:'failed'}]);
    st.msgEl.querySelector('.retry').click();
    check('B2-02 重试把可复核的引用交给原生', sent?.refs[0]?.id === ref.id && !sent.paths.length, sent);
    startRun = start; [st.shownOmitted, st.shownHasMore] = saved;
  }
  {
    const st = S[id], saved = [st.shownOmitted, st.shownHasMore], start = startRun;
    let indices;
    startRun = (_, text, paths, refs) => { indices = refs.map(r => r.index); };
    showEmpty(id, '正在加载历史会话…');
    renderMessages(id, [{role:'user', text:'顺序', images:[{ref:{id:'a'}},{path:'/tmp/b.png'},{ref:{id:'c'}}]},
      {role:'bot', text:'停', outcome:'failed'}]);
    st.msgEl.querySelector('.retry').click();
    check('B2-03 混合来源的重试保留原图序号', JSON.stringify(indices) === '[0,2]', indices);
    startRun = start; [st.shownOmitted, st.shownHasMore] = saved;
  }
  {
    const st = S[id], saved = Object.fromEntries(['conversationId','loadedId','loadedSig','shownOmitted','shownHasMore','ownTurnUnsynced','ownAt','elsewhereAt','watchUntil','externalTurn','unread','pendingScroll'].map(k => [k, st[k]]));
    const cid = 'b2-late', conv = lsGet(id+'_conv');
    for (const tail of [[], [{role:'bot', text:'半', outcome:'inProgress'}]]) {
      showEmpty(id, '正在加载历史会话…'); st.conversationId = cid; st.loadedId = null;
      const messages = [];
      for (const text of ['甲','乙','丙']) {
        startRun(id, text);
        const run = runsOf(id,cid)[0];
        window.onAgentResponse({agent:id, reqId:run.reqId, conversationId:cid, reply:text+'答', outcome:text === '甲' ? 'completed' : 'failed'});
        if (text !== '丙') messages.push({role:'user',text});
        if (text === '甲') messages.push({role:'bot',text:'甲答',outcome:'completed'});
      }
      window.onConversationLoaded({agent:id, conversationId:cid, messages:[...messages,...tail], readAt:Date.now()});
      const answers = [...st.msgEl.querySelectorAll('.turn')];
      check('B2-04 迟到快照逐轮保留本地回答及重试 '+tail.length, answers.length === 3 && answers.every((n,i)=>n.textContent.includes(['甲答','乙答','丙答'][i]) && !!n.querySelector('.retry') === (i>0)), answers.map(n=>n.textContent));
    }
    Object.assign(st,saved); lsSet(id+'_conv',conv);
  }
  {
    const read = readLocalFile, lines = Array.from({length:240},(_,i)=>'行'+(i+1)).join('\n');
    readLocalFile = async path => ({path,content:lines});
    closePreview(); openPreview({path:'/b2-scroll.txt',diff:'@@ -19,0 +20 @@\n+行20\n@@ -89,0 +91 @@\n+行91\n@@ -167,0 +170 @@\n+行170'});
    await until(()=>changeAnchors().length === 3,'B2 三处改动');
    const body = pane.el.querySelector('.ed-body'), anchors = changeAnchors();
    body.dispatchEvent(new WheelEvent('wheel',{deltaY:500,bubbles:true}));
    body.scrollTop = anchors[1].offsetTop + 10;
    jumpChange(1);
    check('B2-06 手动滚过第二处后跳第三处', anchors[2].classList.contains('flash'), anchors.findIndex(a=>a.classList.contains('flash')));
    closePreview(); readLocalFile = read;
  }
  {
    const st = S[id], draft = st.draft, attach = st.attach, note = pets[id].say, notices = [];
    pets[id].say = msg => notices.push(msg);
    const path = '/tmp/已移走.png', reason = '图片读不到：已移走.png';
    setDraft(id,''); st.attach = [];
    for (const steer of [false,true]) {
      startRun(id,steer ? '已有问题' : '看图',steer ? [] : [path]);
      const run = [...st.runs.values()].at(-1);
      if (steer) {
        queueMessage(id,'补图',[path]);
        window.onAgentSteer({agent:id,reqId:run.reqId,steerId:run.queue[0].sid,state:'rejected',reason,restoreDraft:true});
      } else window.onAgentResponse({agent:id,reqId:run.reqId,reply:reason,outcome:'failed',restoreDraft:true});
      check('B2-13 缺图退还文字和附件 '+steer, st.draft === (steer?'补图':'看图') && st.attach.some(a=>a.path===path)
        && (!steer || (!run.queue.length && notices.some(v=>v.includes('已移走.png')))), {draft:st.draft,paths:st.attach.map(a=>a.path),queue:run.queue?.length});
      if (steer) window.onAgentResponse({agent:id,reqId:run.reqId,reply:'好',cancelled:true});
      setDraft(id,''); st.attach = [];
    }
    setDraft(id,draft); st.attach = attach; saveAttachments(id); renderAttachments(); pets[id].say = note;
  }
  {
    const st = S[id], start = startRun, queue = queueMessage;
    startRun(id,'原问题');
    const run = [...st.runs.values()].at(-1);
    for (const text of ['甲','乙','丙']) {
      queueMessage(id,text,['/'+text+'.png']);
      const item = run.queue.at(-1);
      window.onAgentSteer({agent:id,reqId:run.reqId,steerId:item.sid,state:'rejected'});
    }
    run.queue[1].el.querySelector('.queued-now').click();
    const sent = [];
    startRun = (_,text,images) => sent.push(['发送',text,...images]);
    queueMessage = (_,text,images) => sent.push(['排队',text,...images]);
    window.onAgentResponse({agent:id,reqId:run.reqId,cancelled:true,reply:'停'});
    check('B2-14 立即发送选中项并保留其余顺序和附件', JSON.stringify(sent) === JSON.stringify([['发送','乙','/乙.png'],['排队','甲','/甲.png'],['排队','丙','/丙.png']]), sent);
    startRun = start; queueMessage = queue;
  }
  {
    const st = S[id], start = startRun, mood = pets[id].moodEvent, celebrate = pets[id].celebrate, draft = st.draft;
    const events = [];
    pets[id].moodEvent = event => events.push(event); pets[id].celebrate = () => events.push('庆祝');
    for (const outcome of ['completed',undefined]) {
      startRun(id,'列注意事项');
      const run = [...st.runs.values()].at(-1);
      queueMessage(id,'后问');
      startRun = (_,text) => events.push(text); events.length = 0;
      window.onAgentResponse({agent:id,reqId:run.reqId,reply:'⚠️ 高温时请注意通风。',outcome});
      const retry = !![...st.msgEl.querySelectorAll('.turn')].at(-1)?.querySelector('.retry');
      check('B2-15 警告符开头按结局判定 '+outcome, outcome ? !retry && events.includes('庆祝') && events.includes('后问') && !events.includes('error')
        : retry && events.includes('error') && !events.includes('后问'), {retry,events:events.slice()});
      startRun = start;
    }
    pets[id].moodEvent = mood; pets[id].celebrate = celebrate; setDraft(id,draft);
  }
  {
    const st = S[id], saved = {conversationId:st.conversationId, loadedId:st.loadedId, loadedSig:st.loadedSig, workspace:st.workspace, attach:st.attach, draft:st.draft};
    const conv = lsGet(id+'_conv'), ws = lsGet(id+'_workspace'), prompts = st.prompts, stored = lsGet(id+'_prompts'), last = st.lastPrompt;
    const open = cid => { showEmpty(id,'正在加载历史会话…'); openConversation(id,{id:cid,title:cid,cwd:'/tmp/project'}); };
    open('b2-draft-a'); setDraft(id,'原文'); st.attach = [{path:'/tmp/a.png'},{path:'/tmp/note.txt'}]; send();
    const run = [...st.runs.values()].at(-1);
    open('b2-draft-b'); setDraft(id,'另一会话'); st.attach = [{path:'/tmp/b.png'}];
    window.onAgentResponse({agent:id,reqId:run.reqId,conversationId:'b2-draft-a',reply:'⚠️ 工作空间已改名',restoreDraft:true,outcome:'failed'});
    const snapshot = () => [els.input.value,...st.attach.map(a=>a.path)];
    const values = [snapshot()]; open('b2-draft-a'); values.push(snapshot()); open('b2-draft-b'); values.push(snapshot());
    check('B2-16 目录失效后原文和附件退回原会话，当前草稿不串', JSON.stringify(values) === JSON.stringify([['另一会话','/tmp/b.png'],['原文','/tmp/a.png','/tmp/note.txt'],['另一会话','/tmp/b.png']]),values);
    open('b2-draft-a'); setDraft(id,''); st.attach = []; open('b2-draft-b');
    Object.assign(st,saved); setDraft(id,saved.draft); saveAttachments(id); renderAttachments();
    st.prompts = prompts; st.lastPrompt = last; lsSet(id+'_prompts',stored); lsSet(id+'_conv',conv); lsSet(id+'_workspace',ws);
  }
  {
    const st = S[id], prior = {conversationId:st.conversationId, loadedId:st.loadedId, conversations:st.conversations, seenStamp:st.seenStamp};
    showEmpty(id, '正在加载历史会话…');
    st.conversationId = st.loadedId = 'b3-missing';
    window.onConversationsListed({agent:id,items:[{id:'b3-missing',timestamp:42}]});
    const before = requests.length;
    window.onConversationsListed({agent:id,items:[]});
    const reads = requests.slice(before).filter(r => r.action === 'loadConversation' && r.conversationId === 'b3-missing');
    check('B3-4 当前条目消失后按 ID 核实', reads.length === 1, reads.length);
    Object.assign(st,prior);
  }
  {
    for (const agent of ['claude','gemini','deepseek']) {
      const run = {agent, historyStart:0, prompt:'看图', text:'看图', images:['/tmp/原图.png'], imageKeys:['sent-a']};
      const cut = key => liveHistoryCut(run,[{role:'user',text:'看图',images:[{ref:{agent,id:'记录内的编号'},imageKey:key}]}]);
      check('B3-5 '+agent+' 同一轮内嵌图只接一次，同字不同图保留', cut('sent-a') === 0 && cut('sent-b') === -1,[cut('sent-a'),cut('sent-b')]);
    }
  }
  {
    const cid = 'b3-diff', file = {path:'/tmp/project/shell.txt',diff:'@@\n+shell',added:1,removed:0};
    const st = S[id], old = {conversationId:st.conversationId,loadedId:st.loadedId}, stored = lsGet('turn_extras');
    showEmpty(id, '正在加载历史会话…'); st.conversationId = st.loadedId = cid;
    rememberTurn(id,{text:'命令',historyStart:0},{conversationId:cid,files:[file]},'/tmp/project');
    const cached = typeof readTurnExtras === 'function' ? readTurnExtras().get(id+':'+cid) : null;
    check('B3-6 冷启动能还原命令改动的轮次、文件和 diff', cached?.[0]?.at === 0 && cached[0].files[0].diff === file.diff,cached || null);
    turnExtras.delete(id+':'+cid);
    renderMessages(id,[{role:'user',text:'工具'},{role:'bot',text:'好了',files:[file]}],'/tmp/project');
    check('B3-6 历史自带文件也有查看全部改动', !!st.msgEl.querySelector('.files-all'));
    lsSet('turn_extras',stored); Object.assign(st,old);
  }
  {
    const backup = lsGet('turn_extras'), cid = 'b3-delete-diff', sibling = 'b3-keep-diff';
    const insert = cid => rememberTurn(id,{text:'编辑',historyStart:0},{conversationId:cid,files:[{path:'/tmp/a',diff:'@@\n+abc'}]},'/tmp');
    for (const bulk of [false,true]) {
      const ex = insert(cid); insert(sibling); openChanges(ex);
      if (bulk) window.onConversationsDeleted({agent:id,deleted:[cid],failed:[sibling]});
      else window.onConversationDeleted({agent:id,ok:true,conversationId:cid});
      const state = [turnExtras.has(id+':'+cid),pane.tabs.some(t=>t.extra===ex),turnExtras.has(id+':'+sibling)];
      check('B3-7 删除仅释放成功会话的改动缓存和预览 '+bulk, state.join() === 'false,false,true',state);
      pane.tabs.filter(t=>t.extra===ex).forEach(t=>closeTab(t.id));
    }
    turnExtras.delete(id+':'+cid); turnExtras.delete(id+':'+sibling); lsSet('turn_extras',backup);
  }
  {
    for (const agent of ALL_AGENT_IDS) {
      const st = S[agent], cid = 'b3-unread-'+agent, prev = lsGet(agent+'_unread'), flag = st.unread, list = st.conversations;
      const card = {agent,conversationId:cid,reqId:0,requestId:'b3-unread-card',kind:'question',questions:[]};
      window.onAgentRequest(card);
      const ids = [...readUnreadConversations(agent)];
      check('B3-8 '+agent+' 冷启动未读记录含后台会话', ids.includes(cid),ids);
      window.onConversationDeleted({agent,conversationId:cid,ok:true});
      check('B3-8 '+agent+' 删除清除持久未读', ![...readUnreadConversations(agent)].includes(cid));
      st.unread = flag; st.conversations = list; lsSet(agent+'_unread',prev);
    }
  }
  {
    const real = {path:'/tmp/附图.png'}, embedded = {ref:{agent:id,conversationId:'b3-images',id:'record-2'}};
    const mentioned = {path:'/tmp/正文.png',mentioned:true};
    renderMessages(id,[{role:'user',text:'请核对 /tmp/正文.png',images:[embedded,real,mentioned]},{role:'bot',text:'错误',outcome:'failed'}],'/tmp');
    const retry = S[id].msgEl.querySelector('.msg.user')._retry;
    check('B3-9 重试只附上用户发送的图片且保留原位置',retry.images.join() === real.path && retry.refs.length === 1 && retry.refs[0].index === 0,retry);
  }
  {
    for (const agent of ALL_AGENT_IDS) {
      const card = permissionCard({agent}, {title:'运行命令',supportsDenyReason:agent==='claude'});
      check('B3-11 '+agent+' 仅能提交拒绝理由时显示输入框',!!card.querySelector('.req-input') === (agent==='claude'),!!card.querySelector('.req-input'));
    }
    check('B3-11 Claude 的 MCP 链接确认也没有理由框',!permissionCard({agent:'claude'},{tool:'mcp'}).querySelector('.req-input'));
  }
  {
    const st = S[id], saved = [st.conversationId, st.loadedId], cid = 'b3-reload';
    showEmpty(id, '正在加载历史会话…');
    st.conversationId = st.loadedId = cid;
    const reqId = 89133, q = {agent:id,reqId,kind:'permission',requestId:'hold',title:'写入'};
    const data = {agent:id,reqId,prompt:'继续处理',conversationId:cid,workspace:st.workspace,cards:[q],steps:[],historyStart:0};
    const at = requests.length;
    window.onRestoreActiveTurn?.(data);
    window.onRestoreActiveTurn?.(data);
    const run = st.runs.get(reqId), cards = st.msgEl.querySelectorAll('[data-request-id="hold"]');
    check('B3-13 网页重载后在原回合恢复停止入口和一张待答卡',viewBusy(id) && !!run && cards.length === 1,[viewBusy(id),cards.length]);
    cards[0]?.querySelector('.req-btn.danger')?.click();
    check('B3-13 恢复的审批交给原请求且没有再次发送提问',requests.slice(at).some(r=>r.action==='answerAgentRequest' && r.reqId===reqId && r.requestId==='hold') && !requests.slice(at).some(r=>r.action==='askAgent'));
    st.runs.delete(reqId); run?.nodes.forEach(n=>n.remove()); showEmpty(id, '正在加载历史会话…');
    [st.conversationId,st.loadedId]=saved; updateSendUI();
  }
  {
    const st=S[id], key='b3-long-code', old={conversationId:st.conversationId,loadedId:st.loadedId,bodyQuery:st.bodyQuery,bodyHits:st.bodyHits,bodyItems:st.bodyItems}, oldQuery=histQuery;
    showEmpty(id, '正在加载历史会话…'); st.conversationId=st.loadedId=key;
    histQuery=st.bodyQuery='needle-at-end'; st.bodyHits=new Set([key]); st.bodyItems=[];
    renderMessages(id,[{role:'bot',text:'```\n'+'row\n'.repeat(400)+'needle-at-end\n```'}],'');
    st.msgEl.scrollTop=0; jumpToSearchHit(id);
    const code=st.msgEl.querySelector('.answer code'), node=code?.firstChild, range=document.createRange();
    const at=node?.textContent.indexOf(histQuery) ?? -1;
    if (at>=0) { range.setStart(node,at); range.setEnd(node,at+histQuery.length); }
    const match=range.getBoundingClientRect(), viewport=st.msgEl.getBoundingClientRect();
    check('B3-14 单文本节点的长代码块跳到实际命中字',at>=0 && match.top>=viewport.top && match.bottom<=viewport.bottom,[at,match.top,viewport.top,viewport.bottom]);
    histQuery=oldQuery; Object.assign(st,old);
  }
  {
    const value = histSearch.value, query = histQuery, later = window.setTimeout, at = requests.length;
    try {
      window.setTimeout = (fn, delay, ...args) => { if (delay === 300) { fn(); return 0; } return later(fn,delay,...args); };
      histSearch.value = '岸'; histSearch.dispatchEvent(new Event('input'));
      check('B3-15 单字也向四位已启用助手查询列表外的标题和工作空间',AGENT_IDS.every(agent=>requests.slice(at).some(r=>r.action==='searchConversations' && r.agent===agent && r.query==='岸')),requests.slice(at).filter(r=>r.action==='searchConversations').length);
    } finally { window.setTimeout=later; histSearch.value=value; histQuery=query; renderAllHistory(); }
  }
  {
    const files = Array.from({length:65},(_,i)=>({path:'/tmp/bulk-'+i,added:i+1,removed:0}));
    const card = renderFilesCard(files), bar=document.createElement('div'), body=document.createElement('div');
    renderChanges(bar,body,{extra:{files,cwd:'/tmp'}});
    const expected='共 65 个，显示前 60 个';
    check('B3-18 聊天改动卡显示总数、展示数和完整行数',card.textContent.includes(expected) && card.querySelectorAll('.file-row').length===60 && card.querySelector('.files-head .add').textContent==='+2145',card.querySelector('.files-head').textContent);
    check('B3-18 全部改动面板也明确截断范围',bar.textContent.includes(expected) && body.querySelectorAll('.chg-file').length===60,bar.textContent);
  }
