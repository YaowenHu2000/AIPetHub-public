'use strict';

// 回答进行中的交互（接在 stream.js 后面加载）：
//   · 智能体要做一件事先来问（权限不是「最高权限」时才会）：允许 / 这一轮都允许 / 拒绝；它提的问题、写好的计划
//   · 回答还没完又发来一句：能送进去的当场送（下一步之前它就看到），送不进去的排着，这一轮结束后自动发
// 原生那一半在 LiveTurn.swift / Prewarm.swift 和各位的 agent-*.swift。

// ===== 排队 / 中途补充 =====
let steerSeq = 0;

/** 这个会话正在回答时又发了一句。 */
function queueMessage(id, text, images = []) {
  const run = runsOf(id, viewKey(id))[0];
  if (!run) return false;
  const item = { sid: `s${Date.now()}-${++steerSeq}`, text, images, state: 'sending' };
  const el = document.createElement('div');
  el.className = 'msg user queued';
  el.innerHTML = '<div class="queued-text"></div><div class="queued-note"><span class="queued-state"></span><button class="queued-up" title="往前排一位"></button><button class="queued-now" title="不等了：停下正在做的，马上发这一句">立即发送</button><button class="queued-cancel" title="先不发：放回输入框，可以改了再发"></button></div>';
  el.querySelector('.queued-text').textContent = text + (images.length ? `\n📎 ${images.length} 张图片` : '');
  el.querySelector('.queued-cancel').innerHTML = UI.close;
  el.querySelector('.queued-cancel').addEventListener('click', () => {
    if (item.state !== 'waiting') return;
    dropQueued(run, item);
    restoreDraft(id, text);
    if (images.length) addAttachments(id, images, false);   // 图片也放回输入框上面
  });
  // 插队：停下正在进行的回答，马上发这一句（排着的其他话跟着一起发）
  el.querySelector('.queued-now').addEventListener('click', () => {
    if (!['waiting', 'sent'].includes(item.state) || item.jump) return;   // 已经送进去、但它手头的事还没做完（比如一条很久的命令）时也能插队
    item.jump = true;
    setQueuedState(item, item.state);
    postNative('cancelAgent', { agent: id, reqId: run.reqId });
  });
  el.querySelector('.queued-up').innerHTML = UI.arrowUp;
  el.querySelector('.queued-up').addEventListener('click', () => moveQueuedUp(run, item));
  item.el = el;
  item.run = run;
  (run.queue = run.queue || []).push(item);
  run.nodes.push(el);
  const box = S[id].msgEl;
  box.appendChild(el);
  scrollToBottom(box);
  setQueuedState(item, 'sending');
  if (hasBridge()) postNative('steerAgent', { agent: id, reqId: run.reqId, text, images, steerId: item.sid });
  else setQueuedState(item, 'waiting');
  return true;
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
  const before = [item, other].map(x => x.el.getBoundingClientRect().top);
  q.splice(i, 1);
  q.splice(j, 0, item);
  other.el.parentNode.insertBefore(item.el, other.el);
  [item, other].forEach((x, k) => {
    const moved = before[k] - x.el.getBoundingClientRect().top;
    x.el.animate([{ transform: `translateY(${moved}px)` }, { transform: 'none' }], { duration: SPRING_EASE.snappy.ms, easing: SPRING_EASE.snappy.css });
  });
  refreshQueueOrder(run);
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
  if (data.state === 'consumed') run.steered = true;
  if (item.jump) return;   // 已经点了「立即发送」：这一轮正在停，这句话等它停下后重新发，不管 CLI 那边轮没轮到
  if (data.state === 'consumed') {
    // CLI 收下了这句话，但它手头有一条命令还在跑（Codex 会这样）：跑完才轮得到。气泡先留着，可以点「立即发送」打断
    if (commandRunning(run)) { item.held = true; setQueuedState(item, 'sent'); return; }
    dropQueued(run, item);
  }
  else setQueuedState(item, data.state === 'sent' ? 'sent' : 'waiting');
};

/**
 * 这一轮结束了：还排着的话接着发（合成一句）；这一轮是被停止的就不自动发，放回输入框——除非是点「立即发送」插队停的。
 * 在 onAgentResponse 的最后调用。
 */
