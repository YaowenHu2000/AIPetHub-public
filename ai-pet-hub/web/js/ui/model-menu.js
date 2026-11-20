'use strict';

// 模型面板：fast、思考强度滑杆、选模型那一页，以及 CLI 报上来新的模型列表时换掉菜单。
//
// 打开模型菜单先显示缓存，再按需通过后台用量查询获取当前 CLI 的列表。
//
// Claude、Codex、Gemini 按位去重，预热和后台查询收到的模型也会更新已打开的菜单。
//
// CLI 回报部分模型目录时保留已有型号和选择，等完整目录到达后再迁移已下架的型号。

// ===== 模型面板（参考 Codex 桌面版）：上面一行「⚡ fast ｜ 思考强度 ｜ 还原」，中间是模型名（点进去选模型），下面一条滑杆调思考强度，最底下是剩余用量 =====
let subTimer = 0;
/** 最高档：Codex 的 Ultra、Claude 的 Ultracode。面板和输入框下面的字换成渐变色，滑杆也换一套颜色。 */
const TOP_EFFORTS = new Set(['ultra', 'ultracode']);
let modelView = 'panel';   // 面板里现在显示的：'panel' 滑杆那一页 | 'list' 选模型那一页

// 只记本次打开 App 后的查询。上次运行留下的列表可用来立即绘制，随后由 CLI 刷新。
const modelReportedAt = {}, menuRequestedAt = {};
function openModelPopover() {
  modelView = 'panel';
  openPopover(els.chipModel, null, { render: renderModelMenu, cls: 'model-pop' });
  if (pop?.anchor !== els.chipModel) return;
  const now = Date.now(), ttl = 5 * 60 * 1000;
  const needModels = active !== 'deepseek' && now - (modelReportedAt[active] ?? -Infinity) >= ttl;
  if ((needModels || !agentUsage[active]) && now - (menuRequestedAt[active] ?? -Infinity) >= ttl) {
    menuRequestedAt[active] = now;
    postNative('loadUsage', { agent: active, force: needModels });
  }
}

function renderModelMenu(box) {
  if (modelView === 'list') renderModelList(box, active); else renderModelPanel(box, active);
}

/**
 * 换一页（或者同一页重画）。换页时面板不是「这一页消失、那一页出现」：
 * 同一个面板从原来的大小和位置连续地变到新的（弹簧带着它过去，略微冲过头再收住），里面的内容淡进来。
 */
let morph = null;   // 正在变形：{ from, to }（都是面板的位置和大小）
const morphSpring = new Spring({
  stiffness: 330, damping: 30,
  onUpdate: p => {
    if (!morph) return;
    const box = els.popover, { from, to } = morph;
    ['left', 'top', 'width', 'height'].forEach(k => { box.style[k] = `${from[k] + (to[k] - from[k]) * p}px`; });
  },
  onRest: () => {
    if (!morph) return;
    const box = els.popover;
    box.style.width = ''; box.style.height = ''; box.style.overflow = '';
    box.style.left = `${morph.to.left}px`; box.style.top = `${morph.to.top}px`;
    morph = null;
  },
});
function showModelView(view) {
  if (!pop) return;
  const box = els.popover;
  const changed = view !== modelView;
  const a = box.getBoundingClientRect();   // 正在变形的话，这就是变到一半的样子：从这里接着变
  modelView = view;
  hideSubmenu();
  box.style.width = ''; box.style.height = '';
  renderPopover();
  positionPopover();
  // 同一页重画（「还原」、用量回包）会打断正在进行的换页动画：动画收尾时才清的 overflow 也要在这里清，
  // 否则面板一直不能滚，底部选项再也够不着
  if (!changed) { if (morph) box.style.overflow = ''; morph = null; return; }
  const b = box.getBoundingClientRect();
  const rect = r => ({ left: r.left, top: r.top, width: r.width, height: r.height });
  morph = { from: rect(a), to: rect(b) };
  box.style.overflow = 'hidden';
  morphSpring.set(0);
  morphSpring.to(1);
  [...box.children].forEach(c => c.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 260, easing: 'ease-out' }));
}

