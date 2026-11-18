// 不用 CLI：外部会话运行标记、收起后的补充、文件链接/预览、桌宠状态、栏位收放、原生窗口点击。
// REAL=1 tools/uitest/run.sh claude e2e-ui.js
const {out, check, note, until, finish} = makeSuite('ui');
const errors = [];
const onError = e => errors.push(e.message);
window.addEventListener('error', onError);
const section = async (name, fn) => { try { await fn(); } catch (e) { check(name, false, String(e.message || e) + '\n' + String(e.stack || '')); } };
const pathKey = path => String(path || '').replace(/^\/private(?=\/var\/)/, '');
const shown = el => !!el && el.getClientRects().length > 0;
const id = 'claude', box = S[id].msgEl;
setActive(id, false); prewarm = () => {};

await section('别处运行中', async () => {
  renderMessages(id, [{role:'user',text:'问题'}, {role:'bot',text:'中途说明',duration:335,steps:[{kind:'think',title:'思考',status:'done'},{kind:'command',title:'运行命令',status:'done',detail:'ls'}]}], '');
  const label = () => box.querySelector('.work-label')?.textContent, before = label();
  S[id].elsewhereAt = Date.now(); markElsewhere(id);
  const work = box.querySelector('.work');
  check('外部运行标记出现', work.classList.contains('elsewhere') && label().startsWith('在别处运行中'), label());
  check('计时从历史时长继续', label() === '在别处运行中 · 已 5 分 35 秒', label());
  await until(() => { if (document.hidden) markElsewhere(id); return label() !== '在别处运行中 · 已 5 分 35 秒'; }, 4000, '外部运行计时增加');
  check('外部运行计时递增', /在别处运行中 · 已 5 分 (3[6-9]|[4-5]\d) 秒/.test(label()), label());
  // 桌宠跟着动：最后一步已做完 → 在想下一步；状态里写明在别处
  const petStatus = () => pets[id].statusEl.textContent;
  check('别处运行时桌宠在忙', petBusy(id) && pets[id].state === 'thinking' && petStatus().startsWith('在别处 · 思考中'), { state: pets[id].state, status: petStatus() });
  renderMessages(id, [{role:'user',text:'问题'}, {role:'bot',text:'',duration:335,steps:[{kind:'think',title:'思考',status:'done'},{kind:'command',title:'运行命令',status:'running',detail:'sleep 60'}]}], '');
  markElsewhere(id);
  check('别处正在跑命令时桌宠施工', pets[id].state === 'working' && petStatus().startsWith('在别处 · 施工中'), { state: pets[id].state, status: petStatus() });
  // 那边又写了一步：这一轮的节点被换成新的，记录里的时长还是 335 秒。计时不能跳回 5 分 35 秒；
  // 记录末尾那条「未完成」是因为它还在写，标着的时候不显示。
  const beforeSwap = label();
  renderMessages(id, [{role:'user',text:'问题'}, {role:'bot',text:'',duration:335,steps:[{kind:'think',title:'思考',status:'done'},{kind:'command',title:'运行命令',status:'done',detail:'ls'},{kind:'command',title:'运行命令',status:'done',detail:'pwd'},{kind:'error',title:'未完成',status:'error',detail:'记录到这里就断了，这一轮还没写完。'}]}], '');
  markElsewhere(id);
  check('节点换了计时不跳回去', label() !== '在别处运行中 · 已 5 分 35 秒' && label() >= beforeSwap, { beforeSwap, after: label() });
  const pendingStep = [...box.querySelectorAll('.work-steps > .step')].pop();
  check('还在别处写着时不显示「未完成」', !shown(pendingStep) && pendingStep.querySelector('.step-title').textContent === '未完成', pendingStep.className);
  S[id].elsewhereAt = 0; markElsewhere(id);
  box.querySelector('.work').classList.add('open');
  check('撤掉标记后「未完成」重新显示', shown([...box.querySelectorAll('.work-steps > .step')].pop()), null);
  box.querySelector('.work').classList.remove('open');
  S[id].elsewhereAt = Date.now(); markElsewhere(id);
  S[id].elsewhereAt = 0; markElsewhere(id);
  check('结束后撤掉标记并恢复标题', !box.querySelector('.work.elsewhere') && label() === before, label());
  check('结束后桌宠不再忙', !petBusy(id) && !BUSY_STATES.has(pets[id].state), { state: pets[id].state, status: pets[id].statusEl.textContent });
  renderOneMessage(id, {role:'user',text:'又问了一句'}, undefined, '');
  S[id].elsewhereAt = Date.now(); markElsewhere(id);
  check('后面有新提问时不标旧回答', !box.querySelector('.work.elsewhere'), label());
  S[id].elsewhereAt = 0; markElsewhere(id);
});

