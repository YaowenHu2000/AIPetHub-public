'use strict';

// 克劳蒂娜的会话正开在别的程序里（Claude 桌面端、终端里的 claude）时，在这里发话会「分叉」：
// 带着到这一刻为止的记录另开一个会话，有自己的编号，之后和那边互不相通（原生：ClaudeSessions.swift）。
// 不分叉的话，同一个会话上会有两个互相看不到的副本，各干各的，记录也搅在一起。
//   · 发之前：输入框上面一行提示，说明在这里发会另开一个分支；
//   · 发出后：聊天区里一行说明，左栏里新会话带「分支」标记，当前会话自动换成它；原来那个留在列表里，继续跟着那边更新。

const convForks = lsJson('conv_forks', {});          // `${agent}:${新会话}` → 原会话
const liveElsewhere = {};                            // `${agent}:${会话}` → { status, name, at }
const forkKey = (id, cid) => `${id}:${cid}`;
const isFork = (id, cid) => !!convForks[forkKey(id, cid)];

const forkHint = (() => {
  const el = document.createElement('div');
  el.id = 'fork-hint';
  el.hidden = true;
  const composer = document.getElementById('composer');
  composer.insertBefore(el, composer.firstChild);
  return el;
})();

function renderForkHint() {
  const st = S[active];
  const live = st.conversationId && !viewBusy(active) ? liveElsewhere[forkKey(active, st.conversationId)] : null;
  const on = !!live && Date.now() - live.at < 30000;
  forkHint.hidden = !on;
  if (on) {
    forkHint.textContent = `会话正在其他客户端${live.status === 'busy' ? '运行' : '打开'} · 发送将创建分支会话`;
    forkHint.title = `该会话当前由其他客户端持有${live.name ? `（${live.name}）` : ''}。在此发送的消息将基于现有记录创建一个独立的分支会话，后续内容不与原会话同步；两个会话可能各自修改工作区文件。`;
  }
}

/** 看着的这个会话是不是在别处开着：问原生（它用 CLI 自己的清单查，零点几秒）。 */
function askSessionLive() {
  const st = S[active];
  if (active !== 'claude' || !st.conversationId || st.loadedId !== st.conversationId || viewBusy(active)) { renderForkHint(); return; }
  postNative('checkSessionLive', { agent: active, conversationId: st.conversationId });
}

window.onSessionLive = data => {
  const key = forkKey(data.agent, data.conversationId);
  if (data.live) liveElsewhere[key] = { status: data.status, name: data.name, at: Date.now() };
  else delete liveElsewhere[key];
  if (data.live && typeof watchElsewhere === 'function' && S[data.agent].conversationId === data.conversationId) watchElsewhere(data.agent);   // 那边开着：盯着它的新内容
  renderForkHint();
};

/** 原生决定分叉了（这句话发出去的那一刻会话还在别处开着）。 */
window.onAgentForked = data => {
  const id = data.agent;
  const run = S[id]?.runs.get(data.reqId);
  if (!run) return;
  run.forkFrom = data.from;
  const note = document.createElement('div');
  note.className = 'msg sys fork-note';
  note.textContent = '已创建分支会话 · 原会话仍在其他客户端运行';
  note.title = `原会话当前由其他客户端持有${data.name ? `（${data.name}）` : ''}。本条消息基于现有记录创建了独立的分支会话，后续内容不与原会话同步。`;
  const first = run.nodes && run.nodes[0];
  if (first && first.isConnected) first.parentNode.insertBefore(note, first);
  if (run.nodes) run.nodes.unshift(note);
  forkHint.hidden = true;
};

/** 分叉出来的新会话有编号了：记下它是从哪个分出来的（native-callbacks.js 的 onAgentConversation 里叫）。 */
function noteFork(id, run, cid) {
  if (!run.forkFrom || cid === run.forkFrom) return;
  convForks[forkKey(id, cid)] = run.forkFrom;
  const keys = Object.keys(convForks);
  if (keys.length > 300) keys.slice(0, keys.length - 300).forEach(k => delete convForks[k]);   // 只留最近的
  lsSet('conv_forks', JSON.stringify(convForks));
}

setInterval(() => { if (!document.hidden) askSessionLive(); }, 8000);
setInterval(renderForkHint, 1000);   // 切到别的会话 / 别的一位、开始回答时马上收起