/** 只改思考强度（滑杆拖动时用：不说话，松手时再说一句）。 */
function setEffort(id, v) {
  const st = S[id];
  if (st.effort === v) return false;
  st.effort = v;
  st.effortByModel[st.model] = v;
  lsSet(`${id}_efforts`, JSON.stringify(st.effortByModel));
  if (id === active) renderComposer();
  return true;
}

function setFast(id, on) {
  updateSetting(id, 'fast', on, on ? '⚡ fast 开了' : 'fast 关了');
  lsSet(`${id}_fast`, on ? '1' : '');
  pets[id].renderStatus();
}

function renderModelPanel(box, id) {
  const st = S[id];
  const m = find(AGENTS[id].models, st.model);
  const opts = modelEfforts(id, m);
  const head = document.createElement('div');
  head.className = 'mp-head';
  // ⚡ fast：选着的模型有 fast 档才能点（Claude 的 fast 模式、Codex 的 Fast 档；Gemini 没有）
  const fast = document.createElement('button');
  fast.className = 'mp-icon mp-fast' + (fastOn(id) ? ' on' : '');
  fast.innerHTML = UI.bolt;
  fast.disabled = !m.fast;
  fast.title = m.fast ? `fast：${m.fastDesc || '出结果更快，用量消耗也更多'}（现在${st.fast ? '开着' : '关着'}）` : '这个模型没有 fast 档';
  // 开关 fast 不重画整个面板（重画会换掉滑杆的画布，流动的画面就跳一下）：只改这个按钮自己
  fast.addEventListener('click', e => {
    e.stopPropagation();
    setFast(id, !st.fast);
    fast.classList.toggle('on', fastOn(id));
    fast.title = `fast：${m.fastDesc || '出结果更快，用量消耗也更多'}（现在${st.fast ? '开着' : '关着'}）`;
  });
  const label = elSpan('mp-effort', find(opts, st.effort).name);
  const reset = document.createElement('button');
  reset.className = 'mp-icon';
  reset.innerHTML = UI.reset;
  reset.title = '还原：思考强度回到默认，fast 关掉';
  reset.addEventListener('click', e => {
    e.stopPropagation();
    if (st.fast) setFast(id, false);
    if (setEffort(id, pick(opts, AGENTS[id].effort, opts[0].v))) pets[id].say(`${m.name} · ${find(opts, st.effort).name}`, 1800);
    showModelView('panel');
  });
  head.append(fast, label, reset);

  const model = document.createElement('button');
  model.className = 'mp-model';
  model.title = '选择模型';
  model.append(elSpan('', m.name));
  model.insertAdjacentHTML('beforeend', UI.chevron);
  model.addEventListener('click', e => { e.stopPropagation(); showModelView('list'); });

  box.append(head, model, effortSlider(id, opts, label));
  renderContext(box, id);
  renderUsage(box, id);
}