await section('补充的可见性', async () => {
  renderMessages(id, [{role:'user',text:'第一问'}, {role:'bot',text:'答一',duration:30,steps:[{kind:'command',title:'运行命令',status:'done',detail:'ls'},{kind:'user',title:'你补充说',status:'done',detail:'中途补的一句'},{kind:'think',title:'思考',status:'done'}]}, {role:'user',text:'第二问'}, {role:'bot',text:'答二',duration:5,steps:[{kind:'command',title:'运行命令',status:'done',detail:'pwd'}]}], '');
  const works = [...box.querySelectorAll('.work')], [withSteer, plain] = works;
  check('两轮默认收起', works.length === 2 && works.every(w => !w.classList.contains('open')), works.length);
  check('收起时仍显示自己的补充', shown(withSteer.querySelector('.step-user')), withSteer.querySelector('.step-user-text')?.textContent);
  check('收起时隐藏其他步骤', [...withSteer.querySelectorAll('.work-steps > .step:not(.step-user)')].every(s => !shown(s)));
  check('没有补充时隐藏整个步骤列表', !shown(plain.querySelector('.work-steps')));
  withSteer.querySelector('.work-head').click();
  await until(() => [...withSteer.querySelectorAll('.work-steps > .step')].every(shown), 2000, '工作步骤展开');
  check('展开后所有步骤可见', withSteer.querySelectorAll('.work-steps > .step').length === 3 && [...withSteer.querySelectorAll('.work-steps > .step')].every(shown));
});

await section('文件链接与预览', async () => {
  closePreview(); box.innerHTML = '';
  const text = '文件在 `' + DIR + '/`：\n\n- page.html\n- red.png\n- 没有这个文件.md\n\n另外打开keep.txt看看，Node.js 不是文件，`keep.txt` 和 `nothing.md` 写在代码里。';
  const turn = renderTurn({text,steps:[],files:[]}, REPO); box.appendChild(turn);
  const before = turn.querySelector('.answer').textContent;
  note('核对前的文件候选', [...turn.querySelectorAll('.file-maybe')].map(e => e.textContent));
  verifyFileChips(turn, REPO);
  await until(() => ['page.html', 'red.png', 'keep.txt'].every(name => [...turn.querySelectorAll('.file-chip')].some(c => c.textContent === name)), 6000, '真实文件核对');
  const chips = [...turn.querySelectorAll('.file-chip')];
  check('文件名在前文目录或工作区中正确解析', chips.some(c => c.textContent === 'page.html' && pathKey(c.dataset.path) === pathKey(DIR + '/page.html')) && chips.some(c => c.textContent === 'red.png' && pathKey(c.dataset.path) === pathKey(DIR + '/red.png')) && chips.some(c => c.textContent === 'keep.txt' && pathKey(c.dataset.path) === pathKey(REPO + '/keep.txt')), chips.map(c => ({name:c.textContent,path:c.dataset.path})));
  check('不存在的文件和 Node.js 不成为文件链接', !chips.some(c => ['没有这个文件.md','nothing.md','Node.js'].includes(c.textContent)), chips.map(c => c.textContent));
  check('核对不改变回答文字', turn.querySelector('.answer').textContent === before, turn.querySelector('.answer').textContent);
  chips.find(c => c.textContent === 'keep.txt').click();
  await until(() => document.querySelector('.ed-code .cl'), 6000, 'keep.txt 预览内容');
  check('点击文件链接显示代码与标签', [...document.querySelectorAll('.ed-tab-name')].some(e => e.textContent === 'keep.txt') && document.querySelector('.ed-code')?.textContent.includes('hello'), document.querySelector('.ed-code')?.textContent);
  chips.find(c => c.textContent === 'page.html').click();
  await until(() => [...document.querySelectorAll('.ed-tab-name')].some(e => e.textContent === 'page.html'), 4000, 'page.html 预览标签');
  check('点击另一个文件保留两个标签', ['keep.txt','page.html'].every(name => [...document.querySelectorAll('.ed-tab-name')].some(e => e.textContent === name)));
});

