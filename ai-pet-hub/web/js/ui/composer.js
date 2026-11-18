'use strict';

// 输入框周边：预热、图片附件、/ 命令和 @ 文件、↑ ↓ 翻发过的话、消息上的「编辑」、内置浏览器工具的开关、搜索后定位。
// 接在 changes.js 后面加载。纯逻辑在 logic.js。

// 每位的输入在触发时就定下值；程序回填立即落盘，键入才短暂防抖。
const draftTimers = new Map();
function setDraft(id, value, delay = 0) {
  clearTimeout(draftTimers.get(id));
  draftTimers.delete(id);
  S[id].draft = value;
  if (id === active && els.input.value !== value) els.input.value = value;
  const save = () => {
    draftTimers.delete(id);
    // 异常/队列回填可能已经更新了草稿，旧键入不得覆盖它。
    if (S[id].draft === value) lsSet(`${id}_draft`, value);
  };
  if (delay) draftTimers.set(id, setTimeout(save, delay));
  else save();
  closeSuggest();
}

// ===== 预热：开始打字、或者上一轮刚答完，就让原生按现在的设置把 CLI 先起好（LiveTurn.swift / Prewarm.swift），发送时少等两三秒 =====
let warmSig = '', warmAt = 0;
function prewarm(id, typing = false) {
  if (!hasBridge() || viewBusy(id)) return;
  const st = S[id];
  const req = { agent: id, model: st.model, effort: st.effort, permissionMode: st.perm, workspace: st.workspace, conversationId: st.conversationId, typing: typing && !!st.conversationId && ['gpt', 'gemini'].includes(id), browserTools: browserToolsOn(), fast: fastOn(id) };
  const sig = JSON.stringify(req);
  if (!req.typing && sig === warmSig && Date.now() - warmAt < 60000) return;   // 刚为同样的设置预热过
  warmSig = sig;
  warmAt = Date.now();
  postNative('prewarmAgent', req);
}
/** 发出了一句：原生会取走预热好的进程（Prewarm.swift 的 takeWarm），去重记号作废，答完后的下一次预热要照常发。 */
function noteSent() { warmSig = ''; }

// ===== 用户消息上的「编辑」：把这句话放回输入框，改了再发 =====
function addEditButton(div, id, text) {
  if (!text) return;
  const b = document.createElement('button');
  b.className = 'msg-edit';
  b.title = '把这句话放回输入框，改了再发（接在现在的对话后面，不会回到当时）';
  b.innerHTML = UI.pencil;
  b.addEventListener('click', e => {
    e.stopPropagation();
    if (id !== active) setActive(id);
    setDraft(id, text);
    els.input.focus();
    els.input.selectionStart = els.input.selectionEnd = text.length;
    autosize();
    updateSendUI();
  });
  div.appendChild(b);
}

// ===== 输入框里的 / 命令和 @ 文件 =====
// / ：整句以 / 开头、还没打空格时，列出这位 CLI 认得的命令（CLI 自己报上来的，记在本地；第一次用之前是空的）。选了填进去，发出去由 CLI 处理。
// @ ：光标前是「@几个字」时，在工作空间里按名字找文件，选了换成它的路径。
const agentCommands = {};
ALL_AGENT_IDS.forEach(id => { agentCommands[id] = lsJson(`${id}_commands`, []); });
// Codex 不报命令列表：只有压缩上下文这一个是我们替它接的（原生：CodexLive.swift）
agentCommands.gpt = [{ name: 'compact', desc: '把前面的对话压缩成摘要，腾出上下文空间' }];

window.onAgentCommands = data => {
  if (!AGENTS[data.agent] || !Array.isArray(data.commands)) return;
  agentCommands[data.agent] = mergeCommands(agentCommands[data.agent] || [], data.commands);   // 这次没带说明的沿用以前的
  lsSet(`${data.agent}_commands`, JSON.stringify(agentCommands[data.agent].slice(0, 200)));
  // 正在输入框里打 / 等着：列表到了就刷新（Gemini 的列表要等它接上会话才报，常常是打了 / 之后才到）
  if (data.agent === active && slashQuery(els.input.value) !== null) updateSuggest();
};

const suggest = { el: null, items: [], index: 0, kind: '', start: 0, seq: 0, timer: 0 };

function suggestBox() {
  if (!suggest.el) {
    suggest.el = document.createElement('div');
    suggest.el.className = 'suggest-box';
    suggest.el.hidden = true;
    document.querySelector('.composer-box').appendChild(suggest.el);
  }
  return suggest.el;
}

function closeSuggest() {
  suggest.items = [];
  suggest.seq++;
  clearTimeout(suggest.timer);
  suggest.pending = null;
  if (suggest.el) suggest.el.hidden = true;
}

