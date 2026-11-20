'use strict';

// 界面里不碰页面元素的纯逻辑：给定输入、算出结果。单独放在这里，tools/test-logic.mjs 不用开窗口就能测。
// 最先加载；chat/、ui/ 下的脚本调用它们。
//
// 实时、首次打开和切回共用这里的结局判定。
// 重试、桌宠和排队都读同一结局。
// 首次历史回包可能迟到，只有认领了本次请求，或正文和结局都已对上，才允许记录替换本地回答。
// 同文重问即使只改变结局也会更新。
// 历史的末轮边界由 `readElsewhereTurn` 接收；缺少边界时，明确失败或中断会立即撤标，仍可能继续写的旧记录保留活动期限。
//
// 四位助手的网页同步由 `planHistoryRows` 决定保留、插入和撤下哪些行。
// `historyAskMatches` 在首次回读、活动请求切回和增量同步里核对同一份提问身份。
// Claude 保留提问行 UUID，Codex 保留有效历史的回合编号，Gemini 使用数据库用户步骤的创建时间，DeepSeek 保留提问调用编号。
// 新提问的创建时间晚于本地结束时，首次同步就能识别同文重问。
// 提问身份变化时撤下整个旧后缀及其停止提示和重试。
// 缩略图显示字段变化只更新本行。
// 缺少编号的旧记录按提问、附件和已确认的回答核对，首次读到半截时保留本地结局。

function replyFingerprint(text) {
  // 实时错误提示可能比历史多一个警告符；只存长度和摘要，避免长回答挤掉本地补丁。
  const body = (text || '').trim().replace(/^⚠️?\s*/, '');
  let hash = 2166136261;
  for (let i = 0; i < body.length; i++) hash = Math.imul(hash ^ body.charCodeAt(i),16777619);
  return body.length + ':' + (hash >>> 0);
}

// 改动来自一次请求，只能由那次提问的回答认领。位置先走常数时间的路径；旧缓存没有编号时
// 仍按写入顺序从后往前配，但未匹配的旧分支不能占用位置或跨过下一问。
function matchExtras(list, messages, omitted = 0, onMatch) {
  const out = new Map();
  let limit = messages.length, byQuestion, byEnding;
  const questionOf = row => row?.role === 'user' ? row : row?.retryPrompt ? row.retryUser : undefined;
  // 页内位置变动或只剩异常补记时，明确的编号优先于同文同答；整页最多索引一次。
  function indexIdentities() {
    if (byQuestion) return;
    byQuestion = new Map();
    byEnding = new Map();
    messages.forEach((m,i) => {
      const key = questionOf(m)?.turnKey;
      if (key != null) byQuestion.set(key,i);
      if (m.endingReqId != null) byEnding.set(m.endingReqId,i);
    });
  }
  for (let k = list.length - 1; k >= 0; k--) {
    const ex = list[k], at = Number.isInteger(ex.at) ? ex.at - omitted : null;
    let identifiedAt, endingAt;
    if (ex.turnKey != null) {
      if (questionOf(messages[at])?.turnKey === ex.turnKey) identifiedAt = at;
      else { indexIdentities(); identifiedAt = byQuestion.get(ex.turnKey); }
    }
    if (identifiedAt == null && ex.reqId != null && canRetryOutcome(ex.outcome)) {
      indexIdentities();
      endingAt = byEnding.get(ex.reqId);
    }
    if (at < 0 && identifiedAt == null && endingAt == null) continue;
    const ask = ex.imageOnly !== undefined ? ex : {...ex, prompt:ex.text || '请看这张图片。', text:ex.images?.length ? '' : ex.text};
    const questionMatches = i => {
      const m = messages[i];
      if (m.role !== 'user') return m.role === 'bot' && historyAskMatches(ask,m);
      // 旧纯图缓存没有内容键；原位置只有内嵌图时沿用附件数和可见路径核对。
      if (ex.imageOnly === undefined && i === at && !ex.turnKey && (!ex.text || ex.images?.length)) {
        const images = (m.images || []).filter(im => !im.mentioned);
        if (images.length && (!m.text || m.text === (ex.text || '请看这张图片。')) &&
            (!ex.images || images.length === ex.images.length && images.every((im,n) => !im.path || im.path === ex.images[n]))) return true;
      }
      const candidate = !ex.images && !ex.imageRefs && m.images?.length ? {...m,images:[]} : m;
      const same = historyAskMatches(ask,candidate,messages[i+1]);
      return same === true || (same === null && i === at);
    };
    const answerAt = i => {
      const bot = historyReplyIndex(ex,messages,i);
      return bot < limit && (endingAt == null || endingAt === bot) && changeReplyMatches(ex,messages[bot]) ? bot : -1;
    };
    let question = identifiedAt ?? at, answer = -1;
    const atQuestion = question !== null && question >= 0 && question < limit && questionMatches(question);
    if (atQuestion) answer = answerAt(question);
    if (answer < 0 && identifiedAt == null && (!atQuestion || endingAt != null)) {
      let candidates = 0;
      for (let i = limit - 1; i >= 0; i--) {
        if (!questionMatches(i)) continue;
        const bot = answerAt(i);
        if (bot < 0) continue;
        const created = messages[i].createdAt * 1000;
        // 已知位置被占用的情况很常见。要改挂别处，须有请求编号，或有本轮时间范围内的提问。
        if (ex.reqId != null && at !== null && endingAt == null && !(created >= ex.since && created <= ex.endedAt)) continue;
        question = i;
        answer = bot;
        if (endingAt != null || ex.reqId == null) break;
        candidates++;
        if (candidates > 1) { answer = -1; break; }
      }
    }
    if (answer < 0) continue;
    out.set(answer,ex);
    const row = messages[question];
    onMatch?.(ex,row.role === 'bot' ? row.retryUser || row : row,omitted + question);
    limit = question;
  }
  return out;
}