/** 思考强度的滑杆：一格一档，点哪里跳到哪里，也可以拖。只有一档的模型不能拖。 */
function effortSlider(id, opts, label) {
  const st = S[id];
  const track = document.createElement('div');
  track.className = 'mp-slider' + (opts.length < 2 ? ' fixed' : '');
  // 滑过的那一段：一层按档位裁宽度的壳，里面是铺满整条的画布（颜色和粒子一直在流，见 effort-flow.js）
  const fill = document.createElement('div');
  fill.className = 'mp-fill';
  const canvas = document.createElement('canvas');
  fill.appendChild(canvas);
  const knob = document.createElement('i');
  track.append(fill, knob);
  startEffortFlow(track, canvas, () => fastOn(id));
  const stepT = () => {
    const i = Math.max(0, opts.findIndex(o => o.v === st.effort));
    return opts.length > 1 ? i / (opts.length - 1) : 1;
  };
  const label2 = () => {
    const o = find(opts, st.effort);
    label.textContent = o.name;
    track.title = `思考强度：${o.name}（${o.desc}）`;
    // 档位越高字的颜色越深（--lvl）；最高档整块面板换成那一档专门的配色
    const all = AGENTS[id].efforts.map(x => x.v);
    els.popover.style.setProperty('--lvl', all.length > 1 ? Math.max(0, all.indexOf(st.effort)) / (all.length - 1) : 1);
    els.popover.classList.toggle('top', TOP_EFFORTS.has(st.effort));
  };
  // 圆钮的位置（--t，0…1，拖过头时会略微超出）由一根弹簧管：拖的时候直接跟着手指，松手后带着拖的速度落到那一档上
  // 手上的动作可以带一点回弹，但只一点（阻尼比约 0.8）
  const knobSpring = new Spring({ value: stepT(), stiffness: 380, damping: 31, onUpdate: t => track.style.setProperty('--t', t) });
  track.style.setProperty('--t', stepT());
  label2();
  if (opts.length < 2) return track;
  let moved = false, lastT = 0, lastAt = 0, speed = 0;
  const pickAt = x => {
    const r = track.getBoundingClientRect();
    const pad = r.height / 2;   // 圆钮的中心只能在两头各留半个圆钮的范围里走
    const span = Math.max(1, r.width - pad * 2);
    const raw = (x - r.left - pad) / span;
    const t = clamp(raw, 0, 1);
    // 拖过了头：像橡皮筋，多拉出去的只算三分之一，最多 8px
    const over = (raw - t) * span;
    const shown = t + Math.sign(over) * Math.min(8, Math.abs(over) * 0.33) / span;
    const now = performance.now();
    if (lastAt && now > lastAt) speed = (shown - lastT) / ((now - lastAt) / 1000);
    lastT = shown; lastAt = now;
    knobSpring.set(shown);
    if (setEffort(id, opts[Math.round(t * (opts.length - 1))].v)) { moved = true; label2(); postNative('haptic', {}); }   // 过一档，触控板轻轻一下
  };
  track.addEventListener('pointerdown', e => {
    e.preventDefault();
    track.setPointerCapture(e.pointerId);
    track.classList.add('dragging');
    lastAt = 0; speed = 0;
    pickAt(e.clientX);
  });
  track.addEventListener('pointermove', e => { if (track.classList.contains('dragging')) pickAt(e.clientX); });
  const end = () => {
    if (!track.classList.contains('dragging')) return;
    track.classList.remove('dragging');
    knobSpring.to(stepT(), { velocity: clamp(speed, -6, 6) });
    if (moved) {
      moved = false;
      const m = find(AGENTS[id].models, st.model);
      const later = viewBusy(id);
      pets[id].say(`${m.name} · ${find(opts, st.effort).name}${later ? '（下一句起生效）' : ''}`, later ? 2800 : 1600);
    }
  };
  track.addEventListener('pointerup', end);
  track.addEventListener('pointercancel', end);
  return track;
}

/**
 * 选模型那一页：常用的几个直接列出来，其余的收在「更多模型」里（悬停在右边展开）。
 * 怎么分见 logic.js 的 splitModels（Claude：Opus / Fable / Sonnet / Haiku 是常用，旧版本和「默认」在更多里）。
 */
