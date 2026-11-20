'use strict';

// 一轮回答改了哪些文件：记下来（会话重读后还能把改动卡片接回去）、「查看全部改动」标签；智能体用工具打开内置浏览器时切过去。
// 接在 live.js 后面加载。纯逻辑在 logic.js。
//
// 实时收尾由这里把快照和原请求一起保存。
// 切回、分页、后台答完再打开和冷启动都由 `matchTurnExtras` 调用 `logic.js` 的 `matchExtras` 认领回答，和历史同步共用 `historyAskMatches`、
// `historyReplyIndex`。
// Claude 首问回显、Codex 交互回合、DeepSeek 提问调用自带编号；缺少编号时核对位置、发送和结束时间、实际附件、补充、正文摘要与结局，首次认领后记住历史提问编号。
// 这样同文重试不会领走旧卡，拆段补充也只把整轮补丁交给末段。
// 早期缓存按已有字段读取。
// 网页在 localStorage 保留近期改动，预算约 2 MiB，删除会话时清除；读历史补记位置时只改共享存储里的同一条，不拿本页缓存覆盖别的窗口新存的轮次。
// 实时和历史由 `renderChangeTurn` 合成文件列表及「查看全部改动」。
// 同一路径有完整快照时，文件卡显示整轮净差异，编辑步骤保留单次操作的增删。
// 已确认净差异为零的工具路径同样按轮次保存，重开时跳过它们的文件卡。
//
// 补丁达到长度上限时，原生统计和截断标记随改动保存，两个预览都显示完整增删数。

// ===== 这一轮的改动：「查看全部改动」 =====
// CLI 历史没有命令产生的工作区补丁，须把它和原请求的身份一起保存。
function readTurnExtras() {
  const rows = lsJson('turn_extras', []);
  return new Map(Array.isArray(rows) ? rows.filter(row => Array.isArray(row) && typeof row[0] === 'string'
    && Array.isArray(row[1]) && row[1].every(ex => ex && Array.isArray(ex.files))) : []);
}
const turnExtras = readTurnExtras();

function saveTurnExtras(key, list) {
  const stored = readTurnExtras();
  stored.delete(key);
  if (list?.length) stored.set(key, list);
  // localStorage 还放着草稿，给改动预留约 2 MiB；从最久没更新的会话、最早的轮次开始淘汰。
  const rows = [];
  let remaining = 1000000;
  for (const [cid, turns] of [...stored].reverse()) {
    const kept = [];
    for (const turn of [...turns].reverse()) {
      let entry = turn, size = JSON.stringify(entry).length;
      if (size > 900000) {
        const limit = Math.floor(450000 / turn.files.length);
        entry = {...turn, files:turn.files.map(f => ({...f, truncated:f.truncated || (f.diff || '').length > limit, diff:(f.diff || '').slice(0, limit)}))};
        size = JSON.stringify(entry).length;
      }
      if (size + cid.length + 8 > remaining) break;
      remaining -= size + cid.length + 8;
      kept.unshift(entry);
    }
    if (kept.length) rows.unshift([cid, kept]);
  }
  lsSet('turn_extras', rows.length ? JSON.stringify(rows) : '');
}

// 本页缓存只在载入时读一次，别的窗口之后存的轮次不在里面；只把本页定下的位置和身份写回共享存储里的同一条。
function saveTurnPositions(key, touched) {
  const latest = readTurnExtras().get(key);
  if (!latest || !touched.size) return;
  const same = (a, b) => a.reqId === b.reqId && a.since === b.since && a.endedAt === b.endedAt && a.text === b.text && a.replyKey === b.replyKey
    && a.files.length === b.files.length && a.files.every((f, i) => f.path === b.files[i].path);
  let changed = false;
  for (const ex of touched) {
    const row = latest.find(r => same(r, ex));
    if (!row || row.at === ex.at && row.turnKey === ex.turnKey) continue;
    row.at = ex.at;
    if (ex.turnKey != null) row.turnKey = ex.turnKey;
    changed = true;
  }
  if (changed) saveTurnExtras(key, latest);
}

function forgetTurnExtras(id, ids) {
  const stored = readTurnExtras();
  let changed = false;
  for (const cid of ids) {
    const key = `${id}:${cid}`;
    turnExtras.delete(key);
    if (stored.delete(key)) changed = true;
  }
  if (changed) lsSet('turn_extras',stored.size ? JSON.stringify([...stored]) : '');
  const tabs = pane.tabs.filter(t => t.kind === 'changes' && t.extra.agent === id && ids.has(t.extra.conversationId));
  tabs.forEach(t => closeTab(t.id));
  if (tabs.length && !pane.tabs.length) { renderPaneTabs(); renderPaneBody(); }
}

