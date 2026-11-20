'use strict';

// 回答进行中的交互（接在 stream.js 后面加载）：
//   · 智能体要做一件事先来问（权限不是「最高权限」时才会）：允许 / 这一轮都允许 / 拒绝；它提的问题、写好的计划
//   · 回答还没完又发来一句：能送进去的当场送（下一步之前它就看到），送不进去的排着，这一轮结束后自动发
// 原生那一半在 LiveTurn.swift / Prewarm.swift 和各位的 agent-*.swift。
//
// 提问卡按题目分别交回选项数组与自填文字，以免选项里的顿号改变答案。
// 单选以用户最后一次点选或输入为准；Gemini 只在 schema 允许自填时显示相应输入框。
//
// 排队后撤回的图片沿用原附件的归属，从附件栏移除时只清理 App 保存的截图。

// ===== 排队 / 中途补充 =====
let steerSeq = 0;

/** 这个会话正在回答时又发了一句。 */
function queueMessage(id, text, images = [], draft = null, run = runsOf(id, viewKey(id))[0], restored = null, sentPaths = null) {
  if (!run) return false;
  const item = { sid: restored?.steerId || `s${Date.now()}-${++steerSeq}`, text, images, draft, sentPaths:{...(restored?.sentPaths || sentPaths)}, state: 'sending' };
  const el = document.createElement('div');
  el.className = 'msg user queued';
  el.innerHTML = '<div class="queued-text"></div><div class="queued-note"><span class="queued-state"></span><button class="queued-up" title="往前排一位"></button><button class="queued-now" title="不等了：停下正在做的，马上发这一句">立即发送</button><button class="queued-cancel" title="先不发：放回输入框，可以改了再发"></button></div>';
  el.querySelector('.queued-text').textContent = text + (images.length ? `\n📎 ${images.length} 张图片` : '');
  el.querySelector('.queued-cancel').innerHTML = UI.close;
  el.querySelector('.queued-cancel').addEventListener('click', () => {
    if (item.state !== 'waiting') return;
    if (!returnQueuedDrafts(id,run,[item],null,'withdraw')) {
      pets[id].say('附件栏放不下这条补充，请先移除一些附件。', 3000);
      return;
    }
    dropQueued(run, item);
    saveQueueOrder(run);
  });
  // 插队：停下正在进行的回答，马上发这一句（排着的其他话跟着一起发）
  el.querySelector('.queued-now').addEventListener('click', () => {
    if (!['waiting', 'sent'].includes(item.state) || run.queue.some(q => q.jump)) return;   // 已经送进去、但它手头的事还没做完（比如一条很久的命令）时也能插队
    item.jump = true;
    saveQueueOrder(run);
    setQueuedState(item, item.state);
    postNative('cancelAgent', { agent: id, reqId: run.reqId });
  });
  el.querySelector('.queued-up').innerHTML = UI.arrowUp;
  el.querySelector('.queued-up').addEventListener('click', () => moveQueuedUp(run, item));
  item.el = el;
  item.run = run;
  (run.queue = run.queue || []).push(item);
  if (run.returnedQueue && !run.returnedQueue.ids.includes(item.sid)) run.returnedQueue.ids.push(item.sid);
  run.nodes.push(el);
  const box = run.live?.el.parentNode || S[id].msgEl;
  box.appendChild(el);
  scrollToBottom(box);
  if (restored) {
    item.jump = !!restored.jump;
    item.consumed = restored.state === 'consumed';
    setQueuedState(item, restored.state === 'rejected' ? 'waiting' : item.consumed ? 'sent' : restored.state || 'sending');
    return true;
  }
  setQueuedState(item, 'sending');
  if (hasBridge()) postNative('steerAgent', { agent: id, reqId: run.reqId, text, images:sentAttachments(item).images, sourceImages:images, sentPaths:item.sentPaths, draft, steerId:item.sid });
  else setQueuedState(item, 'waiting');
  return true;
}

function saveQueueOrder(run) {
  postNative('queueOrder', {agent:run.agent,reqId:run.reqId,ids:run.queue.map(q => q.sid),jump:run.queue.find(q => q.jump)?.sid,returnedQueue:run.returnedQueue});
}

