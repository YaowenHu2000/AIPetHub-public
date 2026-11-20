  // SV：SVG 图片显示出来以后，工具栏里仍能切到内置浏览器看；PNG 不出现这个按钮。
  {
    const oldRead = readLocalFile, pixel = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';
    readLocalFile = async path => ({path, image: pixel, size: 68});
    const globe = () => [...pane.el.querySelectorAll('.ed-bar .ed-tool')].some(b => b.title === '在内置浏览器中预览');
    closePreview(); openPreview({path:'/sv-fixture/icon.svg',base:''});
    await until(() => activeTab()?.data && pane.el.querySelector('.ed-image img'), 'SVG 预览显示图片');
    check('SV SVG 图片显示后仍有内置浏览器预览按钮', globe(), pane.el.querySelector('.ed-bar')?.innerHTML);
    openPreview({path:'/sv-fixture/icon.png',base:''});
    await until(() => activeTab()?.resolved === '/sv-fixture/icon.png' && pane.el.querySelector('.ed-image img'), 'PNG 预览显示图片');
    check('SV PNG 预览没有内置浏览器预览按钮', !globe(), pane.el.querySelector('.ed-bar')?.innerHTML);
    readLocalFile = oldRead; closePreview();
  }
  // 服务端仍有未取到的旧页时，即使已知 omitted 为零，也要保留同一个加载入口。
  const paged = {agent:id,conversationId:'history-pages-fixture',cwd:'',messages:[{role:'user',text:'最近的一句'}],limit:300,omitted:0,hasMore:true};
  S[id].conversationId = paged.conversationId;
  window.onConversationLoaded(paged);
  const earlier = S[id].msgEl.querySelector('.load-earlier');
  check('C 服务端仍有旧页时保留显示更早', !!earlier && earlier.textContent.includes('更早'), earlier?.textContent);
  const beforeEarlier = requests.length; earlier?.click();
  check('C 继续翻页复用历史加载请求', requests.slice(beforeEarlier).some(r=>r.action==='loadConversation' && r.conversationId===paged.conversationId && r.limit===600));
  const pagedSync = fields => {
    const reqId = nextRequestId();
    (S[id].historyReads ??= new Map()).set(reqId, 'sync');
    window.onConversationLoaded({...paged, ...fields, reqId});
  };
  pagedSync({hasMore:false});
  check('C 同步仅翻页状态变化也更新入口', !S[id].msgEl.querySelector('.load-earlier'));
  // 续取此前未知的旧页会移动本轮在完整历史里的位置；旧的同文不能被当成这次提问截掉。
  const pagedRun = {agent:id,reqId:901234,view:viewKey(id),historyStart:1,text:'继续',prompt:'继续',images:[],nodes:[]};
  S[id].runs.set(pagedRun.reqId,pagedRun);
  window.onConversationLoaded({...paged,messages:[{role:'user',text:'更早一问'},{role:'user',text:'继续'},{role:'bot',text:'旧回答'}],limit:600,hasMore:false,historyPrepended:2});
  check('C 续页修正进行中回答的历史偏移，不误截旧同文', pagedRun.historyStart === 3 && S[id].msgEl.querySelectorAll('.msg.user').length === 2 && S[id].msgEl.textContent.includes('旧回答'), {historyStart:pagedRun.historyStart,text:S[id].msgEl.textContent});
  const firstNode = S[id].msgEl.firstElementChild;
  pagedSync({historyPrepended:2});
  check('C 正在回答的同步不重画也保留旧页偏移修正', pagedRun.historyStart === 5 && S[id].msgEl.firstElementChild === firstNode, pagedRun.historyStart);
  S[id].runs.delete(pagedRun.reqId);
  S[id].conversationId = savedConversationId; S[id].loadedId = savedLoadedId;
  showEmpty(id); renderHistory(id);
  // 文件核对异步回来后才还原的文字，也要完成之前待定的搜索定位。
  histQuery = 'search-async-directory';
  const delayedId = 'search-file-check-fixture', delayedPath = '/tmp/search-async-directory/missing.swift';
  S[id].conversationId = delayedId; S[id].bodyQuery = histQuery; S[id].bodyHits = new Set([delayedId]);
  const beforeFileCheck = requests.length;
  window.onConversationLoaded({agent:id,conversationId:delayedId,messages:[{role:'bot',text:'`'+delayedPath+'`',steps:[],files:[]}],cwd:'',limit:300,omitted:0});
  const fileCheck = requests.slice(beforeFileCheck).find(r=>r.action==='checkFiles');
  if (fileCheck) window.onFilesChecked({reqId:fileCheck.reqId,found:{}});
  check('A 文件核对还原正文后完成搜索定位', !!fileCheck && !!S[id].msgEl.querySelector('.msg.bot.search-hit') && S[id].msgEl.textContent.includes(delayedPath));
  histQuery = ''; S[id].conversationId = savedConversationId; S[id].loadedId = savedLoadedId;
  showEmpty(id); renderHistory(id);
  // KaTeX 的透明占位有 DOM 文字但不显示；零高度的 smash 仍然显示。
  const mathId = 'search-math-fixture';
  histQuery = 'ghostneedle'; S[id].conversationId = mathId; S[id].bodyQuery = histQuery; S[id].bodyHits = new Set([mathId]);
  window.onConversationLoaded({agent:id,conversationId:mathId,messages:[
    {role:'bot',text:'$\\phantom{ghostneedle}$ $\\hphantom{\\text{ghostneedle}}$ $\\vphantom{\\frac{ghostneedle}{x}}$'},
    {role:'bot',text:'真正可见的 ghostneedle'},
    {role:'bot',text:'$\\smash{\\text{shownneedle}}$'},
    {role:'bot',text:'$\\color{transparent}{hidden\\color{red}{showncolored}}$'}
  ],cwd:'',limit:300,omitted:0});
  const mathMessages = [...S[id].msgEl.querySelectorAll('.msg.bot')];
  check('A 搜索定位跳过透明公式占位，命中可见正文', mathMessages.length === 4 && !mathMessages[0].classList.contains('search-hit') && mathMessages[1].classList.contains('search-hit'));
  mathMessages.forEach(n=>n.classList.remove('search-hit'));
  histQuery = 'shownneedle'; S[id].bodyQuery = histQuery; jumpToSearchHit(id);
  check('A 搜索定位保留零高度但可见的 smash 文字', !!mathMessages[2]?.classList.contains('search-hit'));
  histQuery = 'showncolored'; S[id].bodyQuery = histQuery; jumpToSearchHit(id);
  check('A 透明公式父节点中恢复颜色的文字仍可定位', !!mathMessages[3]?.classList.contains('search-hit'));
  histQuery = ''; S[id].conversationId = savedConversationId; S[id].loadedId = savedLoadedId;
  showEmpty(id); renderHistory(id);
  const markdownImageId = 'search-markdown-image-fixture', markdownImagePath = '/tmp/deleted-search-image.png';
  histQuery = 'deletedneedle'; S[id].conversationId = markdownImageId; S[id].bodyQuery = histQuery; S[id].bodyHits = new Set([markdownImageId]);
  const beforeMarkdownImage = requests.length;
  window.onConversationLoaded({agent:id,conversationId:markdownImageId,messages:[{role:'bot',text:'![deletedneedle]('+markdownImagePath+')'}],cwd:'',limit:300,omitted:0});
  const markdownImageRead = requests.slice(beforeMarkdownImage).find(r=>r.action==='readFile' && r.path===markdownImagePath);
  if (markdownImageRead) window.onFileRead({reqId:markdownImageRead.reqId,path:markdownImagePath,error:'不存在'});
  await Promise.resolve();
  check('A 本地图片缺失标签异步出现后完成搜索定位', !!markdownImageRead && !!S[id].msgEl.querySelector('.md-img-missing') && !!S[id].msgEl.querySelector('.msg.bot.search-hit'));
  histQuery = ''; S[id].conversationId = savedConversationId; S[id].loadedId = savedLoadedId;
  showEmpty(id); renderHistory(id);
  const unicodeId = 'search-unicode-fixture';
  histQuery = 'strasse'; S[id].conversationId = unicodeId; S[id].bodyQuery = histQuery; S[id].bodyHits = new Set([unicodeId]); S[id].bodyItems = [{id:unicodeId,searchMatch:'Straße'}];
  window.onConversationLoaded({agent:id,conversationId:unicodeId,messages:[{role:'user',text:'Straße'}],cwd:'',limit:300,omitted:0});
  check('A Unicode大小写按原生命中的原文定位', !!S[id].msgEl.querySelector('.msg.user.search-hit'));
  histQuery = 'οσ'; S[id].bodyQuery = histQuery; S[id].bodyItems = [{id:unicodeId,searchMatch:'ΟΣ'}];
  window.onConversationLoaded({agent:id,conversationId:unicodeId,messages:[{role:'bot',text:'',steps:[{kind:'think',title:'思考',detail:'ΟΣ'}]}],cwd:'',limit:300,omitted:0});
  check('A sigma变体命中并展开工作步骤', !!S[id].msgEl.querySelector('.msg.bot.search-hit') && [...S[id].msgEl.querySelectorAll('.step-body')].some(n=>!n.hidden && n.textContent.includes('ΟΣ')));
  histQuery = ''; S[id].conversationId = savedConversationId; S[id].loadedId = savedLoadedId;
  showEmpty(id); renderHistory(id);
  S[other].draft = 'B草稿';
  type('A重要草稿'); setActive(other); await saved(id, 'A重要草稿');
  check('F01 快速切 AI 不串写', S[id].draft === 'A重要草稿' && lsGet(`${id}_draft`) === 'A重要草稿', {memory:S[id].draft,saved:lsGet(`${id}_draft`)});
  type('B新草稿'); setActive(id); type('A新草稿'); await saved(id, 'A新草稿'); await saved(other, 'B新草稿');
  check('F01 两位防抖各自落盘', lsGet(`${other}_draft`) === 'B新草稿' && lsGet(`${id}_draft`) === 'A新草稿', [lsGet(`${other}_draft`), lsGet(`${id}_draft`)]);
  const edit = document.createElement('div'); addEditButton(edit, id, '编辑回填'); edit.querySelector('button').click(); await saved(id, '编辑回填');
  check('F18 编辑回填保存', lsGet(`${id}_draft`) === '编辑回填', lsGet(`${id}_draft`));
  type(''); await saved(id, ''); S[id].prompts = ['历史回填']; S[id].promptAt = -1; browsePrompts(id,-1); await saved(id, '历史回填');
  check('F18 上翻历史保存', lsGet(`${id}_draft`) === '历史回填', lsGet(`${id}_draft`));
  showSuggest('slash', [{name:'compact',desc:''}], 0); acceptSuggest(); await saved(id, '/compact ');
  check('F18 命令补全保存', lsGet(`${id}_draft`) === '/compact ', lsGet(`${id}_draft`));
  type('@a'); showSuggest('file', [{name:'src/a.js'}], 0); acceptSuggest(); await saved(id, 'src/a.js ');
  check('F18 文件补全保存', lsGet(`${id}_draft`) === 'src/a.js ', lsGet(`${id}_draft`));
  window.onFilesDropped({paths:['/tmp/my file.txt']}); await saved(id, els.input.value);
  check('F18 插入文件路径保存', lsGet(`${id}_draft`) === els.input.value, {saved:lsGet(`${id}_draft`),value:els.input.value});
  type('before\nafter'); els.input.selectionStart = els.input.selectionEnd = 6;
  els.input.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',ctrlKey:true,bubbles:true,cancelable:true})); await saved(id, els.input.value);
  check('F18 修饰键换行保存', lsGet(`${id}_draft`) === els.input.value, {saved:lsGet(`${id}_draft`),value:els.input.value});
  const oldStartRun = startRun; startRun = () => {};
  type('马上发送'); send(); setActive(other); type('另一位保留'); await saved(other, '另一位保留');
  check('F01 发送撤销旧保存', lsGet(`${id}_draft`, '') === '' && S[id].draft === '', lsGet(`${id}_draft`));
  startRun = oldStartRun; setActive(id);

  S[id].workspace = '/project-A'; agentCommands[id] = [{name:'compact',desc:''}];
  const request = async (text = '@abc') => { const n = requests.length; type(text); return until(() => requests.slice(n).find(r => r.action === 'listFiles'), '@ 文件请求'); };
  let req = await request(); type('/com'); window.onFilesListed({reqId:req.reqId,files:['old.js']});
  check('F11 旧文件回调不覆盖命令', suggest.kind === 'slash' && suggest.items[0]?.name === 'compact', {kind:suggest.kind,items:suggest.items});
  req = await request(); S[id].workspace = '/project-B'; window.onFilesListed({reqId:req.reqId,files:['old.js']});
  check('F11 工作区变化拒绝旧结果', !suggest.items.some(x=>x.name==='old.js'), suggest.items);
  req = await request(); setActive(other); window.onFilesListed({reqId:req.reqId,files:['other-old.js']});
  check('F11 切 AI 拒绝旧结果', !suggest.items.some(x=>x.name==='other-old.js'), suggest.items); setActive(id);
  req = await request(); type('@abcd'); window.onFilesListed({reqId:req.reqId,files:['older.js']});
  check('F11 新查询防抖期间拒绝旧结果', !suggest.items.some(x=>x.name==='older.js'), suggest.items);
  req = await until(() => requests.filter(r=>r.action==='listFiles').at(-1)?.reqId !== req.reqId && requests.filter(r=>r.action==='listFiles').at(-1), '新查询请求'); window.onFilesListed({reqId:req.reqId,files:['fresh.js']});
  check('F11 当前查询正常显示', suggest.items[0]?.name === 'fresh.js', suggest.items);
  for (const key of ['Enter','Tab']) for (const mod of ['shiftKey','ctrlKey','altKey','metaKey']) {
    showSuggest('slash',[{name:'compact',desc:''}],0);
    const e = new KeyboardEvent('keydown',{key,[mod]:true,cancelable:true});
    check(`F19 ${mod}+${key} 交回输入框`, !suggestKey(e) && !e.defaultPrevented, e.defaultPrevented);
  }
  for (const key of ['Enter','Tab']) { showSuggest('slash',[{name:'compact',desc:''}],0); const e = new KeyboardEvent('keydown',{key,cancelable:true}); check(`F19 普通 ${key} 接受`, suggestKey(e) && e.defaultPrevented, els.input.value); }
  closeSuggest();

  // 没有消息变化时，导航应保持静止；真实 MutationObserver 能捕获属性自激循环。
  const oldSync = syncJumpNav; let syncs = 0;
  syncJumpNav = () => { syncs++; oldSync(); };
  syncJumpNav(); await Promise.resolve(); await until(() => !jumpQueued, '导航刷新'); syncs = 0;
  check('F12 静止时没有观察器自激', await quiet(() => syncs), syncs);
  const box = S[id].msgEl;
  const fill = label => { box.innerHTML = ''; for (const text of [label+' first',label+' last']) { const el = document.createElement('div'); el.className='msg user'; el.textContent=text; el.style.cssText='height:800px;flex-shrink:0'; box.appendChild(el); } };
  S[id].conversationId = 'conv-alpha'; fill('Alpha'); syncJumpNav();
  S[id].conversationId = 'conv-bravo'; fill('Bravo'); syncJumpNav();
  check('F13 同 AI 等长会话重建提示', jumpRail.children[0]?.dataset.text === 'Bravo first', [...jumpRail.children].map(b=>b.dataset.text));
  await Promise.resolve(); await until(() => !jumpQueued, '导航刷新'); syncs = 0;
  check('F12 有圆点时也没有自激', await quiet(() => syncs), syncs); syncJumpNav = oldSync;

  const oldRead = readLocalFile;
  readLocalFile = async (path, base) => ({path:base+'/'+path.replace(/^\.\//,''),content:base});
  closePreview(); openPreview({path:'src/a.js',base:'/project-A'}); await until(() => activeTab()?.resolved === '/project-A/src/a.js', '项目 A 预览');
  openPreview({path:'src/a.js',base:'/project-B'}); await until(() => activeTab()?.resolved === '/project-B/src/a.js', '项目 B 预览');
  check('F04 不同项目同名相对路径各有标签', pane.tabs.length === 2 && activeTab().base === '/project-B', pane.tabs.map(t=>({base:t.base,resolved:t.resolved})));
  openPreview({path:'src/a.js',base:'/project-A'}); await until(() => activeTab()?.resolved === '/project-A/src/a.js', '项目 A 预览');
  check('F04 同一项目复用标签', pane.tabs.length === 2 && activeTab().base === '/project-A', pane.tabs.length);
  readLocalFile = oldRead;

  // F16 保留响应式状态切换，去掉固定像素宽度的外观量尺。
  setSidebarHidden(false); setStageHidden(false); document.body.classList.add('preview-max');
  widths.sidebar = COLUMNS.sidebar.min; widths.stage = COLUMNS.stage.min;
  postNative('testResize',{width:600,height:720});
  await until(() => innerWidth <= 600, '缩窄窗口'); applyWidths();
  check('F16 放不下时收起舞台', document.body.classList.contains('stage-squeezed'), document.body.className);
  postNative('testResize',{width:1400,height:720});
  await until(() => innerWidth >= 1400, '加宽窗口'); applyWidths();
  check('F16 变宽后舞台回来', !document.body.classList.contains('stage-squeezed'), document.body.className);
  closePreview();

  // 补充消息复用用户图片组件；历史和实时都经 renderStep，原图请求也必须走原来的查看器。
  const supplementImage = {src:'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',w:1,h:1,ref:{agent:'claude',conversationId:'image-fixture',id:'row-id#0'}};
  const imageOnlyStep = renderStep({kind:'user',title:'你补充说',detail:'',images:[supplementImage]});
  const imageTextStep = renderStep({kind:'user',title:'你补充说',detail:'补充图片说明',images:[supplementImage]});
  box.append(imageOnlyStep, imageTextStep);
  check('B 纯图片补充只显示图和标签', imageOnlyStep.querySelectorAll('.msg-img').length === 1 && !imageOnlyStep.querySelector('.msg-text') && imageOnlyStep.textContent === '你补充说', imageOnlyStep.textContent);
  const thumbRow = imageTextStep.querySelector('.msg-images'), supplementText = imageTextStep.querySelector('.msg-text');
  check('B 补充缩略图位于文字上方', !!thumbRow && !!supplementText && thumbRow.compareDocumentPosition(supplementText) === Node.DOCUMENT_POSITION_FOLLOWING && thumbRow.getBoundingClientRect().bottom <= supplementText.getBoundingClientRect().top, imageTextStep.textContent);
  const beforeImageRequest = requests.length;
  imageOnlyStep.querySelector('.msg-img')?.click();
  const originalRequest = requests.slice(beforeImageRequest).find(r => r.action === 'chatImage');
  check('B 点补充缩略图请求同一原图', !!imageViewer && JSON.stringify(originalRequest?.ref) === JSON.stringify(supplementImage.ref), originalRequest);
  closeImageViewer(); imageOnlyStep.remove(); imageTextStep.remove();

  // 原 rail：只保留导航数量、当前项、跳转、悬浮提示和切 AI 的行为。
  box.innerHTML = ''; S[id].conversationId = 'rail-fixture';
  appendMessage(id, 'user', '只有一句的时候'); appendMessage(id, 'bot', '回答。'); syncJumpNav();
  check('一屏放下时不显示导航', jumpRail.hidden, jumpRail.hidden);
  for (let i = 2; i <= 30; i++) {
    appendMessage(id, 'user', `第 ${i} 句：请解释一下第 ${i} 个问题`);
    appendMessage(id, 'bot', ('第 ' + i + ' 个回答，足够长的正文。\n\n').repeat(6));
  }
  box.scrollTop = box.scrollHeight; syncJumpNav();
  const dots = () => [...jumpRail.querySelectorAll('.jump-dot')];
  const onAt = () => dots().findIndex(d => d.classList.contains('on'));
  await until(() => dots().length === 30, '导航建立');
  check('三十句对应三十个点且只有一个当前项', !jumpRail.hidden && dots().length === 30 && jumpRail.querySelectorAll('.on').length === 1, dots().length);
  await until(() => onAt() === 29, '导航跟随底部'); check('在底部选中最后一句', onAt() === 29, onAt());
  box.scrollTop = 0; await until(() => onAt() === 0, '导航跟随顶部'); check('滚到顶部选中第一句', onAt() === 0, onAt());
  dots()[11].click(); await until(() => onAt() === 11, '点击导航跳转'); check('点第 12 个点跳到第 12 句', onAt() === 11 && box.scrollTop > 0, onAt());
  dots()[11].dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));
  const tip = document.querySelector('.jump-tip');
  await until(() => !tip.hidden, '导航提示'); check('悬停显示该句开头', tip.textContent.startsWith('第 12 句'), tip.textContent);
  jumpRail.dispatchEvent(new MouseEvent('mouseleave')); check('移开收起提示', tip.hidden, tip.hidden);
  S[other].msgEl.innerHTML = ''; setActive(other, false); syncJumpNav(); check('切到空会话不显示导航', jumpRail.hidden, jumpRail.hidden);

  // ME 提问卡：带 id 的题（Codex、MCP 表单）按 id 交回，两题文字相同也不串；isOther 为 false 不给输入框；isSecret 的输入框按密码显示
  const qid = active;
  startRun(qid, 'ME 提问卡', []);
  const qrun = [...S[qid].runs.values()].at(-1);
  window.onAgentRequest({agent:qid, reqId:qrun.reqId, requestId:'me-q', kind:'question', message:'请填写资料', questions:[
    {id:'first', question:'选哪个？', header:'', options:[{label:'左', description:''}, {label:'右', description:''}], multiSelect:true, isOther:false, isSecret:false},
    {id:'second', question:'选哪个？', header:'', options:[], multiSelect:false, isOther:true, isSecret:true}]});
  const qcard = qrun.live?.requests?.querySelector('.req-card.req-question');
  check('ME 提问卡出现并带上 MCP 的说明', !!qcard && qcard.textContent.includes('请填写资料'), qcard?.textContent);
  const qblocks = qcard ? [...qcard.querySelectorAll('.req-q')] : [];
  check('ME isOther 为 false 的题不给输入框', qblocks.length === 2 && !qblocks[0].querySelector('.req-input'), qblocks.length);
  check('ME isSecret 的输入框按密码显示', qblocks[1]?.querySelector('.req-input')?.type === 'password');
  qblocks[0]?.querySelectorAll('.req-option').forEach(b => b.click());
  if (qblocks[1]?.querySelector('.req-input')) qblocks[1].querySelector('.req-input').value = '口令';
  const beforeAnswer = requests.length;
  qcard?.querySelector('.req-btn.primary')?.click();
  const qanswer = requests.slice(beforeAnswer).find(r => r.action === 'answerAgentRequest');
  check('ME 按题目 id 交回答案', qanswer?.answers?.first === '左、右' && qanswer?.answers?.second === '口令', qanswer);
  window.onAgentRequestClosed({agent:qid, reqId:qrun.reqId, requestId:'me-q'});
  window.onAgentResponse({agent:qid, reqId:qrun.reqId, conversationId:S[qid].conversationId, reply:'ok'});

