'use strict';

// 左栏：各位的历史会话（按工作空间分组）、搜索、删除会话（会话行与打开 / 新对话在 history-rows.js，删除整个项目在 project-delete.js）。
//
// 侧栏和删除项目共用任务会话来源。
// Claude 的 Python 和 TypeScript SDK 会话归入任务，其他入口核对新版入口与直接创建的会话编号；Gemini 核对同一份 CLI 启动日志里的新建会话与 print 发送记录，
// 并记住已确认的来源，DeepSeek 核对首问是否由 headless 直接交给 agent。
// 交互式续写不改变来源。
// 用户右键移进移出的分组记在本实例的网页存储（WebKit 不在实例之间实时同步），同时经分布式通知告诉其他实例；删除项目发出前按最新分组重新筛选，名单变了先重新显示数量再确认。
//
// 四位助手的单删、项目部分成功、聊天页缺失和后台未读核对都由 `removeConversations` 接收已确认的编号。
// 它一起撤下列表、在途搜索命中、未读、改动预览和当前聊天页；输入框里退回给当前聊天页的稿子转到原项目的新对话。
// 原搜索词的新请求可以接纳恢复的记录。
// 删除成功会通过 macOS 分布式通知请其他实例重读各自的 CLI 来源。
// 手动刷新、切回助手或窗口、重新启用和定时刷新共用 `refreshHistory`。
// 未读按助手和会话逐条存储，兼容旧数组，两个窗口操作不同会话时各写自己的编号。
//
// 历史目录暂时不可读时保留上次列表并提示原因。
// 最近列表最多 300 条，落在外面的当前会话和后台未读按编号核对。
// 重新看到编号时撤销旧核对，读错或当前仍在回答时保留页面。
// 点「显示更早」或定位搜索命中时按需增加显示范围。
// 项目删除回执按提交时的请求编号归回相应项目，另开确认框不影响已提交的操作。

function openPetSettings(id, anchor) {
  openPopover(anchor, () => {
    const c = AGENTS[id];
    const st = S[id];
    const sections = [
      { title: `${c.name} · 自动入睡`, items: SLEEP_OPTIONS.map(o => ({ name: o.name, desc: o.desc, selected: String(st.autoSleep) === o.v,
        onPick: () => { st.autoSleep = parseInt(o.v, 10); lsSet(`${id}_autosleep`, o.v); pets[id].touch(); } })) },
    ];
    if (c.skins.length > 1) {
      sections.push({ title: '形象版本', items: c.skins.map(o => ({ name: o.name, selected: st.skin === o.v,
        onPick: () => {
          if (st.skin === o.v) return;
          st.skin = o.v;
          lsSet(`${id}_skin`, o.v);
          pets[id].applySkin();
          pets[id].say(`已切换：${o.name}`, 1800);
        } })) });
    }
    if (AGENT_IDS.length > 1) {
      sections.push({ items: [{ name: `移除${c.name}`, desc: '只是不放在界面上，会话记录不动；以后可以从「添加 AI」再加回来',
        danger: true, onPick: () => disableAgent(id) }] });
    }
    return sections;
  }, { placement: 'bottom', keepOpen: true });
}

// ===== 左栏：启用的几位的历史会话，每位一格上下排，每格按工作空间分组（可折叠） =====
const histSections = {};
const GROUP_PREVIEW = 5;

function buildHistorySection(id) {
  const c = AGENTS[id];
  const sec = document.createElement('section');
  sec.className = 'hist-section';
  sec.dataset.agent = id;

  const head = document.createElement('div');
  head.className = 'hist-head';
  head.title = `切换到 ${c.name}`;
  const icon = document.createElement('span');
  icon.className = 'hist-icon';
  icon.innerHTML = ICONS[id];
  const name = document.createElement('span');
  name.className = 'hist-name';
  name.textContent = c.name;
  const brand = document.createElement('span');
  brand.className = 'hist-brand';
  brand.textContent = c.brand;
  const dot = document.createElement('span');
  dot.className = 'tab-dot';
  const spacer = document.createElement('span');
  spacer.className = 'hist-spacer';
  const refresh = document.createElement('button');
  refresh.className = 'icon-btn hist-refresh';
  refresh.innerHTML = UI.refresh;
  refresh.title = '刷新历史会话';
  refresh.addEventListener('click', e => {
    e.stopPropagation();
    refreshHistory(id);
    pets[id].say('已刷新历史列表 ↻', 1500);
  });
  const add = document.createElement('button');
  add.className = 'icon-btn';
  add.innerHTML = UI.plus;
  add.title = `和 ${c.name} 开启新对话（不绑定工作空间，在主目录运行）`;
  add.addEventListener('click', e => { e.stopPropagation(); startChatIn(id, ''); });
  // 右上角的文件夹（参考反重力 Projects）：选一个文件夹，在里面开新对话
  const open = document.createElement('button');
  open.className = 'icon-btn';
  open.innerHTML = UI.folderPlus;
  open.title = '打开工作空间…（选择文件夹，在里面开启新对话）';
  open.addEventListener('click', e => { e.stopPropagation(); postNative('pickWorkspace', { agent: id }); });
  head.append(icon, name, brand, dot, spacer, refresh, add, open);
  head.addEventListener('click', () => setActive(id));

  const list = document.createElement('div');
  list.className = 'hist-list';
  list.addEventListener('scroll', () => queueTrimRows(), { passive: true });
  sec.append(head, list);
  histSections[id] = { sec, list };
  return sec;
}

