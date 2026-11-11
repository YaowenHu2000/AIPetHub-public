// 不用 CLI：角色舞台和预览面板拆成多个文件后还都在——每位桌宠的方法齐全、动作 / 散步 / 小憩 / 拖拽 / 说话正常；预览能开文件、能开网页。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const out = { steps: [] };
const note = (k, v) => { out.steps.push(k + ' = ' + JSON.stringify(v)); };
try {
  const need = ['showFrame', 'startBusyLoop', 'startStateLoop', 'setState', 'say', 'particles', 'headpat', 'syncBusyState', 'setBusy', 'celebrate', 'renderStatus', 'applySkin',
    'turn', 'bounds', 'startDrag', 'endDrag', 'land', 'step', 'toggleRoam', 'goToSleep', 'toggleSleep', 'sleepTick', 'tick', 'frameSrc', 'moodEvent'];
  note('每位桌宠缺的方法', AGENT_IDS.map(id => need.filter(n => typeof pets[id][n] !== 'function')).flat());
  const errors = [];
  window.addEventListener('error', e => errors.push(e.message));
  for (const id of AGENT_IDS) {
    const p = pets[id];
    p.say('你好', 800);
    p.setBusy(true); await sleep(300);
    const busy = p.state;
    p.setBusy(false); await sleep(300);
    p.startDrag(); await sleep(350);
    const dragging = p.state;
    p.endDrag(); await sleep(900);
    p.toggleRoam(); await sleep(700);
    const roaming = p.state;
    p.toggleRoam(); await sleep(300);
    p.toggleSleep(); await sleep(2600);
    const sleeping = p.state;
    p.toggleSleep(); await sleep(1500);
    p.celebrate(); await sleep(400);
    note(id, { busy, dragging, roaming, sleeping, after: p.state });
  }
  // 卡片下面只有散步、小憩（预览动作点右上角的状态）；点桌宠 = 和这一位开一个不绑定工作空间的新对话
  note('卡片下面的按钮', [...pets.claude.card.querySelectorAll('.dock-btn')].map(b => b.textContent.trim()));
  pets.claude.statusEl.click(); await sleep(200);
  note('点右上角的状态预览动作', pets.claude.demoPhase);
  setActive('claude'); setWorkspace('gemini', REPO, false);
  pets.gemini.justDragged = false; pets.gemini.body.click(); await sleep(300);
  note('点桌宠之后', { 选中: active, 工作空间: S.gemini.workspace, 会话: S.gemini.conversationId, 左栏有新对话: !!histSections.gemini.list.querySelector('.conv-row.pending') });
  note('思考强度的名字', AGENTS.gpt.efforts.map(e => e.name));
  note('模型菜单里的标签', AGENT_IDS.flatMap(id => AGENTS[id].models.map(m => m.tag)).filter(Boolean));
  for (let i = 0; i < 6; i++) { AGENT_IDS.forEach(id => pets[id].tick()); await sleep(100); }
  postNative('testSnapshot', { path: DIR + '/stage.png' }); await sleep(600);
  // 预览面板
  openPreview({ path: REPO + '/keep.txt', base: '', diff: '@@ -1 +1,2 @@\n hello\n+world' });
  await sleep(1500);
  note('预览里的代码行数', document.querySelectorAll('.ed-code .cl').length);
  note('预览标签', [...document.querySelectorAll('.ed-tab-name')].map(e => e.textContent));
  openBrowser(PAGE);
  await sleep(2500);
  note('内置浏览器的地址', browser.url || browser.file);
  note('标签', [...document.querySelectorAll('.ed-tab-name')].map(e => e.textContent));
  postNative('testSnapshot', { path: DIR + '/preview.png' }); await sleep(600);
  note('这期间的脚本报错', errors);
} catch (e) { out.error = String(e && e.message || e) + ' ' + (e.stack || '').split('\n')[1]; }
return out;
