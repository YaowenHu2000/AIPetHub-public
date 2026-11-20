'use strict';

// 原生调过来的回调：历史列表、会话内容、回答的步骤和结果、文件核对等。

// 实例可以使用不同的 CLI 数据目录。其他窗口的成功回执只触发重读，由本窗口的来源确认删除和恢复。
window.onHistoryChangedElsewhere = ({agent}) => {
  if (!AGENT_IDS.includes(agent)) return;
  S[agent].unreadChecked?.clear();
  refreshHistory(agent);
};
// 另一实例右键移进移出了「任务会话」。网页存储不在实例之间实时同步，按它的结果更新本窗口：
// 删除项目才不会按旧分组多删或漏删，本窗口之后写分组也不会把那一条写回旧值。
window.onTaskGroupChangedElsewhere = ({agent, conversationId, task}) => {
  const st = S[agent];
  if (!st || !conversationId) return;
  if (task === 'task' || task === 'project') st.taskOverrides[conversationId] = task === 'task';
  else delete st.taskOverrides[conversationId];
  lsSet(`${agent}_task_overrides`, JSON.stringify(st.taskOverrides));
  if (AGENT_IDS.includes(agent)) renderHistory(agent);
};

// ===== 原生回调 =====
window.onConversationsListed = data => {
  const st = S[data.agent];
  if (!st) return;
  // 读不出列表（如 DeepSeek 的服务起不来）不是没有会话：保留上次的列表，左栏写明原因
  st.listUnavailable = data.unavailable || '';
  if (st.listUnavailable) {
    if (st.conversations === null) st.conversations = [];
    renderHistory(data.agent);
    return;
  }
  // 「添加 AI」时验证用的那句话（在临时目录 aipethub-verify 里问的）不算会话，不列出来
  st.conversations = (Array.isArray(data.items) ? data.items : []).filter(visibleConversation);
  if (data.agent === 'gpt') st.projectlessIds = new Set(data.projectlessIds || []);
  renderHistory(data.agent);
  if (data.agent === active) renderHeader();
  // 最近列表有条数上限，只有单条载入确认 missing 才能退出当前会话。
  const listed = new Set(st.conversations.map(item => item.id));
  if (st.conversationId && !listed.has(st.conversationId) && !viewBusy(data.agent) && !st.historyReads?.size) {
    postNative('loadConversation', {agent:data.agent, conversationId:st.conversationId, sync:st.loadedId === st.conversationId});
  }
  const checks = st.unreadChecks ??= new Map(), checked = st.unreadChecked ??= new Map();
  for (const cid of checks.keys()) if (listed.has(cid)) checks.delete(cid);
  for (const cid of checked.keys()) if (listed.has(cid) || !st.unreadConvs.has(cid)) checked.delete(cid);
  for (const cid of st.unreadConvs || []) {
    if (cid === st.conversationId || listed.has(cid) || checks.has(cid) || Date.now() - (checked.get(cid) || 0) < 60_000) continue;
    const reqId = nextRequestId();
    checks.set(cid,reqId);
    postNative('loadConversation',{agent:data.agent,conversationId:cid,reqId,unreadProbe:true});
  }
  noteListedStamp(data.agent);   // 打开着的会话在别处动了没有（chat/elsewhere.js）
};

