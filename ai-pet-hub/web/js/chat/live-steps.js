'use strict';

// 回答进行中：实时显示工作步骤，正在写的文字显示在正文位置。

// ===== 回答进行中：实时显示工作步骤 =====
function nearBottom(box) { return box.scrollHeight - box.scrollTop - box.clientHeight < 80; }

function startLiveTurn(id, run) {
  const box = S[id].msgEl;
  box.querySelector('.chat-empty')?.remove();
  const el = document.createElement('div');
  el.className = 'msg bot turn live';
  el.dataset.cwd = run.workspace;
  el._files = [];
  const work = renderWork([], '正在工作', true);
  work.classList.add('live');
  work.querySelector('.work-head .chev').remove();
  el.appendChild(work);
  const answer = document.createElement('div');   // 正在写的回答：边生成边显示在正文位置
  answer.className = 'answer md live-answer';
  el.appendChild(answer);
  box.appendChild(el);
  scrollToBottom(box);
  run.live = { el, work, answer, list: work.querySelector('.work-steps'), steps: [] };
  updateLiveLabel(run);
  return el;
}

function updateLiveStep(run, index, step) {
  const live = run.live;
  if (!live) return;
  const box = S[run.agent].msgEl;
  const stick = live.el.isConnected && nearBottom(box);
  const node = step.kind === 'text' && step.status === 'running' ? lazyTextStep() : renderStep(step);
  const old = live.list.children[index];
  if (old) live.list.replaceChild(node, old);
  else live.list.appendChild(node);
  live.steps[index] = step;
  // 最后一步是说明文字：当作正在写的回答显示在正文位置（工作过程里先藏起来，后面有新步骤时它就变回中途说明）
  let last = live.steps.length - 1;
  while (last >= 0 && !live.steps[last]) last--;
  const lastStep = live.steps[last];
  const asAnswer = lastStep && lastStep.kind === 'text' ? live.list.children[last] : null;
  [...live.list.children].forEach((n, i) => {
    n.classList.remove('as-answer');
    // 空壳只在它当作正文显示（藏着）时用；后面有了新步骤、它变回中途说明，就补上内容
    if (n.dataset.lazy && n !== asAnswer && live.steps[i]) live.list.replaceChild(renderStep(live.steps[i]), n);
  });
  if (asAnswer) {
    streamTo(run, lastStep.detail || '', lastStep.status !== 'running');
    asAnswer.classList.add('as-answer');
  } else {
    streamTo(run, '', true);
  }
  syncRunPhase(run);
  updateLiveLabel(run);
  pets[run.agent]?.syncBusyState();
  if (stick) scrollToBottom(box);
}

function updateLiveLabel(run) {
  if (!run.live) return;
  const latest = [...run.live.steps].reverse().find(s => s && s.kind !== 'text' && s.kind !== 'user');
  const head = run.live.work.querySelector('.work-head');
  const meta = PHASE_META[run.phase || 'thinking'] || PHASE_META.thinking;
  head.querySelector('.work-label').textContent = `${meta.workLabel} · ${elapsedSince(run.since)}`;
  head.querySelector('.work-meta').textContent = latest ? latest.title : AGENTS[run.agent].thinkLine;
}

const elapsedSince = t => `${Math.max(0, Math.round((Date.now() - t) / 1000))}s`;

/** 把当前会话里正在进行的回答（提问 + 进行中的过程）接到聊天区末尾。 */
function attachRuns(id) {
  const box = S[id].msgEl;
  const running = runsOf(id, viewKey(id));
  if (!running.length) return;
  box.querySelector('.chat-empty')?.remove();
  running.forEach(r => r.nodes.forEach(n => box.appendChild(n)));
  scrollToBottom(box);
}
const prettyPath = p => p.replace(/^\/Users\/[^/]+/, '~');
const isHomeLike = p => !p || p === '/' || /^\/Users\/[^/]+\/?$/.test(p);
const wsKey = cwd => (isHomeLike(cwd || '') ? '' : String(cwd).replace(/\/+$/, ''));
const baseName = p => p.split('/').filter(Boolean).pop() || p;

function relTime(ts) {
  const s = Math.max(0, Date.now() / 1000 - (ts || 0));
  if (s < 60) return '刚刚';
  if (s < 3600) return `${Math.floor(s / 60)}分钟`;
  if (s < 86400) return `${Math.floor(s / 3600)}小时`;
  if (s < 86400 * 30) return `${Math.floor(s / 86400)}天`;
  if (s < 86400 * 365) return `${Math.floor(s / 86400 / 30)}个月`;
  return `${Math.floor(s / 86400 / 365)}年`;
}

function currentTitle(id) {
  const st = S[id];
  if (!st.conversationId) return '新对话';
  const item = [...(st.conversations || []), ...liveItems(id)].find(c => c.id === st.conversationId);
  return item ? item.title : `会话 ${st.conversationId.slice(0, 8)}`;
}

/** 顶栏下面那条线平时不画，聊天内容滚到它下面时才出现。 */
function syncHeaderLine(scroller = S[active].msgEl) {
  document.getElementById('chat-header').classList.toggle('scrolled', !!scroller && scroller.scrollTop > 4);
}
document.addEventListener('scroll', e => {
  if (e.target instanceof Element && e.target === S[active].msgEl) syncHeaderLine(e.target);
}, true);

function renderHeader() {
  syncHeaderLine();
  const c = AGENTS[active];
  const st = S[active];
  els.badge.innerHTML = ICONS[active];
  els.name.textContent = c.name;
  // 工作空间 › 会话标题：工作空间在左栏里选（参考反重力），这里只显示，点一下在访达中打开
  const ws = wsKey(st.workspace);
  els.wsCrumb.classList.toggle('none', !ws);
  els.wsCrumb.querySelector('.ws-name').textContent = ws ? baseName(ws) : '未绑定工作空间';
  els.wsCrumb.title = ws ? `工作空间：${prettyPath(ws)}\n点击在访达中打开` : '未绑定工作空间（在主目录运行）\n在左栏点文件夹图标选择工作空间';
  els.convLabel.textContent = currentTitle(active);
  els.convLabel.title = st.conversationId ? `会话 ID：${st.conversationId}` : '';
}