function setQueuedState(item, state) {
  item.state = state;
  item.el.querySelector('.queued-state').textContent = queuedLabel(state, item.held, item.jump);
  item.el.classList.toggle('can-cancel', state === 'waiting' && !item.jump);
  item.el.classList.toggle('can-jump', ['waiting', 'sent'].includes(state) && !item.jump);
  if (item.run) refreshQueueOrder(item.run);
}

/** 还排着没送出去的话可以调顺序：前面还有别的排着的话时，这一句上出现「往前排一位」。 */
const stillWaiting = q => q.state === 'waiting' && !q.jump;
function refreshQueueOrder(run) {
  (run.queue || []).forEach((q, i) => q.el.classList.toggle('can-up', stillWaiting(q) && run.queue.slice(0, i).some(stillWaiting)));
}

/** 往前排一位：和前面最近的那句排着的话换位置（两句话滑过去，不是一下跳过去）。 */
function moveQueuedUp(run, item) {
  const q = run.queue || [];
  const i = q.indexOf(item);
  let j = i - 1;
  while (j >= 0 && !stillWaiting(q[j])) j--;
  if (i < 0 || j < 0 || !stillWaiting(item)) return;
  const other = q[j];
  if (run.returnedQueue) {
    const ids = run.returnedQueue.ids, a = ids.indexOf(item.sid), b = ids.indexOf(other.sid);
    if (a >= 0 && b >= 0) { ids.splice(a,1); ids.splice(b,0,item.sid); }
  }
  const before = [item, other].map(x => x.el.getBoundingClientRect().top);
  q.splice(i, 1);
  q.splice(j, 0, item);
  run.nodes = run.nodes.filter(n => n !== item.el);
  run.nodes.splice(run.nodes.indexOf(other.el), 0, item.el);
  other.el.parentNode.insertBefore(item.el, other.el);
  [item, other].forEach((x, k) => {
    const moved = before[k] - x.el.getBoundingClientRect().top;
    x.el.animate([{ transform: `translateY(${moved}px)` }, { transform: 'none' }], { duration: SPRING_EASE.snappy.ms, easing: SPRING_EASE.snappy.css });
  });
  refreshQueueOrder(run);
  saveQueueOrder(run);
}

function dropQueued(run, item) {
  item.el.remove();
  run.queue = (run.queue || []).filter(q => q !== item);
  run.nodes = run.nodes.filter(n => n !== item.el);
  refreshQueueOrder(run);
}

const commandRunning = run => (run.live?.steps || []).some(s => s && s.kind === 'command' && s.status === 'running');

// 留着的气泡（CLI 已经收下、等命令跑完的）：命令一跑完就收走
const baseAgentStep = window.onAgentStep;
window.onAgentStep = data => {
  baseAgentStep(data);
  const run = S[data.agent]?.runs.get(data.reqId);
  if (run?.queue?.some(q => q.held && !q.jump) && !commandRunning(run)) run.queue.filter(q => q.held && !q.jump).forEach(q => dropQueued(run, q));
};

// 原生：这句话送到了（sent）/ 智能体看到了（consumed，这时它已经作为一步出现在工作过程里）/ 送不进去（rejected，留着排队）
window.onAgentSteer = data => {
  const run = S[data.agent]?.runs.get(data.reqId);
  const item = run?.queue?.find(q => q.sid === data.steerId);
  if (!item) return;
  if (data.restoreDraft) {
    returnQueuedDrafts(data.agent,run,[item],null,'reject');
    dropQueued(run,item);
    saveQueueOrder(run);
    pets[data.agent].say(data.reason, 5000);
    return;
  }
  if (data.state === 'uncertain') {
    item.jump = false;
    setQueuedState(item, 'uncertain');
    return;
  }
  if (data.state === 'consumed') { run.steered = true; item.consumed = true; }
  // 已经点了「立即发送」：这一轮正在停，这句话等它停下后重新发——除非 CLI 停下前已经收下并答了（见 answeredBeforeStop）
  if (item.jump) return;
  if (data.state === 'consumed') {
    // CLI 收下了这句话，但它手头有一条命令还在跑（Codex 会这样）：跑完才轮得到。气泡先留着，可以点「立即发送」打断
    if (commandRunning(run)) { item.held = true; setQueuedState(item, 'sent'); return; }
    dropQueued(run, item);
  }
  else setQueuedState(item, data.state === 'sent' ? 'sent' : 'waiting');
};