function showSuggest(kind, items, start) {
  suggest.kind = kind;
  suggest.items = items;
  suggest.start = start;
  suggest.index = 0;
  const box = suggestBox();
  if (!items.length) { box.hidden = true; return; }
  box.hidden = false;
  box.innerHTML = '';
  items.forEach((it, i) => {
    const row = document.createElement('div');
    row.className = 'suggest-row' + (i === 0 ? ' on' : '');
    row.innerHTML = '<span class="suggest-name"></span><span class="suggest-desc"></span>';
    row.querySelector('.suggest-name').textContent = kind === 'slash' ? '/' + it.name : baseName(it.name);
    row.querySelector('.suggest-desc').textContent = kind === 'slash' ? it.desc : it.name.replace(/\/?[^/]*$/, '');
    row.addEventListener('mousedown', e => { e.preventDefault(); suggest.index = i; acceptSuggest(); });
    box.appendChild(row);
  });
}

/** 建议框里只放一行说明（不能选）。 */
function showSuggestNote(text) {
  suggest.kind = 'note';
  suggest.items = [];
  const box = suggestBox();
  box.hidden = false;
  box.innerHTML = '';
  const row = document.createElement('div');
  row.className = 'suggest-row suggest-note';
  row.textContent = text;
  box.appendChild(row);
}

function moveSuggest(dir) {
  const n = suggest.items.length;
  suggest.index = (suggest.index + dir + n) % n;
  [...suggest.el.children].forEach((r, i) => r.classList.toggle('on', i === suggest.index));
  suggest.el.children[suggest.index].scrollIntoView({ block: 'nearest' });
}

function acceptSuggest() {
  const it = suggest.items[suggest.index];
  if (!it) return;
  const input = els.input;
  if (suggest.kind === 'slash') {
    setDraft(active, '/' + it.name + ' ');
    input.selectionStart = input.selectionEnd = input.value.length;
  } else {
    const caret = input.selectionStart;
    const before = input.value.slice(0, suggest.start);
    const insert = (/\s/.test(it.name) ? `"${it.name}"` : it.name) + ' ';
    setDraft(active, before + insert + input.value.slice(caret));
    input.selectionStart = input.selectionEnd = before.length + insert.length;
  }
  closeSuggest();
  autosize();
  updateSendUI();
}

/** 输入框的按键先过这里：正在选的时候 ↑ ↓ Enter Tab Esc 归它管。返回 true = 已经处理。 */
function suggestKey(e) {
  if (!suggest.items.length || !suggest.el || suggest.el.hidden) return false;
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); moveSuggest(e.key === 'ArrowDown' ? 1 : -1); return true; }
  if ((e.key === 'Enter' || e.key === 'Tab') && !e.shiftKey && !e.ctrlKey && !e.altKey && !e.metaKey) { e.preventDefault(); acceptSuggest(); return true; }
  if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeSuggest(); return true; }
  return false;
}

function updateSuggest() {
  closeSuggest();
  const input = els.input;
  const id = active;
  const value = input.value;
  const slash = slashQuery(value);
  if (slash !== null) {
    const list = agentCommands[id] || [];
    // 还从没拿到过命令列表（Gemini 要接上一个会话才报）：说一声，而不是什么都不出
    if (!list.length && id === 'gemini') { showSuggestNote('先给 Gemini 发一句话，接上会话后这里会显示可用命令'); return; }
    showSuggest('slash', rankCommands(list, slash), 0);
    return;
  }
  const at = mentionQuery(value.slice(0, input.selectionStart));
  if (at && S[id].workspace && hasBridge()) {
    const start = at.start;
    const seq = suggest.seq;
    // reqId 用全页面共用的编号（每次页面加载从不重复的起点开始），重载前发出的旧回应对不上
    const pending = { seq, reqId: nextRequestId(), start, id, workspace: S[id].workspace, value, caret: input.selectionStart };
    suggest.pending = pending;
    suggest.timer = setTimeout(() => {
      if (!currentSuggest(pending)) return;
      postNative('listFiles', { workspace: pending.workspace, query: at.q, reqId: pending.reqId });
    }, 100);
    return;
  }
  closeSuggest();
}

function currentSuggest(pending) {
  return pending && pending.seq === suggest.seq && pending.id === active
    && pending.workspace === S[active].workspace && pending.value === els.input.value
    && pending.caret === els.input.selectionStart;
}

window.onFilesListed = data => {
  if (!currentSuggest(suggest.pending) || data.reqId !== suggest.pending.reqId) return;
  showSuggest('file', (data.files || []).map(f => ({ name: f })), suggest.pending.start);
};

