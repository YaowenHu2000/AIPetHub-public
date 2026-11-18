'use strict';

// 左栏删除整个项目：要先向原生统计这个工作空间的全部会话、等确认后才一起删，流程自成一段，所以单独放一个文件。

// ===== 删除项目：先统计这个工作空间里的全部会话（列表只显示最近 50 条），确认后一起删除 =====
let projectDelete = null;   // { id, key, anchor, ids }

function askDeleteProject(id, key) {
  projectDelete = { id, key, anchor: pop.anchor, ids: null };
  pop.render = renderProjectConfirm;
  pop.cls = 'confirm';
  renderPopover();
  positionPopover();
  if (hasBridge()) postNative('projectConversations', { agent: id, workspace: key });
  else window.onProjectConversations({ agent: id, workspace: key, ids: (S[id].conversations || []).filter(c => groupKeyOf(id, c) === key).map(c => c.id) });
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
    if (data.reason) {
      renderHistory(id);
      pets[id].say(data.reason, 6000);
    } else {
      forgetWorkspace(id, p.key);
      pets[id].say(failed.length ? `有 ${failed.length} 个会话没删掉…` : `已删除项目「${baseName(p.key)}」（${deleted.length} 个会话）🗑️`, 2200);
    }
  } else renderHistory(id);
  if (id === active) renderHeader();
};
