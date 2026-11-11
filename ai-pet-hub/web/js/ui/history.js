'use strict';

// 左栏：三位的历史会话（按工作空间分组）、搜索、删除会话和项目、打开会话、新对话。

// ===== 删除项目：先统计这个工作空间里的全部会话（列表只显示最近 50 条），确认后一起删除 =====
let projectDelete = null;   // { id, key, anchor, ids }

function askDeleteProject(id, key) {
  projectDelete = { id, key, anchor: pop.anchor, ids: null };
  pop.render = renderProjectConfirm;
  pop.cls = 'confirm';
  renderPopover();
  positionPopover();
  if (hasBridge()) postNative('projectConversations', { agent: id, workspace: key });
  else window.onProjectConversations({ agent: id, workspace: key, ids: (S[id].conversations || []).filter(c => wsKey(c.cwd) === key).map(c => c.id) });
}

function renderProjectConfirm(box) {
  const p = projectDelete;
  const c = AGENTS[p.id];
  const wrap = document.createElement('div');
  wrap.className = 'confirm-box';
  const title = document.createElement('div');
  title.className = 'confirm-title';
  title.textContent = `删除项目「${baseName(p.key)}」？`;
  const text = document.createElement('div');
  text.className = 'confirm-text';
  const where = p.id === 'gpt' ? '会归档，可以在 Codex 中恢复' : '会移到废纸篓，可以从废纸篓恢复';
  text.textContent = p.ids === null ? '正在统计这个项目里的会话…'
    : p.ids.length ? `${c.name}在这里的 ${p.ids.length} 个会话${where}。文件夹本身不会删除。`
      : '这里没有会话，只会从列表中去掉。文件夹本身不会删除。';
  const actions = document.createElement('div');
  actions.className = 'confirm-actions';
  const cancel = document.createElement('button');
  cancel.className = 'confirm-btn';
  cancel.textContent = '取消';
  cancel.addEventListener('click', e => { e.stopPropagation(); closePopover(); });
  const ok = document.createElement('button');
  ok.className = 'confirm-btn danger';
  ok.textContent = '删除';
  ok.disabled = p.ids === null;
  ok.addEventListener('click', e => { e.stopPropagation(); confirmDeleteProject(); });
  actions.append(cancel, ok);
  wrap.append(title, text, actions);
  box.appendChild(wrap);
}

window.onProjectConversations = data => {
  const p = projectDelete;
  if (!p || !pop || pop.anchor !== p.anchor || data.agent !== p.id || data.workspace !== p.key) return;
  p.ids = Array.isArray(data.ids) ? data.ids : [];
  renderPopover();
  positionPopover();
};

function confirmDeleteProject() {
  const p = projectDelete;
  closePopover();
  if (!p || p.ids === null) return;
  const st = S[p.id];
  // 正在回答的会话在这个项目里时先不删
  if ([...st.runs.values()].some(r => p.ids.includes(r.view) || (r.view.startsWith('new:') && wsKey(r.workspace) === p.key))) {
    pets[p.id].say('正在回答这个项目里的会话，先等等～', 2200);
    return;
  }
  if (!p.ids.length) { forgetWorkspace(p.id, p.key); pets[p.id].say(`已删除项目「${baseName(p.key)}」🗑️`, 1800); return; }
  projectDelete = { ...p, deleting: true };
  if (hasBridge()) postNative('deleteConversations', { agent: p.id, conversationIds: p.ids });
  else window.onConversationsDeleted({ agent: p.id, deleted: p.ids, failed: [] });
}

window.onConversationsDeleted = data => {
  const id = data.agent;
  const st = S[id];
  if (!st) return;
  const deleted = Array.isArray(data.deleted) ? data.deleted : [];
  const failed = Array.isArray(data.failed) ? data.failed : [];
  if (st.conversations) st.conversations = st.conversations.filter(c => !deleted.includes(c.id));
  if (deleted.includes(st.conversationId)) {
    st.conversationId = '';
    st.loadedId = '';
    lsSet(`${id}_conv`, '');
    showEmpty(id);
  }
  const p = projectDelete;
  if (p && p.deleting && p.id === id) {
    projectDelete = null;
    forgetWorkspace(id, p.key);
    pets[id].say(failed.length ? `有 ${failed.length} 个会话没删掉…` : `已删除项目「${baseName(p.key)}」（${deleted.length} 个会话）🗑️`, 2200);
  } else renderHistory(id);
  if (id === active) renderHeader();
};

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