function visibleHistoryMessages(rows) {
  // 命令气泡会隐藏，失败回答要先记下原命令（保留 /compress 等原拼法），避免重试取到前一问。
  return rows.flatMap((m,i) => {
    if (m.role === 'user' && isCompactCommand(m.text)) return [];
    const prev = rows[i-1];
    return m.role === 'bot' && canRetryOutcome(m.outcome) &&
      prev?.role === 'user' && isCompactCommand(prev.text) ? [{...m,retryPrompt:prev.text.trim(),retryUser:prev}] : [m];
  });
}
window.onConversationLoaded = data => {
  const id = data.agent;
  const st = S[id];
  const cid = data.conversationId;
  const historyError = data.historyError || data.readError;
  const missing = data.missing && !historyError;
  if (data.reqId != null && st?.unreadChecks?.get(cid) === data.reqId) {
    st.unreadChecks.delete(cid);
    st.unreadChecked.set(cid,Date.now());
    if (missing && cid !== st.conversationId && !runsOf(id,cid).length) {
      removeConversations(id,[cid]);
    }
    return;
  }
  const mode = st?.historyReads?.get(data.reqId);
  st?.historyReads?.delete(data.reqId);
  if (data.reqId != null && !mode) return;
  const syncing = mode === 'sync';
  if (!st || data.conversationId !== st.conversationId) return;
  if (missing) {
    if (!viewBusy(id)) removeConversations(id,[cid]);
    return;
  }
  if (!historyError) st.unreadChecks?.delete(cid);
  st.historyErrorNotice?.remove();
  st.historyErrorNotice = null;
  if (historyError) {
    const empty = st.msgEl.querySelector('.chat-empty');
    if (empty && data.messages?.length && !viewBusy(id)) {
      // 首次打开时旧页可能读失败，已经取得的正文仍要显示；重试时交给正常渲染重新对账。
      renderMessages(id, visibleHistoryMessages(data.messages), data.cwd || st.workspace || '', data.omitted || 0);
      st.loadedId = data.conversationId;
    }
    st.msgEl.querySelector('.chat-empty')?.remove();
    const retry = document.createElement('button');
    retry.className = 'msg sys load-earlier history-error';
    retry.textContent = historyError + ' · 重新加载';
    retry.onclick = () => postNative('loadConversation', {agent:id, conversationId:data.conversationId, limit:st.histLimit});
    st.msgEl.appendChild(retry);
    st.historyErrorNotice = retry;
    return;
  }
  if (data.context) window.onAgentContext({ ...data.context, agent: id, conversationId: data.conversationId, history: true });
  // 打开历史、正文还没读回来就发了问：之后画出的提问、回答、错误和「重试」都在历史之后，这次回包只补前面的历史，不整页抹掉
  const fresh = !syncing && mode !== 'steer' && st.loadedId !== data.conversationId
    ? [...st.msgEl.children].filter(n => !n.classList.contains('chat-empty')) : [];
  st.loadedId = data.conversationId;
  const wasElsewhere = syncing && elsewhereOn(id);
  readElsewhereTurn(id, data, syncing);
  if (st.applyCwdOnLoad) {
    st.applyCwdOnLoad = false;
    // 继续历史会话时，工作空间跟随该会话原来的目录
    if (typeof data.cwd === 'string') setWorkspace(id, wsKey(data.cwd), false);
  }
  // 压缩上下文的命令不算一句话（有的 CLI 会把它记成一句提问）：不显示
  const messages = visibleHistoryMessages(Array.isArray(data.messages) ? data.messages : []);
  // 每条都算进来：在终端里回退重聊时，变的可能只是前面的轮次，末轮和条数都不变
  const signatures = messages.map(messageSignature);
  const sig = JSON.stringify([data.conversationId, data.omitted || 0, !!data.hasMore, signatures]);
  // 即使正在回答而暂不重画，后来取回的旧页也已经改变了这轮在历史中的位置。
  const prepended = Math.max(0, data.historyPrepended || 0);
  if (prepended) st.shownOmitted = (st.shownOmitted || 0) + prepended;
  if (prepended) runsOf(id, viewKey(id)).forEach(run => {
    if (Number.isInteger(run.historyStart)) run.historyStart += prepended;
  });
  if (prepended) shiftTurnExtras(id, data.conversationId, prepended);   // 已答完轮次的改动卡片位置同样后移（chat/changes.js）
  if (syncing && (sig === st.loadedSig || viewBusy(id))) return;   // 后台同步：没变化（或正在回答）就不动
  // 没人在这里答，内容却变了：它在别处跑着（chat/elsewhere.js）。
  // 例外：这里自己刚答完一轮之后的第一次同步——记录里多出来的就是刚才那一轮，只是对一下账
  if (syncing && st.ownTurnUnsynced) st.ownTurnUnsynced = false;
  else if (syncing) noteElsewhere(id);
  else { st.elsewhereAt = 0; noteListedStamp(id); }
  st.loadedSig = sig;
  // 当前会话的正文这就摆出来了：后台答完、读回来才显示的那一轮也算看过（会话行和桌宠一起清，chat/send.js）
  if (id === active && markSeen(id)) renderHistory(id);
  const box = st.msgEl;
  const manualPage = st.keepFromBottom && st.keepFromBottom.reqId === data.reqId;
  const cwd = data.cwd || st.workspace || '', omitted = data.omitted || 0;
  const incremental = (syncing || mode === 'steer' || (manualPage && !viewBusy(id))) &&
    syncAppend(id,messages,cwd,omitted,!!data.hasMore,mode === 'steer',signatures,syncing && (wasElsewhere || elsewhereOn(id)));
  if (incremental && !manualPage) { markElsewhere(id); return; }
  st.shownLimit = data.limit || 300;
  if (!incremental) {
    const keepScroll = syncing && !nearBottom(box) ? box.scrollTop : null;
    renderMessages(id,messages,cwd,omitted,!!data.hasMore,{fresh,readAt:data.readAt,signatures});
    if (keepScroll !== null) box.scrollTop = keepScroll;
  }
  const keep = manualPage ? st.keepFromBottom.distance : 0;   // 刚点了「显示更早的」，这就是那次的回包
  if (manualPage) { box.scrollTop = box.scrollHeight - keep; st.keepFromBottom = null; }
  // 在隐藏的面板里画的（后台载入）：这时没有高度，上面的定位都落空。第一次显示时再定位（send.js 的 setActive）。
  // 后台同步不记：用户之前翻到哪儿，切回来时 WebKit 会还原到哪儿
  if (box.hidden && !syncing) st.pendingScroll = { fromBottom: keep };
  markElsewhere(id);
  if (!syncing) askSessionLive();   // 刚打开：它是不是正开在别的程序里（chat/fork.js）
  if (manualPage) st.pendingSearchHit = null;
  else if (!syncing) jumpToSearchHit(id);   // 是从搜索结果点进来的：跳到正文里命中的那一条（composer.js）
};