await section('桌宠状态和入口', async () => {
  closePreview(); setStageHidden(false);
  const need = ['showFrame','startBusyLoop','startStateLoop','setState','say','particles','headpat','syncBusyState','setBusy','celebrate','renderStatus','applySkin','turn','bounds','startDrag','endDrag','land','step','toggleRoam','goToSleep','toggleSleep','sleepTick','tick','frameSrc','moodEvent'];
  check('各桌宠的模块方法齐全', AGENT_IDS.every(a => need.every(n => typeof pets[a][n] === 'function')), AGENT_IDS.map(a => ({agent:a,missing:need.filter(n => typeof pets[a][n] !== 'function')})));
  for (const a of AGENT_IDS) {
    const p = pets[a];
    p.say('你好', 800); check(a + ' 说话显示气泡', p.bubbleEl.classList.contains('show') && p.bubbleEl.textContent === '你好');
    p.setBusy(true); check(a + ' 忙碌进入工作状态', BUSY_STATES.has(p.state), p.state);
    p.setBusy(false); check(a + ' 空闲退出工作状态', !BUSY_STATES.has(p.state), p.state);
    p.startDrag(); check(a + ' 拖拽进入拖动状态', p.dragging && p.state === 'dragged', p.state);
    p.endDrag(); await until(() => !p.dragging && !p.falling, 4000, a + ' 松手落地');
    check(a + ' 松手清除拖动状态', !p.card.classList.contains('dragging') && p.state !== 'dragged', p.state);
    if (S[a].roam) p.toggleRoam(); p.toggleRoam();
    check(a + ' 散步开关进入行走状态', S[a].roam && p.state === 'walk', p.state);
    p.toggleRoam(); check(a + ' 关闭散步恢复空闲', !S[a].roam && p.state !== 'walk', p.state);
    p.toggleSleep(); await until(() => p.state === 'sleep', 10000, a + ' 入睡'); check(a + ' 小憩进入睡眠', p.state === 'sleep');
    p.toggleSleep(); check(a + ' 再点小憩醒来', p.state !== 'sleep', p.state);
    p.celebrate(); check(a + ' 完成反馈可触发', p.state === 'happy', p.state);
  }
  check('桌宠卡片提供散步和小憩入口', pets.claude.card.querySelectorAll('.dock-btn').length === 2, [...pets.claude.card.querySelectorAll('.dock-btn')].map(b => b.textContent.trim()));
  pets.claude.statusEl.click(); check('状态入口可预览动作', !!pets.claude.demoPhase, pets.claude.demoPhase);
  setActive('claude', false); setWorkspace('gemini', REPO, false);
  pets.gemini.justDragged = false; pets.gemini.body.click();
  check('点桌宠切换并开启无工作区新会话', active === 'gemini' && !S.gemini.workspace && !S.gemini.conversationId && !!histSections.gemini.list.querySelector('.conv-row.pending'), {active,workspace:S.gemini.workspace,conversation:S.gemini.conversationId});
  setActive(id, false);
  openPreview({path:REPO + '/keep.txt',base:'',diff:'@@ -1 +1,2 @@\n hello\n+world'});
  await until(() => document.querySelector('.ed-code .cl'), 5000, '改动预览'); check('改动预览显示代码行', document.querySelectorAll('.ed-code .cl').length > 0);
  openBrowser(PAGE); await until(() => pathKey(browser.file) === pathKey(PAGE) || browser.url === PAGE, 5000, '打开网页');
  check('内置浏览器打开指定测试页', pathKey(browser.file) === pathKey(PAGE) || browser.url === PAGE, {file:browser.file,url:browser.url});
  closePreview();
});