/**
 * 这一轮结束了：还排着的话按队列顺序接着发；这一轮是被停止的就不自动发，放回输入框——除非是点「立即发送」插队停的。
 * 在 onAgentResponse 的最后调用。
 */
function flushQueue(id, run, data, original = null) {
  for (const item of [...(run.queue || [])]) {
    if (item.state !== 'uncertain' && !(id === 'deepseek' && item.state === 'sending')) continue;
    const notice = '补充的送达状态待确认，请核对历史：' + item.text;
    if (inDraftView(id,run)) appendMessage(id, 'sys', notice);
    pets[id].say(notice, 5000);
    dropQueued(run, item);
  }
  const jump = (run.queue || []).some(q => q.jump);   // 点了「立即发送」：这一轮是为了插队才停的，接着发
  const steps = Array.isArray(data.steps) ? data.steps : run.live?.steps;
  (run.queue || []).filter(q => (q.held && !q.jump) || (answeredBeforeStop(q, steps) || answeredBeforeStop(q, run.live?.steps))).forEach(q => dropQueued(run, q));   // CLI 已经收下的：不用再发
  const left = run.queue || [];
  if (!left.length) {
    if (original) returnQueuedDrafts(id,run,[],original);
    return;
  }
  left.forEach(item => item.el.remove());
  run.queue = [];
  const here = id === active && inDraftView(id,run);
  if (queueAction({ failed: canRetryOutcome((run.ending || responseEnding(data)).outcome), here, busy: viewBusy(id), jump }) === 'restore') {
    returnQueuedDrafts(id,run,left,original);
    return;
  }
  if (original) returnQueuedDrafts(id,run,[],original);
  // 一句一句发：先发第一句（连它带的图片），其余的接着排在它后面（能送进去的会送进去，送不进去的等它答完再发下一句）
  const first = left.find(q => q.jump) || left[0];
  startRun(id, first.text, first.images || [], [], first.draft, null, null, first.sentPaths);
  left.filter(q => q !== first).forEach(q => queueMessage(id, q.text, q.images, q.draft, undefined, null, q.sentPaths));
}

/**
 * 点了「立即发送」，CLI 却在停下之前收下了这句（consumed）并已经接着答了：工作过程里这句后面还有内容。
 * 这时再发一遍就会同一句答两遍（astra 报告）；收下了但还没来得及答的，照常重发。
 */
function answeredBeforeStop(item, steps) {
  if (!item.consumed) return false;
  const list = (steps || []).filter(Boolean);
  const at = list.map(s => s.kind === 'user' && (s.detail || '') === item.text).lastIndexOf(true);
  return at >= 0 && list.slice(at + 1).some(s => ['text','command','tool','agent','read','write','edit','search','list','todo','web'].includes(s.kind) && (s.kind !== 'text' || s.detail?.trim()));
}

// ===== 审批 / 提问 / 计划 =====
function requestBox(run) {
  const live = run.live;
  if (!live) return null;
  if (!live.requests) {
    live.requests = document.createElement('div');
    live.requests.className = 'live-requests';
    live.el.appendChild(live.requests);
  }
  return live.requests;
}

function answerRequest(run, card, body) {
  postNative('answerAgentRequest', { agent: run.agent, reqId: run.reqId, requestId: card.dataset.requestId, ...body });
  card.classList.add('answered');
  card.querySelectorAll('button, input, textarea').forEach(b => { b.disabled = true; });
  setTimeout(() => card.remove(), 4000);   // 正常情况下原生马上会发 onAgentRequestClosed；这是兜底
}

function reqButton(label, cls, onClick) {
  const b = document.createElement('button');
  b.className = `req-btn ${cls}`;
  b.textContent = label;
  b.addEventListener('click', onClick);
  return b;
}