// ===== 左栏：三位的历史会话上下三格，每格按工作空间分组（可折叠） =====
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
    postNative('listConversations', { agent: id });
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

/** filtered：搜索时只按搜到的会话分组，不加入空的工作空间和「新对话」那一组。 */
function buildGroups(id, items = S[id].conversations, filtered = false) {
  const st = S[id];
  const map = new Map();
  items.forEach(it => {
    const key = wsKey(it.cwd);
    if (!map.has(key)) map.set(key, []);
    map.get(key).push(it);
  });
  const groups = [...map.entries()].map(([key, list]) => ({ key, list, latest: Math.max(...list.map(i => i.timestamp || 0)) }));
  if (filtered) return groups.sort((a, b) => (a.key === '') - (b.key === '') || b.latest - a.latest);
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
  return groups.sort((a, b) => (a.key === '') - (b.key === '') || b.latest - a.latest);   // 未绑定的放最后
}

function isCollapsed(id, key, index) {
  const state = S[id].groupState;
  return Object.prototype.hasOwnProperty.call(state, key) ? state[key] === 1 : index >= 3;
}

function renderAllHistory() { AGENT_IDS.forEach(renderHistory); }

// 左栏顶部的搜索：按会话标题或工作空间名过滤三位的会话
let histQuery = '';
const histSearch = document.getElementById('hist-search');
let bodySearchTimer = 0;
histSearch.addEventListener('input', () => {
  histQuery = histSearch.value.trim().toLowerCase();
  renderAllHistory();
  // 停下来 0.3 秒再去翻正文
  clearTimeout(bodySearchTimer);
  const q = histQuery;
  if (q.length >= 2) bodySearchTimer = setTimeout(() => AGENT_IDS.forEach(id => postNative('searchConversations', { agent: id, query: q })), 300);
});
window.onConversationsSearched = data => {
  const st = S[data.agent];
  if (!st || data.query !== histQuery) return;   // 已经改了搜索词
  st.bodyQuery = data.query;
  st.bodyHits = new Set(data.ids || []);
  renderHistory(data.agent);
};
document.querySelector('.search-clear').addEventListener('click', e => {
  e.preventDefault();
  histSearch.value = '';
  histSearch.dispatchEvent(new Event('input'));
  histSearch.focus();
});
histSearch.addEventListener('keydown', e => {
  if (e.key === 'Escape') { e.stopPropagation(); histSearch.value = ''; histQuery = ''; renderAllHistory(); histSearch.blur(); }
});

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
  const all = [...liveItems(id), ...st.conversations];   // 刚建好、列表里还没有的正在回答的会话放在最前
  // 标题、工作空间里有，或者正文里有（原生在会话记录里找，结果稍后到：onConversationsSearched）
  const inBody = st.bodyQuery === q ? st.bodyHits : null;
  const items = q ? all.filter(it => (it.title || '').toLowerCase().includes(q) || wsKey(it.cwd).toLowerCase().includes(q) || inBody?.has(it.id)) : all;
  const groups = buildGroups(id, items, !!q);
  if (!groups.length) { list.innerHTML = `<div class="hist-empty">${q ? '没有匹配的会话' : '暂无历史会话'}</div>`; return; }

  groups.forEach((g, index) => {
    const pendingHere = !q && showsNewChat(id) && g.key === wsKey(st.workspace);   // 「新对话」在这一组
    const collapsed = q ? false : isCollapsed(id, g.key, index);   // 搜索时全部展开
    const hasActive = pendingHere || g.list.some(it => it.id === st.conversationId);
    const head = document.createElement('div');
    head.className = 'grp-head' + (collapsed && hasActive ? ' has-active' : '');
    head.dataset.k = `g:${g.key}`;   // 每一行一个记号：展开 / 折叠时靠它认出「这还是原来那一行」（renderHistorySmooth）
    head.title = g.key ? prettyPath(g.key) : '未绑定工作空间的会话（在主目录运行）';
    const icon = document.createElement('span');
    icon.className = 'grp-icon';
    icon.innerHTML = collapsed ? UI.folder : UI.folderOpen;
    const name = elSpan('grp-name', g.key ? baseName(g.key) : '未绑定工作空间');
    const count = elSpan('grp-count', g.list.length ? String(g.list.length) : '');
    head.append(icon, name, count);
    // 悬停显示「⋮」「＋」（参考反重力 Projects）
    if (g.key) {
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
    head.appendChild(add);
    head.addEventListener('click', () => {
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
    if (g.list.length > GROUP_PREVIEW) {
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
  if (typeof queueSectionFit === 'function') queueSectionFit();   // 行数变了：三格的高度重新分（layout.js）
}

/**
 * 展开 / 折叠一个工作空间（或者「查看全部」）时重画，但不是一帧闪过去：
 * 还在的行从原来的位置滑到新位置，新出现的行淡进来，消失的行原地淡出去，三格的高度也一起平滑地变。
 * 做法：重画前记下每一行在列表里的位置，重画后算出每一行挪了多少，让它从旧位置动到新位置。
 */
function renderHistorySmooth(id) {
  const { list } = histSections[id];
  const rel = el => el.getBoundingClientRect().top - list.getBoundingClientRect().top + list.scrollTop;
  const before = new Map([...list.children].filter(el => el.dataset.k).map(el => [el.dataset.k, { el, top: rel(el) }]));
  const heightsBefore = AGENT_IDS.map(a => histSections[a].sec.getBoundingClientRect().height);
  renderHistory(id);
  applySectionWeights();   // 三格的高度马上重新分好（平时是攒到下一帧）
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
  const old = run.view;
  run.view = cid;
  if (viewKey(id) === old) {   // 正看着它：当前会话就是这个了（App 重启后也会回到这里）
    st.conversationId = cid;
    st.loadedId = cid;
    st.pendingTitle = '';
    lsSet(`${id}_conv`, cid);
  }
  return true;
}

function pendingRunRow(id, run) {
  const row = document.createElement('div');
  row.className = 'conv-row pending running';
  row.title = '正在回答的新对话（点击查看进度）';
  row.appendChild(elSpan('conv-title', run.title || '新对话'));
  row.addEventListener('click', () => openPendingRun(id, run));
  return row;
}

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
  time.textContent = relTime(item.timestamp);
  const del = document.createElement('button');
  del.className = 'conv-del';
  del.innerHTML = UI.trash;
  del.title = id === 'gpt' ? '删除此会话（归档，可在 Codex 中恢复）' : '删除此会话（移到废纸篓）';
  del.addEventListener('click', e => {
    e.stopPropagation();
    if (!del.classList.contains('confirm')) {
      del.classList.add('confirm');
      del.textContent = '确认删除';
      setTimeout(() => { if (del.isConnected) { del.classList.remove('confirm'); del.innerHTML = UI.trash; } }, 3000);
      return;
    }
    if (runsOf(id, item.id).length) { pets[id].say('正在回答这个会话，先等等～', 2000); return; }
    postNative('deleteConversation', { agent: id, conversationId: item.id });
  });
  row.addEventListener('click', () => openConversation(id, item));
  row.append(title, time, del);
  return row;
}

function openConversation(id, item) {
  if (id !== active) setActive(id, false);
  const st = S[id];
  if (st.conversationId === item.id && st.loadedId === item.id) return;
  st.conversationId = item.id;
  st.loadedId = null;
  st.pendingTitle = '';
  st.unreadConvs.delete(item.id);
  st.applyCwdOnLoad = true;
  lsSet(`${id}_conv`, item.id);
  showEmpty(id, '正在加载历史会话…');
  renderHistory(id);
  renderHeader();
  updateSendUI();
  postNative('loadConversation', { agent: id, conversationId: item.id });
  pets[id].touch();
  pets[id].syncBusyState();
  pets[id].say('已切换历史会话 📜', 1600);
}

/** 回到一个还在回答、还没有会话 ID 的新对话。 */
function openPendingRun(id, run) {
  if (id !== active) setActive(id, false);
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
  if (id !== active) setActive(id, false);
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
