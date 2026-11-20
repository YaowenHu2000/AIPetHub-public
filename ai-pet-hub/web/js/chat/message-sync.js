'use strict';

// 历史消息上屏：整页渲染、按 planHistoryRows 增量对账（syncAppend / reconcileRows）、「显示更早」分页，以及历史行的重试和附件来源。
// 和 messages.js 分开：那边的文字渲染和文件引用核对还要载进原生的搜索 JSContext（ConversationSearchText.swift），这边只在页面里用。
//
// 网页按请求编号区分首次打开、后台同步和补充回读。
// 「显示更早」只恢复该次请求的阅读位置，隐藏面板首次显示时再滚到底。
//
// 读取开始后才发送的提问留在历史之后。
// 若回包已包含本地结束后的外部提问，先在这句之前对齐本地轮，再接上新分支。
// 连续同文用已写入的正文和结局对齐，尚未写入的轮次按顺序占位。
// 分页按绝对位置对齐，只有压成了的提示占一条。
// 附件按发送顺序核对内容键、恢复路径和记录引用。
// Claude、Gemini 的大图可能重编码，沿用提问时间和附件数核对。
// Gemini、DeepSeek 把补充另存为问答时按已消费的补充及末段正文对齐。
// DeepSeek 的手动压缩失败按命令时间补记，隐藏的压缩命令仍可从失败回答重试。

// 首次发送后选定的副本和已经恢复的记录引用才代表这一问；编辑还要保留草稿里普通文件的位置。
function sentAttachments(ask, paths = ask?.images || []) {
  const images = paths.map(path => ask?.sentPaths?.[path] || path);
  const refs = (ask?.imageRefs || ask?.refs || []).map((ref,i) => {
    const snapshot = ask?.restoredPaths?.[i];
    return snapshot ? {...ref,snapshot} : ref;
  });
  const ordered = images.slice();
  for (const ref of refs) ordered.splice(ref.index ?? ordered.length,0,ref.snapshot);
  // 副本按内容命名，附件栏和悬停要的是原文件名和原路径；历史里的副本靠缩略图记下的显示路径找回。
  const origin = path => ask?.draft?.shown?.[path] || ask?.thumbnails?.find(im => im.snapshot === path && im.path)?.path || path;
  const shown = paths.map(origin);
  for (const ref of refs) shown.splice(ref.index ?? shown.length,0,ref.path || ask?.thumbnails?.find(im => im.ref?.id === ref.id && im.ref.conversationId === ref.conversationId && im.path)?.path || '');
  return {images, refs, ordered, shown};
}

function editAttachments(ask) {
  // 历史重试的草稿可能已包含恢复的图片。以提问里的原始附件顺序插回引用，连续点重试也只插一次。
  return sentAttachments(ask,ask?.imageRefs?.length ? ask.images : ask?.draft?.paths || ask?.images);
}

function historyRetry(m) {
  const images = [], refs = [];
  for (const im of m.images || []) {
    if (im.mentioned) continue;
    const {path, ref} = sentImageSource(im);
    if (ref) refs.push({...ref, index:images.length + refs.length});
    else if (path) images.push(path);
  }
  return {text:m.text || '', images, refs, thumbnails:m.images || null};
}

/** 一条消息放到聊天区最后。ex：这次运行里记下的这一轮的改动（live.js），没有就是 undefined。 */
function renderOneMessage(id, m, ex, cwd, before = null, sig = messageSignature(m)) {
  if (m.role === 'compact') {
    const note = document.createElement('div');
    note.className = 'msg sys fork-note compact-note';
    note.dataset.historyCompact = '1';
    note.textContent = m.text;
    note._historySig = sig;
    S[id].msgEl.insertBefore(note,before);
    return note;
  }
  if (m.role === 'user') {
    const el = appendMessage(id, 'user', m.text || '', m.images, S[id].msgEl, before, false);
    el._historySig = sig;
    el._historyAsk = m;
    el._retry = historyRetry(m);
    return el;
  }
  const turn = renderChangeTurn(id,m,ex,cwd,sig);
  S[id].msgEl.insertBefore(turn,before);
  if (canRetryOutcome(m.outcome)) bindHistoryRetry(id,turn,m);
  return turn;
}