function changeReplyMatches(owner, message) {
  if (message?.role !== 'bot') return false;
  if (owner.reqId != null && message.endingReqId != null) return owner.reqId === message.endingReqId;
  return (!owner.outcome || owner.outcome === (message.outcome || 'completed')) &&
    (!owner.replyKey || owner.replyKey === replyFingerprint(message.text));
}

// 只有旧实时回包需要从提示文字恢复结局；历史里正常回答也可能以警告符号开头。
function responseEnding(data) {
  const text = (data.reply || '').trim();
  const outcome = data.cancelled ? 'interrupted' : data.outcome || (text.startsWith('⚠️') ? 'failed' : 'completed');
  return {text, outcome, reqId:data.reqId};
}

function canRetryOutcome(outcome) {
  return outcome === 'failed' || outcome === 'interrupted' || outcome === 'incomplete';
}

// 正文相同的重问也可能有不同结局，两个入口必须用同一对字段确认已落盘。
function recordedTurnEnding(message, ending) {
  if (message?.role !== 'bot' || message.endingReqId == null || message.endingReqId !== ending.reqId) return false;
  const text = (message.text || '').trim();
  // 异常备份可能在字数上限截断，仍在窗口里的完整结尾要保留。
  return !(text.endsWith('…') && ending.text !== text && ending.text.length >= text.length && ending.text.startsWith(text.slice(0, -1)));
}

function matchesTurnEnding(message, ending) {
  return message?.role === 'bot' && (message.outcome || 'completed') === ending.outcome &&
    (message.text || '').trim() === ending.text;
}

/** 正文等长改写、步骤状态/输出变化也算更新，不能只比较数量。 */
function messageSignature(m) {
  const signature = stableStringify([m.role, m.text || '', m.steps || [], m.files || [], m.duration || 0, m.images || [], m.outcome || '']);
  if (m.role === 'user' && (m.turnKey || m.createdAt)) return signature + JSON.stringify([m.turnKey || '',m.createdAt || 0]);
  return m.retryUser || m.retryPrompt || m.endingReqId != null
    ? signature + stableStringify([m.retryUser || m.retryPrompt || '', m.endingReqId ?? null]) : signature;
}

/** 和 JSON.stringify 一样，但对象的字段按名字排序：同样的内容不管字段先后都得到同一串。
 *  原生发来的同一条消息，字段的先后每次都可能不同；拿它判断「内容变没变」不能受这个影响。 */