function flushQueue(id, run, data) {
  (run.queue || []).filter(q => q.held && !q.jump).forEach(q => dropQueued(run, q));   // CLI 已经收下的：不用再发
  const left = run.queue || [];
  if (!left.length) return;
  left.forEach(item => item.el.remove());
  run.queue = [];
  const text = left.map(q => q.text).join('\n\n');   // 发不了时放回输入框用
  const here = id === active && (viewKey(id) === run.view || viewKey(id) === data.conversationId);
  const jump = left.some(q => q.jump);   // 点了「立即发送」：这一轮是为了插队才停的，接着发
  if (queueAction({ cancelled: !!data.cancelled, failed: /^⚠️/.test((data.reply || '').trim()), here, busy: viewBusy(id), jump }) === 'restore') {
    restoreDraft(id, text);   // 没法接着发（停止了 / 出错了 / 已经切到别的会话）：放回输入框，不丢
    const imgs = left.flatMap(q => q.images || []);
    if (imgs.length) addAttachments(id, imgs, false);
    return;
  }
  // 一句一句发：先发第一句（连它带的图片），其余的接着排在它后面（能送进去的会送进去，送不进去的等它答完再发下一句）
  startRun(id, left[0].text, left[0].images || []);
  left.slice(1).forEach(q => queueMessage(id, q.text, q.images || []));
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
  row.append(
    reqButton('允许', 'primary', () => answerRequest(run, card, { decision: 'allow' })),
    reqButton('这一轮都允许', '', () => answerRequest(run, card, { decision: 'allowAll' })),
    reqButton('拒绝', 'danger', () => answerRequest(run, card, { decision: 'deny', message: why.value.trim() })),
  );
  row.lastChild.title = '拒绝这一次';
  row.children[1].title = '这一轮回答里同一类操作不再问';
  why.addEventListener('keydown', e => { if (e.key === 'Enter' && !e.isComposing) row.lastChild.click(); });
  card.append(why, row);
  return card;
}

function questionCard(run, data) {
  const card = document.createElement('div');
  card.className = 'req-card req-question';
  const questions = Array.isArray(data.questions) ? data.questions : [];
  const picked = questions.map(() => new Set());
  const others = [];
  const submit = () => {
    const answers = {};
    questions.forEach((q, i) => {
      const parts = [...picked[i]];
      if (others[i].value.trim()) parts.push(others[i].value.trim());
      answers[q.question] = parts.join('、');
    });
    answerRequest(run, card, { decision: 'allow', answers });
  };
  questions.forEach((q, i) => {
    const block = document.createElement('div');
    block.className = 'req-q';
    const title = document.createElement('div');
    title.className = 'req-q-title';
    title.textContent = q.question || q.header || '';
    block.appendChild(title);
    const opts = document.createElement('div');
    opts.className = 'req-options';
    (q.options || []).forEach(o => {
      const b = document.createElement('button');
      b.className = 'req-option';
      b.innerHTML = '<span class="req-option-label"></span><span class="req-option-desc"></span>';
      b.querySelector('.req-option-label').textContent = o.label;
      b.querySelector('.req-option-desc').textContent = o.description || '';
      b.addEventListener('click', () => {
        if (q.multiSelect) {
          picked[i].has(o.label) ? picked[i].delete(o.label) : picked[i].add(o.label);
          b.classList.toggle('on', picked[i].has(o.label));
        } else {
          picked[i].clear();
          picked[i].add(o.label);
          opts.querySelectorAll('.req-option').forEach(x => x.classList.toggle('on', x === b));
          if (questions.length === 1) submit();   // 只有一个单选题：点了就答
        }
      });
      opts.appendChild(b);
    });
    block.appendChild(opts);
    const other = document.createElement('input');
    other.className = 'req-input';
    other.placeholder = q.multiSelect ? '还有别的？写在这里' : '都不是？写下你的回答';
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
  row.append(
    reqButton('批准，直接做完', 'primary', () => answerRequest(run, card, { decision: 'allow', mode: 'bypassPermissions' })),
    reqButton('批准，每步来问我', '', () => answerRequest(run, card, { decision: 'allow' })),
    reqButton('先改计划', 'danger', () => answerRequest(run, card, { decision: 'deny', message: why.value.trim() || '计划需要修改，请先和我确认。' })),
  );
  why.addEventListener('keydown', e => { if (e.key === 'Enter' && !e.isComposing) row.lastChild.click(); });
  card.append(head, body, why, row);
  return card;
}

window.onAgentRequest = data => {
  const id = data.agent;
  const run = S[id]?.runs.get(data.reqId);
  const box = run && requestBox(run);
  if (!box) return;
  const card = data.kind === 'question' ? questionCard(run, data) : data.kind === 'plan' ? planCard(run, data) : permissionCard(run, data);
  card.dataset.requestId = data.requestId;
  const msgBox = S[id].msgEl;
  const stick = run.live.el.isConnected && nearBottom(msgBox);
  box.appendChild(card);
  if (stick) scrollToBottom(msgBox);
  run.waiting = (run.waiting || 0) + 1;
  // 没在看这个会话：标成未读，桌宠说一声
  if (id !== active || !run.live.el.isConnected) { S[id].unread = true; updateIndicators(id); }
  pets[id]?.say(data.kind === 'question' ? '有个问题要问你' : data.kind === 'plan' ? '计划写好了，等你批准' : '这一步要你同意', 4000);
};

window.onAgentRequestClosed = data => {
  const run = S[data.agent]?.runs.get(data.reqId);
  if (!run?.live?.requests) return;
  run.waiting = Math.max(0, (run.waiting || 0) - 1);
  [...run.live.requests.children].filter(c => c.dataset.requestId === data.requestId).forEach(c => c.remove());
};
