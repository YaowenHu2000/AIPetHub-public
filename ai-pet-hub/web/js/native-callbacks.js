'use strict';

// 原生调过来的回调：历史列表、会话内容、回答的步骤和结果、文件核对等。

// ===== 原生回调 =====
window.onConversationsListed = data => {
  const st = S[data.agent];
  if (!st) return;
  // 「添加 AI」时验证用的那句话（在临时目录 aipethub-verify 里问的）不算会话，不列出来
  st.conversations = (Array.isArray(data.items) ? data.items : []).filter(c => !/\/aipethub-verify\/?$/.test(c.cwd || ''));
  renderHistory(data.agent);
  if (data.agent === active) renderHeader();
  noteListedStamp(data.agent);   // 打开着的会话在别处动了没有（chat/elsewhere.js）
};

window.onConversationLoaded = data => {
  const id = data.agent;
  const st = S[id];
  if (!st || data.conversationId !== st.conversationId) return;
  if (data.missing && !viewBusy(id)) {
    st.conversationId = '';
    st.loadedId = '';
    st.applyCwdOnLoad = false;
    lsSet(`${id}_conv`, '');
    showEmpty(id);
    renderHistory(id);
    if (id === active) renderHeader();
    return;
  }
  st.loadedId = data.conversationId;
  if (st.applyCwdOnLoad) {
    st.applyCwdOnLoad = false;
    // 继续历史会话时，工作空间跟随该会话原来的目录
    if (typeof data.cwd === 'string') setWorkspace(id, wsKey(data.cwd), false);
  }
  // 压缩上下文的命令不算一句话（有的 CLI 会把它记成一句提问）：不显示
  const messages = (Array.isArray(data.messages) ? data.messages : []).filter(m => !(m.role === 'user' && isCompactCommand(m.text)));
  const last = messages[messages.length - 1] || {};
  const sig = `${messages.length}|${data.omitted || 0}|${(last.text || '').length}|${(last.steps || []).length}`;
  const syncing = st.syncing;
  st.syncing = false;
  if (syncing && (sig === st.loadedSig || viewBusy(id))) return;   // 后台同步：没变化（或正在回答）就不动
  // 没人在这里答，内容却变了：它在别处跑着（chat/elsewhere.js）。
  // 例外：这里自己刚答完一轮之后的第一次同步——记录里多出来的就是刚才那一轮，只是对一下账
  if (syncing && st.ownTurnUnsynced) st.ownTurnUnsynced = false;
  else if (syncing) noteElsewhere(id);
  else { st.elsewhereAt = 0; noteListedStamp(id); }
  st.loadedSig = sig;
  const box = st.msgEl;
  if (syncing && syncAppend(id, messages, data.cwd || S[id].workspace || '', data.omitted || 0)) { markElsewhere(id); return; }   // 只多了几条：接在后面，已有的不动
  const keepScroll = syncing && !nearBottom(box) ? box.scrollTop : null;   // 正在往上翻看时，同步后留在原处
  st.shownLimit = data.limit || 300;
  renderMessages(id, messages, data.cwd || S[id].workspace || '', data.omitted || 0);
  if (keepScroll !== null) box.scrollTop = keepScroll;
  if (st.keepFromBottom) { box.scrollTop = box.scrollHeight - st.keepFromBottom; st.keepFromBottom = 0; }   // 刚点了「显示更早的」
  markElsewhere(id);
  if (!syncing) askSessionLive();   // 刚打开：它是不是正开在别的程序里（chat/fork.js）
  if (!syncing) jumpToSearchHit(id);   // 是从搜索结果点进来的：跳到正文里命中的那一条（composer.js）
};

window.onConversationDeleted = data => {
  const id = data.agent;
  const st = S[id];
  if (!st) return;
  if (!data.ok) { pets[id].say('删除失败了…', 1800); return; }
  if (st.conversations) st.conversations = st.conversations.filter(c => c.id !== data.conversationId);
  st.unreadConvs.delete(data.conversationId);
  if (st.conversationId === data.conversationId) {
    st.conversationId = '';
    st.loadedId = '';
    st.newView = `new:${++viewSeq}`;
    lsSet(`${id}_conv`, '');
    showEmpty(id);
  }
  renderHistory(id);
  if (id === active) { renderHeader(); updateSendUI(); }
  pets[id].say('已删除历史会话 🗑️', 1600);
};

// 左栏 📁 选好了文件夹：加进这位的工作空间列表，并在里面开新对话
window.onWorkspacePicked = data => {
  const id = data.agent;
  if (!S[id] || !data.path) return;
  const key = wsKey(data.path);
  if (key) addWorkspace(id, key);
  startChatIn(id, key);
};

window.onAgentStep = data => {
  const run = S[data.agent]?.runs.get(data.reqId);
  if (run && data.step) updateLiveStep(run, data.index, data.step);
};

// CLI 刚报出会话 ID（回答还在进行）：新对话立刻变成这个会话
window.onAgentConversation = data => {
  const id = data.agent;
  const st = S[id];
  const run = st?.runs.get(data.reqId);
  if (!run) return;
  const viewing = viewKey(id) === data.conversationId;   // 已经点开着 CLI 记录里的这个会话（看到的是读进来那一刻的样子）
  if (!bindRun(id, run, data.conversationId)) return;
  noteFork(id, run, data.conversationId);   // 分叉出来的：记下它从哪个会话分出来（chat/fork.js）
  if (viewing) postNative('loadConversation', { agent: id, conversationId: data.conversationId });   // 重新读一遍，接上进行中的回答
  if (!(st.conversations || []).some(c => c.id === data.conversationId)) postNative('listConversations', { agent: id });
  renderHistory(id);
  if (id === active) { renderHeader(); updateSendUI(); }
};