window.onConversationDeleted = data => {
  const id = data.agent;
  const st = S[id];
  if (!st) return;
  if (!data.ok) { pets[id].say(data.reason || '删除失败了…', data.reason ? 6000 : 1800); return; }
  removeConversations(id,[data.conversationId]);
  pets[id].say('已删除历史会话 🗑️', 1600);
};

// 左栏 📁 选好了文件夹：加进这位的工作空间列表，并在里面开新对话
window.onWorkspacePicked = data => {
  const id = data.agent;
  if (!S[id] || !data.path) return;
  const key = wsKey(data.path);
  if (key) addWorkspace(id, key);
  startChatIn(id, data.path);
};

window.onAgentStep = data => {
  const run = S[data.agent]?.runs.get(data.reqId);
  if (run && data.step) updateLiveStep(run, data.index, data.step);
};

// CLI 刚报出会话 ID（回答还在进行）：新对话立刻变成这个会话
window.onAgentSentImages = data => {
  const run = S[data.agent]?.runs.get(data.reqId);
  if (!run) return;
  const item = data.steerId ? run.queue?.find(q => q.sid === data.steerId) : run;
  if (!item) return;
  for (const path of item.images) {
    const copy = data.paths[item.sentPaths[path] || path];
    if (copy) item.sentPaths[path] = copy;
  }
  if (data.steerId) return;
  run.preparingImages = false;
  run.restoredPaths = data.restoredPaths;
  const text = [run.text,...run.images].filter(Boolean).join('\n');
  const sent = sentAttachments(run).ordered;
  if (run.thumbnails?.length) {
    let i = 0;
    run.thumbnails = run.thumbnails.map(im => im.mentioned ? im : {...im, snapshot:sent[i++]});
    fillUserMessage(run.nodes[0],text,run.thumbnails);
  } else requestMessageImages(run.nodes[0],text,run.workspace,sent);
  if (run.pendingEdit && pendingPastes.has(run.pendingEdit.key)) {
    const sent = editAttachments(run);
    run.pendingEdit.shown = sent.shown;
    finishPaste(run.pendingEdit,{paths:sent.ordered});
  }
  delete run.pendingEdit;
};

