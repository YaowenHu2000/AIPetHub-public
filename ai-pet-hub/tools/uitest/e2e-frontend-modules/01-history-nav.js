  // 搜索会话不能受左栏最近列表限制，多次回调保留累计结果并可定位到更早正文。
  const savedConversations = S[id].conversations, savedConversationId = S[id].conversationId, savedLoadedId = S[id].loadedId;
  S[id].conversations = []; histQuery = 'search-needle';
  const distant = {id:'search-outside-list',title:'列表外的历史',cwd:'/search-fixture',timestamp:1,searchLimit:5300};
  window.onConversationsSearched({agent:id,query:histQuery,ids:[distant.id],items:[distant],complete:false});
  check('A 列表之外的正文命中可见', !!histSections[id].list.querySelector('[data-k="c:search-outside-list"]'));
  const second = {...distant,id:'search-second',title:'第二批历史'};
  window.onConversationsSearched({agent:id,query:histQuery,ids:[distant.id,second.id],items:[distant,second],complete:true,unavailable:'部分会话没搜：夹具不可用'});
  check('A 累计分批结果和来源失败同时可见', histSections[id].list.querySelectorAll('.conv-row').length === 2 && histSections[id].list.textContent.includes('部分会话没搜'));
  S[id].conversationId = distant.id; S[id].loadedId = distant.id;
  const beforeSearchOpen = requests.length; openConversation(id,distant);
  check('A 已打开会话仍按深处命中重新定位', requests.slice(beforeSearchOpen).some(r=>r.action==='loadConversation' && r.conversationId===distant.id && r.limit===5300 && r.searchHit===true));
  // 两个不同路径的最后一级同名：组名往上多带一级，分得清；不同名的仍只显示最后一级
  histQuery = ''; S[id].conversationId = ''; S[id].loadedId = '';
  S[id].conversations = [{id:'same-a',title:'甲',cwd:'/fixture/ws-one/app',timestamp:3}, {id:'same-b',title:'乙',cwd:'/fixture/ws-two/app',timestamp:2}, {id:'other-c',title:'丙',cwd:'/fixture/solo',timestamp:1}];
  renderHistory(id);
  const groupNames = [...histSections[id].list.querySelectorAll('.grp-name')].map(n => n.textContent);
  check('A 同名项目组带上一级目录', groupNames.includes('ws-one/app') && groupNames.includes('ws-two/app') && groupNames.includes('solo'), groupNames);
  // 任务会话：原生标了 task 的、临时文件夹里的进底部默认折叠的一组，没有项目操作按钮；右键可以移进移出
  const savedOverrides = S[id].taskOverrides, savedGroupState = S[id].groupState;
  S[id].taskOverrides = {}; S[id].groupState = {};
  S[id].conversations = [{id:'real',title:'真项目',cwd:'/fixture/proj',timestamp:5}, {id:'job',title:'派出去的',cwd:'/fixture/proj',timestamp:4,task:true},
    {id:'tmpjob',title:'临时目录',cwd:'/private/var/folders/x/T/job',timestamp:3}, {id:'loose',title:'未绑定',cwd:'',timestamp:2}];
  renderHistory(id);
  const heads = () => [...histSections[id].list.querySelectorAll('.grp-head')];
  const taskHead = () => heads().find(h => h.querySelector('.grp-name').textContent === '任务会话');
  check('T 任务会话在最底下、默认折叠、没有项目按钮', !!taskHead() && heads().at(-1) === taskHead() && taskHead().querySelector('.grp-count').textContent === '2'
    && !histSections[id].list.querySelector('[data-k="c:job"]') && !taskHead().querySelector('.grp-more, .grp-add'), heads().map(h => h.textContent));
  check('T 真项目里只剩自己的会话', groupKeyOf(id, S[id].conversations[0]) === '/fixture/proj' && groupKeyOf(id, S[id].conversations[1]) === TASK_GROUP);
  histSections[id].list.querySelector('[data-k="c:real"]').dispatchEvent(new MouseEvent('contextmenu', {bubbles: true}));
  const moveIn = [...els.popover.querySelectorAll('.pop-item')].find(n => n.textContent.includes('移到任务会话'));
  moveIn?.click();
  check('T 右键移到任务会话并记住', !!moveIn && S[id].taskOverrides.real === true && groupKeyOf(id, S[id].conversations[0]) === TASK_GROUP, S[id].taskOverrides);
  const delIds = projectDeleteIds(id, '/fixture/proj', { ids: ['real', 'plain', 'job'], taskIds: ['job'] });
  check('T 删除项目不带走任务会话（派出去的、右键移过去的）', delIds.join() === 'plain', delIds);
  // 点开别的项目的历史会话：工作目录当场换成那条会话的，不等正文读回来（读的期间发出去会带着上一个项目的目录续接）
  const savedWs = S[id].workspace; S[id].workspace = '/fixture/proj-a';
  openConversation(id, { id: 'cwd-switch', title: '乙项目的会话', cwd: '/fixture/proj-b', timestamp: 6 });
  check('W 点开历史会话时工作目录立即跟过去', S[id].workspace === '/fixture/proj-b', S[id].workspace);
  setWorkspace(id, savedWs, false); S[id].conversationId = ''; S[id].loadedId = ''; S[id].applyCwdOnLoad = false;
  // 没有回合接着的请求（DeepSeek 自己开的一轮里来问，reqId 0、带会话编号）：正看着就接在对话末尾，否则标未读；答复带 reqId 0 交回
  {
    const box = S[id].msgEl, q = { agent: id, reqId: 0, requestId: 'dshq-wake', kind: 'question', conversationId: 'wake-conv',
      questions: [{ question: '导出成哪种格式？', options: [{ label: 'PDF' }, { label: 'PNG' }] }] };
    const cards = () => [...box.querySelectorAll(':scope > .live-requests.unattended > .req-card')].filter(c => c.dataset.requestId === 'dshq-wake');
    S[id].unreadConvs.delete('wake-conv');
    window.onAgentRequest(q);
    check('U 没在看这个会话时不摆卡片、把会话标成未读', cards().length === 0 && S[id].unreadConvs.has('wake-conv'));
    S[id].conversationId = S[id].loadedId = 'wake-conv'; markSeen(id);
    window.onAgentRequest(q); window.onAgentRequest(q);
    check('U 正看着这个会话时卡片接在对话末尾、重发不重复', cards().length === 1 && box.lastElementChild.classList.contains('unattended'), cards().length);
    const before = requests.length;
    cards()[0].querySelector('.req-option').click();
    const sentAnswer = requests.slice(before).find(r => r.action === 'answerAgentRequest');
    check('U 答复带 reqId 0 和卡片编号交回原生', sentAnswer?.reqId === 0 && sentAnswer?.requestId === 'dshq-wake' && sentAnswer?.answers?.['导出成哪种格式？'] === 'PDF', sentAnswer);
    window.onAgentRequestClosed({ agent: id, reqId: 0, requestId: 'dshq-wake' });
    check('U 了结后撤卡', cards().length === 0);
    box.querySelector(':scope > .live-requests.unattended')?.remove();
    S[id].conversationId = ''; S[id].loadedId = ''; S[id].unreadConvs.delete('wake-conv'); markSeen(id);
  }