function rememberTurn(id, run, data, cwd) {
  const files = Array.isArray(data.files) ? data.files : [];
  if (!files.length && !data.unchangedPaths?.length) return null;
  // 保存和本地回合相同的提问身份，后台收尾和冷启动也能复用历史同步的判据，不必保留正文或缩略图。
  const ex = {agent:id, conversationId:data.conversationId, files, cwd, text:(run.prompt || run.text || '').trim(), imageOnly:run.text === '',
    at:run.historyStart ?? null, since:run.since, endedAt:run.endedAt, reqId:data.reqId, turnKey:data.turnKey,
    outcome:run.ending?.outcome || (data.cancelled ? 'interrupted' : data.outcome), images:run.images, imageRefs:run.imageRefs,
    imageKeys:run.imageKeys, sentPaths:run.sentPaths && {...run.sentPaths}, restoredPaths:run.restoredPaths};
  const supplements = run.supplements || consumedSupplementKeys(data,run);
  if (supplements.length) ex.supplements = supplements;
  if (typeof data.reply === 'string') ex.replyKey = replyFingerprint(data.reply);
  if (data.unchangedPaths?.length) ex.unchangedPaths = data.unchangedPaths;
  if (data.conversationId) {
    const key = `${id}:${data.conversationId}`;
    const list = turnExtras.get(key) || [];
    list.push(ex);
    turnExtras.set(key, list.slice(-40));
    // 共享存储里可能有别的窗口之后存的轮次，本页缓存没有；在最新值上只追加这一条。
    saveTurnExtras(key, [...(readTurnExtras().get(key) || []), ex].slice(-40));
  }
  return ex;
}

function consumedSupplementKeys(data, run) {
  const keys = steps => (steps || []).filter(s => s?.kind === 'user').map(s => replyFingerprint(s.detail));
  const final = keys(data.steps), live = keys(run.live?.steps);
  // 断线后原生可能只取到最后一段。实时步骤和定稿都记录了实际消费，重复同文要按次数对齐。
  const matchedPrefix = (sequence,wanted) => {
    let i = 0;
    for (const key of sequence) if (key === wanted[i]) i++;
    return i;
  };
  if (!live.length || matchedPrefix(final,live) === live.length) return final;
  return live.concat(final.slice(matchedPrefix(live,final)));
}

function matchTurnExtras(id, messages, omitted = 0, asks = [], loggedCount = 0) {
  const key = id + ':' + S[id].conversationId, stored = turnExtras.get(key);
  if (!stored?.length) return new Map();
  const positioned = new Set();
  for (const run of asks) {
    if (run.extra && run.extra.at == null && Number.isInteger(run.historyStart)) {
      run.extra.at = run.historyStart;
      positioned.add(run.extra);
    }
  }
  // 回读前刚答完的请求可能还不在这页；先留给自己的节点，避免占走同文旧轮。
  const unlogged = asks.length > loggedCount ? new Set(asks.slice(loggedCount).map(run => run.extra)) : null;
  const list = unlogged ? stored.filter(ex => !unlogged.has(ex)) : stored;
  const matches = matchExtras(list,messages,omitted,(ex,question,at) => {
    // 首次认领就绑定，不依赖本轮是否还留着实时节点；同文同答的另一分支不能再次取得补丁。
    if (!ex.turnKey && question.turnKey) { ex.turnKey = question.turnKey; positioned.add(ex); }
    if (ex.at !== at) { ex.at = at; positioned.add(ex); }
  });
  saveTurnPositions(key,positioned);
  return matches;
}

/** 续取到更早的旧页：记下的轮次位置和进行中的回答一样跟着后移。 */
function shiftTurnExtras(id, cid, prepended) {
  const key = `${id}:${cid}`, list = turnExtras.get(key);
  if (!list) return;
  const moved = new Set(list.filter(ex => Number.isInteger(ex.at)));
  moved.forEach(ex => { ex.at += prepended; });
  saveTurnPositions(key, moved);
}

// 原生的 Git 根目录已解析符号链接，macOS 的 /tmp、/var 会多出 /private 前缀。
function turnPathKey(path, cwd) {
  let p = String(path || '');
  if (!p.startsWith('/')) {
    if (!cwd) return p;
    p = cwd + '/' + p;
  }
  const parts = [];
  for (const part of p.split('/')) {
    if (part === '..') parts.pop();
    else if (part && part !== '.') parts.push(part);
  }
  return ('/' + parts.join('/')).replace(/^\/private(?=\/(?:tmp|var|etc)\/)/, '');
}

