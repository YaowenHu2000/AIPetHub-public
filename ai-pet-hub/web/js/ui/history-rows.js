'use strict';

// 左栏的一行行会话：还没保存的新对话、在答但列表里还没有的会话、普通会话行；以及点它们（打开会话、回到进行中的新对话、
// 开新对话、在某工作空间开新对话）。和 history.js 分开：那边管列表怎么分组、搜索和整体重画，这边管单独一行和点下去的事。

/**
 * 左栏要不要显示这一位还没发出消息的「新对话」：只在选中的这一位显示。
 * 没选中的几位当前也停在空白新对话上，以前也各自显示一行「新对话」，看起来像选中了别人的会话。
 * 已经发出、还在回答的新对话照样显示（标题是那句话）；回答出错、没拿到会话 ID 的，切走后就不再占一行。
 */
function showsNewChat(id) {
  return !S[id].conversationId && (id === active || viewBusy(id));
}

/** 还没保存的新对话：放在所在工作空间那一组的最上面。 */
function newChatRow(id) {
  const st = S[id];
  const row = document.createElement('div');
  row.className = 'conv-row active pending' + (viewBusy(id) ? ' running' : '');
  row.title = st.pendingTitle ? '新对话（正在建立会话…）' : '新对话（发出第一条消息后保存到这里）';
  row.appendChild(elSpan('conv-title', st.pendingTitle || '新对话'));
  if (runsOf(id, viewKey(id)).some(run => run.waiting > 0)) row.appendChild(elSpan('conv-time','等你处理'));
  row.addEventListener('click', () => { if (id !== active) setActive(id); else els.input.focus(); });
  return row;
}

/** 还在回答、还没有会话 ID、而且现在没在看的新对话。 */
const backgroundNewRuns = id => [...S[id].runs.values()].filter(r => r.view.startsWith('new:') && r.view !== viewKey(id));

/** 正在回答、已经有会话 ID、但历史列表里还没有的会话（CLI 刚建好，列表还没刷新到）：先用提问当标题占个位置。 */
function liveItems(id) {
  const st = S[id];
  const known = new Set((st.conversations || []).map(c => c.id));
  const out = [];
  st.runs.forEach(r => {
    if (r.view.startsWith('new:') || known.has(r.view)) return;
    known.add(r.view);
    out.push({ id: r.view, title: r.title || r.text.replace(/\s+/g, ' ').slice(0, 60), time: '正在回答', timestamp: r.since / 1000, cwd: r.workspace });
  });
  return out;
}

/**
 * 这次回答的会话 ID 有了：把回答记到这个会话名下。CLI 一报出 ID 原生层就转过来（onAgentConversation，新对话启动后几秒），
 * 回答结束时也会再带一次。以前要等回答结束才知道，长任务里左栏会同时出现「新对话」和 CLI 记录里的同一个会话，
 * 点开后者看起来像停了；现在新对话马上就是那个会话，只有一行，点开能看到进度，也不会对着它重复发送或删除。
 */
function bindRun(id, run, cid) {
  const st = S[id];
  if (!cid || run.view === cid) return false;
  const old = run.view, viewing = inDraftView(id,run);
  run.view = cid;
  if (viewing) {   // 正看着它：当前会话就是这个了（App 重启后也会回到这里）
    st.conversationId = cid;
    st.loadedId = cid;
    st.pendingTitle = '';
    lsSet(`${id}_conv`, cid);
  }
  bindRunDraft(id,run,old);
  return true;
}

function pendingRunRow(id, run) {
  const row = document.createElement('div');
  row.className = 'conv-row pending running';
  row.title = '正在回答的新对话（点击查看进度）';
  row.appendChild(elSpan('conv-title', run.title || '新对话'));
  if (run.waiting) row.appendChild(elSpan('conv-time','等你处理'));
  row.addEventListener('click', () => openPendingRun(id, run));
  return row;
}

// 「确认删除」的截止时间按助手和会话记：边搜边删时下一批搜索结果会重建整个列表，状态只存在旧按钮上就会丢，第二下又变回「确认删除」
const deleteConfirmUntil = new Map();

