'use strict';

// 发送、停止、切换到另一位。

// ===== 发送 / 停止 / 切换 =====
function updateSendUI() {
  const busy = viewBusy(active);   // 只看当前这个会话；别的会话在回答不影响这里发送
  els.sendBtn.disabled = false;
  els.sendBtn.classList.toggle('stop', busy);
  els.sendBtn.innerHTML = busy ? UI.stop : UI.send;
  els.sendBtn.title = busy ? '停止这个会话的回答（想补充一句：直接输入，按 Enter）' : '发送（Enter）';
}

function updateIndicators(id) {
  const st = S[id];
  const sec = histSections[id] && histSections[id].sec;
  if (sec) {
    sec.classList.toggle('busy', isBusy(id));
    sec.classList.toggle('unread', !isBusy(id) && st.unread);
  }
  pets[id].renderStatus();
}

function autosize() {
  els.input.style.height = 'auto';
  els.input.style.height = Math.min(200, els.input.scrollHeight) + 'px';
}

/** 输入框里的话（和附着的图片）发出去。这个会话还在回答就交给排队（live.js）；否则开始新的一轮。 */
function send() {
  const id = active;
  const st = S[id];
  const text = els.input.value.trim();
  const images = takeAttachments(id);   // 输入框上面附的图片（composer.js）
  if (!text && !images.length) return;
  els.input.value = '';
  st.draft = '';
  lsSet(`${id}_draft`, '');
  autosize();
  closePopover();
  if (text) rememberPrompt(id, text);
  st.lastPrompt = text;
  const prompt = text || '请看这张图片。';
  if (viewBusy(id)) {
    // 这句话送进去（它做完手头这一步就看到），送不进去就排着、这一轮结束后自动发。图片跟着这句话走
    queueMessage(id, prompt, images);
    updateSendUI();
    return;
  }
  startRun(id, text, images);
}

/** 开始新的一轮回答：记一个 run、显示用户消息和「正在工作」、交给原生去问。 */
function startRun(id, text, images) {
  const st = S[id];
  pets[id].moodEvent('sent');
  const run = {
    agent: id,
    reqId: ++reqCounter,
    view: viewKey(id),
    text,
    since: Date.now(),
    workspace: st.workspace || '',
    fast: fastOn(id),          // 这一轮开着 fast（桌宠换成 fast 的样子）
    phase: 'thinking',
    stepKind: 'think',
    stepTitle: '思考中',
    stepStatus: 'running',
    stepAt: Date.now(),
    nodes: [],
  };
  st.runs.set(run.reqId, run);
  // 气泡里把图片的路径接在话后面：下面会把它们换成缩略图
  const shownText = [text, ...images].filter(Boolean).join('\n');
  const userEl = appendMessage(id, 'user', shownText);
  requestMessageImages(userEl, shownText, st.workspace || '');
  if (!st.conversationId) {   // 新对话：左栏「新对话」先显示这句话
    run.title = text.replace(/\s+/g, ' ').slice(0, 60);
    st.pendingTitle = run.title;
  }
  run.nodes = [userEl, startLiveTurn(id, run)];
  renderHistory(id);
  updateIndicators(id);
  updateSendUI();
  pets[id].setBusy(true);

  postNative('askAgent', {
    agent: id,
    reqId: run.reqId,
    prompt: text || '请看这张图片。',
    images,                          // 作为真正的图片交给模型（原生读文件）
    browserTools: browserToolsOn(),  // 带不带内置浏览器的工具
    fast: run.fast,                  // fast 档（模型没有的话是 false）
    model: st.model,
    effort: st.effort,
    permissionMode: st.perm,
    workspace: st.workspace,
    conversationId: st.conversationId,
  });
  if (!hasBridge()) demoReply(id, run);
}

/** 没有连原生（在普通浏览器里预览界面）：演几步假的过程，方便看样子。 */
function demoReply(id, run) {
  const step = (index, s, ms) => setTimeout(() => window.onAgentStep({ agent: id, reqId: run.reqId, index, step: s }), ms);
  step(0, { kind: 'think', title: '思考过程', status: 'running', text: '正在分析请求与上下文…' }, 250);
  step(1, { kind: 'read', title: 'index.html', status: 'running' }, 1400);
  step(2, { kind: 'edit', title: 'base.css', status: 'running' }, 2600);
  setTimeout(() => window.onAgentResponse({ agent: id, reqId: run.reqId, reply: '（预览模式：没有连接本机 CLI）', conversationId: '' }), 3800);
}

/** 停止当前这个会话的回答（别的会话照常进行）。 */
function stop() {
  const id = active;
  const running = runsOf(id, viewKey(id));
  if (!running.length) return;
  running.forEach(r => postNative('cancelAgent', { agent: id, reqId: r.reqId }));
  els.sendBtn.disabled = true;
  setTimeout(() => { if (id === active) updateSendUI(); }, 4000);
}

function setActive(id, focusInput = true) {
  if (!AGENTS[id]) return;
  if (id !== active) {
    S[active].draft = els.input.value;
    lsSet(`${active}_draft`, els.input.value);
    els.input.value = S[id].draft;
    autosize();
    closePopover();
  }
  active = id;
  lsSet('active', id);
  document.body.dataset.agent = id;
  AGENT_IDS.forEach(a => {
    S[a].msgEl.hidden = a !== id;
    pets[a].card.classList.toggle('active', a === id);
  });
  S[id].unread = false;
  updateIndicators(id);
  renderHeader();
  renderComposer();
  renderAllHistory();
  updateSendUI();
  els.input.placeholder = `给 ${AGENTS[id].name} 发消息（Enter 发送，Shift+Enter 换行）`;
  pets[id].touch();
  pets[id].syncBusyState();
  if (focusInput) els.input.focus();
}
