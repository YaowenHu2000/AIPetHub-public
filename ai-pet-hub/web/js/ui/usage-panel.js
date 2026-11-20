'use strict';

// 模型面板下半截的两块：这个会话的上下文用了多少、剩余用量；数据都由原生推过来，这里只记下和显示。

// ===== 这个会话的上下文用了多少、是什么占的（模型面板里，剩余用量上面）：原生在每一轮答完后报过来（Usage.swift 的 noteContext） =====
const agentContext = lsJson('context_usage', {});   // "谁:会话 ID" → { used, max, parts, estimated }
const tokenLabel = n => (n >= 1e6 ? `${+(n / 1e6).toFixed(n % 1e6 ? 1 : 0)}M` : n >= 1000 ? `${+(n / 1000).toFixed(n < 10000 ? 1 : 0)}k` : String(n));
// 各家报上来的分类 → 给人看的名字和颜色（没见过的分类用它自己的名字、轮着取颜色）
const CONTEXT_PARTS = {
  messages: ['对话内容', '#7aa2ff'], system_prompt: ['系统提示词', '#b79cff'], system: ['系统提示词', '#b79cff'],
  system_tools: ['内置工具的说明', '#5fd0c5'], tools: ['工具的说明', '#5fd0c5'], mcp_tools: ['MCP 工具的说明', '#f2a65a'], mcp_instructions: ['MCP 服务的说明', '#e8875a'],
  memory_files: ['记忆文件', '#f58fb1'], skills: ['技能', '#ffd166'], custom_agents: ['自定义智能体', '#9be28a'],
  cached_input: ['带进去的（缓存里已有）', '#7aa2ff'], new_input: ['带进去的（新的）', '#5fd0c5'], output: ['这一次答出来的', '#ffd166'],
  autocompact_buffer: ['留给自动压缩', 'rgba(255, 255, 255, 0.22)'],
};
const CONTEXT_SPARE = ['#7aa2ff', '#5fd0c5', '#ffd166', '#f58fb1', '#b79cff', '#f2a65a', '#9be28a'];
const contextPart = (p, i) => { const known = CONTEXT_PARTS[p.id]; return { ...p, name: known ? known[0] : (p.name || p.id), color: known ? known[1] : CONTEXT_SPARE[i % CONTEXT_SPARE.length] }; };

/** 这一位能不能主动压缩上下文、用哪条命令：Claude、Codex、DeepSeek 都是 /compact；Gemini（agy）看它报上来的命令里有没有，有就照发。 */
function compactCommand(id) {
  if (id === 'claude' || id === 'gpt' || id === 'deepseek') return 'compact';
  return ((agentCommands[id] || []).find(c => /^(compact|compress)$/.test(c.name)) || {}).name || '';
}

function renderContext(box, id) {
  if (!S[id].conversationId) return;
  const data = agentContext[`${id}:${S[id].conversationId}`];
  const cmd = compactCommand(id);
  if (!data && !cmd) return;
  const sep = document.createElement('div');
  sep.className = 'pop-sep';
  const wrap = document.createElement('div');
  wrap.className = 'usage-box ctx-box';
  const title = elSpan('pop-title usage-title', '这个会话的上下文');
  if (cmd) {
    const b = document.createElement('button');
    b.className = 'ctx-compact';
    b.textContent = '压缩';
    b.title = viewBusy(id) ? '还在回答，等这一轮结束再压缩' : `把前面的对话压缩成摘要，腾出上下文空间（发一句 /${cmd}）`;
    b.disabled = viewBusy(id);
    b.addEventListener('click', e => { e.stopPropagation(); if (viewBusy(id)) return; closePopover(); startRun(id, `/${cmd}`, []); });
    title.appendChild(b);
  }
  wrap.appendChild(title);
  box.append(sep, wrap);
  if (!data) { wrap.appendChild(elSpan('usage-note', '这个会话答完一轮后显示用了多少')); return; }

  const pct = Math.min(100, Math.round(data.used / data.max * 100));
  const parts = (data.parts || []).filter(p => p.tokens > 0).map(contextPart);
  const used = parts.filter(p => p.kind !== 'buffer').sort((a, b) => b.tokens - a.tokens), buffer = parts.filter(p => p.kind === 'buffer');
  const row = document.createElement('div');
  row.className = 'usage-row';
  const bar = document.createElement('span');
  bar.className = 'usage-bar' + (pct >= 92 ? ' low' : pct >= 80 ? ' mid' : '');   // 这里是用得越多越该提醒
  const fill = document.createElement('i');
  fill.style.width = `${Math.max(2, pct)}%`;
  bar.appendChild(fill);
  row.title = pct >= 80 ? '快满了：可以点「压缩」把前面的对话压缩成摘要' : '';
  row.append(elSpan('usage-label', `已用 ${pct}%`), bar, elSpan('usage-reset', `${tokenLabel(data.used)} / ${tokenLabel(data.max)}`));
  wrap.appendChild(row);
  if (used.length) {
    // 已用的这些是什么占的：一条分段的条（整条 = 已用的全部，每一类一段），下面从多到少一行一类
    const mix = document.createElement('div');
    mix.className = 'ctx-mix';
    used.forEach(p => { const seg = document.createElement('i'); seg.style.flex = `${p.tokens} 1 0px`; seg.style.background = p.color; seg.title = p.name; mix.appendChild(seg); });
    wrap.appendChild(mix);
  }
  [...used, ...buffer].forEach(p => {
    const line = document.createElement('div');
    line.className = 'ctx-part' + (p.kind === 'buffer' ? ' spare' : '');
    const dot = document.createElement('i');
    dot.style.background = p.color;
    const share = p.tokens / data.max * 100;
    line.append(dot, elSpan('ctx-name', p.name), elSpan('ctx-tokens', tokenLabel(p.tokens)), elSpan('ctx-share', share >= 10 ? `${Math.round(share)}%` : share >= 0.1 ? `${share.toFixed(1)}%` : '<0.1%'));
    wrap.appendChild(line);
  });
  if (!used.length && data.history && data.estimated) wrap.appendChild(elSpan('usage-note ctx-note', '根据会话记录估算'));
  if (used.length && data.estimated) wrap.appendChild(elSpan('usage-note ctx-note', '各项是估算的，加起来和已用的不完全相等'));
}

