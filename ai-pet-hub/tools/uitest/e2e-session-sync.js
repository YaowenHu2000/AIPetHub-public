// 不用 CLI：会话同步、图片重试/编辑、实时轮身份、队列顺序、旧页面响应。
// tools/uitest/run.sh claude e2e-session-sync.js
const {out, check, section, finish} = makeSuite('session-sync');
const sent = [], originalPost = postNative;
postNative = (action, payload = {}) => {
  if (action === 'loadConversation' && !payload.reqId) payload = { ...payload, reqId: nextRequestId() };
  sent.push({ action, ...payload });
  // loadConversation 交给原生记录同步归属；测试随后注入历史响应。
  if (action === 'loadConversation') originalPost(action, payload);
};
prewarm = () => {};
const id = active, st = S[id], box = st.msgEl;
const originalSyncAppend = syncAppend; let syncAppendCalls = 0;
syncAppend = (...args) => { syncAppendCalls++; return originalSyncAppend(...args); };
const u = (text, images) => ({ role: 'user', text, ...(images ? { images } : {}) });
const b = (text, steps = []) => ({ role: 'bot', text, steps });
const reset = () => {
  st.runs.clear(); st.conversationId = 'fixture'; st.loadedId = 'fixture';
  st.loadedSig = ''; st.historyReads?.clear(); st.shownOmitted = 0; st.attach = [];
  st.conversations = []; st.applyCwdOnLoad = false;
  st.elsewhereAt = 0; st.watchUntil = 0; st.ownAt = 0; st.ownTurnUnsynced = false;
  els.input.value = ''; box.innerHTML = ''; sent.length = 0;
};
const loaded = (messages, reqId) => window.onConversationLoaded({ agent: id, conversationId: st.conversationId, messages, reqId });
const sync = messages => {
  const reqId = nextRequestId();
  postNative('loadConversation', { agent: id, conversationId: st.conversationId, sync: true, reqId });
  loaded(messages, reqId);
};
const runNow = () => [...st.runs.values()][0];
const asks = () => sent.filter(x => x.action === 'askAgent');

await section('F03', () => {
  reset(); loaded([u('old'), b('abcdef')]);
  const reqId = nextRequestId();
  postNative('loadConversation', { agent: id, conversationId: 'fixture', sync: true, reqId });
  openConversation(id, { id: 'new-fixture' });
  window.onConversationLoaded({ agent: id, conversationId: 'fixture', reqId, messages: [u('old'), b('abcdef')] });
  loaded([u('new'), b('uvwxyz')]);
  check('F03 切会话后相同形状的历史正常显示', box.textContent.includes('uvwxyz') && !box.querySelector('.chat-empty'), box.textContent);
});

await section('F02', () => {
  reset();
  const old = [u('first'), b('stable'), u('last'), b('partial', [{ kind: 'command', title: 'cmd', status: 'running', output: 'a' }])];
  loaded(old);
  const stable = box.children[1]; stable.querySelector('.answer').dataset.keep = 'yes';
  const next = old.slice(0, 3).concat(b('changed', [{ kind: 'command', title: 'cmd', status: 'running', output: 'a' }]));
  sync(next);
  check('F02 等长正文变化也更新', box.lastElementChild._text === 'changed', box.lastElementChild._text);
  next[3] = b('changed', [{ kind: 'command', title: 'cmd', status: 'ok', output: 'b' }]);
  sync(next);
  check('F02 仅步骤状态/输出变化也更新', !box.lastElementChild.querySelector('.step.running') && box.lastElementChild.textContent.includes('b'), box.lastElementChild.textContent);
  const final = old.slice(0, 3).concat(b('complete answer'), u('next'), b('appended'));
  sync(final);
  check('F02 追加时也补齐原来的末轮', box.children[3]._text === 'complete answer' && box.children.length === 6, box.children[3]._text);
  check('F02 稳定前缀节点不重画', box.children[1] === stable && stable.querySelector('.answer').dataset.keep === 'yes', box.children[1] === stable);
});