els.input.addEventListener('input', () => {
  setDraft(active, els.input.value, 300);
  updateSuggest();
  if (els.input.value.trim()) prewarm(active, true);   // 开始打字了：先把 CLI 起好
});
els.input.addEventListener('blur', () => setTimeout(closeSuggest, 150));

// ===== 内置浏览器工具的开关（权限菜单里；三位共用） =====
const browserToolsOn = () => lsGet('browser_tools', 'on') !== 'off';

// ===== 附件：粘贴的截图、拖进来 / 粘贴 / 📎 选的文件附在输入框上面。图片发送时作为真正的图片交给模型，其他文件把路径附在话后面 =====
const ATTACH_IMAGE_RE = /\.(png|jpe?g|gif|webp|heic|heif|bmp|tiff?)$/i;
let lastPastedThumb = '';

function attachRow() {
  let row = document.querySelector('.attach-row');
  if (!row) {
    row = document.createElement('div');
    row.className = 'attach-row';
    const box = document.querySelector('.composer-box');
    box.insertBefore(row, box.firstChild);
  }
  return row;
}

function renderAttachments() {
  const list = S[active].attach || [];
  const row = attachRow();
  row.innerHTML = '';
  row.hidden = !list.length;
  list.forEach((a, i) => {
    const chip = document.createElement('div');
    chip.className = 'attach-chip';
    chip.title = a.path;
    chip.innerHTML = (a.thumb ? '<img class="attach-thumb" alt="">' : `<span class="attach-icon">${UI.file}</span>`)
      + '<span class="attach-name"></span><button class="attach-x" title="不发这个"></button>';
    if (a.thumb) chip.querySelector('img').src = a.thumb;
    chip.querySelector('.attach-name').textContent = baseName(a.path);
    chip.querySelector('.attach-x').innerHTML = UI.close;
    chip.querySelector('.attach-x').addEventListener('click', () => { list.splice(i, 1); saveAttachments(active); renderAttachments(); updateSendUI(); });
    row.appendChild(chip);
  });
}

// 附件路径跟草稿一样存在本地：不发送就重开 App，话和附件都还在。
// 粘贴截图的缩略图是整张图的 data URL，太大不存，重开后那张显示成文件图标。
function saveAttachments(id) {
  const paths = (S[id].attach || []).map(a => a.path);
  lsSet(`${id}_attach`, paths.length ? JSON.stringify(paths) : '');
}
function loadAttachments(id) {
  const paths = lsJson(`${id}_attach`, []);
  S[id].attach = Array.isArray(paths) ? paths.filter(p => typeof p === 'string' && p).slice(0, 8).map(path => ({ path, thumb: '' })) : [];
}
ALL_AGENT_IDS.forEach(loadAttachments);

function addAttachments(id, paths, pasted) {
  const st = S[id];
  st.attach = st.attach || [];
  paths.forEach(p => { if (!st.attach.some(a => a.path === p)) st.attach.push({ path: p, thumb: pasted ? lastPastedThumb : '' }); });
  lastPastedThumb = '';
  st.attach = st.attach.slice(0, 8);
  saveAttachments(id);
  if (id === active) { renderAttachments(); els.input.focus(); }
  // 最多 8 个：只对真正在附件栏里的报「附上了」，被上限挤掉的明说，免得以为都会发出去
  const uniq = [...new Set(paths)], kept = uniq.filter(p => st.attach.some(a => a.path === p)), missed = uniq.length - kept.length;
  const pics = kept.filter(p => ATTACH_IMAGE_RE.test(p)).length, files = kept.length - pics;
  const ok = !kept.length ? '' : pasted && !files ? '截图附上了，发送时一起给它' : `附上了 ${[pics && pics + ' 张图片', files && files + ' 个文件'].filter(Boolean).join('、')}`;
  const over = missed ? `有 ${missed} 个没附上（最多 8 个）` : '';
  pets[id].say([ok, over].filter(Boolean).join('，') + (ok ? ' 📎' : ''), missed ? 3000 : 2000);
}

/** 发送前把附件分开：图片作为真正的图片交给模型；其他文件把完整路径附在话后面（每个一行），CLI 按路径自己读。 */
function attachmentsForSend(text, paths) {
  const images = paths.filter(p => ATTACH_IMAGE_RE.test(p)), files = paths.filter(p => !ATTACH_IMAGE_RE.test(p));
  if (!files.length) return { text, images };
  const block = '附件：\n' + files.join('\n');
  return { text: text ? text + '\n\n' + block : block, images };
}

/** 发送时取走附着的图片和文件（路径）。 */
function takeAttachments(id) {
  const list = (S[id].attach || []).map(a => a.path);
  S[id].attach = [];
  saveAttachments(id);
  if (id === active) renderAttachments();
  return list;
}

