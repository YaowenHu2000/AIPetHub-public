'use strict';

// 输入框周边：预热、图片附件、/ 命令和 @ 文件、↑ ↓ 翻发过的话、消息上的「编辑」、内置浏览器工具的开关、搜索后定位。
// 接在 changes.js 后面加载。纯逻辑在 logic.js。

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
  if (!text && !div.querySelector('.msg-images')) return;
  const b = document.createElement('button');
  b.className = 'msg-edit';
  b.title = '把这句话放回输入框，改了再发（接在现在的对话后面，不会回到当时）';
  b.innerHTML = UI.pencil;
  b.addEventListener('click', e => {
    e.stopPropagation();
    if (id !== active) setActive(id);
    const ask = div._run || div._retry;
    const prompt = ask?.draft?.text ?? ask?.text ?? text;
    const sent = editAttachments(ask);
    // 改选另一条提问时，只撤回上次编辑带入的图，包括仍在等待恢复的原图。
    cancelPendingEdit(id);
    const st = S[id];
    if (st.attach?.some(a => a.edited)) {
      st.attach = st.attach.filter(a => !a.edited); saveAttachments(id); renderAttachments();
    }
    setDraft(id, prompt);
    if (ask?.preparingImages) {
      ask.pendingEdit = beginAttachment(id,{edited:true});
    } else if (sent.refs.length) {
      // 历史原图可能只剩记录引用；沿用粘贴的等待机制，确保用户立即发送时也带上原图。
      const {key} = beginAttachment(id,{edited:true,shown:sent.shown});
      postNative('editChatImages', {reqId:key, paths:sent.images, refs:sent.refs});
    } else if (sent.images.length) receiveFiles(id,sent.images,{edited:true,shown:sent.shown});
    els.input.focus();
    els.input.selectionStart = els.input.selectionEnd = prompt.length;
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
// Codex 不报命令列表：压缩上下文是我们替它接的，其余是它的技能（原生：CodexRun.swift）。第一次查到技能之前只有压缩一个
const codexCompact = { name: 'compact', desc: '把前面的对话压缩成摘要，腾出上下文空间' };
if (!agentCommands.gpt.length) agentCommands.gpt = [codexCompact];
// Codex 的项目级技能只在自己的目录里认：点了别的项目的技能会按普通文字发出。候选按原生回包带的工作空间分别存，
// 打 / 时取当前工作空间那份；还没查过的项目只列压缩，开始打字时的预热会去查（CodexRun.swift 的 warmCodex）
const codexCommands = lsJson('gpt_commands_by_workspace', {}) || {};
const slashCommands = id => id !== 'gpt' ? agentCommands[id] || []
  : codexCommands[S.gpt.workspace || ''] || [codexCompact];

window.onAgentCommands = data => {
  if (!AGENTS[data.agent] || !Array.isArray(data.commands)) return;
  if (data.agent === 'gpt' && typeof data.workspace === 'string') {
    const list = mergeCommands(codexCommands[data.workspace] || [], data.commands).slice(0, 200);
    delete codexCommands[data.workspace];   // 重新插到最后：只留最近用过的 50 个项目
    codexCommands[data.workspace] = list;
    Object.keys(codexCommands).slice(0, -50).forEach(ws => delete codexCommands[ws]);
    lsSet('gpt_commands_by_workspace', JSON.stringify(codexCommands));
  }
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
  // 记下出候选时的文字和光标：之后光标可能被点走，接受时要据此确认 @词 还在原处
  suggest.value = els.input.value;
  suggest.end = els.input.selectionStart;
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
    // 光标已离开那个 @词（或文字变了）：拿旧起点和新光标拼接会吞掉中间的话，只关掉候选、不动输入
    if (input.value !== suggest.value || caret !== input.selectionEnd || caret <= suggest.start || caret > suggest.end) { closeSuggest(); return; }
    const before = input.value.slice(0, suggest.start);
    const insert = (/\s/.test(it.name) ? `"${it.name}"` : it.name) + ' ';
    setDraft(active, before + insert + input.value.slice(suggest.end));
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
    const list = slashCommands(id);
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
    chip.title = a.shown || a.path;
    chip.innerHTML = (a.thumb ? '<img class="attach-thumb" alt="">' : `<span class="attach-icon">${UI.file}</span>`)
      + '<span class="attach-name"></span><button class="attach-x" title="不发这个"></button>';
    if (a.thumb) chip.querySelector('img').src = a.thumb;
    chip.querySelector('.attach-name').textContent = baseName(a.shown || a.path);
    chip.querySelector('.attach-x').innerHTML = UI.close;
    chip.querySelector('.attach-x').addEventListener('click', () => {
      list.splice(i, 1);
      if (a.pasted) postNative('discardPastedImage', {path:a.path});
      saveAttachments(active); renderAttachments(); updateSendUI();
    });
    row.appendChild(chip);
  });
}