/** 改动内容：+ / − 行着色。 */
function diffBlock(diff) {
  const pre = document.createElement('pre');
  pre.className = 'req-diff';
  for (const line of String(diff).split('\n')) {
    if (line.startsWith('@@')) continue;
    const span = document.createElement('span');
    span.className = line.startsWith('+') ? 'add' : line.startsWith('-') ? 'del' : '';
    span.textContent = line + '\n';
    pre.appendChild(span);
  }
  return pre;
}

function permissionCard(run, data) {
  const card = document.createElement('div');
  card.className = 'req-card req-permission';
  const head = document.createElement('div');
  head.className = 'req-head';
  head.innerHTML = `<span class="req-icon">${STEP_ICONS[data.stepKind] || UI.shield}</span><span class="req-title"></span>`;
  head.querySelector('.req-title').textContent = `要你同意：${data.title || data.tool || '一个操作'}`;
  card.appendChild(head);
  if (data.path) {
    const p = document.createElement('div');
    p.className = 'req-path';
    p.textContent = prettyPath(data.path);
    card.appendChild(p);
  }
  if (data.diff) card.appendChild(diffBlock(data.diff));
  else if (data.detail) {
    const pre = document.createElement('pre');
    pre.className = 'req-detail';
    pre.textContent = data.detail;
    card.appendChild(pre);
  }
  const why = document.createElement('input');
  why.className = 'req-input';
  why.placeholder = '不同意的话，可以告诉它该怎么做（可不填）';
  const row = document.createElement('div');
  row.className = 'req-actions';
  const once = data.onceOnly || (run.agent === 'deepseek' && run.reqId === 0);
  row.append(reqButton(once ? '允许一次' : '允许', 'primary', () => answerRequest(run, card, { decision: 'allow' })));
  if (!once) {
    const all = reqButton('这一轮都允许', '', () => answerRequest(run, card, { decision: 'allowAll' }));
    all.title = '这一轮回答里同一类操作不再问';
    row.append(all);
  }
  row.append(reqButton('拒绝', 'danger', () => answerRequest(run, card, { decision: 'deny', message: why.value.trim() })));
  row.lastChild.title = '拒绝这一次';
  why.addEventListener('keydown', e => { if (e.key === 'Enter' && !e.isComposing) row.lastChild.click(); });
  if (data.supportsDenyReason) card.appendChild(why);
  card.appendChild(row);
  return card;
}