window.onAgentResponse = data => {
  const id = data.agent;
  const st = S[id];
  const run = st?.runs.get(data.reqId);
  if (!run) return;
  bindRun(id, run, data.conversationId);   // 通常开头就记好了（onAgentConversation）；没收到的话这里补上
  st.ownTurnUnsynced = true;   // 这一轮是这里答的：下一次同步看到它，不算「在别处运行」
  st.ownAt = Date.now();
  st.runs.delete(run.reqId);
  const cwd = data.cwd || run.workspace || '';
  const shown = !!run.live?.el.isConnected;   // 这个会话正显示着（没有切走）
  const extra = rememberTurn(id, run, data, cwd);   // 这一轮改了哪些文件记下来：会话重新读一遍后改动卡片还在（live.js）
  const reply = (data.reply || '').trim();
  if (shown && isCompactCommand(run.text) && !data.cancelled && !/^⚠️/.test(reply)) {
    // 压缩上下文不是一轮对话（CLI 的记录里也没有这一问一答）：收起成一条提示，留在压缩发生的地方
    const note = document.createElement('div');
    note.className = 'msg sys fork-note compact-note';
    note.textContent = reply.split('\n')[0] || '前面的对话已经压缩成摘要';
    note.title = reply;
    run.live.el.replaceWith(note);
    (run.nodes || []).filter(n => n.classList && n.classList.contains('user')).forEach(n => n.remove());
    if (nearBottom(st.msgEl)) scrollToBottom(st.msgEl);
  } else if (shown) {
    const box = st.msgEl;
    const stick = nearBottom(box);
    const turn = renderTurn({
      text: (data.reply || '').trim(),
      steps: Array.isArray(data.steps) ? data.steps : run.live.steps.filter(Boolean),
      files: Array.isArray(data.files) ? data.files : [],
      duration: data.duration,
    }, cwd);
    run.live.el.replaceWith(turn);
    verifyFileChips(turn, cwd);
    if (data.cancelled || /^⚠️/.test((data.reply || '').trim())) addRetry(turn, id, run.text);
    if (extra) decorateTurn(turn, id, extra);   // 这一轮改了文件：可以「查看全部改动」（live.js）
    if (data.cancelled) appendMessage(id, 'sys', '已停止');
    if (stick) scrollToBottom(box);
  } else if (!run.view.startsWith('new:') && viewKey(id) === run.view && !viewBusy(id)) {
    // 正看着这个会话，但进行中的回答没接在页面上（比如刚点开、记录还在读）：再读一遍 CLI 的记录，把这次的回答补上
    postNative('loadConversation', { agent: id, conversationId: run.view });
  }
  // 新对话还没拿到会话 ID 就结束了（多半是出错），而且已经切走：页面上没有它、CLI 记录里也没有，
  // 让桌宠说一声，并把原话放回输入框，方便重发
  const lost = !shown && !data.cancelled && !data.conversationId && run.view.startsWith('new:');
  if (lost) {
    const reason = (data.reply || '').trim().replace(/^⚠️\s*/, '').split('\n')[0].slice(0, 60);
    pets[id].say(`刚才那条没发出去${reason ? '：' + reason : ''}。原话已放回输入框`, 5000);
    restoreDraft(id, run.text);
  }
  if (typeof refreshPreviews === 'function') refreshPreviews(data.files, cwd);   // 预览面板里开着的被改文件跟着更新
  // 切走了的会话不在这里渲染：下次打开时从 CLI 的记录里读（这次的回答已经记进去了）
  if (data.conversationId && (!shown || id !== active) && !data.cancelled) st.unreadConvs.add(data.conversationId);
  if (id !== active || !shown) st.unread = true;
  updateIndicators(id);
  renderHistory(id);
  if (id === active) { updateSendUI(); renderHeader(); }
  postNative('listConversations', { agent: id });
  pets[id].setBusy(isBusy(id));
  // 中途补充过话的回答：CLI 的记录里它是「提问 → 回答 → 补充 → 回答」，按记录重读一遍，现在看到的就和以后重开时一样
  if (run.steered && shown && data.conversationId && viewKey(id) === data.conversationId) {
    st.loadedSig = '';
    postNative('loadConversation', { agent: id, conversationId: data.conversationId });
  }
  flushQueue(id, run, data);   // 回答期间排着的话：接着发（live.js）
  if (id === active) setTimeout(() => prewarm(id), 400);   // 多半还要接着问：先把下一轮的进程起好（live.js）
  // 回答完了：开心一下；出错（回复以 ⚠️ 开头）：心情变失落，不庆祝
  if (/^⚠️/.test((data.reply || '').trim())) pets[id].moodEvent('error');
  else if (!data.cancelled && !lost) pets[id].celebrate();
};

/** 把没发出去的话放回这位的输入框（已有草稿时放在前面，不覆盖） */
function restoreDraft(id, text) {
  if (!text) return;
  const cur = id === active ? els.input.value : S[id].draft;
  if (cur.includes(text)) return;
  const next = cur.trim() ? `${text}\n\n${cur}` : text;
  S[id].draft = next;
  lsSet(`${id}_draft`, next);
  if (id === active) { els.input.value = next; autosize(); updateSendUI(); }
}