// 「任务会话」：别的智能体或脚本派出去的一次性会话（codex exec、别的工具起的 claude -p，原生在列表项上标 task），
// 以及工作目录在系统临时文件夹里的，统一收进历史栏最底下这一组，不和真实项目混在一起。只改分组，续聊仍在原目录。
// 用户可以在会话上右键手动移进移出（taskOverrides，记在本机）。
const TASK_GROUP = '\u0001tasks';
const isTempPath = p => /^(\/private)?\/(tmp|var\/folders)\//.test(p || '');
function isTaskConversation(id, it) {
  const o = S[id].taskOverrides?.[it.id];
  return o != null ? !!o : (!!it.task || isTempPath(it.cwd));
}
const groupKeyOf = (id, it) => isTaskConversation(id, it) ? TASK_GROUP : (S[id].projectlessIds?.has(it.id) ? '' : wsKey(it.cwd));

/** filtered：搜索时只按搜到的会话分组，不加入空的工作空间和「新对话」那一组。 */
function buildGroups(id, items = S[id].conversations, filtered = false) {
  const st = S[id];
  const map = new Map();
  items.forEach(it => {
    const key = groupKeyOf(id, it);
    if (!map.has(key)) map.set(key, []);
    map.get(key).push(it);
  });
  const groups = [...map.entries()].map(([key, list]) => ({ key, list, latest: Math.max(...list.map(i => i.timestamp || 0)) }));
  const order = (a, b) => (a.key === TASK_GROUP) - (b.key === TASK_GROUP) || (a.key === '') - (b.key === '') || b.latest - a.latest;
  if (filtered) return groups.sort(order);
  // 用 📁 打开、还没有会话的工作空间
  st.addedWs.forEach(w => {
    if (map.has(w.path)) return;
    map.set(w.path, []);
    groups.push({ key: w.path, list: [], latest: w.ts || 0 });
  });
  // 正在开新对话：当前工作空间要有一组来放「新对话」（只有选中的这一位才显示，见 renderHistory）；后台还在回答的新对话也一样
  const need = backgroundNewRuns(id).map(r => wsKey(r.workspace));
  if (showsNewChat(id)) need.push(wsKey(st.workspace));
  need.forEach(k => {
    if (map.has(k)) return;
    map.set(k, []);
    groups.push({ key: k, list: [], latest: Date.now() / 1000 });
  });
  return groups.sort(order);   // 未绑定的放在项目后面，任务会话放最后
}

function isCollapsed(id, key, index) {
  const state = S[id].groupState;
  return Object.prototype.hasOwnProperty.call(state, key) ? state[key] === 1 : (key === TASK_GROUP || index >= 3);   // 任务会话默认折叠
}

function renderAllHistory() { AGENT_IDS.forEach(renderHistory); }

// 左栏顶部的搜索：按会话标题或工作空间名过滤各位的会话
let histQuery = '';
const histSearch = document.getElementById('hist-search');
let bodySearchTimer = 0;
histSearch.addEventListener('input', () => {
  histQuery = histSearch.value.trim().toLowerCase();
  if (histQuery) AGENT_IDS.forEach(id => markBodySearch(id, histQuery));
  renderAllHistory();
  // 停下来 0.3 秒再去翻正文
  clearTimeout(bodySearchTimer);
  const q = histQuery;
  if (q) bodySearchTimer = setTimeout(() => AGENT_IDS.forEach(id => requestHistorySearch(id,q)), 300);
});
function refreshHistory(id, automatic = false) {
  postNative('listConversations', {agent:id});
  // 搜索结果包含最近列表以外的会话，切回或刷新时也要读同一个词。慢搜索留给原请求跑完。
  if (histQuery && !(automatic && S[id].searchInFlight === histQuery)) requestHistorySearch(id,histQuery);
}
/**
 * 这个词从输入起就算「正在搜正文」：首批结果回来以前标题没命中，不等于没有匹配的会话。
 * 同一个词重搜（切回、刷新）保留上次的命中，等新批次替换，免得列表闪空。
 */
