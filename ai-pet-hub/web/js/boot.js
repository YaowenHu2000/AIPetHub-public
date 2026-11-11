'use strict';

// 启动：绑定按钮和快捷键、创建桌宠、恢复上次的状态、定时刷新。最后加载（只在 preview/ 下的几个文件之前）。

// ===== 初始化 =====
$('#btn-hide-sidebar').innerHTML = UI.sidebar;
$('#btn-show-sidebar').innerHTML = UI.sidebar;
$('#btn-hide-sidebar').addEventListener('click', () => setSidebarHidden(true));
$('#btn-show-sidebar').addEventListener('click', () => setSidebarHidden(false));
document.body.classList.toggle('sidebar-hidden', lsGet('sidebar_hidden') === '1');

// 聊天区和桌宠对「全部支持的」都建好；放不放到界面上看启用名单（ui/agents.js 的 layoutAgents）
ALL_AGENT_IDS.forEach(id => {
  const box = document.createElement('div');
  box.className = 'chat-messages';
  box.hidden = true;
  els.chatStack.appendChild(box);
  S[id].msgEl = box;
  pets[id] = new Pet(id);
  showEmpty(id, S[id].conversationId ? '正在加载历史会话…' : '');
});
layoutAgents();

applyWidths();
setupColumnResizer($('#resize-sidebar'), 'sidebar');
setupColumnResizer($('#resize-stage'), 'stage');
setupColumnResizer($('#resize-preview'), 'preview');
window.addEventListener('resize', () => { closePopover(); applyWidths(); queueSectionFit(); });

makeDragRegion($('.sidebar-top'));
makeDragRegion($('#chat-header'));
makeDragRegion(els.stage, true);

els.chatStack.addEventListener('click', e => {
  const shot = e.target.closest('.msg-img, .msg-imgref');
  if (shot && shot._image) { openImageViewer(shot._image); return; }
  const chip = e.target.closest('.file-chip');
  if (chip) { previewFromTurn(chip.dataset.path, chip.closest('.turn')); return; }
  const link = e.target.closest('.ext-link');
  if (link) { openLink(link.dataset.url); return; }
  const fileRow = e.target.closest('.file-row');
  if (fileRow) {
    const turnEl = fileRow.closest('.turn');
    const f = turnEl._files[Number(fileRow.dataset.index)];
    if (f) openPreview({ path: f.path, base: turnEl.dataset.cwd, diff: f.diff || '' });
    return;
  }
  const head = e.target.closest('.step-head');
  if (head) {
    if (head.classList.contains('has-file') && !e.target.closest('.step-caret')) { previewFromTurn(head.dataset.path, head.closest('.turn')); return; }
    if (head.classList.contains('expandable')) {
      const body = head.parentElement.querySelector('.step-body');
      body.hidden = !body.hidden;
      head.classList.toggle('open', !body.hidden);
    }
    return;
  }
  const workHead = e.target.closest('.work-head');
  if (workHead && !workHead.parentElement.classList.contains('live')) workHead.parentElement.classList.toggle('open');
});
els.chipModel.addEventListener('click', openModelPopover);
els.chipPerm.addEventListener('click', openPermPopover);
els.popoverSub.addEventListener('mouseenter', () => clearTimeout(subTimer));
document.addEventListener('mousedown', e => {
  if (pop && !els.popover.contains(e.target) && !els.popoverSub.contains(e.target) && !pop.anchor.contains(e.target)) closePopover();
}, true);
els.wsCrumb.querySelector('.ws-icon').innerHTML = UI.folder;
const browserBtn = document.getElementById('btn-browser');
browserBtn.innerHTML = UI.globe;
browserBtn.addEventListener('click', () => openBrowser());
els.wsCrumb.addEventListener('click', () => {
  const ws = wsKey(S[active].workspace);
  if (ws) postNative('openFolder', { path: ws });
});
// 切回窗口时顺手刷新历史列表（在别处新建的会话也能看到）
let lastAutoRefresh = Date.now();
window.addEventListener('focus', () => {
  if (Date.now() - lastAutoRefresh < 15000) return;
  lastAutoRefresh = Date.now();
  AGENT_IDS.forEach(id => {
    postNative('listConversations', { agent: id });
    // 打开着的会话也重新读一遍（在终端里接着聊过的话，这里会同步过来）
    const st = S[id];
    if (st.conversationId && st.loadedId === st.conversationId && !viewBusy(id)) {
      st.syncing = true;
      postNative('loadConversation', { agent: id, conversationId: st.conversationId });
    }
  });
});