function stableStringify(v) {
  if (Array.isArray(v)) return '[' + v.map(stableStringify).join(',') + ']';
  if (v && typeof v === 'object') return '{' + Object.keys(v).sort().map(k => JSON.stringify(k) + ':' + stableStringify(v[k])).join(',') + '}';
  return JSON.stringify(v) ?? 'null';
}

// 外部重问可能发生在本地结束与首次同步之间。只有明确晚于本轮结束的提问才能划出后续历史。
function askedAfterRun(run, message, reply) {
  return message?.role === 'user' && Number.isFinite(run?.endedAt) &&
    Math.floor(message.createdAt * 1000) > run.endedAt &&
    !(run.reqId != null && reply?.endingReqId === run.reqId);
}

// 本地发送、切回和记录同步共用提问身份。缩略图、文件可用性和步骤只影响显示，不改变分支。
function historyAskMatches(ask, m, reply) {
  if (!ask || !m) return false;
  if (m.role !== 'user') {
    if (ask.role || !isCompactCommand(ask.text)) return false;
    // 成功的压缩只占一条提示；失败时命令被隐藏，历史只有带原命令的回答。
    if (m.role === 'compact') return !canRetryOutcome(ask.ending?.outcome);
    return m.role === 'bot' && isCompactCommand(m.retryPrompt) && (!ask.ending || canRetryOutcome(ask.ending.outcome)) &&
      (!m.retryUser || historyAskMatches(ask,m.retryUser,m));
  }
  const recorded = ask.role === 'user';
  if (ask.turnKey && m.turnKey) {
    if (ask.turnKey !== m.turnKey) return false;
    if (!recorded) return true;
  }
  if (!recorded && askedAfterRun(ask,m,reply)) return false;
  if (!recorded && Number.isFinite(m.createdAt) && (m.createdAt + 1) * 1000 <= ask.since &&
      !(ask.reqId != null && reply?.endingReqId === ask.reqId)) return false;
  const text = (m.text || '').trim();
  const paths = ask.images || [], refs = ask.imageRefs || [];
  const expectedText = (recorded ? ask.text : ask.prompt ?? ask.text) || '';
  const imageOnly = !recorded && (ask.imageOnly ?? !ask.text) && (paths.length || refs.length) && !text;
  if (!imageOnly && text !== expectedText.trim()) {
    // 单次 CLI 把当次实际送出的图片路径附在原问之后；重试恢复的图片仍按原发送顺序插回。
    if (recorded || (!paths.length && !refs.length)) return false;
    const sent = paths.map(p => ask.sentPaths?.[p] || p);
    refs.forEach((ref,i) => sent.splice(ref.index ?? sent.length,0,ask.restoredPaths?.[i]));
    return sent.every(Boolean) && text === expectedText.trim() + '\n\n' + sent.join('\n');
  }
  if (!paths.length && !refs.length && !m.images?.length) return true;
  const saved = (m.images || []).filter(im => !im.mentioned);
  const expected = recorded ? paths.filter(im => !im.mentioned) : paths.map(path => ({path}));
  refs.forEach((ref, i) => expected.splice(ref.index ?? expected.length, 0, {ref, path:ask.restoredPaths?.[i]}));
  if (expected.length !== saved.length) return false;
  const reencoded = !recorded && ['claude','gemini'].includes(ask.agent) && m.createdAt * 1000 >= ask.since;
  const pathOf = im => im.path || im.ref?.path || im.ref?.id?.replace(/#\d+(@[^/]*)?$/, '');
  let comparable = true;
  const compatible = expected.every((im, i) => {
    const other = saved[i], key = im.imageKey || ask.imageKeys?.[i];
    if (key && other.imageKey) return key === other.imageKey || (reencoded && other.ref?.agent === ask.agent);
    if (im.ref?.id && other.ref?.id && im.ref.id === other.ref.id &&
        im.ref.agent === other.ref.agent && im.ref.conversationId === other.ref.conversationId) return true;
    if (!recorded && im.path && [other.path, other.snapshot, other.ref?.path].some(path =>
      path && (path === im.path || path === ask.sentPaths?.[im.path]))) return true;
    if ((!pathOf(im) && !key) || (!pathOf(other) && !other.imageKey)) {
      comparable = false;
      return true;
    }
    if (im.ref && other.ref && (recorded || im.ref.agent !== 'gpt')) return false;
    const path = pathOf(im);
    return !!path && (path === pathOf(other) || (im.ref?.agent === 'gpt' && pathOf({ref:im.ref}) === other.path));
  });
  // 缺少可比身份时不能截掉历史，也不能据此撤下本地的重试。
  return compatible && !comparable ? null : compatible;
}

function liveHistoryCut(run, messages, omitted = 0) {
  if (!Number.isInteger(run.historyStart)) return -1;
  const at = run.historyStart - omitted;
  return historyAskMatches(run, messages[at], messages[at+1]) ? at : -1;
}

// agy 和 dsh 偶尔把消费过的补充另存成一问一答；末段也要核对，免得吞掉同文的独立后问。
function historyReplyIndex(run, messages, at) {
  if (messages[at]?.role !== 'user') return at;
  let end = at + 1;
  if (!run?.supplements?.length || !['gemini','deepseek'].includes(run.agent)) return end;
  const first = end;
  let stepStart = 0;
  const stepIndex = (m,key,start) => m?.steps?.findIndex((s,i) =>
    i >= start && s?.kind === 'user' && replyFingerprint(s.detail) === key) ?? -1;
  for (const key of run.supplements) {
    const current = messages[end], inline = stepIndex(current,key,stepStart);
    if (inline >= 0) { stepStart = inline + 1; continue; }
    // 有的历史还没写首段回答就收到补充；dsh 也可能连续给出两段 bot，只在步骤里留补充。
    const nextAt = current?.role === 'bot' ? end + 1 : end, next = messages[nextAt];
    if (next?.role === 'user' && replyFingerprint(next.text) === key && !askedAfterRun(run,next,messages[nextAt+1])) {
      end = nextAt + 1;
      stepStart = stepIndex(messages[end],key,0) + 1;
    } else if (next?.role === 'bot') {
      const index = stepIndex(next,key,0);
      if (index >= 0) { end = nextAt; stepStart = index + 1; }
    }
  }
  if (end === first) return first;
  const owner = run.ending ? {reqId:run.ending.reqId,replyKey:replyFingerprint(run.ending.text),outcome:run.ending.outcome} : run;
  return (owner.replyKey || owner.reqId != null && owner.reqId === messages[end]?.endingReqId) &&
    changeReplyMatches(owner,messages[end]) ? end : first;
}

// 首次回包可能覆盖本页的前几轮。从记录末尾找可以连续对齐的序列；连续同文用已知结局消歧，
// 没有更多证据时取最近的起点，防止把之前问过的「继续」截掉。
function localAsksInHistory(asks, messages, readAt, omitted = 0) {
  if (!asks.length) return [];
  let candidates = 0, best = [], bestScore = -1;
  const limit = asks.reduce((n, run) => n + 1 + (run.supplements?.length || 0), 0);
  for (let p = messages.length - 1; p >= 0; p--) {
    if (messages[p].role !== 'user' && !historyAskMatches(asks[0],messages[p])) continue;
    if (++candidates > limit) break;
    const matched = [];
    let at = p, score = 0;
    for (const run of asks) {
      if (run.since > readAt ||
          (Number.isInteger(run.historyStart) && run.historyStart !== at + omitted) ||
          !historyAskMatches(run,messages[at],messages[at+1])) break;
      matched.push(at);
      const reply = historyReplyIndex(run,messages,at);
      if (run.ending && (matchesTurnEnding(messages[reply],run.ending) || recordedTurnEnding(messages[reply],run.ending))) score++;
      at = reply === at ? at + 1 : reply;
      const next = asks[matched.length];
      while (at < messages.length && messages[at].role !== 'user' && !historyAskMatches(next,messages[at])) at++;
      if (at === messages.length) {
        if (score > bestScore) { best = matched; bestScore = score; }
        break;
      }
    }
  }
  return best;
}

// 先决定哪些显示节点属于记录的同一轮，再动页面。确认过的记录被截短或换问时，整个旧后缀一起撤下；
// 首次只读到半轮时，本地回答和重试仍属这个页面。首次打开、补充回读和后台同步遵守同一规则。
function planHistoryRows(shown, messages, {start = 0, end = messages.length, signatures, afterSteer, opening, agent, extras} = {}) {
  const changes = [];
  let at = start, j = 0, askAt = -1, anchored = false;
  for (; j < shown.length; j++) {
    const old = shown[j];
    if (at >= end) {
      if (old.local && !old.confirmed) continue;
      break;
    }
    let m = messages[at];
    let split = false, unknownAsk = false;
    if (old.role === 'bot' && old.supplements?.length && messages[at-1]?.role === 'user') {
      const reply = historyReplyIndex({agent,supplements:old.supplements,ending:old.ending,endedAt:old.endedAt},messages,at-1);
      split = reply > at && reply < end;
      while (split && at < reply) changes.push({kind:'insert', at:at++, j});
      m = messages[at];
    }
    if (old.role !== m.role) {
      if (old.role === 'user' && m.role === 'bot' && historyAskMatches(old.run,m)) {
        changes.push({kind:'remove',j});   // 原命令仍在失败回答的重试按钮上。
        askAt = at;
        continue;
      }
      // 一轮停得早，CLI 可能只记提问就开始下一问。本地答案留在原问下，后问继续对齐。
      if (m.role === 'user' && old.role === 'bot' && old.local && !old.confirmed && askAt >= 0 && askAt === at - 1) {
        changes.push({kind:'gap',j});
        continue;
      }
      break;
    }
    if (old.role === 'user') {
      const ask = old.ask || old.run;
      const same = ask && historyAskMatches(ask,m,messages[at+1]);
      if (same === false) break;
      unknownAsk = !!ask && same === null && old.local;
      askAt = at;
      anchored = !!(old.ask?.turnKey && m.turnKey);
    }
    const sig = signatures ? signatures[at] : messageSignature(m);
    let replace = sig !== old.sig && !unknownAsk;
    if (old.local && old.role === 'bot') {
      const ending = old.ending;
      const matches = matchesTurnEnding(m,ending), owns = recordedTurnEnding(m,ending);
      const sameRequest = m.endingReqId != null && m.endingReqId === ending.reqId;
      const reread = (afterSteer || split) && !canRetryOutcome(ending.outcome);
      if ((matches || owns) && !old.confirmed) {
        changes.push({kind:'confirm',j});
      }
      if (sameRequest && !owns) replace = false;   // 本地仍有全文，磁盘补记截短了。
      else if (matches) {
        replace = opening || (replace && reread);
      } else if (!owns && !old.confirmed) replace = reread;
      else if (!owns && !anchored && old.confirmed) {
        // 无编号的旧记录只能拿已落盘的定稿作证。正文接着写长时，后面的未落盘节点仍归本页。
        const text = (m.text || '').trim();
        const rewritten = ending.text && text && !text.startsWith(ending.text) && !ending.text.startsWith(text);
        if (m.outcome && m.outcome !== 'inProgress' && (rewritten || m.outcome !== ending.outcome)) break;
      }
    }
    if (old.local && old.role === 'compact') {
      changes.push({kind:'confirm',j});
      replace = false;
    }
    if (extras && old.role === 'bot' && (!old.local || old.confirmed) && old.extra !== extras.get(at)) replace = true;
    if (replace) changes.push({kind:'replace', at, j});
    at++;
  }
  for (; j < shown.length; j++) changes.push({kind:'remove',j});
  for (; at < end; at++) changes.push({kind:'append',at});
  return changes;
}

/** 这句话是不是「压缩上下文」的命令（各家叫 /compact 或 /compress）。它不是一轮对话：界面上显示成一条提示，不显示成一问一答。 */
function isCompactCommand(text) {
  return /^\/(compact|compress)$/.test((text || '').trim());
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
  return { uncertain: '送达状态待确认，不会自动重发', sending: '正在送过去…', sent: '已经送到，它做完手头这一步就会看到', waiting: '排着，这一轮结束后自动发' }[state] || '';
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
