'use strict';

// 界面里不碰页面元素的纯逻辑：给定输入、算出结果。单独放在这里，tools/test-logic.mjs 不用开窗口就能测。
// 最先加载；chat/、ui/ 下的脚本调用它们。

/**
 * 重新渲染一个会话时：哪几条回答是这次运行里答的。list 是记下的那几轮（旧的在前，每个有 text = 那一轮的提问），
 * 按回答前面那句提问来认，从后往前配，同一句话问过两次也各配各的。返回 Map：回答在 messages 里的下标 → 那一轮。
 */
function matchExtras(list, messages) {
  const out = new Map();
  let limit = messages.length;
  for (let k = list.length - 1; k >= 0; k--) {
    const ex = list[k];
    let j = limit - 1;
    while (j >= 0 && !(messages[j].role === 'user' && (messages[j].text || '').trim() === ex.text)) j--;
    if (j < 0) continue;
    const bot = messages.findIndex((m, i) => i > j && m.role !== 'user');
    if (bot > j) out.set(bot, ex);
    limit = j;
  }
  return out;
}

/**
 * 切回窗口时的同步：页面上已有的消息（shownIsUser：每条是不是用户说的）和 CLI 记录里的 messages 对不对得上。
 * 返回要接在后面的条数（0 = 一模一样，什么都不用动）；-1 = 对不上，得整段重画。
 */
function syncPlan(shownIsUser, messages) {
  if (!shownIsUser.length || messages.length < shownIsUser.length) return -1;
  if (shownIsUser.some((isUser, i) => (messages[i].role === 'user') !== isUser)) return -1;
  return messages.length - shownIsUser.length;
}

/** 发过的话里加一句：和已有的重复就挪到最后，最多留 50 句。 */
function pushPrompt(list, text) {
  return [...list.filter(p => p !== text), text].slice(-50);
}

/**
 * 空输入框按 ↑ / ↓ 翻发过的话。at：现在翻到第几句（-1 = 没在翻）；value：输入框里的内容；dir：-1 往前（更早），1 往后。
 * 返回 null = 这次按键不归它管（自己打了字，或者没在翻的时候按 ↓）；否则 { at, value }。
 */
function promptStep(list, at, value, dir) {
  const browsing = at >= 0 && value === list[at];
  if (!browsing && (value || dir > 0)) return null;
  if (!list.length) return null;
  let next = browsing ? at + dir : list.length - 1;
  if (next < 0) next = 0;
  if (next >= list.length) return { at: -1, value: '' };
  return { at: next, value: list[next] };
}

/** 整句是「/几个字」（还没打空格）：返回斜杠后面的字；不是就返回 null。 */
function slashQuery(value) {
  const m = value.match(/^\/([\w:.-]*)$/);
  return m ? m[1] : null;
}

/** 光标前是「@几个字」：返回 { q, start }（start = @ 在整段文字里的位置）；不是就返回 null。邮箱里的 @ 不算。 */
function mentionQuery(before) {
  const m = before.match(/(?:^|\s)@([^\s@]*)$/);
  return m ? { q: m[1], start: before.length - m[1].length - 1 } : null;
}

/** 命令按输入的字筛：名字以它开头的在前，其次名字里有它的。最多 12 个。 */
function rankCommands(all, q) {
  const s = q.toLowerCase();
  const starts = all.filter(c => c.name.toLowerCase().startsWith(s));
  const has = all.filter(c => !c.name.toLowerCase().startsWith(s) && c.name.toLowerCase().includes(s));
  return [...starts, ...has].slice(0, 12);
}

/** CLI 新报上来的命令列表：这次没带说明的，沿用以前记下的说明。 */
function mergeCommands(old, fresh) {
  const desc = new Map(old.map(c => [c.name, c.desc || '']));
  return fresh.map(c => ({ name: c.name, desc: c.desc || desc.get(c.name) || '' }));
}

/** 匀速显示：还差 left 个字、离上一帧过了 dt 毫秒，这一帧再放出几个字。差得多放得快（约半秒追上），至少放 1 个。 */
function revealStep(left, dt) {
  return left > 0 ? Math.max(1, Math.ceil(left * Math.min(300, dt) / 450)) : 0;
}

/**
 * 一轮回答结束时，还排着的话怎么办：'send' 接着发；'restore' 放回输入框。
 * 被停止的、出错的、已经切到别的会话的、那个会话又在回答的：不自动发——除非是点「立即发送」插队才停下来的（jump）。
 */