function markBodySearch(id, query) {
  const st = S[id];
  if (st.bodyQuery === query) return;
  st.bodyQuery = query;
  st.bodyHits = new Set();
  st.bodyItems = [];
  st.bodyUnavailable = '';
  st.bodyComplete = false;
}
function requestHistorySearch(id, query) {
  const st = S[id];
  markBodySearch(id, query);
  st.bodyRequest = nextRequestId();
  st.bodyDropped = null;
  st.searchInFlight = query;
  postNative('searchConversations', {agent:id, query, reqId:st.bodyRequest});
}
window.onConversationsSearched = data => {
  const st = S[data.agent];
  if (!st || data.query !== histQuery || (data.reqId != null && data.reqId !== st.bodyRequest)) return;   // 已经改了搜索词
  const dropped = st.bodyDropped;   // 这次搜索期间删掉的：在途的批次里还带着
  st.bodyQuery = data.query;
  st.bodyHits = new Set((data.ids || []).filter(cid => !dropped?.has(cid)));
  st.bodyItems = (Array.isArray(data.items) ? data.items : []).filter(it => visibleConversation(it) && !dropped?.has(it.id));
  st.bodyUnavailable = data.unavailable || '';
  st.bodyComplete = data.complete !== false;
  if (st.bodyComplete) st.searchInFlight = '';
  renderHistory(data.agent);
};
/** 单删、项目回执和外部缺失都确认了同一件事。一次更新会话的所有入口，避免后台核对只清未读却留下可点的旧页。 */
function removeConversations(id, ids) {
  if (!ids.length) return;
  const st = S[id], gone = new Set(ids);
  if (st.conversations) st.conversations = st.conversations.filter(item => !gone.has(item.id));
  if (st.bodyItems) st.bodyItems = st.bodyItems.filter(item => !gone.has(item.id));
  const dropped = st.bodyDropped ??= new Set();
  for (const cid of gone) {
    dropped.add(cid);   // 只挡本次搜索的迟到批次；新搜索能重新发现恢复的源文件。
    st.bodyHits?.delete(cid);
    st.unreadChecks?.delete(cid);
    st.unreadChecked?.delete(cid);
  }
  forgetTurnExtras(id, gone);
  updateConversationUnread(id,gone,false);
  st.unattendedSince?.forEach(({cid}, requestId) => {
    if (gone.has(cid)) window.onAgentRequestClosed({agent:id, reqId:0, requestId});
  });
  if (gone.has(st.conversationId)) {
    const book = st.returnedDrafts, owned = book.owner === currentDraftKey(id);
    st.conversationId = st.loadedId = st.loadedSig = st.pendingTitle = '';
    st.newView = `new:${++viewSeq}`;
    // 输入框里是退回给这个会话的稿子（比如发送时才发现它在别处被归档、删掉）：那个会话再也打不开，
    // 稿子留在输入框，归到原项目的新对话；那里原先等着的退稿排在前面
    if (owned) {
      const key = currentDraftKey(id), waiting = book.parked[key];
      book.owner = key;
      delete book.parked[key];
      if (waiting) displayReturnedDraft(id, combineDrafts(draftAttachments(st), [waiting], 'return').merged);
      saveReturnedDrafts(id);
    }
    st.applyCwdOnLoad = false;
    st.historyReads?.clear();
    st.elsewhereAt = st.watchUntil = 0;
    st.externalTurn = null;
    setElsewherePet(id,null);
    if (gone.has(lsGet(id+'_conv'))) lsSet(id+'_conv','');
    showEmpty(id);
  }
  refreshUnread(id);
  renderHistory(id);
  if (id === active) { renderHeader(); updateSendUI(); }
}
document.querySelector('.search-clear').addEventListener('click', e => {
  e.preventDefault();
  histSearch.value = '';
  histSearch.dispatchEvent(new Event('input'));
  histSearch.focus();
});
histSearch.addEventListener('keydown', e => {
  if (e.key === 'Escape') { e.stopPropagation(); histSearch.value = ''; histQuery = ''; renderAllHistory(); histSearch.blur(); }
});

function visibleConversation(item) { return !/\/aipethub-verify\/?$/.test(item.cwd || ''); }