// 重开会话：停下或出错的那一轮和实时时一样有「重试」（native-callbacks.js 实时那条路），问的是它前面那句
function bindHistoryRetry(id, turn, m) {
  let user = turn.previousElementSibling;
  while (user && !user.matches('.msg.user:not(.queued), .turn, .compact-note')) user = user.previousElementSibling;
  const ask = isCompactCommand(m.retryPrompt) ? {text:m.retryPrompt.trim()} : m.retryUser ? historyRetry(m.retryUser) : user?._retry;
  // 原问在分页之外时先记下，「显示更早」补回原问后由 syncAppend 再核对。
  turn._retryPending = ask ? null : m;
  if (ask) addRetry(turn, id, ask.text, ask.images, ask.refs, null, ask.thumbnails);
}

const historyRowSelector = '.msg.user:not(.queued), .msg.bot.turn, .compact-note[data-history-compact]';
const directHistoryRows = ':scope > :is(' + historyRowSelector + ')';

function shownHistoryLength(box) {
  return [...box.querySelectorAll(directHistoryRows)].filter(node =>
    !node._historyGap && !(node.classList.contains('user') && node._run?.ending && isCompactCommand(node._run.text))).length;
}

function updateHistoryPage(id, omitted, hasMore) {
  const box = S[id].msgEl;
  box.querySelector(':scope > .load-earlier')?.remove();
  if (omitted > 0 || hasMore) {   // 服务尚有未取回的旧页时，不能把已知条数当作整个会话的开头。
    const note = document.createElement('button');
    note.className = 'msg sys load-earlier';
    note.textContent = hasMore ? '还有更早的消息 · 点这里继续显示'
      : `还有较早的 ${omitted} 条消息没显示 · 点这里再显示 ${Math.min(300, omitted)} 条`;
    note.addEventListener('click', () => {
      const st = S[id];
      st.histLimit = (st.shownLimit || 300) + 300;
      // 载入后停在原来看的那条上。距离跟着这次请求走：回包前换了会话，新会话的回包不能拿去用
      const reqId = nextRequestId();
      st.keepFromBottom = { reqId, distance: box.scrollHeight - box.scrollTop };
      st.loadedSig = '';
      note.textContent = '正在读取更早的消息…';
      postNative('loadConversation', { agent: id, conversationId: st.conversationId, limit: st.histLimit, reqId });
    });
    box.prepend(note);
  }
}

function syncAppend(id, messages, cwd, omitted, hasMore = false, afterSteer = false, signatures, streamTail = false) {
  const st = S[id], box = st.msgEl;
  const nodes = [...box.querySelectorAll(directHistoryRows)];
  if (!nodes.length) return false;
  const keep = nearBottom(box) ? null : box.scrollTop;
  const extras = matchTurnExtras(id,messages,omitted);
  const offset = (st.shownOmitted || 0) - omitted;
  if (offset || !!st.shownHasMore !== hasMore) {
    updateHistoryPage(id,omitted,hasMore);
    st.shownOmitted = omitted;
    st.shownHasMore = hasMore;
  }
  // 翻页只改变共同前缀从哪里开始。仍在范围内的本地停止轮照常对账。
  let dropped = 0, counted = 0;
  while (dropped < nodes.length && (counted < -offset || (dropped && nodes[dropped]._historyGap))) {
    if (!nodes[dropped++]._historyGap) counted++;
  }
  for (const old of nodes.splice(0,dropped)) { old._stopNote?.remove(); old.remove(); }
  const start = Math.min(messages.length,Math.max(0,offset));
  for (let i = 0; i < start; i++) renderOneMessage(id,messages[i],extras.get(i),cwd,nodes[0],signatures?.[i]);
  reconcileRows(id,nodes,messages,cwd,extras,{start,afterSteer,signatures,streamTail:streamTail && !offset});
  // 翻页沿用原来的交界节点：它初绘时找不到原问，补回原问后再接上重试。
  const edge = nodes[0];
  if (start && edge?.isConnected && edge._retryPending && !edge.querySelector('.retry')) bindHistoryRetry(id,edge,edge._retryPending);
  if (!box.children.length) showEmpty(id);
  verifyFileChips(box, cwd);
  if (keep !== null) box.scrollTop = keep; else scrollToBottom(box);
  return true;
}

