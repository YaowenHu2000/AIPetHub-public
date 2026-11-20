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

/**
 * 这位的当前会话已经摆在用户面前：清掉它的未读，AI 级未读（左栏标题的点、桌宠的「有新回复」）只看还剩什么没读——
 * 别的会话答完没看的，或别的会话里等着用户批准 / 回答的。以前两级分开清：点回已载入的会话不清会话行，
 * 同一位的会话间切换不清桌宠。
 */
function markSeen(id) {
  const st = S[id];
  const cleared = !!st.conversationId && setConversationUnread(id, st.conversationId, false);
  refreshUnread(id);
  return cleared;
}

function refreshUnread(id) {
  const st = S[id];
  // 最近列表可能截在第 300 条；只有单条读取确认删除后才清未读。
  st.unread = st.unreadConvs.size > 0
    || [...st.runs.values()].some(r => r.waiting > 0 && (id !== active || r.view !== viewKey(id)));
  updateIndicators(id);
}

function autosize() {
  els.input.style.height = 'auto';
  els.input.style.height = Math.min(200, els.input.scrollHeight) + 'px';
}

/** 输入框里的话（和附着的图片）发出去。这个会话还在回答就交给排队（live.js）；否则开始新的一轮。 */
function send() {
  if (!welcome.hidden) return;
  const id = active;
  const st = S[id];
  const pending = pastesInView(id).at(-1);
  if (pending) {
    pending.sendText = els.input.value;
    // 等图的这次发送已经选定目标；切走时整份草稿要一起留在这个会话。
    claimDraft(id);
    return;
  }
  const draft = {...draftAttachments(st), text:els.input.value};
  takeAttachments(id);
  const { text, images } = attachmentsForSend(draft.text.trim(), draft.paths);   // 附的图片和文件（composer.js）
  if (!text && !images.length) return;
  setDraft(id, '');
  sentDraft(id);
  autosize();
  closePopover();
  if (text) rememberPrompt(id, text);
  st.lastPrompt = text;
  const prompt = text || '请看这张图片。';
  if (viewBusy(id)) {
    // 这句话送进去（它做完手头这一步就看到），送不进去就排着、这一轮结束后自动发。图片跟着这句话走
    queueMessage(id, prompt, images, draft);
    updateSendUI();
    return;
  }
  startRun(id, text, images, [], draft);
}

/** 开始新的一轮回答：记一个 run、显示用户消息和「正在工作」、交给原生去问。 */
function startRun(id, text, images = [], imageRefs = [], draft = null, restored = null, thumbnails = null, sentPaths = null) {
  const st = S[id];
  if (!restored) { discardHistoryRefreshes(st); pets[id].moodEvent('sent'); }
  const run = {
    agent: id,
    reqId: restored?.reqId ?? nextRequestId(),
    view: viewKey(id),
    text, draft, thumbnails, sentPaths: {...(restored?.sentPaths || sentPaths)},
    prompt: text || '请看这张图片。',
    images: images.slice(),
    preparingImages: hasBridge() && (images.length || imageRefs.length) && !restored?.restoredPaths,
    imageRefs: imageRefs.slice(),   // 重试时只剩会话记录里有的图片（ChatImages.swift 的 ref）
    // 和历史条目同一口径（同 message-sync.js 的 syncAppend）：读入的压缩提示也占一条，漏数会截错位置、同一句显示两遍
    historyStart: !st.conversationId ? 0 : st.loadedId === st.conversationId
      ? (st.shownOmitted || 0) + shownHistoryLength(st.msgEl) : null,
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
  if (restored) {
    run.workspace = restored.workspace || '';
    run.view = restored.conversationId || (st.workspace === run.workspace && !st.conversationId && !viewBusy(id) ? st.newView : 'new:restore-' + run.reqId);
    run.historyStart = restored.historyStart ?? null;
    run.returnedQueue = restored.returnedQueue;
    run.imageKeys = restored.imageKeys;
    run.restoredPaths = restored.restoredPaths;
    run.since = restored.since || run.since;
    run.fast = !!restored.fast;
  }
  const box = run.view === viewKey(id) ? st.msgEl : document.createElement('div');
  st.runs.set(run.reqId, run);
  // 气泡里把图片的路径接在话后面：下面会把它们换成缩略图
  const sent = sentAttachments(run);
  const shownText = [text, ...images].filter(Boolean).join('\n');
  const userEl = appendMessage(id, 'user', shownText, thumbnails, box);
  userEl._run = run;   // 打开历史、记录还没读回来就发的：回包时据此认出记录里是否已有这一轮（native-callbacks.js）
  if (!thumbnails?.length && (!images.length || Object.keys(run.sentPaths).length || restored?.restoredPaths?.length)) requestMessageImages(userEl, shownText, run.workspace, sent.ordered.filter(Boolean));
  if (!st.conversationId && box === st.msgEl) {   // 新对话：左栏「新对话」先显示这句话
    run.title = text.replace(/\s+/g, ' ').slice(0, 60);
    st.pendingTitle = run.title;
  }
  run.nodes = [userEl, startLiveTurn(id, run, box)];
  renderHistory(id);
  updateIndicators(id);
  updateSendUI();
  pets[id].setBusy(true);

  if (restored) {
    for (const step of restored.steps || []) window.onAgentStep(step);
    for (const item of restored.queue || []) queueMessage(id, item.text, item.sourceImages || item.images, item.draft, run, item);
    for (const card of restored.cards || []) window.onAgentRequest(card);
    if (box === st.msgEl && st.loadedId && restored.conversationId) {
      postNative('loadConversation', {agent:id, conversationId:restored.conversationId});
    }
    return;
  }
  noteSent();
  postNative('askAgent', {
    agent: id,
    reqId: run.reqId,
    prompt: run.prompt,
    text, draft, historyStart: run.historyStart,
    sourceImages: run.images, sentPaths: run.sentPaths,
    images: sent.images, // 作为真正的图片交给模型（原生读文件）
    imageRefs: sent.refs,        // 原生从会话记录取回原图，和 images 一起发
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

window.onRestoreActiveTurn = data => {
  if (!S[data.agent] || S[data.agent].runs.has(data.reqId)) return;
  startRun(data.agent, data.text ?? data.prompt, data.sourceImages || data.images || [], data.imageRefs || [], data.draft, data);
};

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

function setActive(id, focusInput = true, seen = true) {
  if (!AGENTS[id]) return;
  if (id !== active) {
    refreshHistory(id,true);
    setDraft(active, els.input.value);
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
  const pending = S[id].pendingScroll;   // 后台载入、还没显示过的会话：现在有高度了，补上载入时落空的定位（native-callbacks.js）
  if (pending) {
    S[id].pendingScroll = null;
    S[id].msgEl.scrollTop = S[id].msgEl.scrollHeight - pending.fromBottom;
  }
  if (seen) markSeen(id);
  renderHeader();
  renderComposer();
  renderAllHistory();
  updateSendUI();
  els.input.placeholder = `给 ${AGENTS[id].name} 发消息（Enter 发送，Shift+Enter 换行）`;
  pets[id].touch();
  pets[id].syncBusyState();
  if (focusInput) els.input.focus();
}
