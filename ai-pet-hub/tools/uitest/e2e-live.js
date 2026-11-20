// 主流程：真实回答、审批允许/拒绝、全部改动、重读、中途补充、排队与立即发送。
// 模型是否执行指定工具是前置条件；一段最多重试一次，缺少前置条件单独 skipped。
const { out, check, note, skip, until, finish } = makeSuite('live');
const id = AGENT, saved = {}, events = [], sent = [];
for (const name of ['onAgentResponse', 'onAgentStep', 'onAgentRequest', 'onAgentSteer']) {
  saved[name] = window[name];
  window[name] = data => { if (data.agent === id) events.push({ name, data }); return saved[name]?.(data); };
}
const originalPost = window.postNative;
window.postNative = (action, payload) => { sent.push({ action, payload }); return originalPost(action, payload); };
let watcher;
try {
  setActive(id); newChat(id, true, REPO); setWorkspace(id, REPO, false);
  S[id].model = MODEL; S[id].effort = 'low'; S[id].perm = ASK_PERM; renderComposer();
  const box = S[id].msgEl;
  const lastTurn = () => [...box.querySelectorAll('.msg.bot.turn')].at(-1);
  const response = reqId => events.find(e => e.name === 'onAgentResponse' && e.data.reqId === reqId)?.data;
  const evidence = reqId => events.filter(e => e.data.reqId === reqId).map(e => ({ event: e.name, ...e.data }));
  const start = async text => {
    els.input.value = text; send();
    const run = await until(() => runsOf(id, viewKey(id))[0], '开始回答');
    check('发出问题后进入忙碌状态', viewBusy(id));
    return run.reqId;
  };
  const done = async reqId => {
    const r = await until(() => response(reqId), '收到回答');
    await until(() => !isBusy(id) && !box.querySelector('.msg.user.queued'), '所有排队消息结束');
    check('回答结束后没有 CLI 错误', !/^⚠️/.test((r.reply || '').trim()), r.reply);
    note('实际回答', r.reply);
    return r;
  };
  const reload = async () => {
    const previous = window.onConversationLoaded, cid = S[id].conversationId;
    let loaded;
    window.onConversationLoaded = d => { previous(d); if (d.agent === id && d.conversationId === cid) loaded = d; };
    try { S[id].loadedSig = ''; postNative('loadConversation', { agent: id, conversationId: cid }); await until(() => loaded, '历史读取回调'); }
    finally { window.onConversationLoaded = previous; }
  };
  // 只有正常回答却没用工具才重试/跳过；超时、CLI 错误、原生已有事件而 UI 没有卡片都失败。
  const prepare = async (name, prompt, eventName, accepts) => {
    const attempts = [];
    for (let attempt = 0; attempt < 2; attempt++) {
      const reqId = await start(prompt);
      const e = await until(() => events.find(e => e.data.reqId === reqId && e.name === eventName && accepts(e.data)) || response(reqId), name);
      if (!response(reqId)) return { reqId, event: e.data };
      const r = await done(reqId); attempts.push({ reply: r.reply, events: evidence(reqId) });
      if (/^⚠️/.test((r.reply || '').trim())) return null;
    }
    skip(name, '模型没照做', attempts); return null;
  };

  if (ASK_PERM) {
    const allow = await prepare('允许与改动卡片', '用终端命令运行这一条（一条命令，不要拆开）：echo a > made1.txt; echo b > made2.txt; echo more >> keep.txt 。运行完只回答「好了」。', 'onAgentRequest', d => d.kind === 'permission');
    if (allow) {
      const card = box.querySelector('.req-card.req-permission');
      check('收到权限请求就显示审批卡片', !!card, allow.event);
      if (!card) throw new Error('原生已发权限请求，界面没有审批卡片');
      check('审批卡片显示标题及操作内容', !!card.querySelector('.req-title')?.textContent && !!(card.querySelector('.req-detail') || card.querySelector('.req-diff'))?.textContent);
      card.querySelector('.req-btn.primary').click();
      check('允许按钮把决定发给原生', sent.some(e => e.action === 'answerAgentRequest' && e.payload.reqId === allow.reqId && e.payload.decision === 'allow'));
      const r = await done(allow.reqId);
      await until(() => !box.querySelector('.req-card'), '审批卡片收走');
      check('允许后审批卡片收走', !box.querySelector('.req-card'));
      check('允许后有非空回答', !!lastTurn()?.querySelector('.answer')?.textContent.trim(), r.reply);
      const used = evidence(allow.reqId).filter(e => e.event === 'onAgentStep').map(e => JSON.stringify(e.step)).join('\n');
      if (['made1.txt', 'made2.txt', 'keep.txt'].every(name => used.includes(name))) {
        const files = await until(() => lastTurn()?.querySelector('.files-all'), '查看全部改动按钮');
        check('回答保留改动卡片', !!lastTurn().querySelector('.files-head'));
        files.click();
        await until(() => document.querySelectorAll('.chg-file').length, '全部改动面板');
        const names = [...document.querySelectorAll('.chg-file .chg-name')].map(e => e.textContent);
        check('全部改动恰好包含三个目标文件', names.length === 3 && ['made1.txt', 'made2.txt', 'keep.txt'].every(n => names.some(s => s.includes(n))), names);
        check('全部改动有新增 diff 行', document.querySelectorAll('.chg-file .cl.add').length > 0);
        await reload();
        check('历史重读后还有改动卡片', !!lastTurn()?.querySelector('.files-head'));
      } else skip('三个指定文件的全部改动', '模型没照做', { reply: r.reply, steps: used });
    }
    const deny = await prepare('拒绝审批', '用终端命令运行：echo no > denied.txt 。如果没被同意就不要再试，只回答「被拒绝了」。', 'onAgentRequest', d => d.kind === 'permission');
    if (deny) {
      const card = box.querySelector('.req-card.req-permission');
      check('第二次权限请求显示审批卡片', !!card);
      if (!card) throw new Error('原生已发第二次权限请求，界面没有审批卡片');
      const reason = card.querySelector('.req-input');
      if (reason) reason.value = '不要建这个文件';
      card.querySelector('.req-btn.danger').click();
      check('拒绝按钮传递拒绝及说明', sent.some(e => e.action === 'answerAgentRequest' && e.payload.reqId === deny.reqId && e.payload.decision === 'deny' && e.payload.message === (reason ? '不要建这个文件' : '')));
      await done(deny.reqId);
      await until(() => !box.querySelector('.req-card'), '拒绝卡片收走');
      check('拒绝后卡片收走且回答结束', !box.querySelector('.req-card') && !viewBusy(id));
    }
  }

  S[id].perm = FULL_PERM; renderComposer();
  let sawCard = false;
  watcher = new MutationObserver(records => { if (box.querySelector('.req-card') || records.some(r => [...r.addedNodes].some(n => n.nodeType === 1 && (n.matches('.req-card') || n.querySelector('.req-card'))))) sawCard = true; });
  watcher.observe(box, { childList: true, subtree: true });
  const slow = prompt => prepare('中途补充的命令前置条件', prompt, 'onAgentStep', d => d.step?.kind === 'command' && d.step.status === 'running');
  const round = await slow('用终端命令依次运行这三条，每条单独运行并在前台等完成：sleep 4; echo one 然后 sleep 4; echo two 然后 sleep 4; echo three。最后告诉我三个输出。');
  if (round) {
    check('原生命令步骤出现在实时工作过程', !!box.querySelector('.msg.bot.turn.live .step-command'));
    const said = [], originalSay = pets[id].say.bind(pets[id]);
    pets[id].say = (t, ms) => { said.push(t); return originalSay(t, ms); };
    try { updateSetting(id, 'effort', S[id].effort, '思考强度不变'); }
    finally { pets[id].say = originalSay; }
    check('回答中修改设置提示下一句生效', said.some(s => s.includes('下一句起生效')), said);
    const text1 = '补充：回答的最后请加上「收到补充」这四个字。', text2 = '再补充：只需简短回答。';
    els.input.value = text1; send();
    const q1 = box.querySelector('.msg.user.queued');
    check('补充发出当下出现排队气泡', !!q1 && !!q1.querySelector('.queued-state')?.textContent, q1?.textContent);
    els.input.value = text2; send();
    const queued = [...box.querySelectorAll('.msg.user.queued .queued-text')].map(e => e.textContent);
    check('连续补充在队列里保持发送顺序', queued.length >= 2 && queued.at(-2).includes(text1) && queued.at(-1).includes(text2), queued);
    await done(round.reqId);
    check('补充结束后队列清空', box.querySelectorAll('.msg.user.queued').length === 0);
    const steers = events.filter(e => e.name === 'onAgentSteer' && e.data.reqId === round.reqId);
    if (steers.some(e => e.data.state === 'consumed')) {
      check('CLI 收到补充时工作过程里实时记下你补充说', events.some(e => e.name === 'onAgentStep' && e.data.reqId === round.reqId && e.data.step?.kind === 'user' && e.data.step.detail === text1));
      if (id === 'gemini') {
        // agy 的记录里补充是单独一句提问（提问 → 回答 → 补充 → 回答）；答完按记录重读，页面就和以后重开时一样
        const asked = () => [...box.querySelectorAll('.msg.user:not(.queued)')].some(e => e.textContent.includes(text1));
        await until(asked, '按记录重读后的补充');
        check('答完按记录重读后补充显示成一句提问', asked());
      } else {
        await until(() => !!box.querySelector('.step-user'), '补充步骤');
        check('CLI 收到补充后显示你补充说', !!box.querySelector('.step-user'));
      }
    } else {
      const users = [...box.querySelectorAll('.msg.user:not(.queued)')].map(e => e.textContent);
      check('不能实时补充时两句话分别发出且顺序不变', users.findIndex(s => s.includes(text1)) >= 0 && users.findIndex(s => s.includes(text1)) < users.findIndex(s => s.includes(text2)), users.slice(-3));
    }
    if (id === 'gpt') {
      const users = box.querySelectorAll('.msg.user').length, turns = box.querySelectorAll('.msg.bot.turn').length;
      await reload();
      check('历史同步后仍有补充步骤', !!box.querySelector('.step-user'));
      check('历史同步不把补充拆成新回合', box.querySelectorAll('.msg.user').length === users && box.querySelectorAll('.msg.bot.turn').length === turns);
    }
  }

  const jump = await slow('用终端命令运行：sleep 60; echo done。要在前台等它跑完，不要放到后台，不要提前回答。');
  if (jump) {
    els.input.value = '算了，直接回答：1+1 等于几？只答数字。'; send();
    check('插队消息即时显示排队气泡', !!box.querySelector('.msg.user.queued'));
    const q = await until(() => box.querySelector('.msg.user.queued.can-jump') || response(jump.reqId), '可立即发送的气泡');
    if (response(jump.reqId)) {
      skip('立即发送', '模型没照做', { reply: response(jump.reqId).reply, events: evidence(jump.reqId) });
      await until(() => !isBusy(id), '自动续发完成');
    } else {
      const at = Date.now(); q.querySelector('.queued-now').click();
      check('立即发送会取消旧请求', sent.some(e => e.action === 'cancelAgent' && e.payload.reqId === jump.reqId));
      await until(() => [...box.querySelectorAll('.msg.user:not(.queued)')].some(e => e.textContent.includes('1+1')), '插队消息正式发出');
      note('立即发送耗时秒', (Date.now() - at) / 1000);
      await done(jump.reqId);
      check('立即发送完成后输入与队列都清空', els.input.value === '' && !box.querySelector('.msg.user.queued'));
      check('立即发送有回答', !!lastTurn()?.querySelector('.answer')?.textContent.trim());
    }
  }
  check('最高权限下全程没有审批卡片', !sawCard);
} catch (e) { out.error = String(e.message || e); }
finally {
  watcher?.disconnect();
  for (const name of Object.keys(saved)) window[name] = saved[name];
  window.postNative = originalPost;
  note('实时重试提示', events.filter(e => e.name === 'onAgentStep' && /被限流|连接中断，正在重试|模型满载，等待重试/.test(e.data.step?.title || '')).map(e => e.data.step));
}
return finish();