function questionCard(run, data) {
  const card = document.createElement('div');
  card.className = 'req-card req-question';
  const questions = Array.isArray(data.questions) ? data.questions : [];
  const picked = questions.map(() => new Set());
  const others = [];
  const submit = () => {
    for (const [i,q] of questions.entries()) {
      if (q.required && !picked[i].size && !others[i]?.value.trim()) {
        const field = others[i] || card.querySelectorAll('.req-q')[i].querySelector('.req-option');
        field?.focus();
        if (field) { field.setCustomValidity(others[i] ? '请填写这一项' : '请选择一项'); field.reportValidity(); }
        return;
      }
      others[i]?.setCustomValidity('');
      if (!['integer','number'].includes(q.valueType)) continue;
      const field = others[i], value = field.value.trim();
      let valid = !q.required;
      if (value && q.valueType === 'integer') {
        valid = /^[+-]?\d+$/.test(value) && BigInt(value) >= -(1n << 63n) && BigInt(value) < (1n << 63n);
      } else if (value) {
        valid = /^[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?$/i.test(value) && Number.isFinite(Number(value));
      }
      field.setCustomValidity(valid ? '' : q.valueType === 'integer' ? '请填写有效整数' : '请填写有效数字');
      if (!valid) { field.focus(); field.reportValidity(); return; }
    }
    const answers = {}, answerParts = {};
    questions.forEach((q, i) => {
      const parts = [...picked[i]];
      const custom = others[i]?.value.trim() || '';
      answerParts[q.id || q.question] = {selected: [...parts], custom};
      if (custom) parts.push(custom);
      answers[q.id || q.question] = parts.join('、');   // 有编号的题按编号交回：两题文字相同也不串
    });
    answerRequest(run, card, { decision: 'allow', answers, answerParts });
  };
  if (data.message) {   // MCP 表单的说明（它要你填什么）
    const head = document.createElement('div');
    head.className = 'req-q-title';
    head.textContent = data.message;
    card.appendChild(head);
  }
  questions.forEach((q, i) => {
    const block = document.createElement('div');
    block.className = 'req-q';
    const title = document.createElement('div');
    title.className = 'req-q-title';
    title.textContent = q.question || q.header || '';
    block.appendChild(title);
    const prior = data.answerParts?.[q.id || q.question];
    const opts = document.createElement('div');
    opts.className = 'req-options';
    (q.options || []).forEach(o => {
      const b = document.createElement('button');
      b.className = 'req-option';
      if (prior?.selected?.includes(o.label)) { picked[i].add(o.label); b.classList.add('on'); }
      b.innerHTML = '<span class="req-option-label"></span><span class="req-option-desc"></span>';
      b.querySelector('.req-option-label').textContent = o.label;
      b.querySelector('.req-option-desc').textContent = o.description || '';
      b.addEventListener('click', () => {
        if (q.multiSelect) {
          picked[i].has(o.label) ? picked[i].delete(o.label) : picked[i].add(o.label);
          b.classList.toggle('on', picked[i].has(o.label));
        } else {
          if (others[i]) others[i].value = '';
          picked[i].clear();
          picked[i].add(o.label);
          opts.querySelectorAll('.req-option').forEach(x => x.classList.toggle('on', x === b));
          if (questions.length === 1) submit();   // 只有一个单选题：点了就答
        }
      });
      opts.appendChild(b);
    });
    block.appendChild(opts);
    // isOther 为 false：只能从选项里选，不给输入框；isSecret：输入框按密码显示
    if (q.isOther === false && (q.options || []).length) { others.push(null); card.appendChild(block); return; }
    const other = document.createElement('input');
    other.className = 'req-input';
    other.value = prior?.custom || '';
    if (q.isSecret) other.type = 'password';
    other.placeholder = !(q.options || []).length ? '写下你的回答' : q.multiSelect ? '还有别的？写在这里' : '都不是？写下你的回答';
    if (!q.multiSelect) other.addEventListener('input', () => {
      if (!other.value.trim()) return;
      picked[i].clear();
      opts.querySelectorAll('.on').forEach(x => x.classList.remove('on'));
    });
    other.addEventListener('keydown', e => { if (e.key === 'Enter' && !e.isComposing) submit(); });
    others.push(other);
    block.appendChild(other);
    card.appendChild(block);
  });
  const row = document.createElement('div');
  row.className = 'req-actions';
  row.append(
    reqButton('回答', 'primary', submit),
    reqButton('不回答', '', () => answerRequest(run, card, { decision: 'deny', message: '用户没有回答这个问题，请按你自己的判断继续。' })),
  );
  card.appendChild(row);
  return card;
}

function planCard(run, data) {
  const card = document.createElement('div');
  card.className = 'req-card req-plan';
  const head = document.createElement('div');
  head.className = 'req-head';
  head.innerHTML = `<span class="req-icon">${STEP_ICONS.todo || UI.tool}</span><span class="req-title">计划写好了，要照这个做吗？</span>`;
  const body = document.createElement('div');
  body.className = 'req-plan-body md';
  body.innerHTML = renderRich(data.plan || '（没有给出计划内容）');
  const why = document.createElement('input');
  why.className = 'req-input';
  why.placeholder = '要改的话，告诉它哪里要改';
  const row = document.createElement('div');
  row.className = 'req-actions';
  if (run.agent === 'deepseek') {
    row.append(reqButton('批准计划', 'primary', () => answerRequest(run, card, { decision: 'allow' })));
  } else {
    row.append(
      reqButton('批准，直接做完', 'primary', () => answerRequest(run, card, { decision: 'allow', mode: 'bypassPermissions' })),
      reqButton('批准，每步来问我', '', () => answerRequest(run, card, { decision: 'allow' })),
    );
  }
  row.append(
    reqButton('先改计划', 'danger', () => answerRequest(run, card, { decision: 'deny', message: why.value.trim() || '计划需要修改，请先和我确认。' })),
  );
  why.addEventListener('keydown', e => { if (e.key === 'Enter' && !e.isComposing) row.lastChild.click(); });
  card.append(head, body, why, row);
  return card;
}

function requestCard(run, data) {
  if (data.kind === 'question') return questionCard(run, data);
  const card = data.kind === 'plan' ? planCard(run, data) : permissionCard(run, data);
  if (data.message) {
    const reason = document.createElement('div');
    reason.className = 'req-detail';
    reason.textContent = data.message;
    card.querySelector('.req-actions').before(reason);
  }
  return card;
}
const requestSay = kind => kind === 'question' ? '有个问题要问你' : kind === 'plan' ? '计划写好了，等你批准' : '这一步要你同意';

/**
 * 没有回合接着的请求（reqId 0、带会话编号）：DeepSeek 自己开的一轮（后台任务唤醒、子智能体回报）里来问，这里没有在答的回合。
 * 正看着这个会话就把卡片接在对话末尾，否则把这个会话标成未读、桌宠说一声；点开会话读完历史后原生会再发一次（重画时卡片跟着补回）。
 */
function unattendedRequest(data) {
  const id = data.agent, st = S[id];
  if (!st) return;
  const here = st.conversationId === data.conversationId && st.loadedId === data.conversationId;
  let fresh = !here;
  if (id === 'deepseek') {
    st.unattendedSince ??= new Map();
    if (!st.unattendedSince.has(data.requestId)) st.unattendedSince.set(data.requestId,{cid:data.conversationId, since:Date.now()});
  }
  if (here) {
    const msgBox = st.msgEl, stick = nearBottom(msgBox);
    let box = msgBox.querySelector(':scope > .live-requests.unattended');
    if (!box) { box = document.createElement('div'); box.className = 'live-requests unattended'; }
    if (![...box.children].some(c => c.dataset.requestId === data.requestId)) {
      const card = requestCard({ agent: id, reqId: data.reqId }, data);
      card.dataset.requestId = data.requestId;
      card.dataset.since = Date.now();
      box.appendChild(card);
      fresh = true;
    }
    msgBox.appendChild(box);   // 一直放在最后：后台同步接上的新内容不压到它下面
    if (stick) scrollToBottom(msgBox);
  }
  pets[id]?.syncBusyState();
  if (!here || id !== active) { setConversationUnread(id, data.conversationId, true); refreshUnread(id); renderHistory(id); }
  if (fresh) pets[id]?.say(requestSay(data.kind), 4000);
}

window.onAgentRequest = data => {
  const id = data.agent;
  const run = S[id]?.runs.get(data.reqId);
  if (!run && data.conversationId) { unattendedRequest(data); return; }
  const box = run && requestBox(run);
  if (!box || [...box.children].some(c => c.dataset.requestId === data.requestId)) return;
  const card = requestCard(run, data);
  card.dataset.requestId = data.requestId;
  const msgBox = S[id].msgEl;
  const stick = run.live.el.isConnected && nearBottom(msgBox);
  box.appendChild(card);
  if (stick) scrollToBottom(msgBox);
  run.waiting = (run.waiting || 0) + 1;
  if (histSections[id]) renderHistory(id);
  pets[id]?.renderStatus();
  // 没在看这个会话：标成未读，桌宠说一声
  refreshUnread(id);
  pets[id]?.say(requestSay(data.kind), 4000);
};

window.onAgentRequestClosed = data => {
  const run = S[data.agent]?.runs.get(data.reqId);
  if (!run) {   // 没有回合接着的那种（见 unattendedRequest）
    S[data.agent]?.msgEl.querySelectorAll(':scope > .live-requests.unattended > .req-card').forEach(c => { if (c.dataset.requestId === data.requestId) c.remove(); });
    if (S[data.agent]?.unattendedSince?.delete(data.requestId) && histSections[data.agent]) renderHistory(data.agent);
    pets[data.agent]?.syncBusyState();
    return;
  }
  if (!run?.live?.requests) return;
  run.waiting = Math.max(0, (run.waiting || 0) - 1);
  refreshUnread(data.agent);
  if (histSections[data.agent]) renderHistory(data.agent);
  pets[data.agent]?.renderStatus();
  [...run.live.requests.children].filter(c => c.dataset.requestId === data.requestId).forEach(c => c.remove());
};