function conversationRow(id, item) {
  const st = S[id];
  const row = document.createElement('div');
  row.className = 'conv-row' + (item.id === st.conversationId ? ' active' : '') + (runsOf(id, item.id).length ? ' running' : '')
    + (st.unreadConvs.has(item.id) ? ' unread' : '');
  row.title = `${item.title}\n${item.time}${item.cwd && !isHomeLike(item.cwd) ? `\n目录：${item.cwd}` : ''}`;
  const title = document.createElement('span');
  title.className = 'conv-title';
  title.textContent = item.title;
  if (isFork(id, item.id)) {   // 从别处开着的会话分叉出来的（chat/fork.js）
    const from = (st.conversations || []).find(c => c.id === convForks[forkKey(id, item.id)]);
    const tag = elSpan('conv-fork', '分支');
    tag.title = from ? `从「${from.title}」分出来的` : '从另一个会话分出来的';
    title.prepend(tag);
  }
  const time = document.createElement('span');
  time.className = 'conv-time';
  const unattended = st.unattendedSince && [...st.unattendedSince.values()].some(request => request.cid === item.id);
  time.textContent = unattended || runsOf(id, item.id).some(run => run.waiting > 0) ? '等你处理' : relTime(item.timestamp);
  const del = document.createElement('button');
  del.className = 'conv-del';
  del.innerHTML = UI.trash;
  del.title = id === 'gpt' ? '删除此会话（归档，可在 Codex 中恢复）' : '删除此会话（移到废纸篓）';
  const confirmKey = id + '\n' + item.id;
  const arm = ms => {
    del.classList.add('confirm');
    del.textContent = '确认删除';
    setTimeout(() => { if (del.isConnected) { del.classList.remove('confirm'); del.innerHTML = UI.trash; } }, ms);
  };
  const left = (deleteConfirmUntil.get(confirmKey) || 0) - Date.now();
  if (left > 0) arm(left); else deleteConfirmUntil.delete(confirmKey);
  del.addEventListener('click', e => {
    e.stopPropagation();
    if (!del.classList.contains('confirm')) {
      deleteConfirmUntil.set(confirmKey, Date.now() + 3000);
      arm(3000);
      return;
    }
    if (runsOf(id, item.id).length) { pets[id].say('正在回答这个会话，先等等～', 2000); return; }
    deleteConfirmUntil.delete(confirmKey);
    postNative('deleteConversation', { agent: id, conversationId: item.id });
  });
  row.addEventListener('click', () => openConversation(id, item));
  row.addEventListener('contextmenu', e => {   // 右键：手动移进 / 移出「任务会话」
    e.preventDefault();
    const inTasks = isTaskConversation(id, item);
    openPopover(row, () => [{ items: [{
      name: inTasks ? '移出任务会话' : '移到任务会话',
      desc: inTasks ? '放回它所在的项目' : '归进历史栏底部的「任务会话」',
      onPick: () => {
        const auto = !!item.task || isTempPath(item.cwd);
        if (!inTasks === auto) delete st.taskOverrides[item.id]; else st.taskOverrides[item.id] = !inTasks;
        lsSet(`${id}_task_overrides`, JSON.stringify(st.taskOverrides));
        // 网页存储不在实例之间实时同步：告诉其他实例，免得它们按旧分组删除项目
        postNative('taskGroupChanged', { agent: id, conversationId: item.id, task: st.taskOverrides[item.id] ?? null });
        renderHistory(id);
      },
    }] }], { placement: 'bottom' });
  });
  row.append(title, time, del);
  return row;
}

function openConversation(id, item) {
  if (id !== active) setActive(id, false, false);
  const st = S[id];
  const searching = st.bodyQuery === histQuery && st.bodyHits?.has(item.id);
  if (st.conversationId === item.id && st.loadedId === item.id && !searching) { if (markSeen(id)) renderHistory(id); return; }   // 已经显示着：只清未读
  st.conversationId = item.id;
  st.loadedSig = '';
  st.loadedId = null;
  st.pendingTitle = '';
  markSeen(id);   // 会话行和 AI 级未读一起清（chat/send.js）
  st.applyCwdOnLoad = true;   // 正文读回来时再按记录里的目录校一遍
  // 列表里已经知道它的目录：当场换过去。等正文读回来才换的话，读的期间发出去会带着上一个项目的目录续接（astra 报告）
  if (typeof item.cwd === 'string') setWorkspace(id, wsKey(item.cwd), false);
  lsSet(`${id}_conv`, item.id);
  showEmpty(id, '正在加载历史会话…');
  renderHistory(id);
  renderHeader();
  updateSendUI();
  const hit = st.bodyQuery === histQuery && st.bodyHits?.has(item.id)
    ? st.bodyItems?.find(it => it.id === item.id) : null;
  postNative('loadConversation', { agent: id, conversationId: item.id, ...(hit ? { limit: hit.searchLimit, searchHit: true } : {}) });
  pets[id].touch();
  pets[id].syncBusyState();
  pets[id].say('已切换历史会话 📜', 1600);
}

/** 回到一个还在回答、还没有会话 ID 的新对话。 */
function openPendingRun(id, run) {
  if (id !== active) setActive(id, false, false);
  const st = S[id];
  st.conversationId = '';
  st.loadedId = '';
  st.newView = run.view;
  st.pendingTitle = run.title || '';
  st.workspace = run.workspace;
  lsSet(`${id}_workspace`, run.workspace);
  lsSet(`${id}_conv`, '');
  showEmpty(id);
  attachRuns(id);
  renderHistory(id);
  renderHeader();
  updateSendUI();
  pets[id].syncBusyState();
}

/** 开新对话；workspace 不传 = 留在当前工作空间。 */
function newChat(id = active, quiet = false, workspace = null) {
  if (id !== active) setActive(id, false, false);
  const st = S[id];
  st.conversationId = '';
  st.loadedId = '';
  st.pendingTitle = '';
  st.newView = `new:${++viewSeq}`;   // 别的会话可能还在回答，新对话用新的编号
  lsSet(`${id}_conv`, '');
  if (workspace !== null) {
    st.workspace = workspace;
    lsSet(`${id}_workspace`, workspace);
  }
  st.groupState[wsKey(st.workspace)] = 0;   // 展开所在的工作空间，露出「新对话」
  lsSet(`${id}_groups`, JSON.stringify(st.groupState));
  showEmpty(id);
  renderHistory(id);
  renderHeader();
  updateSendUI();
  histSections[id].list.querySelector('.conv-row.pending')?.scrollIntoView({ block: 'nearest' });
  pets[id].touch();
  pets[id].syncBusyState();
  if (!quiet) pets[id].say('已开启新对话 ✨', 1800);
  els.input.focus();
  return true;
}

/** 分组上的「＋」、左栏 📁 选好文件夹后：在这个工作空间里开新对话。 */
function startChatIn(id, workspace) {
  if (newChat(id, true, workspace)) pets[id].say(workspace ? `新对话 · ${baseName(workspace)} 📁` : '已开启新对话 ✨', 1800);
}
