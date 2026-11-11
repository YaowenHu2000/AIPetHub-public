'use strict';

// 一轮回答改了哪些文件：记下来（会话重读后还能把改动卡片接回去）、「查看全部改动」标签；智能体用工具打开内置浏览器时切过去。
// 接在 live.js 后面加载。纯逻辑在 logic.js。

// ===== 这一轮的改动：「查看全部改动」 =====
// 这次运行里答完的每一轮记一份改了哪些文件。会话从 CLI 的记录重新读一遍（切回窗口时会同步）以后，靠它把改动卡片接回去
// ——CLI 的记录里没有「命令改的文件」（那是回答前后比 git 得来的）。
const turnExtras = new Map();    // `${agent}:${会话ID}` → [extra…]（旧的在前）

function rememberTurn(id, run, data, cwd) {
  const files = Array.isArray(data.files) ? data.files : [];
  if (!files.length) return null;
  const ex = { agent: id, text: (run.text || '').trim(), files, cwd };
  if (data.conversationId) {
    const key = `${id}:${data.conversationId}`;
    const list = turnExtras.get(key) || [];
    list.push(ex);
    turnExtras.set(key, list.slice(-40));
  }
  return ex;
}

/** 重新渲染一个会话时：哪几条回答是这次运行里答的（按它前面那句提问认，从后往前配）。返回 回答的下标 → extra。 */
function matchTurnExtras(id, messages) {
  return matchExtras(turnExtras.get(`${id}:${S[id].conversationId}`) || [], messages);
}

/** 给一轮回答的改动卡片接上「查看全部改动」。 */
function decorateTurn(turn, id, ex) {
  const head = turn.querySelector('.files-card .files-head');
  if (!head || head.querySelector('.files-all')) return;
  const all = document.createElement('span');
  all.className = 'files-all';
  all.textContent = '查看全部改动';
  all.title = '在右边把这一轮改的所有文件连着看';
  all.addEventListener('click', e => { e.stopPropagation(); openChanges(ex); });
  head.insertBefore(all, head.querySelector('.diff-count'));
}

// ===== 「全部改动」标签：这一轮改的所有文件连着看 =====
function openChanges(ex) {
  let tab = pane.tabs.find(t => t.kind === 'changes' && t.extra === ex);
  if (!tab) {
    tab = { id: ++pane.seq, kind: 'changes', raw: '这一轮的改动', title: `改动（${ex.files.length} 个文件）`, extra: ex };
    pane.tabs.push(tab);
    if (pane.tabs.length > 8) pane.tabs.shift();
  }
  pane.active = tab.id;
  setPaneVisible(true);
  renderPaneTabs();
  renderPaneBody();
}

/** preview/pane.js 的 renderPaneContent 遇到「全部改动」标签时调用。 */
function renderChanges(bar, body, tab) {
  const ex = tab.extra;
  const added = ex.files.reduce((n, f) => n + (f.added || 0), 0);
  const removed = ex.files.reduce((n, f) => n + (f.removed || 0), 0);
  bar.innerHTML = `<span class="chg-summary">这一轮改了 ${ex.files.length} 个文件</span><span class="diff-count"><span class="add">+${added}</span> <span class="del">−${removed}</span></span>`;
  const wrap = document.createElement('div');
  wrap.className = 'chg-list';
  ex.files.forEach(f => {
    const sec = document.createElement('section');
    sec.className = 'chg-file';
    const head = document.createElement('div');
    head.className = 'chg-file-head';
    const badge = f.kind === 'create' ? '<span class="file-badge">新建</span>' : f.kind === 'delete' ? '<span class="file-badge del">删除</span>' : '';
    head.innerHTML = `<span class="chg-name"></span><span class="chg-dir"></span>${badge}<span class="diff-count"><span class="add">+${f.added || 0}</span> <span class="del">−${f.removed || 0}</span></span><span class="chg-spacer"></span>`;
    head.querySelector('.chg-name').textContent = baseName(f.path);
    head.querySelector('.chg-dir').textContent = prettyPath(f.path.replace(/\/[^/]*$/, ''));
    if (f.kind !== 'delete') {
      const open = document.createElement('button');
      open.className = 'chg-btn';
      open.textContent = '打开文件';
      open.addEventListener('click', () => openPreview({ path: f.path, base: ex.cwd || '', diff: f.diff || '' }));
      head.appendChild(open);
    }
    sec.appendChild(head);
    const rows = [];
    parseHunks(f.diff || '').forEach((h, k) => {
      if (k) rows.push({ type: 'ctx', text: '⋯', no: '' });
      let no = h.newStart;
      h.lines.forEach(l => {
        const type = l.t === '+' ? 'add' : l.t === '-' ? 'del' : 'ctx';
        rows.push({ type, text: l.s, no: type !== 'del' && no ? no : '' });
        if (type !== 'del' && no) no++;
      });
    });
    if (rows.length) renderCode(sec, rows, f.path);
    else sec.insertAdjacentHTML('beforeend', `<div class="ed-note">${f.kind === 'delete' ? '这个文件被删掉了' : '没有可显示的改动内容（二进制文件，或者不在 git 仓库里）；点「打开文件」看现在的样子'}</div>`);
    wrap.appendChild(sec);
  });
  body.appendChild(wrap);
}

// 智能体用工具打开内置浏览器（原生：BrowserTools.swift）：切到浏览器标签，有地址就打开
window.onBrowserToolOpen = data => { openBrowser(data.url || ''); };
