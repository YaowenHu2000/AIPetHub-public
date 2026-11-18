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
  const edit = div.querySelector('.msg-edit');
  div.textContent = '';
  div.classList.toggle('has-images', imgs.length > 0);
  if (!imgs.length) { div.textContent = text; if (edit) div.appendChild(edit); return; }
  div.appendChild(renderMsgImages(imgs));
  if (!text.trim()) { if (edit) div.appendChild(edit); return; }
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
  if (edit) div.appendChild(edit);   // 缩略图回来后保留原编辑按钮及其原文回调
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

function requestMessageImages(el, text, base) {
  if (!hasBridge() || !IMG_PATH_HINT.test(text)) return;
  const reqId = nextRequestId();
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
  imageViewer = { el, img, cap, reqId: nextRequestId() };
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

// 文件标签只留给真实存在的文件（或这次回答改过的文件）；回答里举例用的文件名（不存在）变回普通代码 / 文字。
// 文字里直接写的文件名（.file-maybe，见 markdown.js）反过来：核对到真有这个文件才变成标签。
// 只写了文件名、没写在哪时，除了工作目录，还到同一条回答前面提到过的文件夹里找（「文件在 `/a/b/`：x.md、x.pdf」）。
const chipChecks = new Map();   // reqId → Map(key → { paths, dirs, els })

// 搜索正文也要得到核对后的可见文字，因此目录提示与改动文件规则在这里共用。
function noteFileDirectory(dirs, dir) {
  if (dir && dir !== '/' && dirs[0] !== dir) { dirs.unshift(dir); dirs.length = Math.min(dirs.length, 4); }
}

function noteCodeDirectory(dirs, text) {
  const t = text.trim();
  if (t.length < 300 && !/\n/.test(t) && (/^(~\/|\/[^/\s])/.test(t) || /^[^\s`]+\/$/.test(t)) && !looksLikeFile(t)) noteFileDirectory(dirs, t);
}

function fileReferencePlan(path, isChip, files, dirs) {
  const rooted = /^(file:|\/|~\/)/.test(path);
  const mine = dirs.slice();
  if (rooted) noteFileDirectory(dirs, dirOf(cleanPath(path)));
  const clean = cleanPath(path).replace(/^\.\//, '');
  const edited = isChip && files.some(f => f.path === clean || f.path.endsWith('/' + clean));
  const paths = [path];
  if (!isChip) {
    const tail = path.match(/[A-Za-z0-9_\-.\/~]+(:\d+(:\d+)?)?$/);
    if (tail && tail[0] !== path && looksLikeFile(tail[0])) paths.push(tail[0]);
  }
  return { paths, dirs: rooted ? [] : mine, edited };
}

function verifyFileChips(root, fallbackBase = '') {
  const byBase = new Map();
  const hints = new Map();   // 一条回答 → 前面提到过的文件夹（近的在前）
  root.querySelectorAll('code, .file-chip, .file-maybe').forEach(el => {
    const turn = el.closest('.turn');
    const scope = turn || root;
    if (!hints.has(scope)) hints.set(scope, []);
    const dirs = hints.get(scope);
    if (el.tagName === 'CODE') {
      if (!el.closest('pre')) noteCodeDirectory(dirs, el.textContent);
      return;
    }
    const path = el.dataset.path;
    const plan = fileReferencePlan(path, el.classList.contains('file-chip'), turn?._files || [], dirs);
    if (el.dataset.checked) return;
    el.dataset.checked = '1';
    if (plan.edited) return;   // 改过的文件能带着 diff 打开
    const { paths } = plan;
    const base = turn?.dataset.cwd || fallbackBase;
    if (!byBase.has(base)) byBase.set(base, new Map());
    const items = byBase.get(base);
    const key = [path, ...plan.dirs].join('\n');
    if (!items.has(key)) items.set(key, { paths, dirs: plan.dirs, els: [] });
    items.get(key).els.push(el);
  });
  if (!hasBridge()) return;
  byBase.forEach((items, base) => {
    const reqId = nextRequestId();
    chipChecks.set(reqId, items);
    postNative('checkFiles', { reqId, base, items: [...items].map(([key, it]) => ({ key, paths: it.paths, dirs: it.dirs })) });
  });
}

window.onFilesChecked = data => {
  const items = chipChecks.get(data.reqId);
  chipChecks.delete(data.reqId);
  if (!items) return;
  items.forEach((it, key) => {
    const hit = data.found && data.found[key];   // { path: 找到的完整路径, index: 是 paths 里的第几个 }
    it.els.forEach(el => {
      if (el.classList.contains('file-maybe')) {
        if (!hit) return;
        const shown = it.paths[hit.index] || it.paths[0];
        const holder = document.createElement('span');
        // 这一轮改过的文件：留着回答里的写法，点开时能对上它的改动
        const clean = cleanPath(shown).replace(/^\.\//, '');
        const edited = (el.closest('.turn')?._files || []).some(f => f.path === clean || f.path.endsWith('/' + clean));
        holder.innerHTML = fileChip(escapeHtml(edited ? shown : hit.path), escapeHtml(shown), 'text');
        const chip = holder.firstChild;
        chip.dataset.checked = '1';
        el.replaceWith(it.paths[0].slice(0, it.paths[0].length - shown.length), chip);
        return;
      }
      if (hit) { el.dataset.path = hit.path; return; }
      const path = it.paths[0];
      const fromCode = el.dataset.src !== 'link';
      const plain = document.createElement(fromCode ? 'code' : 'span');
      plain.textContent = fromCode ? path : (el.querySelector('span')?.textContent || path);
      el.replaceWith(plain);
    });
  });
  // 不存在的文件标签会在核对后还原完整路径；仅补做先前未找到正文的那次定位。
  if (typeof retryPendingSearchHit === 'function') retryPendingSearchHit();
};

/** 一条消息放到聊天区最后。ex：这次运行里记下的这一轮的改动（live.js），没有就是 undefined。 */
function renderOneMessage(id, m, ex, cwd) {
  if (m.role === 'compact') {
    const note = document.createElement('div');
    note.className = 'msg sys fork-note compact-note';
    note.dataset.historyCompact = '1';
    note.textContent = m.text;
    note._historySig = messageSignature(m);
    S[id].msgEl.appendChild(note);
    return note;
  }
  if (m.role === 'user') {
    const el = appendMessage(id, 'user', m.text || '', m.images);
    el._historySig = messageSignature(m);
    return el;
  }
  // CLI 的记录里没有「命令改的文件」（那是回答前后比 git 得来的）：用当时记下的补上
  const turn = renderTurn(ex && ex.files.length > (m.files || []).length ? { ...m, files: ex.files } : m, cwd);
  S[id].msgEl.appendChild(turn);
  if (ex) decorateTurn(turn, id, ex);
  turn._historySig = messageSignature(m);
  return turn;
}

/**
 * 切回窗口时的同步：页面上已有的消息和 CLI 的记录对得上（条数一样，或者记录只是在后面多了几条——在终端里接着聊过），
 * 就保留稳定的前缀：末轮变了局部更新，多出来的接在后面；展开状态和翻到的位置留着。对不上才返回 false。
 */
function syncAppend(id, messages, cwd, omitted, hasMore = false, afterSteer = false) {
  const box = S[id].msgEl;
  if ((S[id].shownOmitted || 0) !== omitted) return false;
  if (!!S[id].shownHasMore !== hasMore) return false;
  const shown = [...box.children].filter(n => n.matches('.msg.user:not(.queued), .msg.bot.turn, .compact-note[data-history-compact]'));
  // 角色的顺序得一样（中途补充过的回答，记录里是拆开的，对不上就重画）
  // 这里刚发的话、刚答完（或刚停下）的那一轮，CLI 的记录里可能还没有、或者永远不会有（停得早的回答它不记）。
  // 记录比页面少、少的又正好是末尾这些自己的节点时，按前面对得上的部分对账，末尾的留着不动——
  // 否则整页按记录重画，刚停下的回答和它的重试按钮就没了。
  const mine = n => n.classList.contains('user') ? n._historySig === undefined : !!n._answeredHere;
  let known = shown.length;
  while (known > messages.length && known > 0 && mine(shown[known - 1])) known--;
  const more = syncPlan(shown.slice(0, known).map(n => n.classList.contains('user')), messages);
  if (more < 0 || shown.slice(0, known).some((n, i) =>
    n.classList.contains('compact-note') !== (messages[i].role === 'compact'))) return false;
  const keep = nearBottom(box) ? null : box.scrollTop;   // 正在往上翻看：留在原处
  const extras = matchTurnExtras(id, messages);
  // 只有最后一轮还可能在写。前面的节点保留，末轮变了才替换，并保留展开状态。
  let tail = shown.length - 1;
  while (tail > 0 && !shown[tail].classList.contains('user')) tail--;
  shown.slice(tail).forEach((old, k) => {
    const i = tail + k, m = messages[i];
    if (!m) return;   // 记录里还没有的（上面说的自己的节点）
    const sig = messageSignature(m);
    if (old._historySig === sig) return;
    // 这里自己答出来的那一轮是实时画的（native-callbacks.js 里标了 _answeredHere）。CLI 的记录要晚几秒才写全，
    // 前后两次读到的也不一样，照着记录换节点会把刚答完的回答重画一两遍、把重试按钮弄丢。
    // 答完的一轮不会再被别处续写，所以对账时不动它；整个会话重新打开时自然按记录画。
    if (old._answeredHere && m.role !== 'user') {
      // 补充后的回读只核对刚完成的普通回答；停止节点上的重试仍属于这个页面。
      if (!afterSteer || m.role !== 'bot' || old.querySelector('.retry')) return;
    }
    const fresh = renderOneMessage(id, m, extras.get(i), cwd);
    if (old.querySelector('.work.open')) fresh.querySelector('.work')?.classList.add('open');
    const bodies = fresh.querySelectorAll('.step-body');
    old.querySelectorAll('.step-body').forEach((body, j) => { if (bodies[j]) bodies[j].hidden = body.hidden; });
    old.replaceWith(fresh);
  });
  messages.slice(shown.length).forEach((m, k) => renderOneMessage(id, m, extras.get(shown.length + k), cwd));
  verifyFileChips(box, cwd);
  if (keep !== null) box.scrollTop = keep; else scrollToBottom(box);
  return true;
}

function renderMessages(id, messages, cwd = '', omitted = 0, hasMore = false) {
  const box = S[id].msgEl;
  // 这个会话正在回答：CLI 的记录里可能已经有这次的提问和部分过程，截到这次提问之前，再接上正在进行的回答
  const running = runsOf(id, viewKey(id));
  if (running.length) {
    const cut = liveHistoryCut(running[0], messages, omitted);
    if (cut >= 0) messages = messages.slice(0, cut);
  }
  box.innerHTML = '';
  if (omitted > 0 || hasMore) {   // 服务尚有未取回的旧页时，不能把已知条数当作整个会话的开头。
    const note = document.createElement('button');
    note.className = 'msg sys load-earlier';
    note.textContent = hasMore ? '还有更早的消息 · 点这里继续显示'
      : `还有较早的 ${omitted} 条消息没显示 · 点这里再显示 ${Math.min(300, omitted)} 条`;
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
  S[id].shownHasMore = hasMore;
  running.forEach(r => r.nodes.forEach(n => box.appendChild(n)));
  if (!box.children.length) showEmpty(id);
  verifyFileChips(box, cwd);
  scrollToBottom(box);
}