// 往上翻看时右下出现「回到最新」
const jumpBtn = document.createElement('button');
jumpBtn.id = 'jump-bottom';
jumpBtn.title = '回到最新';
jumpBtn.innerHTML = UI.caret;
jumpBtn.hidden = true;
els.chatStack.appendChild(jumpBtn);
function updateJumpButton() {
  const box = S[active].msgEl;
  jumpBtn.hidden = !box || box.scrollHeight - box.scrollTop - box.clientHeight < 240;
}
jumpBtn.addEventListener('click', () => {
  const box = S[active].msgEl;
  box.scrollTo({ top: box.scrollHeight, behavior: 'smooth' });
});
els.chatStack.addEventListener('scroll', updateJumpButton, true);   // 滚动事件不冒泡，用捕获

els.sendBtn.addEventListener('click', () => (viewBusy(active) ? stop() : send()));
let draftTimer = 0;
els.input.addEventListener('input', () => {
  autosize();
  // 输入框里的草稿随时存下来（App 重启、崩溃后还在）
  clearTimeout(draftTimer);
  const id = active;
  draftTimer = setTimeout(() => { S[id].draft = els.input.value; lsSet(`${id}_draft`, els.input.value); }, 300);
});
els.input.addEventListener('keydown', e => {
  pets[active].touch();   // 打字算互动：不会打着字她睡着；已经睡着的会醒
  if (e.isComposing || e.keyCode === 229) return;
  if (suggestKey(e)) return;   // 正在选 / 命令或 @ 文件（live.js）
  // 空输入框按 ↑：找回上一句；接着按 ↑ / ↓ 在发过的话里往前、往后翻
  if ((e.key === 'ArrowUp' || e.key === 'ArrowDown') && !e.shiftKey && !e.metaKey && !e.altKey
      && browsePrompts(active, e.key === 'ArrowUp' ? -1 : 1)) {
    e.preventDefault();
    return;
  }
  if (e.key !== 'Enter') return;
  if (e.shiftKey || e.altKey || e.ctrlKey || e.metaKey) {
    if (!e.shiftKey) {
      e.preventDefault();
      const { selectionStart: start, selectionEnd: end, value } = els.input;
      els.input.value = value.slice(0, start) + '\n' + value.slice(end);
      els.input.selectionStart = els.input.selectionEnd = start + 1;
      autosize();
    }
    return;
  }
  e.preventDefault();
  send();
});

document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && imageViewer) { closeImageViewer(); return; }
  if (e.key === 'Escape' && pop) { closePopover(); return; }
  if (e.key === 'Escape' && document.body.classList.contains('preview-max')) {
    document.body.classList.remove('preview-max');
    applyWidths();
    return;
  }
  if (!e.metaKey || e.altKey || e.ctrlKey) return;
  if (['1', '2', '3', '4', '5'].includes(e.key)) {
    e.preventDefault();
    if (AGENT_IDS[Number(e.key) - 1]) setActive(AGENT_IDS[Number(e.key) - 1]);
  } else if (e.key.toLowerCase() === 'n' && !e.shiftKey) {
    e.preventDefault();
    startChatIn(active, '');   // 和区域标题上的 ＋ 一样：不绑定工作空间
  } else if (e.key.toLowerCase() === 'f' && !e.shiftKey) {
    e.preventDefault();
    if (document.body.classList.contains('sidebar-hidden')) setSidebarHidden(false);
    histSearch.focus();
    histSearch.select();
  }
});

setInterval(() => AGENT_IDS.forEach(id => pets[id].tick()), 500);
setInterval(() => {
  const now = Date.now();
  AGENT_IDS.forEach(id => {
    if (!isBusy(id)) return;
    let phaseChanged = false;
    S[id].runs.forEach(run => {
      if (run.stepStatus !== 'running' && run.phase !== 'thinking' && now - (run.stepAt || run.since) > 4200) {
        run.phase = 'thinking';
        run.stepKind = 'think';
        run.stepTitle = '思考下一步…';
        phaseChanged = true;
      }
      updateLiveLabel(run);
    });
    if (phaseChanged) pets[id].syncBusyState();
    else pets[id].renderStatus();
  });
  updateJumpButton();
}, 1000);
setInterval(renderAllHistory, 60000);   // 刷新「几分钟前」

els.input.value = S[active].draft || '';   // 启动时恢复上次没发出去的草稿
autosize();
setActive(active, true);
AGENT_IDS.forEach(id => {
  postNative('listConversations', { agent: id });
  if (S[id].conversationId) postNative('loadConversation', { agent: id, conversationId: S[id].conversationId });
});
// 第一次打开（全新安装：还没存过启用名单、也没看过引导）：引导页——找本机装了哪些、讲清楚默认权限（ui/welcome.js）
if (!lsGet('enabled_agents') && !lsGet('welcomed') && !window.__uitest) openWelcome();
else if (!lsGet('enabled_agents')) postNative('probeAgents', { agents: ALL_AGENT_IDS });

// 页面好了：让原生把窗口现在的状态（全屏、在不在前台）告诉这边（body 上的 fullscreen / window-inactive）
postNative('pageReady', {});
