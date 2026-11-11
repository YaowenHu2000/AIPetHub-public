'use strict';

// 本地存储、三位各自的状态（S）、正在进行的回答（run）的查询、和原生通信的入口。

// ===== 本地存储（失败时退回默认值） =====
function lsGet(key, fallback = null) {
  try {
    const v = localStorage.getItem('aihub_' + key);
    return v === null ? fallback : v;
  } catch (_) { return fallback; }
}
function lsSet(key, value) {
  try {
    if (value === '' || value === null || value === undefined) localStorage.removeItem('aihub_' + key);
    else localStorage.setItem('aihub_' + key, String(value));
  } catch (_) { /* 忽略 */ }
}
function lsJson(key, fallback) {
  try { return JSON.parse(lsGet(key)) ?? fallback; } catch (_) { return fallback; }
}

// 上次 CLI 报上来的模型列表（记在本地）：一打开就是最新的，不用等这次再报
ALL_AGENT_IDS.forEach(id => {
  const saved = lsJson(`${id}_models`, null);
  if (Array.isArray(saved) && saved.length && saved.every(m => m && typeof m.v === 'string')) AGENTS[id].models = saved;
});
const pick = (options, value, fallback) => (options.some(o => o.v === value) ? value : fallback);
const find = (options, value) => options.find(o => o.v === value) || options[0];
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

const S = {};
ALL_AGENT_IDS.forEach(id => {
  const c = AGENTS[id];
  S[id] = {
    model: pick(c.models, MODEL_ALIASES[lsGet(`${id}_model`)] || lsGet(`${id}_model`), c.model),
    effortByModel: lsJson(`${id}_efforts`, {}),   // 每个模型各自记住的思考强度
    effort: '',                                   // 当前模型的思考强度（由 effortOf 算出）
    fast: lsGet(`${id}_fast`) === '1',            // 开着 fast（只对有 fast 档的模型起作用，见 fastOn）
    perm: pick(c.perms, lsGet(`${id}_perm`), c.perm),
    skin: pick(c.skins, lsGet(`${id}_skin`), c.skin),
    autoSleep: parseInt(pick(SLEEP_OPTIONS, lsGet(`${id}_autosleep`), '45'), 10),
    workspace: lsGet(`${id}_workspace`, ''),
    addedWs: lsJson(`${id}_added_ws`, []),        // 在左栏用 📁 打开过的工作空间：[{ path, ts }]
    conversationId: lsGet(`${id}_conv`, ''),
    roam: lsGet(`${id}_roam`) === '1',
    groupState: lsJson(`${id}_groups`, {}),   // 工作空间分组：1 = 折叠，0 = 展开
    expanded: new Set(),                     // 已点「查看全部」的分组
    conversations: null,
    loadedId: null,
    applyCwdOnLoad: false,
    runs: new Map(),          // 正在进行的回答：reqId → run（同一位可以同时在好几个会话里回答）
    newView: 'new:0',         // 当前新对话的临时编号（还没有会话 ID 时用）
    unread: false, unreadConvs: new Set(), draft: lsGet(`${id}_draft`, ''), pendingTitle: '',   // 没发出去的草稿重启后还在
    msgEl: null,
  };
  // 旧版只存了一个思考强度：记到当前模型上
  const legacy = lsGet(`${id}_effort`);
  if (legacy) {
    if (!S[id].effortByModel[S[id].model]) S[id].effortByModel[S[id].model] = legacy;
    lsSet(`${id}_efforts`, JSON.stringify(S[id].effortByModel));
    lsSet(`${id}_effort`, '');
  }
  if (!Array.isArray(S[id].addedWs)) S[id].addedWs = [];
  S[id].effort = effortOf(id, S[id].model);
});

// 一次性：克劳蒂娜改成默认 Opus 5.5 + 思考强度高（之后用户自己改的会保留）
if (lsGet('claude_default_v2') !== '1') {
  S.claude.model = 'claude-opus-5-5';
  S.claude.effortByModel['claude-opus-5-5'] = 'high';
  S.claude.effort = 'high';
  lsSet('claude_model', S.claude.model);
  lsSet('claude_efforts', JSON.stringify(S.claude.effortByModel));
  lsSet('claude_default_v2', '1');
}

