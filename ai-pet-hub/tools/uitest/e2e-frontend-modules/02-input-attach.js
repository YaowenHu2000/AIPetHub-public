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
  // WL：从「添加 AI」重看引导页不点权限就关，按高亮项给最高权限（用户定的）、不能把移除的 AI 加回来；首次检测没回来就点「开始使用」，名单等检测结果再定
  {
    const wlKeys = ['enabled_agents', 'welcomed', 'section_weights', ...ALL_AGENT_IDS.map(a => `${a}_perm`)];
    const wlLs = Object.fromEntries(wlKeys.map(k => [k, lsGet(k)]));
    const wlPerm = Object.fromEntries(ALL_AGENT_IDS.map(a => [a, S[a].perm]));
    const wlProbe = { ...agentProbe }, wlAgents = AGENT_IDS.slice();
    const probeAll = found => window.onAgentsProbed({ items: ALL_AGENT_IDS.map(a => ({ agent: a, found: found.includes(a), path: '' })) });
    try {
      ALL_AGENT_IDS.forEach(a => { agentProbe[a] = { found: true, path: '' }; });
      AGENT_IDS.splice(0, AGENT_IDS.length, 'gemini', 'gpt'); afterAgentsChanged(); setActive('gemini', false);
      S.gpt.perm = 'read-only'; lsSet('gpt_perm', 'read-only'); lsSet('welcomed', '1');
      openWelcome();
      const wlNote = welcome.querySelector('.wl-note').textContent;
      check('WL 重看引导页底部提示不说会按检测结果启用', !wlNote.includes('会启用') && wlNote.includes('启用名单不变'), wlNote);
      welcome.querySelector('.wl-go').click();
      check('WL 重看引导页不点权限直接开始使用，Codex 回到最高权限', S.gpt.perm === AGENTS.gpt.perm && lsGet('gpt_perm') === AGENTS.gpt.perm, [S.gpt.perm, lsGet('gpt_perm')]);
      check('WL 重看引导页不把移除的 Claude 加回来', AGENT_IDS.join() === 'gemini,gpt' && lsGet('enabled_agents') === JSON.stringify(['gemini', 'gpt']), [AGENT_IDS.slice(), lsGet('enabled_agents')]);
      openWelcome(); welcome.querySelector('.wl-opt[data-safe="1"]').click(); welcome.querySelector('.wl-go').click();
      check('WL 重看引导页主动点保守仍然生效', S.gpt.perm === AGENTS.gpt.safePerm && lsGet('gpt_perm') === AGENTS.gpt.safePerm, [S.gpt.perm, lsGet('gpt_perm')]);

      // 全新设置：检测还在找时点「开始使用」，晚到的「只找到 Claude」决定名单
      lsSet('enabled_agents', ''); lsSet('welcomed', '');
      AGENT_IDS.splice(0, AGENT_IDS.length, 'gemini', 'claude', 'gpt'); afterAgentsChanged(); lsSet('enabled_agents', '');
      ALL_AGENT_IDS.forEach(a => delete agentProbe[a]);
      openWelcome(); welcome.querySelector('.wl-go').click();
      probeAll(['claude']);
      check('WL 检测没回来就开始使用，名单按晚到的检测结果保存', AGENT_IDS.join() === 'claude' && lsGet('enabled_agents') === JSON.stringify(['claude']) && lsGet('welcomed') === '1', [AGENT_IDS.slice(), lsGet('enabled_agents'), lsGet('welcomed')]);
    } finally {
      welcome.hidden = true;
      ALL_AGENT_IDS.forEach(a => { delete agentProbe[a]; if (wlProbe[a]) agentProbe[a] = wlProbe[a]; S[a].perm = wlPerm[a]; });
      AGENT_IDS.splice(0, AGENT_IDS.length, ...wlAgents); afterAgentsChanged(); setActive(id, false);
      wlKeys.forEach(k => lsSet(k, wlLs[k])); renderComposer();
    }
  }
  // @ 文件补全：候选出来后光标被点走，再按 Tab 不能拿旧起点和新光标拼接吞掉后半句；光标还在 @词 上时只换掉 @词
  // 引导页移焦时的候选关闭回调可能仍在排队；等本次失焦收尾再开始补全用例。
  els.input.focus();
  const beforeBlur = suggest.seq;
  els.input.blur();
  await until(() => suggest.seq > beforeBlur, '引导页失焦已收尾');
  els.input.focus();
  const mnWs = S[id].workspace, mnInput = els.input.value;
  S[id].workspace = '/fixture/mn';
  const mnText = '检查 @kee 后保留这段说明', mnEnd = mnText.indexOf('@kee') + 4, mnDone = '检查 keep.txt  后保留这段说明';
  const mnShow = async () => {
    const n = requests.length;
    els.input.value = mnText; els.input.selectionStart = els.input.selectionEnd = mnEnd; els.input.dispatchEvent(new Event('input'));
    const r = await until(() => requests.slice(n).find(x => x.action === 'listFiles'), 'MN @ 文件请求');
    window.onFilesListed({reqId: r.reqId, files: ['keep.txt']});
    return suggest.items[0]?.name === 'keep.txt' && !suggest.el.hidden;
  };
  const mnTab = () => suggestKey(new KeyboardEvent('keydown', {key: 'Tab', cancelable: true}));
  const mnSaved = text => saved(id, text).then(() => true, () => false);
  let mnShown = await mnShow();
  els.input.selectionStart = els.input.selectionEnd = mnText.length; mnTab();
  check('MN 光标移到句末后按 Tab 不吞后半句、关掉候选', mnShown && els.input.value === mnText && await mnSaved(mnText) && suggest.el.hidden,
    {shown: mnShown, value: els.input.value, saved: lsGet(`${id}_draft`), hidden: suggest.el.hidden});
  mnShown = await mnShow(); mnTab();
  check('MN 光标仍在 @词 末尾时正常补全且保留后半句', mnShown && els.input.value === mnDone && await mnSaved(mnDone),
    {shown: mnShown, value: els.input.value, saved: lsGet(`${id}_draft`)});
  mnShown = await mnShow();
  els.input.selectionStart = els.input.selectionEnd = mnEnd - 1; mnTab();
  check('MN 光标移到 @词 中间时只换掉整个 @词', mnShown && els.input.value === mnDone && await mnSaved(mnDone),
    {shown: mnShown, value: els.input.value, saved: lsGet(`${id}_draft`)});
  // 打 @ 也会触发预热，Codex、Gemini 起好后紧跟着报模型列表；检测结果晚到时也重画选择器。
  // 这两种同一位的重画不能关掉正在等的请求或已经显示的候选（之前候选闪一下就没了，再不重发）
  {
    const mrKeys = [`${id}_models`, `${id}_model`, `${id}_effort`], mrLs = Object.fromEntries(mrKeys.map(k => [k, lsGet(k)]));
    const mrModels = AGENTS[id].models, mrModel = S[id].model, mrEffort = S[id].effort;
    const redraw = () => {
      window.onAgentModels({agent: id, complete: false, models: [...mrModels.map(m => ({v: m.v, name: m.name, desc: m.tip, efforts: m.efforts, fast: m.fast})), {v: 'mr-extra', name: 'MR'}]});
      setActive(id, false);
    };
    const n = requests.length;
    els.input.value = mnText; els.input.selectionStart = els.input.selectionEnd = mnEnd; els.input.dispatchEvent(new Event('input'));
    redraw();
    const r = await until(() => requests.slice(n).find(x => x.action === 'listFiles'), 'MR @ 文件请求').catch(() => null);
    if (r) window.onFilesListed({reqId: r.reqId, files: ['keep.txt']});
    const shownBefore = !!r && !suggest.el.hidden;
    AGENTS[id].models = mrModels.filter(m => m.v !== 'mr-extra'); redraw();
    check('MR 同一位重画选择器不关 @ 候选（等着的照发、显示着的还在）', shownBefore && suggest.items[0]?.name === 'keep.txt' && !suggest.el.hidden,
      {requested: !!r, shownBefore, items: suggest.items, hidden: suggest.el.hidden});
    AGENTS[id].models = mrModels; S[id].model = mrModel; S[id].effort = mrEffort;
    mrKeys.forEach(k => lsSet(k, mrLs[k])); closeSuggest(); renderComposer();
  }
  S[id].workspace = mnWs; setDraft(id, mnInput);