function queueAction({ cancelled, failed, here, busy, jump }) {
  if (!here || busy) return 'restore';
  if (jump) return 'send';
  return cancelled || failed ? 'restore' : 'send';
}

/** 排着的气泡下面那行字。 */
function queuedLabel(state, held, jump) {
  if (jump) return '正在停下手头的事，马上发…';
  if (held) return '已经送到；它手头的命令跑完才会看到';
  return { sending: '正在送过去…', sent: '已经送到，它做完手头这一步就会看到', waiting: '排着，这一轮结束后自动发' }[state] || '';
}

/**
 * 模型菜单跟着 CLI 走：fresh 是 CLI 刚报上来的模型（{ v, name, desc, efforts }），builtin 是 App 里写死的那份。
 * 结果以 CLI 的为准；写死的那份只用来补说明，以及保留标了 keep 的条目（CLI 不单独列出来的变体，比如 1M 上下文的 Opus）。
 * validEfforts：界面认得的思考强度。
 */
function mergeModels(builtin, fresh, validEfforts) {
  const known = new Map(builtin.map(m => [m.v, m]));
  const seen = new Set();
  const usable = fresh.filter(m => m && typeof m.v === 'string' && m.v && !seen.has(m.v) && seen.add(m.v));   // 没有名字的、重复的不要
  const list = usable.map(m => {
    const old = known.get(m.v) || {};
    const efforts = Array.isArray(m.efforts) && m.efforts.length ? m.efforts.filter(e => validEfforts.includes(e)) : old.efforts;
    const out = { v: m.v, name: m.name || old.name || m.v };
    if (m.desc || old.tip) out.tip = m.desc || old.tip;
    if (efforts && efforts.length) out.efforts = efforts;
    if (m.fast) { out.fast = true; if (m.fastDesc) out.fastDesc = m.fastDesc; }   // 有 fast 档的模型
    return out;
  });
  const kept = builtin.filter(m => m.keep && !list.some(x => x.v === m.v));
  return [...kept, ...list];
}

/**
 * 把一段高度分给几格：先按比例分；哪一格要的（need）比分到的少，就只给它要的那么多，
 * 省下的再按比例分给还不够的格，直到分完。返回每格的高度（够用的格 = need，不够的格 = 按比例分到的）。
 */
function fitSections(need, weights, total) {
  const heights = need.map(() => 0);
  let open = need.map((_, i) => i), free = total;
  for (;;) {
    const wsum = open.reduce((s, i) => s + weights[i], 0);
    const fits = open.filter(i => need[i] <= free * weights[i] / wsum);
    if (!fits.length) break;
    fits.forEach(i => { heights[i] = need[i]; free -= need[i]; });
    open = open.filter(i => !fits.includes(i));
    if (!open.length) return heights;
  }
  const wsum = open.reduce((s, i) => s + weights[i], 0);
  open.forEach(i => { heights[i] = free * weights[i] / wsum; });
  return heights;
}

/**
 * 选模型那一页怎么分：每个系列里 CLI 排在最前面的那个（最新的）直接列出来，同一个系列后面的旧版本收进「更多模型」。
 * 系列 = 名字去掉版本号（「Fable 5.2」和「Fable 5.1」都是 Fable，「Gemini 4 Argon」是 Gemini Argon）。
 * 「默认」只是另一个模型的别名，也放在更多里。
 */
function splitModels(models) {
  const family = m => String(m.name || m.v).split(' ').filter(w => !/^[\d.]+$/.test(w)).join(' ');
  const main = [], more = [];
  models.forEach(m => {
    if (m.v === 'default') more.unshift(m);
    else if (!main.some(x => family(x) === family(m))) main.push(m);
    else more.push(m);
  });
  return main.length ? { main, more } : { main: models, more: [] };
}

/** 选着的模型不在新列表里了：按别名换成对应的（比如旧的 Fable 条目 → CLI 的 fable），没有对应的就用 fallback。 */
function migrateModel(current, list, aliases, fallback) {
  if (list.some(m => m.v === current)) return current;
  const alias = aliases[current];
  if (alias && list.some(m => m.v === alias)) return alias;
  return list.some(m => m.v === fallback) ? fallback : (list[0] ? list[0].v : current);
}