function reconcileRows(id, nodes, messages, cwd, extras, options) {
  const shown = nodes.map(node => {
    const role = node.classList.contains('user') ? 'user' : node.classList.contains('compact-note') ? 'compact' : 'bot';
    return {role, ask:node._historyAsk, run:node._run, sig:node._historySig,
      local:role === 'user' ? !node._historyAsk : node._answeredHere,
      confirmed:node._confirmedReply, supplements:node._supplements, endedAt:node._endedAt, extra:node._changeExtra,
      ending:{text:(node._text || '').trim(), outcome:node._outcome, reqId:node._endingReqId}};
  });
  nodes.forEach(node => { if (node._historyGap) delete node._historyGap; });
  for (const {kind, at, j} of planHistoryRows(shown,messages,{...options, agent:id,extras})) {
    const old = nodes[j];
    if (kind === 'gap') { old._historyGap = true; continue; }
    if (kind === 'confirm') {
      old._confirmedReply = true;
      continue;
    }
    if (kind === 'remove') { old._stopNote?.remove(); old.remove(); continue; }
    const fresh = renderOneMessage(id,messages[at],extras.get(at),cwd,old,options.signatures?.[at]);
    if (options.streamTail && at === messages.length - 1 && messages[at].role === 'bot' && !old?._answeredHere) {
      if (kind === 'replace' && old.matches('.turn') && fresh._text?.startsWith(old._text || '')) {
        continueAnswer(id,fresh,old._answerStream || {answer:old.querySelector('.answer')},old._text);
      } else if (kind === 'append' && nodes.at(-1)?._historyAsk && nodes.at(-1)._historySig === options.signatures?.[at-1]) {
        continueAnswer(id,fresh);
      }
    }
    if (kind === 'insert') old._supplements = null;   // 计划已经确认末段；以后的同步直接核对拆开后的历史行。
    if (kind !== 'replace') continue;
    if (old.querySelector('.work.open')) fresh.querySelector('.work')?.classList.add('open');
    const bodies = fresh.querySelectorAll('.step-body');
    old.querySelectorAll('.step-body').forEach((body, k) => { if (bodies[k]) bodies[k].hidden = body.hidden; });
    old._stopNote?.remove();
    old.remove();
  }
}

function renderMessages(id, messages, cwd = '', omitted = 0, hasMore = false, {fresh = [], readAt, signatures} = {}) {
  const st = S[id], box = st.msgEl;
  const running = runsOf(id,viewKey(id)), activeRun = running[0];
  const asks = fresh.map(n => n._run).filter(Boolean);
  // 网页重载接回的请求也可能在首次读取前发出；这时页面上只有原生恢复的进行中节点。
  if (activeRun && !asks.includes(activeRun) && activeRun.historyStart == null && Number.isFinite(readAt)) asks.push(activeRun);
  const lastAsk = asks.at(-1);
  const later = !activeRun && lastAsk?.endedAt && !(lastAsk.since > readAt)
    ? messages.findIndex((m,i) => askedAfterRun(lastAsk,m,messages[i+1])) : -1;
  const overlap = later < 0 ? messages : messages.slice(0,later);
  const logged = localAsksInHistory(asks,overlap,readAt,omitted);
  let nextPosition = omitted + overlap.length;
  for (const [k,run] of asks.entries()) {
    const at = logged[k];
    const position = at === undefined ? nextPosition : omitted + at;
    if (run.historyStart == null) run.historyStart = position;
    // 即使整批提问都晚于快照，后一个本地回合也在前一问一答之后。
    const after = at === undefined ? position + (isCompactCommand(run.text) ? 1 : 2) :
      omitted + historyReplyIndex(run,messages,at) + 1;
    nextPosition = Math.max(nextPosition,after);
  }
  const cut = activeRun && !(activeRun.since > readAt) ? liveHistoryCut(activeRun,messages,omitted) : -1;
  const end = cut >= 0 ? cut : messages.length;
  const start = Math.min(logged[0] ?? overlap.length,end);
  const extras = matchTurnExtras(id,cut >= 0 ? messages.slice(0,end) : messages,omitted,asks,logged.length);
  box.innerHTML = '';
  updateHistoryPage(id,omitted,hasMore);
  for (let i = 0; i < start; i++) {
    renderOneMessage(id,messages[i],extras.get(i),cwd,null,signatures?.[i]);
    // WebKit 一次结算整页 300 条比分批结算慢约半秒（35d6eb0 起整页只在末尾结算）；每 12 条读一次高度，节点和高度不变。
    if (i % 12 === 11) void box.offsetHeight;
  }
  fresh.forEach(n=>box.appendChild(n));
  const activeNodes = new Set(running.flatMap(run=>run.nodes));
  if (fresh.length && start < end) {
    const local = fresh.filter(n=>n.matches(historyRowSelector) && !activeNodes.has(n));
    reconcileRows(id,local,messages,cwd,extras,{start,end,signatures,opening:true});
  }
  for (const n of activeNodes) box.appendChild(n);
  st.shownOmitted = omitted;
  st.shownHasMore = hasMore;
  if (!box.children.length) showEmpty(id);
  verifyFileChips(box, cwd);
  scrollToBottom(box);
}