// ===== 搜索正文后点进会话：跳到命中的那一条，闪一下 =====
function jumpToSearchHit(id) {
  const st = S[id];
  const q = histQuery;
  if (!q || q.length < 2 || !st.bodyHits?.has(st.conversationId) || st.bodyQuery !== q) { st.pendingSearchHit = null; return; }
  const box = st.msgEl;
  // 原生大小写规则包含 ß / sigma 等等价字；用它返回的实际原文定位，避免 JavaScript lowerCase 漏掉。
  const actual = st.bodyItems?.find(it => it.id === st.conversationId)?.searchMatch;
  const needles = [q, actual].filter(Boolean).map(text => text.toLowerCase());
  const matches = text => needles.some(needle => text.toLowerCase().includes(needle));
  function userText(node) {
    const text = node.querySelector('.msg-text')?.textContent
      ?? [...node.childNodes].filter(n => n.nodeType === 3).map(n => n.textContent).join('');
    return [...node.querySelectorAll('.msg-img-missing')].map(n => n.textContent).concat(text).join('\n');
  }
  function visibleText(node) {
    const copy = node.cloneNode(true);
    copy.querySelectorAll('.katex-mathml, button').forEach(n => n.remove());
    // 透明颜色会继承，但子节点可以显式换回可见颜色；零高度的 smash 仍然显示。
    const walker = document.createTreeWalker(copy, NodeFilter.SHOW_TEXT);
    let text = '', part;
    while ((part = walker.nextNode())) {
      let color = '', el = part.parentElement;
      while (el && !color) { color = el.style.color; el = el.parentElement; }
      if (color !== 'transparent') text += part.textContent;
    }
    return text;
  }
  function bodyText(node) {
    if (node.matches('.msg.user')) return userText(node);
    return [...node.querySelectorAll('.step-user-tag, .step-user-text, .step-text, .step-title, .step-cmdline, .step-body pre, .answer')]
      .map(n => n.classList.contains('step-user-text') ? userText(n) : visibleText(n)).join('\n');
  }
  const hit = [...box.children].find(n => n.matches('.msg.user, .msg.bot') && matches(bodyText(n)));
  if (!hit) { st.pendingSearchHit = { query: q, cid: st.conversationId }; return; }
  st.pendingSearchHit = null;
  // 搜索也包含已折叠步骤的文字，定位后展开，避免点进来还看不到命中。
  hit.querySelector('.work')?.classList.add('open');
  hit.querySelectorAll('.step-body').forEach(body => { if (matches(visibleText(body))) body.hidden = false; });
  hit.scrollIntoView({ block: 'center' });
  hit.classList.add('search-hit');
  setTimeout(() => hit.classList.remove('search-hit'), 2600);
}

function retryPendingSearchHit() {
  AGENT_IDS.forEach(id => {
    const st = S[id], pending = st.pendingSearchHit;
    if (!pending) return;
    if (pending.query !== histQuery || pending.cid !== st.conversationId) { st.pendingSearchHit = null; return; }
    jumpToSearchHit(id);
  });
}

// ===== 空输入框按 ↑ / ↓ 翻发过的话 =====
/** 发过的话记下来（每位最近 50 句，重开 App 还在）：空输入框按 ↑ 往前翻，↓ 往后翻。 */
function rememberPrompt(id, text) {
  const st = S[id];
  st.prompts = pushPrompt(st.prompts || lsJson(`${id}_prompts`, []), text);
  st.promptAt = -1;
  lsSet(`${id}_prompts`, JSON.stringify(st.prompts));
}

/** dir：-1 往前（更早），1 往后。返回是否处理了这次按键。 */
function browsePrompts(id, dir) {
  const st = S[id];
  const list = st.prompts || (st.prompts = lsJson(`${id}_prompts`, []));
  const next = promptStep(list, st.promptAt ?? -1, els.input.value, dir);
  if (!next) return false;   // 自己打了字就不翻了
  st.promptAt = next.at;
  setDraft(id, next.value);
  els.input.selectionStart = els.input.selectionEnd = next.value.length;
  autosize();
  return true;
}

// 切到另一位时，附件栏跟着换成那一位的
const baseRenderComposer = renderComposer;
renderComposer = function () { closeSuggest(); baseRenderComposer(); renderAttachments(); };

// 📎：系统的选文件窗口，可以多选（Bridge.swift 的 pickAttachments），选好的走 onFilesDropped
const attachBtn = document.getElementById('attach-btn');
attachBtn.innerHTML = UI.clip;
attachBtn.addEventListener('click', () => postNative('pickAttachments'));