window.onAgentContext = function (data) {
  if (!data || !AGENTS[data.agent] || !data.conversationId || !(data.max > 0)) return;
  const key = `${data.agent}:${data.conversationId}`, parts = Array.isArray(data.parts) ? data.parts : [];
  const old = agentContext[key], history = !!data.history;
  const at = data.at || (history ? 0 : Date.now());
  const bySeq = data.seq != null && old?.seq != null;
  if (!history && old?.history && (bySeq ? data.seq < old.seq : at < old.at)) return;
  if (history && old) {
    // 旧版只存实时数字。首次遇到历史时记下比较起点，保住已有明细。
    if (old.at == null) {
      Object.assign(old, { at, seq: data.seq });
      lsSet('context_usage', JSON.stringify(agentContext));
      return;
    }
    const newer = bySeq ? data.seq > old.seq : at > old.at;
    if (!newer) return;
  }
  // 实时通知有时分两次给出明细；不同轮次的历史估算只能展示本条记录里的分项。
  agentContext[key] = { used: data.used, max: data.max, parts: history || old?.history || parts.length ? parts : (old?.parts || []),
    estimated: !!data.estimated, history, at, seq: data.seq };
  const keys = Object.keys(agentContext);
  if (keys.length > 60) keys.slice(0, keys.length - 60).forEach(k => delete agentContext[k]);   // 只留最近的几十个会话
  lsSet('context_usage', JSON.stringify(agentContext));
  if (data.agent === active && S[active].conversationId === data.conversationId &&
      pop?.anchor === els.chipModel && modelView === 'panel') showModelView('panel');
};

// ===== 剩余用量（模型面板最下面）：原生在后台每 5 分钟查一次（Usage.swift），查到就推过来，这里只管显示 =====
const agentUsage = {};   // id → { items, error }

function renderUsage(box, id) {
  const sep = document.createElement('div');
  sep.className = 'pop-sep';
  const wrap = document.createElement('div');
  wrap.className = 'usage-box';
  wrap.dataset.agent = id;
  box.append(sep, wrap);
  fillUsage(wrap, id);
}

/** 「3 小时 20 分后」「周五 15:25」这样的重置时间。 */
function usageResetLabel(secs) {
  const ms = secs * 1000 - Date.now();
  if (!(ms > 0)) return '';
  const mins = Math.round(ms / 60000);
  if (mins < 60) return `${mins} 分钟后重置`;
  if (mins < 24 * 60) return `${Math.floor(mins / 60)} 小时 ${mins % 60} 分后重置`;
  const d = new Date(secs * 1000);
  return `周${'日一二三四五六'[d.getDay()]} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')} 重置`;
}

function fillUsage(wrap, id) {
  const data = agentUsage[id];
  wrap.innerHTML = '';
  const title = elSpan('pop-title usage-title', '剩余用量');
  if (data && data.at) {
    const mins = Math.max(0, Math.round((Date.now() / 1000 - data.at) / 60));
    title.appendChild(elSpan('usage-age', mins < 1 ? '刚刚更新' : mins < 60 ? `${mins} 分钟前更新` : `${Math.floor(mins / 60)} 小时前更新`));
  }
  wrap.appendChild(title);
  if (!data) { wrap.appendChild(elSpan('usage-note', '正在查…')); return; }
  if (!data.items.length) { wrap.appendChild(elSpan('usage-note', data.error || '没有用量信息')); return; }
  data.items.forEach(it => {
    const row = document.createElement('div');
    row.className = 'usage-row';
    row.appendChild(elSpan('usage-label', it.label));
    if (typeof it.left === 'number') {
      const bar = document.createElement('span');
      bar.className = 'usage-bar' + (it.left <= 10 ? ' low' : it.left <= 30 ? ' mid' : '');
      const fill = document.createElement('i');
      fill.style.width = `${it.left}%`;
      bar.appendChild(fill);
      row.append(bar, elSpan('usage-left', `${it.left}%`), elSpan('usage-reset', it.resetsAt ? usageResetLabel(it.resetsAt) : ''));
    } else {
      row.appendChild(elSpan('usage-text', it.text || ''));
    }
    wrap.appendChild(row);
  });
}

window.onAgentUsage = function (data) {
  if (!data || !AGENTS[data.agent]) return;
  // 这次没查到、但之前查到过：留着之前的
  if (!(data.items || []).length && agentUsage[data.agent]?.items.length) return;
  agentUsage[data.agent] = { items: data.items || [], error: data.error || '', at: data.at || 0 };
  const wrap = els.popover.querySelector(`.usage-box[data-agent="${data.agent}"]`);
  if (wrap && !els.popover.hidden) { fillUsage(wrap, data.agent); positionPopover(); }
};
