'use strict';

// 聊天区：文字渲染成 Markdown、一条条消息、用户消息里的图片和看图。

// ===== 文本渲染（回答里常见的 Markdown：代码块、行内代码、粗体、标题、列表） =====
function escapeHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
const FILE_EXTS = new Set(('md txt json jsonl js mjs cjs ts tsx jsx swift py ipynb html htm css scss less sh zsh bash yml yaml toml '
  + 'xml plist csv tsv pdf png jpg jpeg gif svg webp docx doc docm xlsx xls xlsm pptx ppt pptm ppsx rtf odt '
  + 'tex bib rs go java kt c h cc cpp hpp m mm rb php '
  + 'sql log conf ini env lock vue svelte dart lua r jl zip mp4 mov wav mp3 icns').split(' '));

/** 看起来像文件路径（有常见扩展名，可带 :行号）。 */
function looksLikeFile(text) {
  const t = text.replace(/^file:\/\//, '').replace(/:\d+(:\d+)?$/, '');
  if (!t || t.length > 300 || /\s{2,}|[<>|*?"]/.test(t) || /^https?:/i.test(t)) return false;
  const m = t.match(/\.([A-Za-z0-9]{1,6})$/);
  return !!m && FILE_EXTS.has(m[1].toLowerCase()) && !/^\.[A-Za-z0-9]+$/.test(t);
}

/** 文件标签。src：code = 来自行内代码，link = 来自 Markdown 链接（核对不存在时分别变回代码 / 文字）。 */
function fileChip(target, label, src = 'code') {
  const name = label || baseName(target.replace(/^file:\/\//, '').replace(/:\d+(:\d+)?$/, ''));
  return `<span class="file-chip" data-src="${src}" data-path="${target}">${UI.file}<span>${name}</span></span>`;
}

/** 回答正文：完整的 Markdown（表格、公式、列表、代码块等，见 markdown.js），行内代码里的文件路径变成文件标签。 */
function renderRich(text) {
  return renderMarkdown(text, { chips: true });
}

// ===== 聊天区 =====
function scrollToBottom(el) { el.scrollTop = el.scrollHeight; }

function appendMessage(id, role, text, images) {
  const box = S[id].msgEl;
  box.querySelector('.chat-empty')?.remove();
  const div = document.createElement('div');
  div.className = `msg ${role}${role === 'bot' ? ' md' : ''}`;
  if (role === 'bot') div.innerHTML = renderRich(text);
  else if (role === 'user') { fillUserMessage(div, text, images); addEditButton(div, id, text); }
  else div.textContent = text;
  box.appendChild(div);
  scrollToBottom(box);
  return div;
}

// ===== 用户消息里的图片：附上的图片、文字里写到的图片路径（缩略图由原生生成），点开看原图 =====
const IMG_PATH_HINT = /\.(png|jpe?g|gif|webp|heic|heif|bmp|tiff?)\b/i;

function imageName(im) { return im.name || (im.path ? baseName(im.path) : ''); }

/** 用户消息：图片在上，文字气泡在下；粘贴截图那种临时路径（match）在文字里换成短标签。 */
function fillUserMessage(div, text, images) {
  const imgs = (Array.isArray(images) ? images : []).filter(im => im && (im.src || im.missing));
  div.textContent = '';
  div.classList.toggle('has-images', imgs.length > 0);
  if (!imgs.length) { div.textContent = text; return; }
  div.appendChild(renderMsgImages(imgs));
  if (!text.trim()) return;
  const body = document.createElement('div');
  body.className = 'msg-text';
  const refs = imgs.filter(im => im.match && text.includes(im.match));
  if (!refs.length) body.textContent = text;
  else {
    const re = new RegExp(refs.map(im => im.match.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'), 'g');
    let last = 0;
    for (const m of text.matchAll(re)) {
      const im = refs.find(r => r.match === m[0]);
      const tag = document.createElement('span');
      tag.className = 'msg-imgref';
      tag.textContent = imageName(im) || m[0];
      tag.title = im.path || '';
      tag._image = im;
      body.append(text.slice(last, m.index), tag);
      last = m.index + m[0].length;
    }
    body.append(text.slice(last));
  }
  div.appendChild(body);
}

function renderMsgImages(imgs) {
  const row = document.createElement('div');
  row.className = 'msg-images';
  const maxW = imgs.length > 1 ? 200 : 320;
  const maxH = imgs.length > 1 ? 150 : 240;
  imgs.forEach(im => {
    if (im.missing) {
      const miss = document.createElement('div');
      miss.className = 'msg-img-missing';
      miss.textContent = `图片已不在：${imageName(im) || '原文件已删除'}`;
      miss.title = im.path || '';
      row.appendChild(miss);
      return;
    }
    const img = document.createElement('img');
    img.className = 'msg-img';
    img.src = im.src;
    img.alt = imageName(im) || '图片';
    img.draggable = false;
    if (im.w && im.h) {   // 先按比例占好位置：图片解码前后高度不变，滚到底不会被撑开
      const s = Math.min(1, maxW / im.w, maxH / im.h);
      img.style.width = `${Math.max(32, Math.round(im.w * s))}px`;
      img.style.aspectRatio = `${im.w} / ${im.h}`;
    }
    img._image = im;
    row.appendChild(img);
  });
  return row;
}

// 刚发出的消息：文字里写到的图片也配上缩略图（历史记录里的，原生载入时已经配好）
const thumbReqs = new Map();
let thumbSeq = 0;

function requestMessageImages(el, text, base) {
  if (!hasBridge() || !IMG_PATH_HINT.test(text)) return;
  const reqId = ++thumbSeq;
  thumbReqs.set(reqId, { el, text });
  postNative('chatThumbs', { reqId, text, base });
}

window.onChatThumbs = data => {
  const req = thumbReqs.get(data.reqId);
  thumbReqs.delete(data.reqId);
  if (!req || !Array.isArray(data.images) || !data.images.length) return;
  const box = req.el.parentElement;   // 切去别的会话时这条消息不在页面上，换好了等切回来再显示
  const stick = box && nearBottom(box);
  fillUserMessage(req.el, req.text, data.images);
  if (stick) scrollToBottom(box);
};

// 图片查看器：先放缩略图，原图读到了再换上
let imageViewer = null;
let viewerSeq = 0;

function viewerButton(icon, title, onClick) {
  const b = document.createElement('button');
  b.className = 'img-viewer-btn';
  b.innerHTML = `${icon}<span>${title}</span>`;
  b.addEventListener('click', e => { e.stopPropagation(); onClick(); });
  return b;
}

function openImageViewer(im) {
  closeImageViewer();
  const el = document.createElement('div');
  el.className = 'img-viewer';
  const img = document.createElement('img');
  img.src = im.src;
  img.alt = imageName(im) || '图片';
  img.draggable = false;
  const bar = document.createElement('div');
  bar.className = 'img-viewer-bar';
  const cap = document.createElement('span');
  cap.className = 'img-viewer-cap';
  cap.textContent = im.path ? prettyPath(im.path) : imageName(im);
  bar.appendChild(cap);
  if (im.path) {
    bar.append(viewerButton(UI.reveal, '在访达中显示', () => postNative('revealFile', { path: im.path })),
               viewerButton(UI.external, '用默认应用打开', () => postNative('openFile', { path: im.path })));
  }
  el.append(img, bar);
  el.addEventListener('click', closeImageViewer);
  document.body.appendChild(el);
  imageViewer = { el, img, cap, reqId: ++viewerSeq };
  if (typeof syncBrowser === 'function') syncBrowser();   // 内置浏览器是原生视图，会盖住查看器，先藏起来
  if (hasBridge() && (im.path || im.ref)) postNative('chatImage', { reqId: imageViewer.reqId, path: im.path || '', ref: im.ref || null });
}

window.onChatImage = data => {
  if (!imageViewer || data.reqId !== imageViewer.reqId) return;
  if (data.image) imageViewer.img.src = data.image;
  else if (data.error) imageViewer.cap.textContent = data.error;
};

function closeImageViewer() {
  if (!imageViewer) return;
  imageViewer.el.remove();
  imageViewer = null;
  if (typeof syncBrowser === 'function') syncBrowser();
}

function showEmpty(id, text) {
  const box = S[id].msgEl;
  box.innerHTML = '';
  const empty = document.createElement('div');
  empty.className = 'chat-empty';
  empty.innerHTML = `<div class="empty-icon">${ICONS[id]}</div>`;
  const line = document.createElement('div');
  line.textContent = text || `和 ${AGENTS[id].name} 开始新对话`;
  empty.appendChild(line);
  box.appendChild(empty);
}

// 文件标签只留给真实存在的文件（或这次回答改过的文件）；回答里举例用的文件名（不存在）变回普通代码 / 文字
let chipCheckSeq = 0;
const chipChecks = new Map();   // reqId → Map(路径 → [标签])

function verifyFileChips(root, fallbackBase = '') {
  const byBase = new Map();
  root.querySelectorAll('.file-chip:not([data-checked])').forEach(chip => {
    chip.dataset.checked = '1';
    const turn = chip.closest('.turn');
    const clean = cleanPath(chip.dataset.path).replace(/^\.\//, '');
    if ((turn?._files || []).some(f => f.path === clean || f.path.endsWith('/' + clean))) return;   // 改过的文件能带着 diff 打开
    const base = turn?.dataset.cwd || fallbackBase;
    if (!byBase.has(base)) byBase.set(base, new Map());
    const paths = byBase.get(base);
    if (!paths.has(chip.dataset.path)) paths.set(chip.dataset.path, []);
    paths.get(chip.dataset.path).push(chip);
  });
  if (!hasBridge()) return;
  byBase.forEach((paths, base) => {
    const reqId = ++chipCheckSeq;
    chipChecks.set(reqId, paths);
    postNative('checkFiles', { reqId, base, paths: [...paths.keys()] });
  });
}

window.onFilesChecked = data => {
  const paths = chipChecks.get(data.reqId);
  chipChecks.delete(data.reqId);
  if (!paths) return;
  paths.forEach((chips, path) => {
    if (data.exists && data.exists[path]) return;
    chips.forEach(chip => {
      const fromCode = chip.dataset.src !== 'link';
      const plain = document.createElement(fromCode ? 'code' : 'span');
      plain.textContent = fromCode ? path : (chip.querySelector('span')?.textContent || path);
      chip.replaceWith(plain);
    });
  });
};

/** 一条消息放到聊天区最后。ex：这次运行里记下的这一轮的改动（live.js），没有就是 undefined。 */
function renderOneMessage(id, m, ex, cwd) {
  if (m.role === 'user') return appendMessage(id, 'user', m.text || '', m.images);
  // CLI 的记录里没有「命令改的文件」（那是回答前后比 git 得来的）：用当时记下的补上
  const turn = renderTurn(ex && ex.files.length > (m.files || []).length ? { ...m, files: ex.files } : m, cwd);
  S[id].msgEl.appendChild(turn);
  if (ex) decorateTurn(turn, id, ex);
  return turn;
}

/**
 * 切回窗口时的同步：页面上已有的消息和 CLI 的记录对得上（条数一样，或者记录只是在后面多了几条——在终端里接着聊过），
 * 就不重画：展开着的工作过程、翻到的位置都留着，只把多出来的接在后面。对不上才返回 false，让调用方整段重画。
 */
function syncAppend(id, messages, cwd, omitted) {
  const box = S[id].msgEl;
  if ((S[id].shownOmitted || 0) !== omitted) return false;
  const shown = [...box.children].filter(n => n.matches('.msg.user:not(.queued), .msg.bot.turn'));
  // 角色的顺序得一样（中途补充过的回答，记录里是拆开的，对不上就重画）
  const more = syncPlan(shown.map(n => n.classList.contains('user')), messages);
  if (more < 0) return false;
  if (more === 0) return true;
  const keep = nearBottom(box) ? null : box.scrollTop;   // 正在往上翻看：留在原处
  const extras = matchTurnExtras(id, messages);
  messages.slice(shown.length).forEach((m, k) => renderOneMessage(id, m, extras.get(shown.length + k), cwd));
  verifyFileChips(box, cwd);
  if (keep !== null) box.scrollTop = keep; else scrollToBottom(box);
  return true;
}

function renderMessages(id, messages, cwd = '', omitted = 0) {
  const box = S[id].msgEl;
  // 这个会话正在回答：CLI 的记录里可能已经有这次的提问和部分过程，截到这次提问之前，再接上正在进行的回答
  const running = runsOf(id, viewKey(id));
  if (running.length) {
    const cut = messages.map((m, i) => (m.role === 'user' && (m.text || '').trim() === running[0].text ? i : -1)).filter(i => i >= 0).pop();
    if (cut !== undefined) messages = messages.slice(0, cut);
  }
  box.innerHTML = '';
  if (omitted > 0) {   // 太长的会话默认只显示最近 300 条；点一下再多显示 300 条
    const note = document.createElement('button');
    note.className = 'msg sys load-earlier';
    note.textContent = `还有较早的 ${omitted} 条消息没显示 · 点这里再显示 ${Math.min(300, omitted)} 条`;
    note.addEventListener('click', () => {
      const st = S[id];
      st.histLimit = (st.shownLimit || 300) + 300;
      st.keepFromBottom = box.scrollHeight - box.scrollTop;   // 载入后停在原来看的那条上
      st.loadedSig = '';
      note.textContent = '正在读取更早的消息…';
      postNative('loadConversation', { agent: id, conversationId: st.conversationId, limit: st.histLimit });
    });
    box.appendChild(note);
  }
  const extras = matchTurnExtras(id, messages);   // 这次运行里答的那几轮：把改动卡片接回去（live.js）
  messages.forEach((m, i) => renderOneMessage(id, m, extras.get(i), cwd));
  S[id].shownOmitted = omitted;
  running.forEach(r => r.nodes.forEach(n => box.appendChild(n)));
  if (!box.children.length) showEmpty(id);
  verifyFileChips(box, cwd);
  scrollToBottom(box);
}