window.onAgentImageKeys = data => {
  const run = S[data.agent]?.runs.get(data.reqId);
  if (run) run.imageKeys = data.keys;
};

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
  run.preparingImages = false;
  if (run.pendingEdit && pendingPastes.has(run.pendingEdit.key)) {
    finishPaste(run.pendingEdit,{error:'当次图片未能保存'});
  }
  delete run.pendingEdit;
  bindRun(id, run, data.conversationId);   // 通常开头就记好了（onAgentConversation）；没收到的话这里补上
  st.ownTurnUnsynced = true;   // 这一轮是这里答的：下一次同步看到它，不算「在别处运行」
  st.ownAt = Date.now();
  st.runs.delete(run.reqId);
  finishDraftBinding(id,run);
  if (id === active && run.view === viewKey(id) && pop?.anchor === els.chipModel && modelView === 'panel') showModelView('panel');
  const cwd = data.cwd || run.workspace || '';
  const shown = !!run.live?.el.isConnected;   // 这个会话正显示着（没有切走）
  if (shown) discardHistoryRefreshes(st);
  run.endedAt = Date.now();
  run.turnKey = data.turnKey;
  if (data.draftImagePaths) run.restoredPaths = data.draftImageCopies || data.draftImagePaths;
  const ending = run.ending = responseEnding(data);
  run.supplements = consumedSupplementKeys(data,run);
  const extra = run.extra = rememberTurn(id,run,data,cwd);
  const {text:reply, outcome} = ending;
  const retryable = canRetryOutcome(outcome);
  // 新对话还没拿到会话 ID 就停止、失败，或已经切走才结束：页面上的这一轮切走就没了、CLI 记录里也没有，
  // 让桌宠说一声，并把原话和附件放回原项目的新对话草稿，方便重发（和 DeepSeek 原生带 restoreDraft 的退回同一条路）
  const lost = !data.conversationId && run.view.startsWith('new:') && (retryable || !shown);
  if (shown && isCompactCommand(run.text) && !retryable) {
    // 压缩上下文不是一轮对话（CLI 的记录里也没有这一问一答）：收起成一条提示，留在压缩发生的地方
    const note = document.createElement('div');
    note.className = 'msg sys fork-note compact-note';
    note.textContent = reply.split('\n')[0] || '前面的对话已经压缩成摘要';
    note.title = reply;
    // 压成了的压缩在 CLI 记录里多出一条（Claude 手动压缩、Gemini 压缩或 agy 把 /compact 当普通提问作答时的那条回答、Codex 的 /compact 回合；
    // 原生按记录的口径判断后给 compacted）：实时这条按同一口径算进历史条目，本轮起点和对账才对得上。
    // 没压成（如 Claude 的「Not enough messages」）记录里什么都没有，算进去就会多算一条
    if (data.compacted) { note.dataset.historyCompact = '1'; note._answeredHere = true; note._run = run; }
    run.live.el.replaceWith(note);
    (run.nodes || []).filter(n => n.classList && n.classList.contains('user')).forEach(n => n.remove());
    if (nearBottom(st.msgEl)) scrollToBottom(st.msgEl);
  } else if (shown) {
    const box = st.msgEl;
    const stick = nearBottom(box);
    const turn = renderChangeTurn(id,{
      ...ending,
      steps: Array.isArray(data.steps) ? data.steps : run.live.steps.filter(Boolean),
      files: Array.isArray(data.files) ? data.files : [],
      duration: data.duration,
    },extra || undefined,cwd);
    turn._endedAt = run.endedAt;
    turn._supplements = run.supplements;
    turn._endingReqId = ending.reqId;
    turn._answeredHere = true;   // 之后和记录对账时不重画这一轮（message-sync.js 的 syncAppend），重试按钮、展开状态都留着
    run.live.el.replaceWith(turn);
    if (outcome === 'completed' && run.live.typing?.text) continueAnswer(id,turn,run.live);
    verifyFileChips(turn, cwd);
    if (retryable) {
      const draft = unsentDraft(run);
      addRetry(turn, id, run.text, run.images, sentAttachments(run).refs, data.restoreDraft || lost ? {...draft, returned:true} : draft, run.thumbnails, run.sentPaths);
    }
    if (data.cancelled) turn._stopNote = appendMessage(id, 'sys', '已停止');
    if (stick) scrollToBottom(box);
  } else if (!run.view.startsWith('new:') && viewKey(id) === run.view && !viewBusy(id)) {
    // 正看着这个会话，但进行中的回答没接在页面上（比如刚点开、记录还在读）：再读一遍 CLI 的记录，把这次的回答补上
    postNative('loadConversation', { agent: id, conversationId: run.view });
  }
  if (data.restoreDraft) {
    pets[id].say(reply, 5000);
  } else if (lost) {
    const reason = (data.reply || '').trim().replace(/^⚠️\s*/, '').split('\n')[0].slice(0, 60);
    pets[id].say(`刚才那条没发出去${reason ? '：' + reason : ''}。已退回原项目草稿`, 5000);
  }
  if (typeof refreshPreviews === 'function') refreshPreviews(data.files, cwd);   // 预览面板里开着的被改文件跟着更新
  // 切走了的会话不在这里渲染：下次打开时从 CLI 的记录里读（这次的回答已经记进去了）
  if (data.conversationId && (!shown || id !== active) && !data.cancelled) setConversationUnread(id, data.conversationId, true);
  refreshUnread(id);
  renderHistory(id);
  if (id === active) { updateSendUI(); renderHeader(); }
  postNative('listConversations', { agent: id });
  pets[id].setBusy(isBusy(id));
  // 中途补充过话的回答：CLI 的记录里它是「提问 → 回答 → 补充 → 回答」，按记录重读一遍，现在看到的就和以后重开时一样
  if (run.steered && shown && data.conversationId && viewKey(id) === data.conversationId) {
    st.loadedSig = '';
    postNative('loadConversation', { agent: id, conversationId: data.conversationId, afterSteer: true });
  }
  flushQueue(id, run, data, (lost || data.restoreDraft) && !run.draft?.returned ? unsentDraft(run) : null);   // 回答期间排着的话：接着发（live.js）
  if (id === active) setTimeout(() => prewarm(id), 400);   // 多半还要接着问：先把下一轮的进程起好（live.js）
  // 回答完了：开心一下；出错（回复以 ⚠️ 开头，或先出了正文再失败的 outcome=failed，和上面加「重试」同一判定）：心情变失落，不庆祝
  if (retryable && outcome !== 'interrupted') pets[id].moodEvent('error');
  else if (!retryable && !lost) pets[id].celebrate();
};