function addAttachments(id, paths, pasted, origin = null) {
  const temporary = pasted ? paths : [];
  // 编辑带回的副本与回执路径一一对应，显示原文件名。
  const shown = origin?.shown?.length === paths.length ? Object.fromEntries(paths.flatMap((p,i) => origin.shown[i] && origin.shown[i] !== p ? [[p,origin.shown[i]]] : [])) : {};
  const kept = mergeDraft(draftTarget(id,origin),[{paths,pasted:temporary,edited:origin?.edited ? paths : [],shown}],'add',origin?.thumb);
  const missed = new Set(paths).size - kept.length;
  for (const path of new Set(temporary)) if (!kept.includes(path)) postNative('discardPastedImage',{path});
  if (id === active && (!origin || originDraftKey(origin) === currentDraftKey(id))) els.input.focus();
  const pics = kept.filter(p => ATTACH_IMAGE_RE.test(p)).length, files = kept.length - pics;
  const ok = !kept.length ? '' : pasted && !files ? '截图附上了，发送时一起给它' : `附上了 ${[pics && pics + ' 张图片', files && files + ' 个文件'].filter(Boolean).join('、')}`;
  const over = missed ? `有 ${missed} 个没附上（最多 ${attachmentLimit} 个）` : '';
  pets[id].say([ok, over].filter(Boolean).join('，') + (ok ? ' 📎' : ''), missed ? 3000 : 2000);
  return kept;
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
  // 长回答整条居中时关键词可能远在屏幕外：逐层找到仍包含命中文字的最小元素（段落、步骤输出等），滚到它那里。
  // 命中跨了几个子元素时停在它们的共同父元素上，最差也和整条居中一样。
  let target = hit;
  for (let next; (next = [...target.children].find(c => !c.hidden && c.getClientRects().length && matches(visibleText(c)))); ) target = next;
  target.scrollIntoView({ block: 'center' });
  // 长代码块可能只有一个文本节点；按命中文字的位置滚动，包括代码块自己的横向滚动条。
  const walker = document.createTreeWalker(target, NodeFilter.SHOW_TEXT);
  const parts = [];
  let text = '';
  for (let node; (node = walker.nextNode()); ) {
    if (node.parentElement.closest('button,.katex-mathml') || !node.parentElement.getClientRects().length) continue;
    const color = getComputedStyle(node.parentElement).color;
    if (color === 'rgba(0, 0, 0, 0)') continue;
    parts.push({node,start:text.length});
    text += node.data;
  }
  for (const needle of needles) {
    const match = new RegExp(needle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'iu').exec(text);
    if (!match) continue;
    const end = match.index + match[0].length;
    const first = parts.findLast(p => p.start <= match.index), last = parts.findLast(p => p.start < end);
    const range = document.createRange();
    range.setStart(first.node,match.index-first.start); range.setEnd(last.node,end-last.start);
    if (!range.getClientRects().length) continue;
    for (let el = first.node.parentElement; el && box.contains(el); el = el.parentElement) {
      const rect = range.getBoundingClientRect(), bounds = el.getBoundingClientRect();
      if (el.clientHeight && el.scrollHeight > el.clientHeight && (rect.top < bounds.top || rect.bottom > bounds.bottom))
        el.scrollTop += rect.top - bounds.top - (el.clientHeight - rect.height) / 2;
      if (el.clientWidth && el.scrollWidth > el.clientWidth && (rect.left < bounds.left || rect.right > bounds.right))
        el.scrollLeft += rect.left - bounds.left - (el.clientWidth - rect.width) / 2;
    }
    break;
  }
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

// 切到另一位时，附件栏跟着换成那一位的，候选也关掉。同一位的重画不关：原生报来模型列表（打 @ 触发的预热起好后，
// Codex、Gemini 紧跟着就报）、检测结果晚到都会重画选择器，关掉会让刚出的 @ 候选闪一下就没了，也不再重发
const baseRenderComposer = renderComposer;
let composerAgent = active;
renderComposer = function () {
  if (composerAgent !== active) closeSuggest();
  composerAgent = active;
  baseRenderComposer();
  renderAttachments();
};

// 📎：系统的选文件窗口，可以多选（Bridge.swift 的 pickAttachments），选好的走 onFilesDropped
const attachBtn = document.getElementById('attach-btn');
attachBtn.innerHTML = UI.clip;
attachBtn.addEventListener('click', () => {
  if (hasBridge()) postNative('pickAttachments',{pasteId:beginAttachment(active,{file:true,picker:true}).key});
});
