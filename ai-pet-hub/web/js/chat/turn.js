'use strict';

// 一轮回答的样子：可折叠的工作过程 + 正文 + 改动的文件；拷贝、重试。

// ===== 一次回答：可折叠的工作过程 + 正文 + 改动的文件（参考反重力） =====
const STEP_ICONS = {
  think: UI.think, command: UI.terminal, read: UI.file, edit: UI.pencil, write: UI.filePlus, delete: UI.trash,
  search: UI.search, list: UI.folder, web: UI.globe, todo: UI.listIcon, agent: UI.agent, tool: UI.tool,
  error: UI.alert, denied: UI.alert,
};
const FILE_STEP_KINDS = ['read', 'edit', 'write', 'delete', 'list'];

function durationText(sec) {
  const s = Math.round(sec || 0);
  if (s < 1) return '';
  if (s < 60) return `${s} 秒`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} 分 ${s % 60} 秒`;
  return `${Math.floor(m / 60)} 小时 ${m % 60} 分`;
}

function renderStep(step) {
  const el = document.createElement('div');
  el.className = `step step-${step.kind}` + (step.status === 'running' ? ' running' : '') + (step.status === 'error' ? ' error' : '');
  if (step.kind === 'user') {   // 回答进行中你补充的一句
    el.innerHTML = '<div class="step-user"><span class="step-user-tag">你补充说</span><span class="step-user-text"></span></div>';
    el.querySelector('.step-user-text').textContent = step.detail || '';
    return el;
  }
  if (step.kind === 'text') {   // 中途的说明文字直接显示成浅色段落
    el.innerHTML = `<div class="step-text md">${renderRich(step.detail || '')}</div>`;
    return el;
  }
  const head = document.createElement('div');
  head.className = 'step-head';
  const icon = document.createElement('span');
  icon.className = 'step-icon';
  icon.innerHTML = step.status === 'running' ? UI.spinner : (STEP_ICONS[step.kind] || UI.tool);
  const title = document.createElement('span');
  title.className = 'step-title';
  title.textContent = step.title || '';
  head.append(icon, title);
  if (step.kind === 'command' && step.detail) {
    const cmd = document.createElement('code');
    cmd.className = 'step-cmdline';
    cmd.textContent = step.detail.split('\n')[0];
    head.appendChild(cmd);
  }
  if (step.added || step.removed) {
    const c = document.createElement('span');
    c.className = 'diff-count';
    c.innerHTML = `<span class="add">+${step.added || 0}</span> <span class="del">−${step.removed || 0}</span>`;
    head.appendChild(c);
  }
  if (step.path && FILE_STEP_KINDS.includes(step.kind)) {
    head.classList.add('has-file');
    head.dataset.path = step.path;
    head.title = `${step.path}\n点击预览`;
  }
  const more = (step.kind === 'command' ? step.output : (step.detail || step.output)) || (step.kind === 'command' && step.detail && step.detail.includes('\n'));
  el.appendChild(head);
  if (more) {
    head.classList.add('expandable');
    const caret = document.createElement('span');
    caret.className = 'step-caret';
    caret.innerHTML = UI.chevron;
    head.appendChild(caret);
    const body = document.createElement('div');
    body.className = 'step-body';
    body.hidden = true;
    if (step.detail && (step.kind !== 'command' || step.detail.includes('\n'))) {
      const pre = document.createElement('pre');
      pre.textContent = step.detail;
      body.appendChild(pre);
    }
    if (step.output) {
      const pre = document.createElement('pre');
      pre.className = 'step-output';
      pre.textContent = step.output;
      body.appendChild(pre);
    }
    el.appendChild(body);
  }
  return el;
}

function renderWork(steps, label, open) {
  const work = document.createElement('div');
  work.className = 'work' + (open ? ' open' : '');
  const head = document.createElement('button');
  head.className = 'work-head';
  head.innerHTML = `<span class="work-label"></span><span class="work-meta"></span>${UI.chevron}`;
  head.querySelector('.work-label').textContent = label;
  const toolSteps = steps.filter(s => s.kind !== 'text').length;
  head.querySelector('.work-meta').textContent = toolSteps ? `${toolSteps} 步` : '';
  const list = document.createElement('div');
  list.className = 'work-steps';
  steps.forEach(st => list.appendChild(renderStep(st)));
  work.append(head, list);
  return work;
}

function renderFilesCard(files) {
  const card = document.createElement('div');
  card.className = 'files-card';
  const added = files.reduce((n, f) => n + (f.added || 0), 0);
  const removed = files.reduce((n, f) => n + (f.removed || 0), 0);
  const head = document.createElement('div');
  head.className = 'files-head';
  head.innerHTML = `<span>${files.length} 个文件有改动</span><span class="diff-count"><span class="add">+${added}</span> <span class="del">−${removed}</span></span>`;
  card.appendChild(head);
  files.forEach((f, i) => {
    const row = document.createElement('button');
    row.className = 'file-row';
    row.dataset.index = i;
    row.title = `${f.path}\n点击预览${f.diff ? '改动' : '文件'}`;
    const icon = f.kind === 'create' ? UI.filePlus : (f.kind === 'delete' ? UI.trash : UI.pencil);
    row.innerHTML = `<span class="file-icon">${icon}</span><span class="file-name"></span><span class="file-dir"></span>`
      + (f.kind === 'create' ? '<span class="file-badge">新建</span>' : (f.kind === 'delete' ? '<span class="file-badge del">删除</span>' : ''))
      + `<span class="diff-count"><span class="add">+${f.added || 0}</span> <span class="del">−${f.removed || 0}</span></span>`;
    row.querySelector('.file-name').textContent = baseName(f.path);
    row.querySelector('.file-dir').textContent = prettyPath(f.path.replace(/\/[^/]*$/, ''));
    card.appendChild(row);
  });
  return card;
}

/** msg = { text, steps, files, duration } */
function renderTurn(msg, cwd) {
  const el = document.createElement('div');
  el.className = 'msg bot turn';
  el.dataset.cwd = cwd || '';
  el._files = msg.files || [];
  const steps = msg.steps || [];
  if (steps.length) {
    const d = durationText(msg.duration);
    el.appendChild(renderWork(steps, d ? `已工作 ${d}` : '工作过程', false));
  }
  if (msg.text) {
    const answer = document.createElement('div');
    answer.className = 'answer md';
    answer.innerHTML = renderRich(msg.text);
    if (typeof loadLocalImages === 'function') loadLocalImages(answer, cwd || '');   // 回答里引用的本地图片直接显示
    el.appendChild(answer);
  }
  if (el._files.length) el.appendChild(renderFilesCard(el._files));
  if (msg.text) {
    el._text = msg.text;
    const actions = document.createElement('div');
    actions.className = 'turn-actions';
    actions.innerHTML = `<button class="answer-copy" title="拷贝回答（Markdown 原文，公式保留 LaTeX）">${UI.copy}<span>拷贝</span></button>`;
    el.appendChild(actions);
  }
  return el;
}

/** 出错或被停止的回答下面加「重试」：用同一句话在这个会话里再问一次。 */
function addRetry(turn, id, text) {
  let actions = turn.querySelector('.turn-actions');
  if (!actions) {
    actions = document.createElement('div');
    actions.className = 'turn-actions';
    turn.appendChild(actions);
  }
  actions.classList.add('pinned');
  const btn = document.createElement('button');
  btn.className = 'answer-copy retry';
  btn.innerHTML = `${UI.refresh}<span>重试</span>`;
  btn.title = '用同一句话再问一次';
  btn.addEventListener('click', () => {
    if (id !== active || viewBusy(id)) return;
    els.input.value = text;
    autosize();
    send();
  });
  actions.appendChild(btn);
}

/** 拷贝到剪贴板（App 里走原生，网页预览里退回浏览器接口），按钮短暂显示「已拷贝」。 */
function copyText(text, btn) {
  if (hasBridge()) postNative('copyText', { text });
  else navigator.clipboard?.writeText(text).catch(() => {});
  if (!btn) return;
  const old = btn.innerHTML;
  btn.classList.add('done');
  btn.innerHTML = btn.classList.contains('answer-copy') ? `${UI.check}<span>已拷贝</span>` : UI.check;
  setTimeout(() => { btn.classList.remove('done'); btn.innerHTML = old; }, 1300);
}

// 代码块和回答上的「拷贝」：聊天区和文件预览都有，统一在这里处理
document.addEventListener('click', e => {
  const codeBtn = e.target.closest('.code-copy');
  if (codeBtn) {
    e.stopPropagation();
    copyText(codeBtn.parentElement.querySelector('code')?.textContent || '', codeBtn);
    return;
  }
  const answerBtn = e.target.closest('.answer-copy:not(.retry)');   // 「重试」用同样的样式，但有自己的点击处理
  if (answerBtn) {
    e.stopPropagation();
    copyText(answerBtn.closest('.turn')?._text || '', answerBtn);
  }
}, true);

// 从访达拖进窗口的文件：把路径插到输入框（含空格的路径加引号），CLI 可以直接读
window.onFilesDropped = data => {
  let paths = Array.isArray(data.paths) ? data.paths : [];
  // 图片不插路径：附在输入框上面，发送时作为真正的图片交给模型（composer.js）
  const imgs = paths.filter(p => ATTACH_IMAGE_RE.test(p));
  if (imgs.length) {
    addAttachments(active, imgs, data.pasted);
    paths = paths.filter(p => !ATTACH_IMAGE_RE.test(p));
  }
  if (!paths.length) return;
  const text = paths.map(p => (/\s/.test(p) ? `"${p}"` : p)).join(' ');
  const el = els.input;
  const focused = document.activeElement === el;
  const a = focused ? el.selectionStart : el.value.length;
  const b = focused ? el.selectionEnd : el.value.length;
  const before = el.value.slice(0, a);
  const after = el.value.slice(b);
  const lead = before && !/\s$/.test(before) ? ' ' : '';
  const tail = after && !/^\s/.test(after) ? ' ' : '';
  el.value = before + lead + text + tail + after;
  el.selectionStart = el.selectionEnd = (before + lead + text).length;
  el.focus();
  autosize();
  pets[active].say(data.pasted ? '截图已存成文件，路径放进输入框了 📎' : paths.length > 1 ? `已添加 ${paths.length} 个文件路径 📎` : '已添加文件路径 📎', 2000);
};

// 粘贴截图（只有图片、没有文字时）：交给原生存成文件，再把路径插进输入框；有文字就照常粘贴文字
els.input.addEventListener('paste', e => {
  const items = [...(e.clipboardData?.items || [])];
  const img = items.find(it => it.kind === 'file' && /^image\//.test(it.type));
  if (!img || items.some(it => it.type === 'text/plain')) return;
  e.preventDefault();
  const file = img.getAsFile();
  if (!file || !hasBridge()) return;
  const reader = new FileReader();
  reader.onload = () => { lastPastedThumb = reader.result; postNative('savePastedImage', { data: reader.result }); };
  reader.readAsDataURL(file);
});
