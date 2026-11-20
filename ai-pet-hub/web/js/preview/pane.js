'use strict';

// 预览面板：多标签、面包屑、代码 / Markdown / 图片的显示、在改动之间跳转。

// ---------- 面板 ----------
const pane = {
  el: document.getElementById('preview-pane'),
  tabs: [],
  active: null,
  seq: 0,
};
const PREVIEW_TEXT_EXTS = new Set(['md', 'markdown']);
const dirOf = p => p.replace(/\/[^/]*$/, '') || '/';
const cleanPath = p => p.replace(/^file:\/\//, '').replace(/:\d+(:\d+)?$/, '');
/** 在内置浏览器里看的文档：PDF 由 WebKit 直接显示；Word、Excel、PPT 等由 App 用系统预览（Quick Look）转成网页，文字都能选中复制。 */
/** （.dot、.pot、.key 不算：常见的是 Graphviz、翻译模板、密钥这些文本文件。） */
const BROWSER_DOC_RE = /\.(pdf|docx?|docm|dotx|dotm|xlsx?|xlsm|xltx?|xltm|pptx?|pptm|ppsx?|ppsm|potx|potm|rtf|odt)$/i;

function setPaneVisible(on) {
  pane.el.hidden = !on;
  document.getElementById('resize-preview').hidden = !on;
  if (!on) document.body.classList.remove('preview-max');
  applyWidths();
  syncBrowser();
}

/** 打开文件（已打开就切过去）；diff 是这一轮回答里对它的改动。 */
function openPreview({ path, base = '', diff = '', change = null }) {
  const raw = cleanPath(path);
  if (BROWSER_DOC_RE.test(raw)) { openBrowser(raw, base, true); return; }
  let tab = pane.tabs.find(t => (t.raw === raw && t.base === base) || (raw.startsWith('/') && t.resolved === raw));
  const existed = !!tab;
  if (!tab) {
    tab = { id: ++pane.seq, raw, path, base, diff, data: null, mode: null, scrolled: false };
    pane.tabs.push(tab);
    if (pane.tabs.length > 8) removePaneTab(0);
  } else if (diff !== tab.diff) {   // 空 diff 也要换上：从没改动的引用打开时，上一轮的增删标记不该留着
    tab.diff = diff;
    tab.scrolled = false;
  }
  tab.change = change;
  if (pane.active !== tab.id) rememberScroll();
  pane.active = tab.id;
  setPaneVisible(true);
  renderPaneTabs();
  renderPaneBody();
  // 已经开着的也重新读：文件可能被改过（不然显示旧内容、配上新的改动标记，对不上）
  if (!tab.data || existed) loadTab(tab);
}

/** 读文件内容放进标签；内容没变就不重画（保持滚动位置）。 */
function loadTab(tab) {
  const seq = tab.loadSeq = (tab.loadSeq || 0) + 1;   // 连着读好几次时，结果回来的顺序不一定，只认最后一次
  readLocalFile(tab.path, tab.base).then(data => {
    if (seq !== tab.loadSeq) return;
    if (!pane.tabs.includes(tab)) return;   // 读完前已经关掉了
    const same = tab.data && tab.data.content === data.content && tab.data.image === data.image && tab.data.error === data.error;
    tab.data = data;
    if (data.path) tab.resolved = data.path;
    const dup = pane.tabs.find(t => t !== tab && t.resolved && t.resolved === tab.resolved);
    if (dup) {
      // 留下的是先开的那个标签，但这次读到的正文和这次打开带的改动才是最新的
      dup.data = data;
      dup.change = tab.change;
      if (tab.diff !== dup.diff) { dup.diff = tab.diff; dup.scrolled = false; }
      pane.tabs = pane.tabs.filter(t => t !== tab);
      if (pane.active === tab.id) pane.active = dup.id;
    }
    if (same && !dup && !tab.changeUpdated) return;
    tab.changeUpdated = false;
    renderPaneTabs();
    if (dup || pane.active === tab.id) renderPaneBody();
  });
}

/** 一轮回答改了文件：开着的预览跟着更新（文本重新读、显示这一轮的改动；网页、文档预览重新载入）。 */
function refreshPreviews(files, cwd) {
  if (!Array.isArray(files) || !files.length || !pane.tabs.length) return;
  const abs = p => (p.startsWith('/') ? p : `${cwd || ''}/${p.replace(/^\.\//, '')}`);
  const changed = new Map(files.filter(f => f && f.path).map(f => [abs(cleanPath(f.path)), f]));
  pane.tabs.forEach(t => {
    if (t.kind === 'browser') return;
    const f = t.resolved && changed.get(t.resolved);
    if (!f) return;
    const diff = f.diff || '';
    const updated = t.diff !== diff || ['added','removed','truncated','kind'].some(key => t.change?.[key] !== f[key]);
    t.change = f; t.diff = diff;
    if (updated) { t.scrolled = false; t.changeUpdated = true; }
    loadTab(t);
  });
  // 浏览器：正在看的文件被改了就刷新；看的是网页文件时，交给原生按页面实际加载的本地资源判断（Browser.swift 的 reloadBrowserIfUses），
  // 不按所在文件夹：同目录的 README 改了不该重载清空表单，引用上层目录的样式改了要刷新
  const shown = browser.file;
  if (shown && browserTab()) {
    if (changed.has(shown)) postNative('browserCommand', { cmd: 'reload' });
    else if (/\.html?$/i.test(shown)) postNative('browserReloadIfUses', { paths: [...changed.keys()] });
  }
}

function removePaneTab(index) {
  const [removed] = pane.tabs.splice(index, 1);
  if (removed?.kind === 'browser') postNative('browserCommand', {cmd:'close'});
}

function closePreview() {
  if (browserTab()) postNative('browserCommand', {cmd:'close'});
  pane.tabs = [];
  pane.active = null;
  setPaneVisible(false);
}

function closeTab(id) {
  const idx = pane.tabs.findIndex(t => t.id === id);
  if (idx < 0) return;
  removePaneTab(idx);
  if (pane.active === id) pane.active = pane.tabs.length ? pane.tabs[Math.max(0, idx - 1)].id : null;
  if (!pane.tabs.length) { closePreview(); return; }
  renderPaneTabs();
  renderPaneBody();
}

const activeTab = () => pane.tabs.find(t => t.id === pane.active);

function renderPaneTabs() {
  const box = pane.el.querySelector('.ed-tabs-list');
  box.innerHTML = '';
  pane.tabs.forEach(t => {
    const isWeb = t.kind === 'browser';
    const isChanges = t.kind === 'changes';   // 「全部改动」标签（live.js）
    const name = isWeb ? (t.title || '网页预览') : isChanges ? t.title : baseName(t.resolved || t.raw);
    const tab = document.createElement('div');
    tab.className = 'ed-tab' + (t.id === pane.active ? ' on' : '') + (t.diff ? ' changed' : '');
    tab.title = isWeb ? (browser.file || browser.url || '内置浏览器') : (t.resolved || t.raw);
    const icon = isChanges ? UI.pencil : isWeb && !browser.file ? UI.globe : UI.file;   // 浏览器里看的是本地文档时用文件图标
    tab.innerHTML = `<span class="ed-tab-icon">${icon}</span><span class="ed-tab-name"></span><button class="ed-tab-x" title="关闭">${UI.close}</button>`;
    tab.querySelector('.ed-tab-name').textContent = name;
    tab.addEventListener('click', e => {
      if (e.target.closest('.ed-tab-x')) { closeTab(t.id); return; }
      if (pane.active !== t.id) rememberScroll();
      pane.active = t.id;
      renderPaneTabs();
      renderPaneBody();
    });
    box.appendChild(tab);
  });
}

/** 面包屑：在当前工作空间里就从工作空间名开始，否则从 ~ 开始。 */
function crumbsFor(path) {
  const ws = (S[active] && S[active].workspace) || '';
  let rel = prettyPath(path);
  let root = '';
  if (ws && path.startsWith(ws + '/')) { root = baseName(ws); rel = path.slice(ws.length + 1); }
  const parts = rel.split('/').filter(Boolean);
  if (root) parts.unshift(root);
  return parts;
}

function renderPaneBody() {
  renderPaneContent();
  updatePaneActions();
  syncBrowser();   // 切到别的标签、关掉面板时藏起内置浏览器
}

/** 右上角按钮跟着当前标签：浏览器里看的是网页时没有「在访达中显示」，「打开」变成用系统浏览器。 */
function updatePaneActions() {
  const t = activeTab();
  const web = !!t && ((t.kind === 'browser' && !browser.file) || t.kind === 'changes');
  pane.el.querySelector('.ed-reveal').style.display = web ? 'none' : '';
  pane.el.querySelector('.ed-open').style.display = t?.kind === 'changes' ? 'none' : '';
  pane.el.querySelector('.ed-open').title = web ? '在系统浏览器中打开' : '用默认应用打开';
  const ext = pane.el.querySelector('.browser-ext');
  if (ext) ext.title = browser.file ? '用默认应用打开' : '在系统浏览器中打开';
}

/** 右上角按钮操作的文件：普通标签是它的文件；浏览器标签是正在看的本地文件（文档预览是原文件）。 */
function paneTarget(t) {
  if (!t) return null;
  if (t.kind === 'browser') return browser.file ? { path: browser.file, base: '' } : null;
  if (t.kind === 'changes') return null;
  return { path: t.resolved || t.path, base: t.base };
}

function renderPaneContent() {
  const tab = activeTab();
  const bar = pane.el.querySelector('.ed-bar');
  const body = pane.el.querySelector('.ed-body');
  body.classList.remove('browser-mode');
  if (!tab) { body.innerHTML = ''; bar.innerHTML = ''; return; }
  if (tab.kind === 'browser') { bar.innerHTML = ''; body.innerHTML = ''; renderBrowser(bar, body); return; }
  if (tab.kind === 'changes') {
    bar.innerHTML = ''; body.innerHTML = '';
    renderChanges(bar, body, tab);
    body.scrollTop = tab.savedScroll ?? 0;
    tab.savedScroll = null;
    return;
  }
  const data = tab.data;
  const path = tab.resolved || tab.raw;
  const ext = (path.split('.').pop() || '').toLowerCase();
  const isMd = PREVIEW_TEXT_EXTS.has(ext);
  if (isMd && !tab.mode) tab.mode = 'render';

  // 面包屑 + 工具
  bar.innerHTML = '';
  const crumbs = document.createElement('div');
  crumbs.className = 'ed-crumbs';
  crumbs.title = path;
  crumbsFor(path).forEach((part, i, arr) => {
    if (i) crumbs.insertAdjacentHTML('beforeend', '<span class="ed-sep">›</span>');
    const s = document.createElement('span');
    s.className = i === arr.length - 1 ? 'ed-crumb last' : 'ed-crumb';
    s.textContent = part;
    crumbs.appendChild(s);
  });
  bar.appendChild(crumbs);
  const tools = document.createElement('div');
  tools.className = 'ed-tools';
  bar.appendChild(tools);

  if (/^(html?|svg)$/.test(ext)) {   // 网页文件：可以在内置浏览器里看效果
    const ws = (S[active] && S[active].workspace) || '';
    tools.appendChild(toolButton(UI.globe, '在内置浏览器中预览', () => openBrowser(path, ws && path.startsWith(ws + '/') ? ws : dirOf(path))));
  }
  if (!data) { body.innerHTML = '<div class="ed-note">正在读取…</div>'; return; }
  body.innerHTML = '';
  if (data.image) { renderImage(body, data); return; }

  const hasContent = typeof data.content === 'string';
  const marks = tab.diff && hasContent ? annotateFile(data.content, tab.diff) : null;
  if (marks || (tab.diff && !hasContent)) {
    const truncated = patchTruncated(tab.change);
    const add = truncated ? tab.change.added : marks ? marks.added : tab.diff.split('\n').filter(l => l.startsWith('+') && !l.startsWith('+++')).length;
    const del = truncated ? tab.change.removed : marks ? marks.removed : tab.diff.split('\n').filter(l => l.startsWith('-') && !l.startsWith('---')).length;
    tools.insertAdjacentHTML('beforeend', `<span class="ed-diffinfo" title="这一轮回答对它的改动"><span class="add">+${add}</span> <span class="del">−${del}</span></span>`);
    if (truncated) tools.append(document.createTextNode('改动预览已截断'));
    const prev = toolButton(UI.caret, '上一处改动', () => jumpChange(-1));
    const next = toolButton(UI.caret, '下一处改动', () => jumpChange(1));
    next.classList.add('flip');
    tools.append(prev, next);
  }
  if (isMd && hasContent) {
    const seg = document.createElement('div');
    seg.className = 'ed-seg';
    [['render', '预览'], ['source', '源码']].forEach(([mode, label]) => {
      const b = document.createElement('button');
      b.textContent = label;
      b.className = tab.mode === mode ? 'on' : '';
      b.addEventListener('click', () => { tab.mode = mode; tab.scrolled = false; renderPaneBody(); });
      seg.appendChild(b);
    });
    tools.appendChild(seg);
  }

  if (!hasContent) {
    if (tab.diff) { renderCode(body, parseHunks(tab.diff).flatMap(h => h.lines.map(l => ({ type: l.t === '+' ? 'add' : l.t === '-' ? 'del' : 'ctx', text: l.s, no: null }))), path); }
    const note = document.createElement('div');
    note.className = 'ed-note';
    const hint = data.error && /二进制|无法/.test(data.error) ? '，可以点右上角「用默认应用打开」' : '';
    note.textContent = data.error ? `${data.error}${tab.diff ? '，下面是这一轮的改动' : hint}` : '无法预览这个文件，可以点右上角「用默认应用打开」';
    body.prepend(note);
    finishScroll(tab, body);
    return;
  }

  if (isMd && tab.mode === 'render') {
    const doc = document.createElement('div');
    doc.className = 'md md-doc';
    doc.innerHTML = renderMarkdown(data.content, { marks, remoteImages: true });
    if (typeof verifyFileChips === 'function') verifyFileChips(doc, dirOf(path));   // 文档里指向不存在文件的链接不做成标签
    body.appendChild(doc);
    loadLocalImages(doc, dirOf(path));
  } else {
    const rows = marks ? marks.rows : data.content.split('\n').map((text, i) => ({ type: 'ctx', text: text.replace(/\r$/, ''), no: i + 1 }));
    renderCode(body, rows, path);
  }
  if (marks && marks.unplaced.length) {
    // 纯删除或文件之后又被改过：定位不到的改动单独列在最上面
    const box = document.createElement('div');
    box.className = 'ed-unplaced';
    const note = document.createElement('div');
    note.className = 'ed-note';
    note.textContent = `以下 ${marks.unplaced.length} 处改动无法对应到当前文件里的位置（纯删除，或文件之后又被改过）：`;
    box.appendChild(note);
    renderCode(box, marks.unplaced.flatMap(h => h.lines.map(l => ({ type: l.t === '+' ? 'add' : l.t === '-' ? 'del' : 'ctx', text: l.s, no: null }))), path);
    body.prepend(box);
  }
  if (data.truncated) body.insertAdjacentHTML('beforeend', '<div class="ed-note">文件较大，只显示了前一部分</div>');
  finishScroll(tab, body);
}

function toolButton(icon, title, onClick) {
  const b = document.createElement('button');
  b.className = 'icon-btn ed-tool';
  b.title = title;
  b.innerHTML = icon;
  b.addEventListener('click', onClick);
  return b;
}

function renderCode(body, rows, path) {
  const MAX = 8000;
  const shown = rows.slice(0, MAX);
  // 新文件里的行（ctx / add）连续着色以保留跨行状态；删除的行单独着色
  const newSide = shown.filter(r => r.type !== 'del');
  const hlNew = highlightFileLines(newSide.map(r => r.text), path);
  let k = 0;
  const code = document.createElement('div');
  code.className = 'ed-code';
  let prevType = 'ctx';
  const parts = [];
  shown.forEach(r => {
    const html = r.type === 'del' ? highlightFileLines([r.text], path)[0] : hlNew[k++];
    const start = r.type !== 'ctx' && r.type !== prevType ? ' chg-start' : '';
    parts.push(`<div class="cl ${r.type}${start}"><span class="gn">${r.no || ''}</span><span class="gm">${r.type === 'add' ? '+' : r.type === 'del' ? '−' : ''}</span><span class="tx">${html || ' '}</span></div>`);
    prevType = r.type;
  });
  code.innerHTML = parts.join('');
  body.appendChild(code);
  if (rows.length > MAX) body.insertAdjacentHTML('beforeend', `<div class="ed-note">只显示了前 ${MAX} 行</div>`);
}

function renderImage(body, data) {
  const wrapEl = document.createElement('div');
  wrapEl.className = 'ed-image';
  const img = document.createElement('img');
  img.src = data.image;
  const info = document.createElement('div');
  info.className = 'ed-image-info';
  img.addEventListener('load', () => {
    info.textContent = `${img.naturalWidth} × ${img.naturalHeight}${data.size ? ` · ${(data.size / 1024).toFixed(data.size > 1024 * 1024 ? 0 : 1)} KB` : ''}`;
  });
  wrapEl.append(img, info);
  body.appendChild(wrapEl);
}

function loadLocalImages(root, base) {
  root.querySelectorAll('img[data-local]').forEach(img => {
    readLocalFile(img.dataset.local, base).then(data => {
      if (data.image) img.src = data.image;
      else {
        img.replaceWith(Object.assign(document.createElement('span'), { className: 'md-img-missing', textContent: `［图片：${img.alt || img.dataset.local}］` }));
        if (typeof retryPendingSearchHit === 'function') retryPendingSearchHit();
      }
    });
  });
}

function changeAnchors() {
  return [...pane.el.querySelectorAll('.ed-body .chg-start, .ed-body .md-chg, .ed-body .md-del')];
}

// 平滑跳转期间保留目标序号，用户接手滚动后再按可见位置定位。
for (const event of ['wheel', 'touchstart', 'pointerdown', 'keydown']) {
  pane.el.querySelector('.ed-body').addEventListener(event, e => {
    if (event === 'keydown' && !['ArrowUp','ArrowDown','PageUp','PageDown','Home','End',' '].includes(e.key)) return;
    const tab = activeTab();
    if (tab) tab.chgAt = null;
  }, {passive:true});
}

function jumpChange(dir) {
  const anchors = changeAnchors();
  if (!anchors.length) return;
  const body = pane.el.querySelector('.ed-body');
  const tab = activeTab();
  const at = tab && tab.chgAt;
  let target;
  // 按记下的那一处挪：停下的位置在锚点上方 60 像素，按滚动位置找会又找回当前这处；平滑滚动没走完时滚动位置也不准
  if (Number.isInteger(at) && at < anchors.length) target = anchors[(at + dir + anchors.length) % anchors.length];
  else {
    const top = body.scrollTop + 40;
    if (dir > 0) target = anchors.find(a => a.offsetTop > top + 4) || anchors[0];
    else target = [...anchors].reverse().find(a => a.offsetTop < top - 4) || anchors[anchors.length - 1];
  }
  if (tab) tab.chgAt = anchors.indexOf(target);
  body.scrollTo({ top: Math.max(0, target.offsetTop - 60), behavior: 'smooth' });
  target.classList.add('flash');
  setTimeout(() => target.classList.remove('flash'), 900);
}

/** 第一次打开有改动的文件时，滚到第一处改动；之后切回这个标签时回到切走前的位置。 */
function finishScroll(tab, body) {
  if (tab.scrolled) {
    // 各标签共用一个正文区，切标签会重建内容，滚动位置只能自己记着；用一次就丢，免得同一标签之后重画时被拉回旧位置
    if (tab.savedScroll != null) { body.scrollTop = tab.savedScroll; tab.savedScroll = null; }
    return;
  }
  tab.scrolled = true;
  tab.savedScroll = null;   // 要重新定位到改动处时（改动换了、切了预览 / 源码），切走前的位置作废
  const first = changeAnchors()[0];
  tab.chgAt = first ? 0 : null;
  body.scrollTop = first ? Math.max(0, first.offsetTop - 60) : 0;
}

/** 切到别的标签前记下当前标签读到哪里。 */
function rememberScroll() {
  const t = activeTab();
  if (t) t.savedScroll = pane.el.querySelector('.ed-body').scrollTop;
}

/** 回答里的文件标签：顺便找这一轮改动里有没有它的 diff。 */
function previewFromTurn(path, turnEl) {
  const files = (turnEl && turnEl._files) || [];
  const base = (turnEl && turnEl.dataset.cwd) || (S[active] && S[active].workspace) || '';
  const match = turnFileChange(files, path, base);
  openPreview({ path: match ? match.path : path, base, diff: match ? (match.diff || '') : '', change:match });
}
