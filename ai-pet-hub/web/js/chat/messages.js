'use strict';

// 聊天区：文字渲染成 Markdown、一条条消息、用户消息里的图片和看图（历史整页渲染和增量同步在 message-sync.js）。

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

function appendMessage(id, role, text, images, box = S[id].msgEl, before = null, scroll = true) {
  box.querySelector('.chat-empty')?.remove();
  const div = document.createElement('div');
  div.className = `msg ${role}${role === 'bot' ? ' md' : ''}`;
  if (role === 'bot') div.innerHTML = renderRich(text);
  else if (role === 'user') { fillUserMessage(div, text, images); addEditButton(div, id, text); }
  else div.textContent = text;
  box.insertBefore(div,before);
  if (scroll) scrollToBottom(box);
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

function requestMessageImages(el, text, base, snapshots = []) {
  if (!hasBridge() || (!snapshots.length && !IMG_PATH_HINT.test(text))) return;
  const reqId = nextRequestId();
  thumbReqs.delete(el._thumbReq); el._thumbReq = reqId;
  thumbReqs.set(reqId, { el, text });
  postNative('chatThumbs', { reqId, text, base, snapshots });
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

// 显示路径负责文件名和访达定位；有实际副本或记录引用时，查看、用默认应用打开和再发送都用同一个来源。
function sentImageSource(im, copy) {
  if (im.ref) return {ref:im.snapshot ? {...im.ref, snapshot:im.snapshot} : im.ref};
  const path = im.snapshot || copy || im.path;
  if (!path && im.missing) return {ref:{missing:true}};
  return {path};
}

function openImageViewer(im, snapshot) {
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
  const source = sentImageSource(im,snapshot);
  // 访达只能定位真实路径；重开会话时内嵌图只有记录引用，原生层会先落成副本再交给默认应用，所以外部打开按来源显示
  if (im.path) bar.append(viewerButton(UI.reveal, '在访达中显示', () => postNative('revealFile', { path: im.path })));
  if (source.path || (source.ref && !source.ref.missing)) bar.append(viewerButton(UI.external, '用默认应用打开', () => postNative('openFile', source)));
  el.append(img, bar);
  el.addEventListener('click', closeImageViewer);
  document.body.appendChild(el);
  imageViewer = { el, img, cap, reqId: nextRequestId() };
  if (typeof syncBrowser === 'function') syncBrowser();   // 内置浏览器是原生视图，会盖住查看器，先藏起来
  if (hasBridge() && (source.path || source.ref)) postNative('chatImage', {reqId:imageViewer.reqId, ...source});
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
  syncReturnedDraft(id);
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

/** 回答里写的路径对应这一轮改动里的哪个文件（标签核对、点开预览、搜索正文共用）。./x、../x 写明了从工作目录起，
 * 按本轮工作目录解析，完整路径相同才算：按结尾匹配的话，根目录的 ./README.md 会配上 pages/README.md 的改动、点开成子目录那份。
 * a/b 先按工作目录比完整路径，配不上再按结尾找：回答里常写相对某个子目录的路径（工作目录 ai-pets-workspace，
 * 写 tools/rig/README.md，改的是 ai-pet-hub/ 下那份），从工作目录找不到这个文件，只能靠结尾对上改动。
 * 只写文件名的（README.md）回答里很常见，也按结尾找；不知道工作目录时也照旧。 */
function turnFileChange(files, path, cwd) {
  const clean = cleanPath(path);
  const bare = clean.replace(/^\.\//, '');
  const byTail = () => files.find(f => f.path === bare || f.path.endsWith('/' + bare));
  if (cwd && clean.includes('/') && !/^(\/|~\/)/.test(clean)) {
    const full = p => p.split('/').reduce((out, s) => { if (s === '..') { if (out.length > 1) out.pop(); } else if (s && s !== '.') out.push(s); return out; }, ['']).join('/');
    const want = full(cwd + '/' + clean);
    const exact = files.find(f => full(f.path.startsWith('/') ? f.path : cwd + '/' + f.path) === want);
    return exact || (/^\.\.?\//.test(clean) ? undefined : byTail());
  }
  return byTail();
}

function fileReferencePlan(path, isChip, files, dirs, cwd = '') {
  const rooted = /^(file:|\/|~\/)/.test(path);
  const mine = dirs.slice();
  if (rooted) noteFileDirectory(dirs, dirOf(cleanPath(path)));
  const edited = isChip && !!turnFileChange(files, path, cwd);
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
    const base = turn?.dataset.cwd || fallbackBase;
    const plan = fileReferencePlan(path, el.classList.contains('file-chip'), turn?._files || [], dirs, base);
    if (el.dataset.checked) return;
    el.dataset.checked = '1';
    if (plan.edited) return;   // 改过的文件能带着 diff 打开
    const { paths } = plan;
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
        const turn = el.closest('.turn');
        const edited = !!turnFileChange(turn?._files || [], shown, turn?.dataset.cwd || '');
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
