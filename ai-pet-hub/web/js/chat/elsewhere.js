'use strict';

// Codex 和 DeepSeek 以历史里最后一轮的明确状态为准。没有边界的旧记录和其他 CLI 仍按可见内容的变化判断。
//
// Claude 有明确结束记录、Gemini 的空闲摘要与当前步数相符时，侧栏同步立即撤下外部运行提示。
// Codex 和 DeepSeek 把最后一轮的开始和结束状态随历史发给网页。
// 运行中的回合静默时仍显示计时，读到结束事件就撤标；该会话一小时没有写入时按意外退出处理。
// 缺少回合状态的记录仍按可见内容的变化判断。
const TURN_STALE_MS = 60 * 60 * 1000;   // 崩溃可能没有结束事件，也可能恰好遇到长时间静默推理

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

function readElsewhereTurn(id, data, syncing) {
  const st = S[id], previous = st.externalTurn;
  const tail = data.messages?.at(-1);
  // 老记录可能没有运行边界。失败或中断的末轮已经结束；未完成的末轮仍可能在另一窗口继续写。
  const ended = tail?.role === 'bot' && canRetryOutcome(tail.outcome) && tail.outcome !== 'incomplete';
  const turn = typeof data.lastTurn?.running === 'boolean' ? data.lastTurn : (ended ? {running:false} : null);
  st.externalTurn = typeof turn?.running === 'boolean' ? { ...turn, cid: data.conversationId } : null;
  if (turn?.running && elsewhereOn(id)) watchElsewhere(id);
  if ((turn || previous) && syncing) markElsewhere(id);   // 状态可以先于可见步骤变化
}

function elsewhereOn(id) {
  if (viewBusy(id)) return false;
  const st = S[id], turn = st.externalTurn;
  if (turn && turn.cid === st.conversationId) return turn.running && Date.now() - turn.updatedAt * 1000 < TURN_STALE_MS;
  return Date.now() - (st.elsewhereAt || 0) < ELSEWHERE_SHOW_MS;
}

/** 桌宠跟着「在别处运行中」动：从这一轮最后一步推出思考 / 查阅 / 施工，和自己答的时候用同一套规则（syncRunPhase）。
 *  只认当前选中的那位：别的几位不再同步记录，不知道那边结束了没有，留着会一直显示在忙。 */
function setElsewherePet(id, work) {
  const st = S[id];
  let next = null;
  if (work && id === active) {
    const steps = [...work.querySelectorAll('.work-steps > .step:not(.pending-elsewhere)')].map(el => ({
      kind: ([...el.classList].find(c => c.startsWith('step-')) || 'step-think').slice(5),
      title: el.querySelector('.step-title')?.textContent || '',
      status: el.classList.contains('running') ? 'running' : 'ok',
    }));
    const run = { live: { steps } };
    syncRunPhase(run);
    // 最后一步已经做完、又没有在跑的：那边是在想下一步（自己答的时候 4 秒后也会这样切，见 boot.js）
    if (run.stepStatus !== 'running') { run.phase = 'thinking'; run.stepKind = 'think'; run.stepTitle = '思考下一步…'; }
    next = { phase: run.phase, stepKind: run.stepKind, stepTitle: run.stepTitle, since: st.elsewhereTurn?.startAt || Date.now() };
  }
  const key = p => p ? `${p.phase}|${p.stepTitle}` : '';
  const changed = key(next) !== key(st.elsewherePet);
  st.elsewherePet = next;
  if (changed && typeof pets !== 'undefined' && pets[id]) pets[id].syncBusyState();
}

/** 把最后一轮的标题换成「在别处运行中」（或者换回去）。每次重画、接上新消息之后都要叫一次。 */
function markElsewhere(id) {
  const box = S[id].msgEl;
  const on = elsewhereOn(id);
  const turns = box.querySelectorAll('.msg.bot.turn:not(.live)');
  const last = on ? turns[turns.length - 1] : null;
  // 后面已经有新的提问了就不标；接在末尾的「没有回合接着的卡片」（live.js 的 unattendedRequest）不算
  let tail = box.lastElementChild;
  if (tail?.classList?.contains('unattended')) tail = tail.previousElementSibling;
  box.querySelectorAll('.turn[data-incomplete] .retry').forEach(button => {
    const running = last === tail && last?.contains(button);
    button.hidden = button.disabled = !!running;
  });
  const work = last && tail === last ? last.querySelector('.work') : null;
  box.querySelectorAll('.work.elsewhere').forEach(w => {
    if (w === work) return;
    w.classList.remove('elsewhere');
    w.querySelector('.work-label').textContent = w.dataset.label;
    w.querySelectorAll('.pending-elsewhere').forEach(n => n.classList.remove('pending-elsewhere'));
  });
  if (!work) { setElsewherePet(id, null); return; }
  const label = work.querySelector('.work-label');
  if (!work.classList.contains('elsewhere')) {
    work.dataset.label = label.textContent;
    work.classList.add('elsewhere');
  }
  // 记录里的时长只到它写下的最后一步为止，两步之间（一条命令跑好几分钟）就停着不动，看起来像卡死。
  // 所以倒推出这一轮是什么时候开始的，之后按现在的时间实时算。
  // 开始时间记在会话上、不记在节点上：这一轮每多一步节点就会被换成新的，记在节点上的话每次同步都从记录里的时长重新起算，
  // 秒数走几秒又跳回去。同一轮（同一个会话、同样的轮数）只取最早的那个估计，不往回跳。
  const st = S[id], key = `${st.conversationId}|${turns.length}`;
  const recorded = st.externalTurn?.cid === st.conversationId && st.externalTurn.startedAt * 1000;
  const guess = Date.now() - (+work.dataset.sec || 0) * 1000;
  if (recorded > 0 || st.elsewhereTurn?.key !== key) st.elsewhereTurn = { key, startAt: recorded || guess };
  else st.elsewhereTurn.startAt = Math.min(st.elsewhereTurn.startAt, guess);
  const d = durationText((Date.now() - st.elsewhereTurn.startAt) / 1000);
  label.textContent = d ? `在别处运行中 · 已 ${d}` : '在别处运行中';
  // 这一轮还在那边写着：记录读到这里像是「没写完」，末尾会带一条红色的「未完成」。它没断，只是还没写完，先不显示；
  // 不再有动静、标记撤掉之后（上面那段）它自然会重新出现。
  const lastStep = work.querySelector('.work-steps > .step:last-child');
  if (lastStep && lastStep.classList.contains('step-error') && lastStep.querySelector('.step-title')?.textContent === '未完成') lastStep.classList.add('pending-elsewhere');
  setElsewherePet(id, work);
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
    postNative('loadConversation', { agent: id, conversationId: st.conversationId, sync: true });
  }
  markElsewhere(id);   // 到时间了把标记撤掉
}, 3000);
// 标着的时候每秒走一下时间
setInterval(() => {
  AGENT_IDS.forEach(id => { if (id !== active && S[id].elsewherePet) setElsewherePet(id, null); });   // 换到别的位了
  if (!document.hidden && elsewhereOn(active)) markElsewhere(active);
  if (S[active].elsewherePet && typeof pets !== 'undefined') pets[active].renderStatus();   // 桌宠状态里的时长每秒走
}, 1000);
// 没在盯的时候，每 20 秒看一眼列表：打开着的会话在别处开始动了，就能发现
setInterval(() => { if (!document.hidden) refreshHistory(active,true); }, 20000);
