'use strict';

// 打开着的会话正在别处跑（终端里的 CLI、别的程序起的 codex exec……）：
// 以前这里只是一份读出来的记录，标题写着「已工作 5 分 35 秒」一动不动，看起来像卡死了，其实那边还在干活。
// 现在：发现它在变，就每 3 秒重新读一遍把新的步骤接上，最后一轮的标题换成「在别处运行中」，前面一个跳动的点；
// 连着 3 分钟没有新东西就当它结束了，标题变回去。
// 只在「看着它变了」之后才标（两次读到的内容不一样），不凭修改时间猜，免得把刚答完的会话标成还在跑。

const ELSEWHERE_WATCH_MS = 300000;   // 盯多久：最后一次有动静之后 5 分钟（思考强度高的时候两步之间能隔好几分钟）
const ELSEWHERE_SHOW_MS = 180000;    // 标多久：最后一次看到变化之后 3 分钟

/** 这个会话可能在别处跑着：开始盯它。 */
function watchElsewhere(id) {
  S[id].watchUntil = Date.now() + ELSEWHERE_WATCH_MS;
}

/** 后台同步时读到的内容和上次不一样，而且不是这里自己在答：它在别处跑。 */
function noteElsewhere(id) {
  const st = S[id];
  if (Date.now() - (st.ownAt || 0) < 8000) return;   // 这里刚答完，记录晚一点才写全，不算
  st.elsewhereAt = Date.now();
  watchElsewhere(id);
}

const elsewhereOn = id => !viewBusy(id) && Date.now() - (S[id].elsewhereAt || 0) < ELSEWHERE_SHOW_MS;

/** 把最后一轮的标题换成「在别处运行中」（或者换回去）。每次重画、接上新消息之后都要叫一次。 */
function markElsewhere(id) {
  const box = S[id].msgEl;
  const on = elsewhereOn(id);
  const turns = box.querySelectorAll('.msg.bot.turn:not(.live)');
  const last = on ? turns[turns.length - 1] : null;
  const work = last && box.lastElementChild === last ? last.querySelector('.work') : null;   // 后面已经有新的提问了就不标
  box.querySelectorAll('.work.elsewhere').forEach(w => {
    if (w === work) return;
    w.classList.remove('elsewhere');
    w.querySelector('.work-label').textContent = w.dataset.label;
  });
  if (!work) return;
  const label = work.querySelector('.work-label');
  if (!work.classList.contains('elsewhere')) { work.dataset.label = label.textContent; work.classList.add('elsewhere'); }
  label.textContent = work.dataset.label.replace(/^已工作 /, '在别处运行中 · 已 ').replace(/^工作过程$/, '在别处运行中');
}

/** 历史列表刷新了：打开着的这个会话的时间比上次看到的新，说明有人在别处动它。 */
function noteListedStamp(id) {
  const st = S[id];
  const item = (st.conversations || []).find(c => c.id === st.conversationId);
  const stamp = item && item.timestamp ? item.timestamp * 1000 : 0;
  const key = `${st.conversationId}|${stamp}`;
  const first = !st.seenStamp || st.seenStamp.split('|')[0] !== st.conversationId;
  if (st.seenStamp === key) return;
  st.seenStamp = key;
  // 第一次看到：两分钟内动过的才盯；之后每次时间变新都盯
  if (stamp && (!first || Date.now() - stamp < 120000) && !viewBusy(id)) watchElsewhere(id);
}

setInterval(() => {
  AGENT_IDS.forEach(id => { if (isBusy(id)) S[id].ownAt = Date.now(); });
  const id = active, st = S[id];
  if (document.hidden || !st.conversationId || st.loadedId !== st.conversationId || viewBusy(id)) return;
  if (Date.now() < (st.watchUntil || 0)) {
    st.syncing = true;
    postNative('loadConversation', { agent: id, conversationId: st.conversationId });
  }
  markElsewhere(id);   // 到时间了把标记撤掉
}, 3000);
// 没在盯的时候，每 20 秒看一眼列表：打开着的会话在别处开始动了，就能发现
setInterval(() => { if (!document.hidden) postNative('listConversations', { agent: active }); }, 20000);