function renderModelList(box, id) {
  const st = S[id];
  const all = AGENTS[id].models;
  const { main, more } = splitModels(all);
  const title = document.createElement('button');
  title.className = 'pop-title mp-back';
  title.innerHTML = UI.back;
  title.append(elSpan('', '选择模型'));
  title.addEventListener('click', e => { e.stopPropagation(); showModelView('panel'); });
  box.appendChild(title);
  const row = (m, cls) => {
    const b = document.createElement('button');
    b.className = `pop-item model-row ${cls}` + (m.v === st.model ? ' selected' : '');
    b.dataset.v = m.v;
    if (m.tip) b.title = m.tip;
    const check = elSpan('pop-check', '');
    if (m.v === st.model) check.innerHTML = UI.check;
    b.append(elSpan('mr-name', m.name), check);
    b.addEventListener('click', e => { e.stopPropagation(); chooseModel(id, m.v); showModelView('panel'); });
    return b;
  };
  main.forEach(m => {
    const b = row(m, '');
    b.addEventListener('mouseenter', () => { clearTimeout(subTimer); subTimer = setTimeout(hideSubmenu, 140); });
    box.appendChild(b);
  });
  if (!more.length) return;
  const sep = document.createElement('div');
  sep.className = 'pop-sep';
  const moreRow = document.createElement('button');
  const current = more.find(m => m.v === st.model);
  moreRow.className = 'pop-item model-row more-row' + (current ? ' selected' : '');
  moreRow.append(elSpan('mr-name', '更多模型'), elSpan('mr-effort', current ? current.name : ''));
  moreRow.insertAdjacentHTML('beforeend', `<span class="mr-chev">${UI.chevron}</span>`);
  const open = () => {
    clearTimeout(subTimer);
    if (moreRow.classList.contains('sub-open')) return;
    hideSubmenu();
    moreRow.classList.add('sub-open');
    const sub = els.popoverSub;
    more.forEach(m => sub.appendChild(row(m, 'sub-item')));
    sub.hidden = false;
    // 放在主面板右侧、和这一行的底对齐；右边放不下就放到左边
    const pr = els.popover.getBoundingClientRect();
    const rr = moreRow.getBoundingClientRect();
    let left = pr.right + 6;
    if (left + sub.offsetWidth > window.innerWidth - 8) left = Math.max(8, pr.left - sub.offsetWidth - 6);
    sub.style.left = `${left}px`;
    sub.style.top = `${clamp(rr.bottom + 7 - sub.offsetHeight, 8, window.innerHeight - sub.offsetHeight - 8)}px`;
  };
  moreRow.addEventListener('mouseenter', open);
  moreRow.addEventListener('click', e => { e.stopPropagation(); open(); });
  box.append(sep, moreRow);
}

// ===== 模型菜单跟着 CLI 走 =====
// 原生把 CLI 现在能用的模型报上来（Claude：initialize；Codex：model/list；Gemini：会话的配置项）。菜单换成它的，记在本地；
// 选着的模型如果不在新列表里（比如以前写死的旧条目），换成对应的那个。CLI 升级后有了新模型，这里自己就有了。
window.onAgentModels = data => {
  const id = data.agent;
  if (!AGENTS[id] || !Array.isArray(data.models) || !data.models.length) return;
  if (data.complete !== false) modelReportedAt[id] = Date.now();   // Claude 主目录和 Gemini 会话可能只报部分模型
  const list = mergeModels(BUILTIN_MODELS[id], data.models, Object.keys(EFFORTS));
  // 部分目录只能补充已知型号，完整目录才能确认用户选的型号已经下架。
  if (data.complete === false) list.push(...AGENTS[id].models.filter(old => !list.some(m => m.v === old.v)));
  if (JSON.stringify(list) === JSON.stringify(AGENTS[id].models)) return;
  AGENTS[id].models = list;
  lsSet(`${id}_models`, JSON.stringify(list));
  const st = S[id];
  // 旧菜单把带 xhigh 等后缀的型号单列。CLI 现在把它归到基础型号时，保留用户选中的档位。
  const oldVariant = data.complete !== false && id === 'gemini' && list.find(m => m.efforts?.some(e => m.v + '-' + e === st.model));
  if (oldVariant) {
    st.effortByModel[oldVariant.v] = st.model.slice(oldVariant.v.length + 1);
    lsSet(id + '_efforts', JSON.stringify(st.effortByModel));
  }
  const next = oldVariant?.v || migrateModel(st.model, list, MODEL_ALIASES, (data.models.find(m => m.isDefault) || {}).v || AGENTS[id].model);
  if (next !== st.model) {
    if (id === 'claude' && MODEL_ALIASES[st.model] === next && st.effortByModel[st.model]) {
      st.effortByModel[next] = st.effortByModel[st.model];
      lsSet(id + '_efforts', JSON.stringify(st.effortByModel));
    }
    st.model = next;
    lsSet(`${id}_model`, next);
  }
  st.effort = effortOf(id, st.model);   // 新模型支持的思考强度可能不一样
  lsSet(`${id}_effort`, st.effort);
  if (id === active) {
    renderComposer();
    if (pop?.anchor === els.chipModel) showModelView(modelView);
  }
};