// 完成回调真实创建末轮，再模拟迟到的 CLI 记录对账；保护节点和重试按钮。
await section('刚答完的末轮对账', () => {
  reset(); loaded([u('前一问'), b('前一答')]);
  startRun(id, '本轮问题', []); const run = runNow();
  window.onAgentResponse({agent:id,reqId:run.reqId,conversationId:st.conversationId,reply:'⚠️ 本轮已停止',cancelled:true});
  const turn = [...box.querySelectorAll('.msg.bot.turn')].at(-1), retry = turn.querySelector('.retry');
  check('完成回调生成末轮与重试按钮', !!turn && !!retry, {answeredHere:turn._answeredHere,retry:!!retry});
  const calls = syncAppendCalls;
  sync([u('前一问'), b('前一答'), u('本轮问题'), b('CLI 记录迟到的正文')]);
  check('对账真正调用 syncAppend', syncAppendCalls === calls + 1, {before:calls,after:syncAppendCalls});
  check('同步后回答还是原来的节点', [...box.querySelectorAll('.msg.bot.turn')].at(-1) === turn, {same:[...box.querySelectorAll('.msg.bot.turn')].at(-1) === turn,text:[...box.querySelectorAll('.msg.bot.turn')].at(-1)?.textContent});
  check('同步后重试按钮还是原来的节点', !!retry && turn.isConnected && turn.querySelector('.retry') === retry && retry.isConnected, {same:turn.querySelector('.retry') === retry,connected:retry?.isConnected});
  check('同步后消息没有重复', box.querySelectorAll('.msg.user,.msg.bot.turn').length === 4, box.querySelectorAll('.msg.user,.msg.bot.turn').length);
});

await section('失败结局和 checkpoint', () => {
  reset(); loaded([u('前一问'), b('前一答')]);
  startRun(id, '再试这句', []); const run = runNow();
  window.onAgentResponse({agent:id, reqId:run.reqId, conversationId:st.conversationId, reply:'已有的半句', outcome:'failed'});
  const failed = box.lastElementChild;
  check('失败正文原样保留并可重试', failed.textContent.includes('已有的半句') && !!failed.querySelector('.retry'));
  reset();
  const history = [u('旧问'), b('旧答'), u('/compact'), { role:'compact', text:'已压缩上下文' }, u('新问'), b('新答')];
  loaded(history); sync(history);
  const note = box.querySelector('.compact-note');
  check('重开和同步在原位置显示唯一压缩提示', box.querySelectorAll('.compact-note').length === 1 &&
    note?.previousElementSibling?._text === '旧答' && note?.nextElementSibling?.textContent.includes('新问'));
});

await section('补充回读只核对本轮', () => {
  reset();
  const history = [u('旧问'), b('旧答')];
  loaded(history);
  startRun(id, '/compact', []);
  // Claude 手动压缩、Gemini 压缩压成了在记录里都有一条压缩提示（和原生读历史一致），原生回答里带 compacted
  const recorded = id === 'gemini' || id === 'claude';
  window.onAgentResponse({agent:id,reqId:runNow().reqId,conversationId:st.conversationId,reply:'压缩提示', ...(recorded ? {compacted:true} : {})});
  const note = box.querySelector('.compact-note');
  if (recorded) history.push({role:'compact', text:'已压缩上下文'});
  for (const cancelled of [false, true]) {
    const question = cancelled ? '这轮叫停' : '正常完成';
    startRun(id, question, []); const run = runNow(); run.steered = true;
    window.onAgentResponse({agent:id,reqId:run.reqId,conversationId:st.conversationId,cancelled,reply:'实时正文'});
    const turn = [...box.querySelectorAll('.msg.bot.turn')].at(-1);
    const retry = turn.querySelector('.retry');
    const read = sent.filter(r => r.action === 'loadConversation' && r.afterSteer).at(-1);
    history.push(u(question), b('补充落盘后的回答'));
    loaded(history, read.reqId);
    check('补充回读保留前面的压缩提示：' + question, !!note?.isConnected);
    if (cancelled) check('本轮先补充再停止，回读保留回答及重试', turn.isConnected && !!retry?.isConnected);
    else check('正常完成的补充仍按记录核对正文', box.lastElementChild?._text === '补充落盘后的回答');
  }
});

await section('F05', () => {
  reset(); const text = 'look /tmp/fixture.png';
  const el = appendMessage(id, 'user', text); requestMessageImages(el, text, '');
  const req = sent.find(x => x.action === 'chatThumbs');
  const edit = el.querySelector('.msg-edit');
  window.onChatThumbs({ reqId: req.reqId, images: [{ src: 'data:image/png;base64,', path: '/tmp/fixture.png' }] });
  el.querySelector('.msg-edit')?.click();
  check('F05 缩略图到达后仍可编辑原文', !!el.querySelector('.msg-img') && !!el.querySelector('.msg-edit') && els.input.value === text, { before: !!edit, after: !!el.querySelector('.msg-edit'), input: els.input.value });
});

for (const text of ['', 'describe image']) await section('F06 ' + text, () => {
  reset(); const images = ['/tmp/original.png']; startRun(id, text, images);
  const run = runNow(); images.push('/tmp/mutated.png');
  check('F06 请求独立保存原附件 ' + JSON.stringify(text), JSON.stringify(run.images) === '["/tmp/original.png"]', run.images);
  window.onAgentResponse({ agent: id, reqId: run.reqId, reply: '⚠️ fixture failure', cancelled: true });
  els.input.value = 'draft'; st.attach = [{ path: '/tmp/draft.png' }];
  box.querySelector('.retry').click();
  const retried = asks()[1];
  check('F06 重试发送原文字和图片 ' + JSON.stringify(text), retried?.prompt === (text || '请看这张图片。') && JSON.stringify(retried?.images) === '["/tmp/original.png"]', retried);
  check('F06 重试不消耗输入框附件 ' + JSON.stringify(text), st.attach[0]?.path === '/tmp/draft.png', st.attach);
});

