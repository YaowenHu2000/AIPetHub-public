// 输入与历史：@、/、↑↓、编辑、同步节点身份、正文搜索、模型/用量、更多历史、真实分叉。
// 图片、带图补充、停止后同步在 e2e-images-stop.js；上下文与压缩在 e2e-compact.js（三套同时跑，各约一分钟）。
const { out, check, note, skip, until, finish } = makeSuite('input-history');
const id = AGENT;
const { events, sent, restore, key, type, box, response, lastTurn, start, done, ask, load, ctx } = chatHarness(id, { check, note, until });
try {
  setActive(id); newChat(id, true, REPO); setWorkspace(id, REPO, false);
  // 测试工作区在临时文件夹里，会话归进默认折叠的「任务会话」组；展开它，才看得到这些会话的历史行
  S[id].groupState[TASK_GROUP] = 0;
  S[id].model = MODEL; S[id].effort = 'low'; S[id].perm = FULL_PERM; renderComposer();
  type('看一下 @kee');
  await until(() => document.querySelector('.suggest-box:not([hidden]) .suggest-row'), 6000, '@ 文件候选');
  const files = [...document.querySelectorAll('.suggest-row .suggest-name')].map(e => e.textContent);
  check('@ 候选包含工作区文件', files.some(n => n.includes('keep.txt')), files);
  key('Enter'); check('@ 选择将文件名写进输入框', els.input.value.includes('keep.txt'), els.input.value); type('');
  if (id === 'gemini') {
    agentCommands[id] = []; type('/'); updateSuggest();
    check('尚无 Gemini 命令时显示说明', !!document.querySelector('.suggest-note')?.textContent.includes('Gemini'));
    type('');
  }
  const firstPrompt = '请在回答里原样写出这个词：紫藤萝瀑布。只写这个词。', secondPrompt = '只回答：第二句';
  const first = await ask(firstPrompt), cid = S[id].conversationId;
  if (id === 'gemini') {
    type('/'); updateSuggest();
    await until(() => document.querySelectorAll('.suggest-box:not([hidden]) .suggest-row:not(.suggest-note)').length > 0, 20000, 'Gemini 首轮返回的命令');
    check('Gemini 续聊前可用上一轮取得的命令', !viewBusy(id) && agentCommands[id].length > 0);
    type('');
  }
  await ask(secondPrompt);
  check('普通续聊沿用同一会话且没有分叉提示', !!cid && S[id].conversationId === cid && !box.querySelector('.fork-note'), S[id].conversationId);
  type(''); key('ArrowUp'); const up1 = els.input.value; key('ArrowUp'); const up2 = els.input.value;
  key('ArrowDown'); const down1 = els.input.value; key('ArrowDown'); const down2 = els.input.value;
  check('↑↑↓↓按顺序翻历史并回到空草稿', up1 === secondPrompt && up2 === firstPrompt && down1 === secondPrompt && down2 === '', [up1, up2, down1, down2]);
  type('/');
  await until(() => document.querySelectorAll('.suggest-box:not([hidden]) .suggest-row:not(.suggest-note)').length > 0, 30000, 'CLI 命令候选');
  const commands = [...document.querySelectorAll('.suggest-row .suggest-name')].map(e => e.textContent);
  check('/ 候选来自 CLI 报告的命令', commands.length > 0 && (agentCommands[id] || []).length > 0, commands);
  type('/comp'); updateSuggest();
  const compact = (agentCommands[id] || []).find(c => /^comp/.test(c.name));
  if (compact) {
    await until(() => document.querySelector('.suggest-box:not([hidden]) .suggest-row .suggest-name'), 3000, '/comp 候选');
    check('/comp 筛出相应命令', document.querySelector('.suggest-row .suggest-name')?.textContent === '/' + compact.name);
    key('Enter'); check('选择命令后写回输入框', els.input.value.trim() === '/' + compact.name, els.input.value);
  }
  type(''); box.querySelector('.msg.user .msg-edit').click();
  check('编辑消息将原文放回输入框', els.input.value === firstPrompt, els.input.value); type('');

  // 这是原 misc 的强制回归点：等原生回调后比较同一个对象，不能只看文字相等。
  const turn = lastTurn(), count = box.querySelectorAll('.msg.user, .msg.bot.turn').length;
  turn.dataset.marker = 'same-node'; await load(true);
  check('同步后回答还是原来的节点', lastTurn() === turn && turn.dataset.marker === 'same-node', { sameNode: lastTurn() === turn, marker: lastTurn()?.dataset.marker });
  check('同步后问答数量不变', box.querySelectorAll('.msg.user, .msg.bot.turn').length === count, { before: count, after: box.querySelectorAll('.msg.user, .msg.bot.turn').length });
  const search = document.getElementById('hist-search');
  search.value = '藤萝瀑'; search.dispatchEvent(new Event('input', { bubbles: true }));
  // 搜索分批返回，第一批可能先命中别的会话。等到当前会话出现，或搜完再判失败。
  const searched = await until(() => events.find(e => e.name === 'onConversationsSearched' && e.data.query === '藤萝瀑' &&
    (e.data.ids?.includes(cid) || e.data.complete))?.data, 60000, '正文搜索命中当前会话或结束');
  check('搜索正文命中当前会话', S[id].bodyHits?.has(cid), { expected: cid, response: searched, bodyQuery: S[id].bodyQuery, hits: [...(S[id].bodyHits || [])] });
  check('正文搜索结果显示在历史列表', document.querySelectorAll('#hist-sections .hist-item, #hist-sections .conv-row').length > 0);
  note('第一条实际回答', first.reply); search.value = ''; search.dispatchEvent(new Event('input', { bubbles: true }));

  // CLI 报模型后从真实列表选择；不依赖某个新模型名称、也不额外消耗昂贵模型额度。
  await until(() => events.some(e => e.name === 'onAgentModels'), 30000, 'CLI 模型列表');
  const reportedModels = events.filter(e => e.name === 'onAgentModels').at(-1).data.models;
  check('CLI 报告的模型全部进入 App 模型列表', reportedModels?.length > 0 && reportedModels.every(m => AGENTS[id].models.some(x => x.v === m.v)), { reported: reportedModels, displayed: AGENTS[id].models.map(m => m.v) });
  check('CLI 模型列表包含所选模型', AGENTS[id].models.some(m => m.v === MODEL), MODEL);
  const alternate = AGENTS[id].models.find(m => m.v !== MODEL);
  if (alternate) {
    chooseModel(id, alternate.v, 'low');
    check('切换模型更新选择和菜单', S[id].model === alternate.v && els.chipModel.textContent.includes(alternate.name));
  }
  chooseModel(id, MODEL, 'low');
  check('模型选择写回状态与菜单按钮', S[id].model === MODEL && els.chipModel.textContent.includes(find(AGENTS[id].models, MODEL).name));
  openModelPopover();
  const m = find(AGENTS[id].models, S[id].model), opts = modelEfforts(id, m), fast = els.popover.querySelector('.mp-fast');
  check('fast 可用状态符合当前模型能力', !!fast && fast.disabled === !m.fast);
  const fastModel = AGENTS[id].models.find(model => model.fast);
  if (fastModel) {
    // 只在菜单里选择支持 fast 的模型验证开关，真实请求仍用 MODEL（默认 Haiku）。
    closePopover(); chooseModel(id, fastModel.v, 'low'); S[id].fast = false; openModelPopover();
    els.popover.querySelector('.mp-fast').click();
    check('fast 开关打开后状态与菜单一致', S[id].fast && fastOn(id) && els.popover.querySelector('.mp-fast').classList.contains('on'));
    els.popover.querySelector('.mp-fast').click();
    check('fast 开关关闭后状态与菜单一致', !S[id].fast && !fastOn(id) && !els.popover.querySelector('.mp-fast').classList.contains('on'));
    closePopover(); chooseModel(id, MODEL, 'low'); openModelPopover();
  }
  await until(() => agentUsage[id], 60000, '剩余用量回调');
  const usageBox = els.popover.querySelector('.usage-box[data-agent="' + id + '"]');
  check('剩余用量显示数据或明确说明', !!usageBox && (!!usageBox.querySelector('.usage-row') || !!usageBox.querySelector('.usage-note')?.textContent.trim()), agentUsage[id]);
  const slide = frac => {
    const track = els.popover.querySelector('.mp-slider'), r = track.getBoundingClientRect();
    const at = { clientX: r.left + r.width * frac, clientY: r.top + r.height / 2, pointerId: 1, bubbles: true };
    track.dispatchEvent(new PointerEvent('pointerdown', at)); track.dispatchEvent(new PointerEvent('pointerup', at));
  };
  if (opts.length > 1) {
    slide(.99); check('思考强度滑杆最右选择最高档', S[id].effort === opts.at(-1).v, S[id].effort);
    slide(.01); check('思考强度滑杆最左选择最低档', S[id].effort === opts[0].v, S[id].effort);
  }
  els.popover.querySelector('.mp-model').click();
  check('模型列表展示 CLI 报告的模型', els.popover.querySelectorAll('.model-row').length > 0);
  const more = els.popover.querySelector('.more-row');
  if (more) { more.dispatchEvent(new MouseEvent('mouseenter')); check('更多模型子菜单可展开', !els.popoverSub.hidden && els.popoverSub.querySelectorAll('.model-row').length > 0); }
  els.popover.querySelector('.mp-back').click(); check('返回按钮回到模型面板', !!els.popover.querySelector('.mp-slider')); closePopover();

  // 真实外部 Claude 常驻会话由 run.sh 准备、登记并只按 PID 清理。
  if (id === 'claude') {
    if (typeof FORK_SID !== 'string' || !FORK_SID) throw new Error('run.sh 没有准备真实分叉会话 FORK_SID');
    postNative('listConversations', { agent: id });
    const item = await until(() => S[id].conversations?.find(c => c.id === FORK_SID), 15000, '外部会话出现在列表');
    openConversation(id, item); await until(() => S[id].loadedId === FORK_SID, 15000, '载入外部会话');
    openModelPopover();
    check('外部 Claude 会话直接显示记录估算，无虚构明细', ctx()?.used > 0 && ctx()?.estimated && !ctx()?.parts.length
      && els.popover.querySelector('.ctx-note')?.textContent.includes('估算'));
    closePopover();
    await until(() => !document.getElementById('fork-hint').hidden, 15000, '分叉提示');
    check('外部打开的会话显示分支提示', document.getElementById('fork-hint').textContent.includes('分支'));
    await ask('我上一句让你回复了哪个字？只回复那个字');
    const forked = S[id].conversationId;
    check('发送后创建独立会话', !!forked && forked !== FORK_SID, { source: FORK_SID, forked });
    check('分叉后显示系统说明且记录来源', !!box.querySelector('.fork-note') && convForks[id + ':' + forked] === FORK_SID);
    postNative('listConversations', { agent: id });
    await until(() => S[id].conversations?.some(c => c.id === forked), 15000, '分支出现在列表');
    check('分叉后源会话还在列表', S[id].conversations.some(c => c.id === FORK_SID));
    check('当前历史行显示分支标记', !!document.querySelector('.conv-row.active .conv-fork'));
  }

  // 更多历史只观察 loadConversation 的请求，不需要造 420 条 CLI 对话。
  const capturePost = window.postNative, loads = [];
  window.postNative = (action, payload) => { if (action === 'loadConversation') loads.push(payload); else capturePost(action, payload); };
  try {
    renderMessages(id, [{ role: 'user', text: '旧消息' }, { role: 'bot', text: '旧回答' }], REPO, 420);
    const more = box.querySelector('.load-earlier');
    check('历史较多时显示再读 300 条按钮', !!more && more.textContent.includes('300'));
    more?.click(); check('点击后请求增加 300 条历史', loads.length === 1 && loads[0].limit === 600, loads);
  } finally { window.postNative = capturePost; }
} catch (e) { out.error = String(e.message || e); }
finally { restore(); }
return finish();