await section('栏位收放', async () => {
  setSidebarHidden(false); setStageHidden(false); closePreview();
  const stageHidden = () => document.body.classList.contains('stage-hidden'), sideHidden = () => document.body.classList.contains('sidebar-hidden');
  const btn = document.querySelector('#chat-header .btn-stage-toggle');
  btn.click(); check('聊天栏开关收起舞台并保存', stageHidden() && lsGet('stage_hidden') === '1');
  btn.click(); check('再点开关展开舞台并保存', !stageHidden() && lsGet('stage_hidden') !== '1');
  openBrowser(PAGE); await until(() => !pane.el.hidden, 3000, '预览打开');
  const paneBtn = document.querySelector('#preview-pane .btn-stage-toggle');
  check('打开预览后开关转移到预览面板', !shown(btn) && shown(paneBtn));
  paneBtn.click(); check('预览面板开关可收起舞台', stageHidden()); paneBtn.click(); closePreview();
  check('关闭预览后聊天栏开关恢复', shown(btn));
  const fire = (el, type, x) => el.dispatchEvent(new PointerEvent(type, {bubbles:true,button:0,clientX:x,clientY:300,pointerId:1}));
  for (const [name, selector, side, width] of [['舞台','#resize-stage',1,els.stage.getBoundingClientRect().width],['历史栏','#resize-sidebar',-1,els.sidebar.getBoundingClientRect().width]]) {
    const bar = document.querySelector(selector), x = bar.getBoundingClientRect().left + 2;
    const hidden = side === 1 ? stageHidden : sideHidden;
    fire(bar,'pointerdown',x); fire(bar,'pointermove',x + side * (width - 40));
    check(name + ' 拖到底可暂时收起', hidden());
    fire(bar,'pointermove',x + side * 10); check(name + ' 未松手拖回来可展开', !hidden());
    fire(bar,'pointermove',x + side * (width - 10)); fire(bar,'pointerup',x + side * (width - 10));
    check(name + ' 松手后保存收起状态', hidden() && lsGet(side === 1 ? 'stage_hidden' : 'sidebar_hidden') === '1');
    (side === 1 ? btn : document.getElementById('btn-show-sidebar')).click(); check(name + ' 展开按钮恢复栏位', !hidden());
  }
});

await section('原生窗口点击', async () => {
  closePreview(); closePopover(); setSidebarHidden(false); setStageHidden(false); setActive(id, false);
  const click = async (el, condition, name) => {
    // 原生 testClick 分开派发 down/up；必须等上一击 mouseup，不能在聚焦的 down 阶段就发下一击。
    let released = false; const onUp = () => { released = true; };
    document.addEventListener('mouseup', onUp, true);
    try { const r = el.getBoundingClientRect(); postNative('testClick',{x:r.left+r.width/2,y:r.top+r.height/2}); await until(() => released && condition(), 3000, name); check(name, !!condition()); }
    finally { document.removeEventListener('mouseup', onUp, true); }
  };
  const search = document.getElementById('hist-search');
  await click(search, () => document.activeElement === search, '原生点击搜索框可以聚焦'); search.blur();
  await click(document.getElementById('btn-browser'), () => !pane.el.hidden, '原生点击浏览器按钮打开预览'); closePreview();
  await click(document.getElementById('btn-hide-sidebar'), () => document.body.classList.contains('sidebar-hidden'), '原生点击收起历史栏');
  await click(document.getElementById('btn-show-sidebar'), () => !document.body.classList.contains('sidebar-hidden'), '原生点击展开历史栏');
  await click(els.chipModel, () => !els.popover.hidden, '原生点击模型按钮打开菜单'); closePopover();
});
check('交互期间没有脚本异常', errors.length === 0, errors);
window.removeEventListener('error', onError);
return finish();
