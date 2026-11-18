// 不用 CLI：输入草稿/建议、会话导航、预览标签与窄窗恢复、AI 增删。
// tools/uitest/run.sh claude e2e-frontend-modules.js
const sleep = ms => new Promise(r => setTimeout(r, ms));
const {out, check, until, finish} = makeSuite('frontend-modules');
const saved = (id, text) => until(() => lsGet(`${id}_draft`, '') === text, 2000, '草稿落盘：' + text);
const quiet = async (count, ms = 700) => { const at = Date.now(), n = count(); while (Date.now() - at < ms) { if (count() !== n) return false; await sleep(25); } return true; };
try {
  const native = postNative, requests = [];
  postNative = (action, data) => { requests.push({action, ...data}); if (action === 'testResize') native(action, data); };
  const type = value => { els.input.value = value; els.input.selectionStart = els.input.selectionEnd = value.length; els.input.dispatchEvent(new Event('input')); };
  const id = active, other = AGENT_IDS.find(a => a !== id);
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
  check('A 已打开会话仍按深处命中重新定位', requests.slice(beforeSearchOpen).some(r=>r.action==='loadConversation' && r.conversationId===distant.id && r.limit===5300));
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
  // 预热去重只管打字期间：发送时原生已经取走了预热的进程，答完后同样设置的下一次预热不能被「60 秒内预热过」跳过
  const warms = () => requests.filter(r => r.action === 'prewarmAgent' && r.agent === id).length;
  warmSig = ''; prewarm(id); const w1 = warms(); prewarm(id);
  check('P 同样设置 60 秒内不重复预热', warms() === w1, warms() - w1);
  noteSent(); prewarm(id);
  check('P 发送后下一次预热照常发出', warms() === w1 + 1, warms() - w1);
  // 文件附件：拖进来的 zip 和图片都成卡片，不往输入框插路径；发送时图片单独交给模型，其他文件的路径附在话后面
  const savedAttach = S[id].attach, savedInput = els.input.value;
  S[id].attach = []; els.input.value = '看看这个';
  window.onFilesDropped({ paths: ['/tmp/资料 包.zip', '/tmp/red.png'] });
  check('A 拖进的 zip 和图片都成附件卡片', document.querySelectorAll('.attach-chip').length === 2 && els.input.value === '看看这个', { chips: document.querySelectorAll('.attach-chip').length, input: els.input.value });
  const out = attachmentsForSend('看看这个', ['/tmp/资料 包.zip', '/tmp/red.png']);
  check('A 发送时图片单独给模型，文件路径附在话后', out.images.join() === '/tmp/red.png' && out.text === '看看这个\n\n附件：\n/tmp/资料 包.zip', out);
  check('A 只有文件没有话时也能发', attachmentsForSend('', ['/tmp/a.zip']).text === '附件：\n/tmp/a.zip');
  check('A 输入框旁有选文件按钮', !!document.getElementById('attach-btn'));
  S[id].attach = savedAttach; els.input.value = savedInput; renderAttachments();
  // 重开会话：结局是已中断或出错的那一轮也要有「重试」（和实时时一样），正常完成的没有
  renderMessages(id, [{role:'user',text:'数到 400'}, {role:'bot',text:'1 2 3',outcome:'interrupted',steps:[]},
    {role:'user',text:'你好'}, {role:'bot',text:'',outcome:'failed',steps:[{kind:'error',title:'出错',status:'error',detail:'API Error: 400'}]},
    {role:'user',text:'再来'}, {role:'bot',text:'好的',outcome:'completed',steps:[]}], '');
  const turnsShown = [...S[id].msgEl.querySelectorAll('.msg.bot.turn')];
  check('RT 重开后已中断和出错的轮次有重试，完成的没有', turnsShown.map(t => !!t.querySelector('.answer-copy.retry')).join() === 'true,true,false',
    turnsShown.map(t => !!t.querySelector('.answer-copy.retry')));
  // 点「立即发送」后 CLI 在停下前已经收下并答了这句补充：这一轮结束后不再重发（不然同一句答两遍）；收下了还没答的照常重发
  const jumpRun = { reqId: 'jump-req', agent: id, view: 'jump-view', nodes: [], queue: [], live: { steps: [] } };
  const jumpEl = document.createElement('div'); jumpEl.innerHTML = '<span class="queued-state"></span>';
  const jumpItem = { sid: 'sq-jump', text: '改答 2+3', images: [], state: 'sent', jump: true, el: jumpEl, run: jumpRun };
  jumpRun.queue.push(jumpItem); S[id].runs.set(jumpRun.reqId, jumpRun);
  window.onAgentSteer({ agent: id, reqId: jumpRun.reqId, steerId: jumpItem.sid, state: 'consumed' });
  const beforeJump = requests.length, inputBeforeJump = els.input.value;
  flushQueue(id, jumpRun, { cancelled: true, steps: [{ kind: 'command', title: 'cat gate' }, { kind: 'user', detail: '改答 2+3' }, { kind: 'text', detail: '5' }] });
  check('S 立即发送的补充停下前已答过，不再发一遍', !requests.slice(beforeJump).some(r => r.action === 'askAgent') && !jumpRun.queue.length && els.input.value === inputBeforeJump,
    { sent: requests.slice(beforeJump).map(r => r.action), queue: jumpRun.queue.length, input: els.input.value });
  check('S 收下了还没来得及答的照常重发', !answeredBeforeStop({ ...jumpItem, consumed: true }, [{ kind: 'user', detail: '改答 2+3' }]));
  S[id].runs.delete(jumpRun.reqId);
  // 附件跟草稿一起留到重开 App；一次附超过 8 个时只对真正附上的报成功，多出来的明说没附上
  const atSay = pets[id].say, atSaid = []; pets[id].say = text => { atSaid.push(text); };
  const atChips = () => document.querySelectorAll('.attach-chip').length;
  S[id].attach = []; renderAttachments();
  window.onFilesDropped({ paths: ['/tmp/at-a.zip', '/tmp/at-b.zip'] });
  S[id].attach = []; renderAttachments();   // 重新载入界面：内存里的附件没了，只剩本地存下的
  if (typeof loadAttachments === 'function') loadAttachments(id);
  renderAttachments();
  check('AT 重新载入后附件卡片还在', atChips() === 2 && (S[id].attach || []).map(a => a.path).join() === '/tmp/at-a.zip,/tmp/at-b.zip', { chips: atChips(), saved: lsGet(`${id}_attach`) });
  document.querySelector('.attach-chip .attach-x')?.click();
  check('AT 移除附件后存下的也跟着少', lsJson(`${id}_attach`, []).join() === '/tmp/at-b.zip', lsGet(`${id}_attach`));
  takeAttachments(id);
  check('AT 发送取走附件后存下的清空', !lsJson(`${id}_attach`, []).length, lsGet(`${id}_attach`));
  const atNine = Array.from({ length: 9 }, (_, i) => `/tmp/at-${i}.zip`);
  window.onFilesDropped({ paths: atNine });
  check('AT 一次附 9 个：卡片 8 张，提示说附上 8 个、1 个没附上', atChips() === 8 && /附上了 8 个文件/.test(atSaid.at(-1)) && /1 个没附上/.test(atSaid.at(-1)), { chips: atChips(), said: atSaid.at(-1) });
  window.onFilesDropped({ paths: ['/tmp/at-extra.zip'] });
  check('AT 已满 8 个再加一个不报成功', atChips() === 8 && !/附上了/.test(atSaid.at(-1)) && /1 个没附上/.test(atSaid.at(-1)), { chips: atChips(), said: atSaid.at(-1) });
  pets[id].say = atSay; takeAttachments(id);
  // 地址栏：带主机或端口的输入即使以 .html/.pdf 结尾也是网址；真正的相对路径仍按本地文件
  const opened = input => { const at = requests.length; navigateBrowser(input, '/fixture/ws'); return requests.slice(at).find(r => r.action === 'browserOpen') || {}; };
  const asURL = { 'localhost:5173/index.html': 'http://localhost:5173/index.html', '127.0.0.1:8080/a.pdf': 'http://127.0.0.1:8080/a.pdf',
    'example.org/guide.pdf': 'https://example.org/guide.pdf', 'localhost:5173': 'http://localhost:5173' };
  const asPath = ['index.html', 'docs/a.pdf', './x.html', '/abs/path.html', 'src/page.html', 'readme.md/x.html'];
  const wrongURL = Object.entries(asURL).filter(([t, u]) => opened(t).url !== u).map(([t]) => [t, opened(t)]);
  const wrongPath = asPath.filter(t => opened(t).path !== t).map(t => [t, opened(t)]);
  check('BR 带主机的地址栏输入按网址打开', wrongURL.length === 0, wrongURL);
  check('BR 相对和绝对路径仍按本地文件打开', wrongPath.length === 0, wrongPath);
  // 回答里的文件标签、改动行点开的文档一定是本地文件：目录名像域名（en.lproj、user.github.io）也不能当网址
  const previewed = path => { const at = requests.length; openPreview({ path, base: '/fixture/ws' }); return requests.slice(at).find(r => r.action === 'browserOpen') || {}; };
  const docPaths = ['en.lproj/Guide.pdf', 'user.github.io/cv.pdf', 'Foo.bundle/a.docx', 'Docs.docc/slides.pptx'];
  const wrongDoc = docPaths.filter(p => previewed(p).path !== p).map(p => [p, previewed(p)]);
  closePreview();
  check('BR 文件标签打开的文档不按域名判成网址', wrongDoc.length === 0, wrongDoc);
  showEmpty(id);
  S[id].taskOverrides = savedOverrides; S[id].groupState = savedGroupState;
  S[id].conversations = savedConversations; S[id].conversationId = savedConversationId; S[id].loadedId = savedLoadedId;
  renderHistory(id); showEmpty(id);
  // SV：SVG 图片显示出来以后，工具栏里仍能切到内置浏览器看；PNG 不出现这个按钮。
  {
    const oldRead = readLocalFile, pixel = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';
    readLocalFile = async path => ({path, image: pixel, size: 68});
    const globe = () => [...pane.el.querySelectorAll('.ed-bar .ed-tool')].some(b => b.title === '在内置浏览器中预览');
    closePreview(); openPreview({path:'/sv-fixture/icon.svg',base:''});
    await until(() => activeTab()?.data && pane.el.querySelector('.ed-image img'), 2000, 'SVG 预览显示图片');
    check('SV SVG 图片显示后仍有内置浏览器预览按钮', globe(), pane.el.querySelector('.ed-bar')?.innerHTML);
    openPreview({path:'/sv-fixture/icon.png',base:''});
    await until(() => activeTab()?.resolved === '/sv-fixture/icon.png' && pane.el.querySelector('.ed-image img'), 2000, 'PNG 预览显示图片');
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
  const request = async (text = '@abc') => { const n = requests.length; type(text); return until(() => requests.slice(n).find(r => r.action === 'listFiles'), 2000, '@ 文件请求'); };
  let req = await request(); type('/com'); window.onFilesListed({reqId:req.reqId,files:['old.js']});
  check('F11 旧文件回调不覆盖命令', suggest.kind === 'slash' && suggest.items[0]?.name === 'compact', {kind:suggest.kind,items:suggest.items});
  req = await request(); S[id].workspace = '/project-B'; window.onFilesListed({reqId:req.reqId,files:['old.js']});
  check('F11 工作区变化拒绝旧结果', !suggest.items.some(x=>x.name==='old.js'), suggest.items);
  req = await request(); setActive(other); window.onFilesListed({reqId:req.reqId,files:['other-old.js']});
  check('F11 切 AI 拒绝旧结果', !suggest.items.some(x=>x.name==='other-old.js'), suggest.items); setActive(id);
  req = await request(); type('@abcd'); window.onFilesListed({reqId:req.reqId,files:['older.js']});
  check('F11 新查询防抖期间拒绝旧结果', !suggest.items.some(x=>x.name==='older.js'), suggest.items);
  req = await until(() => requests.filter(r=>r.action==='listFiles').at(-1)?.reqId !== req.reqId && requests.filter(r=>r.action==='listFiles').at(-1), 2000, '新查询请求'); window.onFilesListed({reqId:req.reqId,files:['fresh.js']});
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
  syncJumpNav(); await Promise.resolve(); await until(() => !jumpQueued, 2000, '导航刷新'); syncs = 0;
  check('F12 静止时没有观察器自激', await quiet(() => syncs), syncs);
  const box = S[id].msgEl;
  const fill = label => { box.innerHTML = ''; for (const text of [label+' first',label+' last']) { const el = document.createElement('div'); el.className='msg user'; el.textContent=text; el.style.cssText='height:800px;flex-shrink:0'; box.appendChild(el); } };
  S[id].conversationId = 'conv-alpha'; fill('Alpha'); syncJumpNav();
  S[id].conversationId = 'conv-bravo'; fill('Bravo'); syncJumpNav();
  check('F13 同 AI 等长会话重建提示', jumpRail.children[0]?.dataset.text === 'Bravo first', [...jumpRail.children].map(b=>b.dataset.text));
  await Promise.resolve(); await until(() => !jumpQueued, 2000, '导航刷新'); syncs = 0;
  check('F12 有圆点时也没有自激', await quiet(() => syncs), syncs); syncJumpNav = oldSync;

  const oldRead = readLocalFile;
  readLocalFile = async (path, base) => ({path:base+'/'+path.replace(/^\.\//,''),content:base});
  closePreview(); openPreview({path:'src/a.js',base:'/project-A'}); await until(() => activeTab()?.resolved === '/project-A/src/a.js', 2000, '项目 A 预览');
  openPreview({path:'src/a.js',base:'/project-B'}); await until(() => activeTab()?.resolved === '/project-B/src/a.js', 2000, '项目 B 预览');
  check('F04 不同项目同名相对路径各有标签', pane.tabs.length === 2 && activeTab().base === '/project-B', pane.tabs.map(t=>({base:t.base,resolved:t.resolved})));
  openPreview({path:'src/a.js',base:'/project-A'}); await until(() => activeTab()?.resolved === '/project-A/src/a.js', 2000, '项目 A 预览');
  check('F04 同一项目复用标签', pane.tabs.length === 2 && activeTab().base === '/project-A', pane.tabs.length);
  readLocalFile = oldRead;

  // F16 保留响应式状态切换，去掉固定像素宽度的外观量尺。
  setSidebarHidden(false); setStageHidden(false); document.body.classList.add('preview-max');
  widths.sidebar = COLUMNS.sidebar.min; widths.stage = COLUMNS.stage.min;
  postNative('testResize',{width:600,height:720});
  await until(() => innerWidth <= 600, 3000, '缩窄窗口'); applyWidths();
  check('F16 放不下时收起舞台', document.body.classList.contains('stage-squeezed'), document.body.className);
  postNative('testResize',{width:1400,height:720});
  await until(() => innerWidth >= 1400, 3000, '加宽窗口'); applyWidths();
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
  await until(() => dots().length === 30, 2000, '导航建立');
  check('三十句对应三十个点且只有一个当前项', !jumpRail.hidden && dots().length === 30 && jumpRail.querySelectorAll('.on').length === 1, dots().length);
  await until(() => onAt() === 29, 2000, '导航跟随底部'); check('在底部选中最后一句', onAt() === 29, onAt());
  box.scrollTop = 0; await until(() => onAt() === 0, 2000, '导航跟随顶部'); check('滚到顶部选中第一句', onAt() === 0, onAt());
  dots()[11].click(); await until(() => onAt() === 11, 4000, '点击导航跳转'); check('点第 12 个点跳到第 12 句', onAt() === 11 && box.scrollTop > 0, onAt());
  dots()[11].dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));
  const tip = document.querySelector('.jump-tip');
  await until(() => !tip.hidden, 2000, '导航提示'); check('悬停显示该句开头', tip.textContent.startsWith('第 12 句'), tip.textContent);
  jumpRail.dispatchEvent(new MouseEvent('mouseleave')); check('移开收起提示', tip.hidden, tip.hidden);
  S[other].msgEl.innerHTML = ''; setActive(other, false); syncJumpNav(); check('切到空会话不显示导航', jumpRail.hidden, jumpRail.hidden);

  // 原 agents：本地增删和当前 AI 切换；CLI 的添加验证留在 DeepSeek 套件。
  AGENT_IDS.splice(0, AGENT_IDS.length, 'gemini', 'claude', 'gpt'); afterAgentsChanged(); setActive('claude', false);
  disableAgent('gpt');
  check('移除 AI 同步移除历史区与桌宠', AGENT_IDS.join() === 'gemini,claude' && document.querySelectorAll('.hist-section').length === 2 && document.querySelectorAll('#stage-column .pet-card').length === 2, AGENT_IDS.slice());
  disableAgent('claude');
  check('移除当前 AI 自动切到剩余 AI', active === 'gemini' && document.body.dataset.agent === 'gemini' && !S.gemini.msgEl.hidden && S.claude.msgEl.hidden && S.gpt.msgEl.hidden, active);
  disableAgent('gemini'); check('最后一位不允许移除', AGENT_IDS.join() === 'gemini', AGENT_IDS.slice());
  enableAgent('claude'); enableAgent('gpt');
  check('加回 AI 恢复固定顺序并保存', AGENT_IDS.join() === 'gemini,claude,gpt' && lsGet('enabled_agents') === JSON.stringify(AGENT_IDS), AGENT_IDS.slice());
  check('历史区顺序跟随 AI 名单', [...document.querySelectorAll('.hist-section')].map(x => x.dataset.agent).join() === AGENT_IDS.join(), AGENT_IDS.slice());
} catch (e) { out.error = String(e && e.message ? `${e.message}\n${e.stack || ""}` : e); }   // WebKit 里 eval 脚本的 stack 常常只有「@」，消息要单独记
return finish();