function renderHistory(id) {
  const st = S[id];
  const { sec, list } = histSections[id];
  sec.classList.toggle('active', id === active);
  sec.classList.toggle('busy', isBusy(id));
  sec.classList.toggle('unread', !isBusy(id) && st.unread);
  const scroll = list.scrollTop;
  list.innerHTML = '';
  if (st.conversations === null) { list.innerHTML = '<div class="hist-empty">正在读取历史会话…</div>'; return; }
  const q = histQuery;
  const listed = [...liveItems(id), ...st.conversations];
  const listedIds = new Set(listed.map(it => it.id));
  const extra = st.bodyQuery === q ? (st.bodyItems || []).filter(it => !listedIds.has(it.id)) : [];
  const all = [...listed, ...extra];   // 刚建好、列表里还没有的正在回答的会话放在最前
  // 标题、工作空间里有，或者正文里有（原生在会话记录里找，结果稍后到：onConversationsSearched）
  const inBody = st.bodyQuery === q ? st.bodyHits : null;
  const items = q ? all.filter(it => (it.title || '').toLowerCase().includes(q) || wsKey(it.cwd).toLowerCase().includes(q) || inBody?.has(it.id) || !listedIds.has(it.id)) : all;
  const groups = buildGroups(id, items, !!q);
  const searchStatus = q.length >= 2 && st.bodyQuery === q
    ? (st.bodyUnavailable || (!st.bodyComplete ? '正在搜索正文…' : '')) : '';
  if (searchStatus) {
    const note = elSpan('hist-empty', searchStatus);
    note.dataset.k = 'search-status';
    list.appendChild(note);
  }
  if (st.listUnavailable) {
    // 原因第一行已带出错的文件和行列号；完整的调用栈摘录放在悬停提示里，不撑长左栏
    const note = elSpan('hist-empty', '历史会话读取失败：' + st.listUnavailable.split('\n')[0]);
    note.title = st.listUnavailable;
    note.dataset.k = 'list-status';
    list.appendChild(note);
  }
  if (!groups.length) {
    if (!searchStatus && !st.listUnavailable) list.innerHTML = `<div class="hist-empty">${q ? '没有匹配的会话' : '暂无历史会话'}</div>`;
    return;
  }

  // 不同路径的最后一级同名（如两个 …/ai-pet-hub）时往上多显示一级，否则看起来像同一个项目被拆成两组
  const nameCount = new Map();
  groups.forEach(g => { if (g.key && g.key !== TASK_GROUP) nameCount.set(baseName(g.key), (nameCount.get(baseName(g.key)) || 0) + 1); });
  const groupName = key => nameCount.get(baseName(key)) > 1 ? `${baseName(key.replace(/\/+[^/]*\/*$/, '') || '/')}/${baseName(key)}` : baseName(key);

  groups.forEach((g, index) => {
    const pendingHere = !q && showsNewChat(id) && g.key === wsKey(st.workspace);   // 「新对话」在这一组
    const collapsed = q ? false : isCollapsed(id, g.key, index);   // 搜索时全部展开
    const hasActive = pendingHere || g.list.some(it => it.id === st.conversationId);
    const head = document.createElement('div');
    head.className = 'grp-head' + (collapsed && hasActive ? ' has-active' : '');
    head.dataset.k = `g:${g.key}`;   // 每一行一个记号：展开 / 折叠时靠它认出「这还是原来那一行」（renderHistorySmooth）
    const isTasks = g.key === TASK_GROUP;
    head.title = isTasks ? '别的智能体或脚本派出去的一次性会话、临时文件夹里的会话（右键会话可移进移出）'
      : g.key ? prettyPath(g.key) : '未绑定工作空间的会话（在主目录运行）';
    const icon = document.createElement('span');
    icon.className = 'grp-icon';
    icon.innerHTML = collapsed ? UI.folder : UI.folderOpen;
    const name = elSpan('grp-name', isTasks ? '任务会话' : g.key ? groupName(g.key) : '未绑定工作空间');
    const count = elSpan('grp-count', g.list.length ? String(g.list.length) : '');
    head.append(icon, name, count);
    // 悬停显示「⋮」「＋」（参考反重力 Projects）
    if (g.key && !isTasks) {
      const more = document.createElement('button');
      more.className = 'icon-btn grp-btn grp-more';
      more.innerHTML = UI.more;
      more.title = '更多操作';
      more.addEventListener('click', e => { e.stopPropagation(); openGroupMenu(id, g, more); });
      head.appendChild(more);
    }
    const add = document.createElement('button');
    add.className = 'icon-btn grp-btn grp-add';
    add.innerHTML = UI.plus;
    add.title = g.key ? `在「${baseName(g.key)}」里开启新对话` : '开启不绑定工作空间的新对话';
    add.addEventListener('click', e => { e.stopPropagation(); startChatIn(id, g.key); });
    if (!isTasks) head.appendChild(add);   // 任务会话不是一个目录，不在这里开新对话
    if (q) head.style.cursor = 'default';
    else head.addEventListener('click', () => {
      st.groupState[g.key] = collapsed ? 0 : 1;
      lsSet(`${id}_groups`, JSON.stringify(st.groupState));
      renderHistorySmooth(id);
    });
    list.appendChild(head);
    if (collapsed) return;

    if (pendingHere) list.appendChild(newChatRow(id));
    const background = q ? [] : backgroundNewRuns(id).filter(r => wsKey(r.workspace) === g.key);
    background.forEach(r => list.appendChild(pendingRunRow(id, r)));
    if (!pendingHere && !background.length && !g.list.length) list.appendChild(elSpan('grp-empty', '暂无对话'));
    const showAll = !!q || st.expanded.has(g.key);
    (showAll ? g.list : g.list.slice(0, GROUP_PREVIEW)).forEach(item => {
      const row = conversationRow(id, item);
      row.dataset.k = `c:${item.id}`;
      list.appendChild(row);
    });
    if (!q && g.list.length > GROUP_PREVIEW) {
      const more = document.createElement('div');
      more.className = 'see-all';
      more.dataset.k = `m:${g.key}`;
      more.textContent = showAll ? '收起' : `查看全部（${g.list.length}）`;
      more.addEventListener('click', () => {
        if (showAll) st.expanded.delete(g.key); else st.expanded.add(g.key);
        renderHistorySmooth(id);
      });
      list.appendChild(more);
    }
  });
  list.scrollTop = scroll;
  if (typeof queueSectionFit === 'function') queueSectionFit();   // 行数变了：各格的高度重新分（layout.js）
}