let viewSeq = 0;
/** 当前显示的会话：有 ID 用 ID，新对话用临时的 new:N。 */
const viewKey = id => S[id].conversationId || S[id].newView;
const isBusy = id => S[id].runs.size > 0;
const runsOf = (id, view) => [...S[id].runs.values()].filter(r => r.view === view);
const viewBusy = id => runsOf(id, viewKey(id)).length > 0;
const busySince = id => Math.min(Date.now(), ...[...S[id].runs.values()].map(r => r.since));

/** 根据实时步骤判断这个会话当前处于「思考 / 查阅 / 施工」哪一阶段。 */
function syncRunPhase(run) {
  const steps = (run.live?.steps || []).filter(s => s && s.kind !== 'user');   // 你中途补充的话不算它的工作步骤
  const running = [...steps].reverse().find(s => s.status === 'running');
  const activeStep = running || steps[steps.length - 1] || null;
  if (!activeStep || activeStep.kind === 'think') {
    run.phase = 'thinking';
    run.stepKind = 'think';
    run.stepTitle = '思考中';
  } else if (READING_KINDS.has(activeStep.kind)) {
    run.phase = 'reading';
    run.stepKind = activeStep.kind;
    run.stepTitle = activeStep.title || '查阅资料';
  } else if (WORKING_KINDS.has(activeStep.kind)) {
    run.phase = 'working';
    run.stepKind = activeStep.kind;
    run.stepTitle = activeStep.kind === 'text' ? '撰写回答' : (activeStep.title || '正在施工');
  } else {
    run.phase = 'thinking';
    run.stepKind = activeStep.kind;
    run.stepTitle = activeStep.title || '思考中';
  }
  run.stepStatus = activeStep?.status || 'running';
  run.stepAt = Date.now();
}

/** 汇总某位 AI 娘当前展示的忙碌阶段（优先看当前打开的会话，否则看最近活跃的会话）。 */
function busyInfo(id) {
  const st = S[id];
  if (!st || !st.runs.size) return null;
  const inView = runsOf(id, viewKey(id));
  const list = inView.length ? inView : [...st.runs.values()];
  const run = list.reduce((a, b) => ((b.stepAt || b.since) >= (a.stepAt || a.since) ? b : a), list[0]);
  const phase = run.phase || 'thinking';
  const kind = run.stepKind || 'think';
  const meta = PHASE_META[phase] || PHASE_META.thinking;
  return {
    phase,
    kind,
    meta,
    icon: KIND_ICONS[kind] || meta.icon,
    title: run.stepTitle || meta.workLabel,
    count: st.runs.size,
    fast: !!run.fast,
    since: busySince(id),
  };
}

/** 这一位现在是不是真的在用 fast：开关开着，而且选着的模型有 fast 档。 */
const fastOn = id => S[id].fast && !!find(AGENTS[id].models, S[id].model).fast;

/** 这个模型支持的思考强度选项。 */
function modelEfforts(id, m) {
  const all = AGENTS[id].efforts;
  return m.efforts ? all.filter(o => m.efforts.includes(o.v)) : all;
}
/** 这个模型的思考强度：上次给它选的 → 默认 → 它支持的第一个。 */
function effortOf(id, v) {
  const opts = modelEfforts(id, find(AGENTS[id].models, v));
  return pick(opts, S[id].effortByModel[v], pick(opts, AGENTS[id].effort, opts[0].v));
}

let active = AGENT_IDS.includes(lsGet('active')) ? lsGet('active') : AGENT_IDS[0];
let reqCounter = Date.now();   // 从当前时间起编号：网页进程崩溃重新载入后，新的回答不会和原生层还在跑的旧回答撞号
const pets = {};

const $ = sel => document.querySelector(sel);
const els = {
  sidebar: $('#history-sidebar'),
  sections: $('#hist-sections'),
  chatStack: $('#chat-stack'),
  input: $('#chat-input'),
  sendBtn: $('#send-btn'),
  badge: $('#agent-badge'),
  name: $('#chat-name'),
  convLabel: $('#conv-label'),
  wsCrumb: $('#ws-crumb'),
  chipModel: $('#chip-model'),
  chipPerm: $('#chip-perm'),
  popover: $('#popover'),
  popoverSub: $('#popover-sub'),
  stage: $('#stage-column'),
};

const hasBridge = () => !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hubBridge);
function postNative(action, payload = {}) {
  if (hasBridge()) window.webkit.messageHandlers.hubBridge.postMessage({ action, ...payload });
}
