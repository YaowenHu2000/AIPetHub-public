'use strict';

// 输入框周边：预热、图片附件、/ 命令和 @ 文件、↑ ↓ 翻发过的话、消息上的「编辑」、内置浏览器工具的开关、搜索后定位。
// 接在 changes.js 后面加载。纯逻辑在 logic.js。

// ===== 预热：开始打字、或者上一轮刚答完，就让原生按现在的设置把 CLI 先起好（LiveTurn.swift / Prewarm.swift），发送时少等两三秒 =====
let warmSig = '', warmAt = 0;
function prewarm(id) {
  if (!hasBridge() || viewBusy(id)) return;
  const st = S[id];
  const req = { agent: id, model: st.model, effort: st.effort, permissionMode: st.perm, workspace: st.workspace, conversationId: st.conversationId, browserTools: browserToolsOn(), fast: fastOn(id) };
  const sig = JSON.stringify(req);
  if (sig === warmSig && Date.now() - warmAt < 60000) return;   // 刚为同样的设置预热过
  warmSig = sig;
  warmAt = Date.now();
  postNative('prewarmAgent', req);
}

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
    els.input.value = text;
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
    input.value = '/' + it.name + ' ';
    input.selectionStart = input.selectionEnd = input.value.length;
  } else {
    const caret = input.selectionStart;
    const before = input.value.slice(0, suggest.start);
    const insert = (/\s/.test(it.name) ? `"${it.name}"` : it.name) + ' ';
    input.value = before + insert + input.value.slice(caret);
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
  if (e.key === 'Enter' || e.key === 'Tab') { e.preventDefault(); acceptSuggest(); return true; }
  if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeSuggest(); return true; }
  return false;
}

function updateSuggest() {
  const input = els.input;
  const id = active;
  const value = input.value;
  const slash = slashQuery(value);
  if (slash !== null) {
    showSuggest('slash', rankCommands(agentCommands[id] || [], slash), 0);
    return;
  }
  const at = mentionQuery(value.slice(0, input.selectionStart));
  if (at && S[id].workspace && hasBridge()) {
    const start = at.start;
    const seq = ++suggest.seq;
    clearTimeout(suggest.timer);
    suggest.timer = setTimeout(() => {
      suggest.pending = { seq, start };
      postNative('listFiles', { workspace: S[id].workspace, query: at.q, reqId: seq });
    }, 100);
    return;
  }
  closeSuggest();
}

window.onFilesListed = data => {
  if (!suggest.pending || data.reqId !== suggest.pending.seq || data.reqId !== suggest.seq) return;   // 已经接着打字了
  showSuggest('file', (data.files || []).map(f => ({ name: f })), suggest.pending.start);
};

els.input.addEventListener('input', () => {
  updateSuggest();
  if (els.input.value.trim()) prewarm(active);   // 开始打字了：先把 CLI 起好
});
els.input.addEventListener('blur', () => setTimeout(closeSuggest, 150));

// ===== 内置浏览器工具的开关（权限菜单里；三位共用） =====
const browserToolsOn = () => lsGet('browser_tools', 'on') !== 'off';

// ===== 图片附件：粘贴的截图、拖进来的图片附在输入框上面，发送时作为真正的图片交给模型 =====
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
      + '<span class="attach-name"></span><button class="attach-x" title="不发这张"></button>';
    if (a.thumb) chip.querySelector('img').src = a.thumb;
    chip.querySelector('.attach-name').textContent = baseName(a.path);
    chip.querySelector('.attach-x').innerHTML = UI.close;
    chip.querySelector('.attach-x').addEventListener('click', () => { list.splice(i, 1); renderAttachments(); updateSendUI(); });
    row.appendChild(chip);
  });
}

function addAttachments(id, paths, pasted) {
  const st = S[id];
  st.attach = st.attach || [];
  paths.forEach(p => { if (!st.attach.some(a => a.path === p)) st.attach.push({ path: p, thumb: pasted ? lastPastedThumb : '' }); });
  lastPastedThumb = '';
  st.attach = st.attach.slice(0, 8);
  if (id === active) { renderAttachments(); els.input.focus(); }
  pets[id].say(pasted ? '截图附上了，发送时一起给它 📎' : `附上了 ${paths.length} 张图片 📎`, 2000);
}

/** 发送时取走附着的图片（路径）。 */
function takeAttachments(id) {
  const list = (S[id].attach || []).map(a => a.path);
  S[id].attach = [];
  if (id === active) renderAttachments();
  return list;
}

// ===== 搜索正文后点进会话：跳到命中的那一条，闪一下 =====
function jumpToSearchHit(id) {
  const st = S[id];
  const q = histQuery;
  if (!q || q.length < 2 || !st.bodyHits?.has(st.conversationId) || st.bodyQuery !== q) return;
  const box = st.msgEl;
  const hit = [...box.children].find(n => n.matches('.msg.user, .msg.bot') && n.textContent.toLowerCase().includes(q));
  if (!hit) return;   // 命中的在更早、没显示的消息里，或者在工作过程的细节里
  hit.scrollIntoView({ block: 'center' });
  hit.classList.add('search-hit');
  setTimeout(() => hit.classList.remove('search-hit'), 2600);
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
  els.input.value = next.value;
  els.input.selectionStart = els.input.selectionEnd = next.value.length;
  autosize();
  return true;
}

// 切到另一位时，附件栏跟着换成那一位的
const baseRenderComposer = renderComposer;
renderComposer = function () { baseRenderComposer(); renderAttachments(); };