// 实时、增量替换和整页打开都从本轮快照合成同一张卡；历史工具另报的路径保留，净差异为零的跳过。
function renderChangeTurn(id, message, ex, cwd, sig) {
  let files = message.files;
  if (ex && !files?.length) files = ex.files;
  else if (ex && files !== ex.files) {
    // Git 快照记绝对路径，CLI 历史可能记相对路径；只拿归一后的路径去重，显示仍用原文。
    const base = ex.cwd || cwd || '', key = path => turnPathKey(path, base);
    const paths = new Set([...ex.files.map(f => key(f.path)), ...(ex.unchangedPaths || []).map(key)]);
    files = [...ex.files,...(files || []).filter(f => !paths.has(key(f.path)))];
  }
  const turn = renderTurn(files === message.files ? message : {...message,files},cwd,sig);
  turn._changeExtra = ex;
  if (files?.length) decorateTurn(turn,id,ex && files.length === ex.files.length ? ex :
    {agent:id,conversationId:S[id].conversationId,files,cwd});
  return turn;
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
    if (pane.tabs.length > 8) removePaneTab(0);
  }
  if (pane.active !== tab.id) rememberScroll();
  pane.active = tab.id;
  setPaneVisible(true);
  renderPaneTabs();
  renderPaneBody();
}

function patchTruncated(file, hunks) {
  if (!file?.diff || file.truncated != null) return !!file?.truncated;
  // 旧记录只有完整增删数和部分补丁，仍可确认缺少的行。
  let added = 0, removed = 0;
  for (const h of hunks || parseHunks(file.diff)) {
    for (const line of h.lines) {
      if (line.t === '+') added++;
      if (line.t === '-') removed++;
    }
  }
  return added < file.added || removed < file.removed;
}

/** preview/pane.js 的 renderPaneContent 遇到「全部改动」标签时调用。 */
function renderChanges(bar, body, tab) {
  const ex = tab.extra;
  const added = ex.files.reduce((n, f) => n + (f.added || 0), 0);
  const removed = ex.files.reduce((n, f) => n + (f.removed || 0), 0);
  bar.innerHTML = `<span class="chg-summary">${changedFileCount(ex.files.length, ex.files.length + ' 个文件有改动')}</span><span class="diff-count"><span class="add">+${added}</span> <span class="del">−${removed}</span></span>`;
  const wrap = document.createElement('div');
  wrap.className = 'chg-list';
  ex.files.slice(0,60).forEach(f => {
    const sec = document.createElement('section');
    sec.className = 'chg-file';
    const head = document.createElement('div');
    head.className = 'chg-file-head';
    const badge = f.kind === 'included' ? '<span class="file-badge">本轮纳入比较</span>' : f.kind === 'create' ? '<span class="file-badge">新建</span>' : f.kind === 'delete' ? '<span class="file-badge del">删除</span>' : '';
    head.innerHTML = `<span class="chg-name"></span><span class="chg-dir"></span>${badge}${f.toolTotal ? '<span class="file-badge">工具累计编辑</span>' : ''}${f.workspaceOnly ? '<span class="file-badge">同期工作区改动</span>' : ''}<span class="diff-count"><span class="add">+${f.added || 0}</span> <span class="del">−${f.removed || 0}</span></span><span class="chg-spacer"></span>`;
    head.querySelector('.chg-name').textContent = baseName(f.path);
    head.querySelector('.chg-dir').textContent = prettyPath(f.path.replace(/\/[^/]*$/, ''));
    if (f.kind !== 'delete') {
      const open = document.createElement('button');
      open.className = 'chg-btn';
      open.textContent = '打开文件';
      open.addEventListener('click', () => openPreview({ path: f.path, base: ex.cwd || '', diff: f.diff || '', change:f }));
      head.appendChild(open);
    }
    sec.appendChild(head);
    const rows = [];
    const hunks = parseHunks(f.diff || '');
    hunks.forEach((h, k) => {
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
    if (patchTruncated(f, hunks)) sec.insertAdjacentHTML('beforeend','<div class="ed-note">改动预览已截断，增删统计包含全部行。</div>');
    wrap.appendChild(sec);
  });
  body.appendChild(wrap);
}

// 智能体用工具打开内置浏览器（原生：BrowserTools.swift）：切到浏览器标签，有地址就打开
window.onBrowserToolOpen = data => { openBrowser(data.url || ''); };