await section('F10', () => {
  reset(); const previous = [u('repeat'), b('previous answer')]; renderMessages(id, previous);
  startRun(id, 'repeat', []); renderMessages(id, previous);
  check('F10 本轮尚未写入记录时保留旧同句回答', box.textContent.includes('previous answer') && box.children.length === 4, box.textContent);
  renderMessages(id, previous.concat(u('repeat'), b('history partial')));
  check('F10 只在本轮起始位置接回', box.children.length === 4 && !box.textContent.includes('history partial'), box.textContent);
  reset(); renderMessages(id, []); startRun(id, '', ['/tmp/current.png']);
  renderMessages(id, [u('请看这张图片。', [{ path: '/tmp/current.png', missing: true }]), b('history partial')]);
  check('F10 纯图按实际提问及图片身份接回', box.children.length === 2 && !box.textContent.includes('history partial'), box.textContent);
  renderMessages(id, [u('请看这张图片。', [{ path: '/tmp/another.png', missing: true }]), b('other image answer')]);
  check('F10 不截掉另一张图片的历史轮', box.textContent.includes('other image answer') && box.children.length === 4, box.textContent);
  reset(); st.shownOmitted = 300; renderMessages(id, previous, '', 300); startRun(id, 'repeat', []);
  renderMessages(id, [u('earlier'), b('older'), ...previous, u('repeat'), b('history partial')], '', 298);
  check('F10 加载更早历史后仍按绝对起始位置接回', box.textContent.includes('previous answer') && !box.textContent.includes('history partial'), box.textContent);
});

await section('F15', () => {
  reset(); startRun(id, 'working', []); const run = runNow();
  ['first', 'held', 'second'].forEach(text => queueMessage(id, text));
  run.queue.forEach(q => setQueuedState(q, q.text === 'held' ? 'sent' : 'waiting'));
  moveQueuedUp(run, run.queue[2]);
  const order = () => [...box.querySelectorAll('.queued-text')].map(n => n.textContent);
  const expected = JSON.stringify(run.queue.map(q => q.text));
  check('F15 上移后的视觉顺序符合队列', JSON.stringify(order()) === expected, order());
  box.innerHTML = ''; attachRuns(id);
  check('F15 attachRuns 接回顺序符合队列', JSON.stringify(order()) === expected, order());
  renderMessages(id, []);
  check('F15 renderMessages 接回顺序符合队列', JSON.stringify(order()) === expected, order());
});

await section('N10', async () => {
  reset();
  let read; const promise = readLocalFile('/tmp/new', '').then(d => { read = d; });
  const req = sent.find(x => x.action === 'readFile');
  window.onFileRead({ reqId: 1, content: 'old' }); await Promise.resolve();
  check('N10 旧文件响应不命中新页面请求', !read && req.reqId > 1, { read, reqId: req.reqId });
  window.onFileRead({ reqId: req.reqId, content: 'new' }); await promise;
  check('N10 本页文件响应仍可匹配', read.content === 'new', read);
  const el = appendMessage(id, 'user', '/tmp/new.png'); requestMessageImages(el, '/tmp/new.png', '');
  const thumb = sent.filter(x => x.action === 'chatThumbs').pop();
  window.onChatThumbs({ reqId: 7, images: [{ src: 'old-image' }] });
  check('N10 旧缩略图响应丢弃', !el.querySelector('img') && thumb.reqId > 1, thumb.reqId);
  openImageViewer({ src: 'new-thumb', path: '/tmp/new.png' });
  const viewer = sent.filter(x => x.action === 'chatImage').pop();
  window.onChatImage({ reqId: 1, image: 'old-original' });
  check('N10 旧原图响应丢弃', imageViewer.img.getAttribute('src') === 'new-thumb' && viewer.reqId > 1, viewer.reqId);
  closeImageViewer();
  const turn = renderOneMessage(id, b('`/tmp/new.txt`'), undefined, ''); verifyFileChips(turn);
  const chips = sent.filter(x => x.action === 'checkFiles').pop();
  window.onFilesChecked({ reqId: 1, found: {} });
  check('N10 旧文件核对响应丢弃', !!turn.querySelector('.file-chip') && chips.reqId > 1, chips.reqId);
});
st.runs.clear();
syncAppend = originalSyncAppend;
return finish();