/**
 * 展开 / 折叠一个工作空间（或者「查看全部」）时重画，但不是一帧闪过去：
 * 还在的行从原来的位置滑到新位置，新出现的行淡进来，消失的行原地淡出去，各格的高度也一起平滑地变。
 * 做法：重画前记下每一行在列表里的位置，重画后算出每一行挪了多少，让它从旧位置动到新位置。
 */
function renderHistorySmooth(id) {
  const { list } = histSections[id];
  const rel = el => el.getBoundingClientRect().top - list.getBoundingClientRect().top + list.scrollTop;
  const before = new Map([...list.children].filter(el => el.dataset.k).map(el => [el.dataset.k, { el, top: rel(el) }]));
  const heightsBefore = AGENT_IDS.map(a => histSections[a].sec.getBoundingClientRect().height);
  renderHistory(id);
  applySectionWeights();   // 各格的高度马上重新分好（平时是攒到下一帧）
  const rows = [...list.children].filter(el => el.dataset.k).map(el => ({ el, top: rel(el), old: before.get(el.dataset.k) }));
  const heightsAfter = AGENT_IDS.map(a => histSections[a].sec.getBoundingClientRect().height);
  const spring = { duration: SPRING_EASE.snappy.ms, easing: SPRING_EASE.snappy.css };
  AGENT_IDS.forEach((a, i) => {
    if (Math.abs(heightsAfter[i] - heightsBefore[i]) > 1) {
      histSections[a].sec.animate([{ flex: `0 0 ${heightsBefore[i]}px` }, { flex: `0 0 ${heightsAfter[i]}px` }], spring);
    }
  });
  rows.forEach(({ el, top, old }) => {
    if (!old) el.animate([{ opacity: 0, transform: 'translateY(-8px)' }, { opacity: 1, transform: 'none' }], spring);
    else if (Math.abs(old.top - top) > 0.5) el.animate([{ transform: `translateY(${old.top - top}px)` }, { transform: 'none' }], spring);
  });
  // 消失的行：放回原来的位置（不占地方），淡出去再拿掉
  const kept = new Set(rows.map(r => r.el.dataset.k));
  before.forEach((old, k) => {
    if (kept.has(k)) return;
    const ghost = old.el;
    ghost.classList.add('row-ghost');
    ghost.style.top = `${old.top}px`;
    list.appendChild(ghost);
    ghost.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 150, easing: 'ease-out', fill: 'forwards' });
    setTimeout(() => ghost.remove(), 170);
  });
}
