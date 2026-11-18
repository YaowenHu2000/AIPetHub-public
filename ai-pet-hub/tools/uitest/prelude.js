// 各个测试脚本共用的小工具（run.sh 会把它接在每个脚本前面）。
// 等这一轮开始跑命令。等不到时，把这一轮实际做了哪些步骤、最后答了什么写进报错里——
// 多半是模型这次没按要求跑命令（直接答了、或者先问了一句），有了这些就能分清是模型没照做，还是界面没把步骤显示出来。
const untilCommand = async (box, ms = 120000) => {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (box.querySelector('.msg.bot.turn.live .step-command')) return;
    await new Promise(r => setTimeout(r, 200));
  }
  const live = box.querySelector('.msg.bot.turn.live');
  const last = [...box.querySelectorAll('.msg.bot.turn')].pop();
  const steps = live ? [...live.querySelectorAll('.step')].map(n => n.textContent.trim().replace(/\s+/g, ' ').slice(0, 40)) : null;
  throw new Error('等不到命令开始。这一轮实际的步骤：' + JSON.stringify(steps) + '；最后一条回答：' + (last ? last.textContent.trim().replace(/\s+/g, ' ').slice(0, 100) : '（没有）'));
};

// 真实窗口模式（run.sh 前面加 REAL=1）才有意义的三个：
/** 把整个窗口截下来（连红绿灯、毛玻璃），存在结果目录里。 */
const realShot = async name => { postNative('testWindowShot', { path: DIR + '/' + name + '.png' }); await new Promise(r => setTimeout(r, 900)); };
/** 在一个元素的正中真的点一下（事件从窗口那一层走，会经过标题栏和原生视图）。 */
const realClick = async el => {
  const r = el.getBoundingClientRect();
  postNative('testClick', { x: r.left + r.width / 2, y: r.top + r.height / 2 });
  await new Promise(res => setTimeout(res, 450));
};
/** 红绿灯的位置：[{ left, right, centerY, hidden }]（CSS 像素）。 */
const trafficLights = () => new Promise(resolve => {
  window.onTestChrome = data => resolve(data);
  postNative('testChrome', {});
  setTimeout(() => resolve(null), 3000);
});

// 输入、历史、图片、压缩这几套共用：截住发给网页的回调和发给原生的消息，发问并等回答，按请求号读历史，
// 以及把历史读取卡在原生里（TestHooks）。restore() 在套件结束时把截住的东西还原。
const chatHarness = (id, { check, note, until }) => {
  const saved = {}, events = [], sent = [];
  for (const name of ['onAgentResponse', 'onAgentStep', 'onAgentModels', 'onAgentSteer', 'onConversationsSearched']) {
    saved[name] = window[name];
    window[name] = d => { if (d.agent === id) events.push({ name, data: d }); return saved[name]?.(d); };
  }
  const originalPost = window.postNative;
  window.postNative = (action, payload) => { sent.push({ action, payload }); return originalPost(action, payload); };
  const restore = () => { for (const name of Object.keys(saved)) window[name] = saved[name]; window.postNative = originalPost; };
  const key = k => els.input.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
  const type = v => { els.input.value = v; els.input.selectionStart = els.input.selectionEnd = v.length; els.input.dispatchEvent(new Event('input', { bubbles: true })); };
  const box = S[id].msgEl, response = req => events.find(e => e.name === 'onAgentResponse' && e.data.reqId === req)?.data;
  const lastTurn = () => [...box.querySelectorAll('.msg.bot.turn')].at(-1);
  const start = async text => { type(text); send(); const run = await until(() => runsOf(id, viewKey(id))[0], 5000, '开始回答'); check('发送后进入忙碌状态', viewBusy(id)); return run.reqId; };
  const done = async req => {
    const r = await until(() => response(req), 240000, '回答回调');
    await until(() => !isBusy(id) && !box.querySelector('.msg.user.queued'), 240000, '回答与排队结束');
    check('回答完成且无 CLI 错误', !!r.reply?.trim() && !/^⚠️/.test(r.reply.trim()), r.reply);
    note('实际回答', r.reply); return r;
  };
  const ask = async text => done(await start(text));
  const load = async (sync = false) => {
    const previous = window.onConversationLoaded, cid = S[id].conversationId, reqId = nextRequestId();
    let data;
    window.onConversationLoaded = d => { previous(d); if (d.agent === id && d.conversationId === cid && d.reqId === reqId) data = d; };
    try {
      S[id].loadedSig = 'force';
      postNative('loadConversation', { agent: id, conversationId: cid, reqId, sync });
      await until(() => data, 15000, '会话读取回调'); return data;
    } finally { window.onConversationLoaded = previous; }
  };
  const held = new Set(); let released = false;
  window.onTestHistoryHeld = d => { held.add(d.reqId); };
  window.onTestHistoryReleased = () => { released = true; };
  const holdHistory = () => { held.clear(); released = false; postNative('testHoldHistory'); };
  const releaseHistory = async () => {
    postNative('testReleaseHistory');
    await until(() => released, 5000, '原生已交付卡住的历史');
  };
  const ctx = () => agentContext[`${id}:${S[id].conversationId}`];
  return { events, sent, restore, key, type, box, response, lastTurn, start, done, ask, load, held, holdHistory, releaseHistory, ctx };
};
