'use strict';

// 对话标题栏、输入框底部的选择器、弹出面板、模型菜单、权限菜单。

// ===== 输入框底部的选择器（参考反重力：模型·思考强度 / 权限） =====
function renderComposer() {
  const c = AGENTS[active];
  const st = S[active];
  const m = find(c.models, st.model);
  const e = find(c.efforts, st.effort);
  els.chipModel.innerHTML = `<span class="chip-label"></span><span class="chip-sub"></span>${UI.caret}`;
  els.chipModel.querySelector('.chip-label').textContent = m.name;
  const fast = fastOn(active);
  const sub = els.chipModel.querySelector('.chip-sub');
  sub.textContent = fast ? `${e.name} ⚡` : e.name;
  sub.classList.toggle('top', TOP_EFFORTS.has(st.effort));   // 最高档（Ultra / Ultracode）换一种颜色
  els.chipModel.title = `对话模型：${m.name}　思考强度：${e.name}${fast ? '　fast 开着' : ''}`;

  const p = find(c.perms, st.perm);
  els.chipPerm.innerHTML = `${UI.shield}<span class="chip-label"></span>${UI.caret}`;
  els.chipPerm.querySelector('.chip-label').textContent = p.name;
  els.chipPerm.title = `权限模式：${p.name}（${p.desc}）`;
}

function updateSetting(id, key, value, message) {
  S[id][key] = value;
  lsSet(`${id}_${key}`, value);
  if (id === active) renderComposer();
  // 正在回答的这一轮用的还是发出时的模型和权限
  const later = viewBusy(id) && ['model', 'effort', 'perm', 'fast'].includes(key);
  pets[id].say(later ? `${message}（正在回答的这一轮不变，下一句起生效）` : message, later ? 3200 : 1800);
}

/** 选模型和思考强度（不传思考强度 = 用这个模型上次的）。 */
function chooseModel(id, v, effort) {
  const st = S[id];
  const m = find(AGENTS[id].models, v);
  const e = pick(modelEfforts(id, m), effort, effortOf(id, v));
  const changed = st.model !== v || st.effort !== e;
  st.model = v;
  st.effort = e;
  st.effortByModel[v] = e;
  lsSet(`${id}_model`, v);
  lsSet(`${id}_efforts`, JSON.stringify(st.effortByModel));
  if (id === active) renderComposer();
  if (changed) pets[id].say(`${m.name} · ${find(AGENTS[id].efforts, e).name}`, 1800);
}

function setWorkspace(id, path, announce = true) {
  S[id].workspace = path || '';
  lsSet(`${id}_workspace`, S[id].workspace);
  if (id === active) renderHeader();
  renderHistory(id);
  if (announce) pets[id].say(path ? `工作空间：${baseName(path)} 📁` : '已解绑工作空间', 1800);
}

/** 左栏 📁 打开的工作空间：记下来，没有会话时也显示在列表里。 */
function addWorkspace(id, path) {
  const st = S[id];
  st.addedWs = [{ path, ts: Date.now() / 1000 }, ...st.addedWs.filter(w => w.path !== path)].slice(0, 20);
  lsSet(`${id}_added_ws`, JSON.stringify(st.addedWs));
  renderHistory(id);
}

/** 项目删除后：从列表里去掉；当前就在这个工作空间的话改成不绑定工作空间（否则「新对话」又会把它带回来）。 */
function forgetWorkspace(id, path) {
  const st = S[id];
  st.addedWs = st.addedWs.filter(w => w.path !== path);
  lsSet(`${id}_added_ws`, JSON.stringify(st.addedWs));
  delete st.groupState[path];
  st.expanded.delete(path);
  if (!st.conversationId && !viewBusy(id) && wsKey(st.workspace) === path) {
    st.groupState[''] = 0;
    setWorkspace(id, '', false);
  }
  lsSet(`${id}_groups`, JSON.stringify(st.groupState));
  renderHistory(id);
}

// ===== 弹出面板 =====
let pop = null;   // { anchor, build, keepOpen, placement, render, cls }

/**
 * 弹出面板出现 / 收回：一根弹簧管着「出来了几成」（0 = 藏着，1 = 完全出来），透明度、位置、大小都跟着它。
 * 随时可以打断：正在收回时又要打开（或者反过来），带着当时的速度拐回去。收回到头才真的藏起来。
 */
const popSpring = new Spring({
  value: 0,
  onUpdate: p => {
    const box = els.popover;
    box.style.opacity = Math.min(1, Math.max(0, p));
    box.style.transform = p === 1 ? '' : `translateY(${(1 - p) * 7}px) scale(${0.965 + 0.035 * p})`;   // 出来时会略微冲过头再回来
  },
  onRest: p => { if (p === 0) els.popover.hidden = true; },
});
function playPop(show) {
  els.popover.style.pointerEvents = show ? '' : 'none';
  popSpring.onUpdate(popSpring.value);   // 先按现在的位置摆好，免得第一帧整块闪出来
  if (show) popSpring.to(1, { stiffness: 520, damping: 34 });
  else popSpring.to(0, { stiffness: 760, damping: 54 });   // 收回快一点、不弹
}

function openPopover(anchor, build, { placement = 'top', keepOpen = false, render = null, cls = '' } = {}) {
  if (pop && pop.anchor === anchor) { closePopover(); return; }
  closePopover();
  pop = { anchor, build, keepOpen, placement, render, cls };
  anchor.classList.add('open');
  renderPopover();
  els.popover.hidden = false;
  positionPopover();
  playPop(true);
  if (typeof syncBrowser === 'function') syncBrowser();   // 菜单开着时藏起内置浏览器，免得盖住菜单
}

function renderPopover() {
  const box = els.popover;
  box.innerHTML = '';
  box.className = pop.cls;
  if (pop.render) { pop.render(box); return; }   // 自己画内容的面板（模型菜单、删除确认）
  pop.build().forEach((section, i) => {
    if (i > 0) {
      const sep = document.createElement('div');
      sep.className = 'pop-sep';
      box.appendChild(sep);
    }
    if (section.title) {
      const t = document.createElement('div');
      t.className = 'pop-title';
      t.textContent = section.title;
      box.appendChild(t);
    }
    section.items.forEach(item => {
      const row = document.createElement('button');
      row.className = 'pop-item' + (item.selected ? ' selected' : '') + (item.danger ? ' danger' : '');
      const check = document.createElement('span');
      check.className = 'pop-check';
      check.innerHTML = item.selected ? UI.check : '';
      const text = document.createElement('span');
      text.className = 'pop-text';
      const name = document.createElement('span');
      name.className = 'pop-name';
      name.textContent = item.name;
      text.appendChild(name);
      if (item.desc) {
        const desc = document.createElement('span');
        desc.className = 'pop-desc';
        desc.textContent = item.desc;
        text.appendChild(desc);
      }
      row.append(check, text);
      row.addEventListener('click', e => {
        e.stopPropagation();
        if (item.stay) { item.onPick(); return; }   // 自己换面板内容（例如删除前的确认）
        const keep = pop && pop.keepOpen && !item.close;
        item.onPick();
        if (keep && pop) { renderPopover(); positionPopover(); } else closePopover();
      });
      box.appendChild(row);
    });
  });
}

function positionPopover() {
  const box = els.popover;
  if (!pop.anchor.isConnected) return;   // 左栏刚刷新、锚点已被替换：留在原处
  const r = pop.anchor.getBoundingClientRect();
  // 内容多到要滚动时，面板退回普通圆角（连续圆角的底和边是伪元素画的，会跟着内容滚走，见 squircle.css）
  box.classList.toggle('scrolls', box.scrollHeight > box.clientHeight + 1);
  const w = box.offsetWidth;
  const h = box.offsetHeight;
  const left = clamp(pop.placement === 'bottom' ? r.right - w : r.left, 8, window.innerWidth - w - 8);
  let top = pop.placement === 'top' ? r.top - h - 8 : r.bottom + 8;
  if (top < 8) top = r.bottom + 8;
  if (top + h > window.innerHeight - 8) top = Math.max(8, r.top - h - 8);
  box.style.left = `${left}px`;
  box.style.top = `${top}px`;
  // 出现的动画从锚点那一侧长出来：在锚点上面就以下边为起点，对着锚点的左边还是右边就靠哪边
  box.style.transformOrigin = `${left + w / 2 > r.left + r.width / 2 ? 'left' : 'right'} ${top < r.top ? 'bottom' : 'top'}`;
}

function closePopover() {
  if (!pop) return;
  pop.anchor.classList.remove('open');
  pop = null;
  playPop(false);
  hideSubmenu();
  if (typeof syncBrowser === 'function') syncBrowser();
}

const elSpan = (cls, text) => {
  const s = document.createElement('span');
  s.className = cls;
  s.textContent = text;
  return s;
};

// ===== 模型面板（参考 Codex 桌面版）：上面一行「⚡ fast ｜ 思考强度 ｜ 还原」，中间是模型名（点进去选模型），下面一条滑杆调思考强度，最底下是剩余用量 =====
let subTimer = 0;
/** 最高档：Codex 的 Ultra、Claude 的 Ultracode。面板和输入框下面的字换成渐变色，滑杆也换一套颜色。 */
const TOP_EFFORTS = new Set(['ultra', 'ultracode']);
let modelView = 'panel';   // 面板里现在显示的：'panel' 滑杆那一页 | 'list' 选模型那一页

function openModelPopover() {
  modelView = 'panel';
  openPopover(els.chipModel, null, { render: renderModelMenu, cls: 'model-pop' });
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
  if (!changed) { morph = null; return; }
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

// ===== 这个会话的上下文用了多少（模型面板里，剩余用量上面）：原生在每一轮答完后报过来（Usage.swift 的 noteContext） =====
const agentContext = lsJson('context_usage', {});   // "谁:会话 ID" → { used, max }
const tokenLabel = n => (n >= 1e6 ? `${+(n / 1e6).toFixed(n % 1e6 ? 1 : 0)}M` : n >= 1000 ? `${Math.round(n / 1000)}k` : String(n));

function renderContext(box, id) {
  const data = agentContext[`${id}:${S[id].conversationId}`];
  if (!data || !S[id].conversationId) return;
  const pct = Math.min(100, Math.round(data.used / data.max * 100));
  const sep = document.createElement('div');
  sep.className = 'pop-sep';
  const wrap = document.createElement('div');
  wrap.className = 'usage-box';
  wrap.appendChild(elSpan('pop-title usage-title', '这个会话的上下文'));
  const row = document.createElement('div');
  row.className = 'usage-row';
  row.title = pct >= 80 ? '快满了：可以发 /compact 把前面的对话压缩成摘要' : '';
  const bar = document.createElement('span');
  bar.className = 'usage-bar' + (pct >= 92 ? ' low' : pct >= 80 ? ' mid' : '');   // 这里是用得越多越该提醒
  const fill = document.createElement('i');
  fill.style.width = `${Math.max(2, pct)}%`;
  bar.appendChild(fill);
  row.append(elSpan('usage-label', `已用 ${pct}%`), bar, elSpan('usage-reset', `${tokenLabel(data.used)} / ${tokenLabel(data.max)}`));
  wrap.appendChild(row);
  box.append(sep, wrap);
}

window.onAgentContext = function (data) {
  if (!data || !AGENTS[data.agent] || !data.conversationId || !(data.max > 0)) return;
  agentContext[`${data.agent}:${data.conversationId}`] = { used: data.used, max: data.max };
  const keys = Object.keys(agentContext);
  if (keys.length > 60) keys.slice(0, keys.length - 60).forEach(k => delete agentContext[k]);   // 只留最近的几十个会话
  lsSet('context_usage', JSON.stringify(agentContext));
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
  if (!agentUsage[id]) postNative('loadUsage', { agent: id });   // 原生在后台每 5 分钟查一次；手头还没有才现要
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

function hideSubmenu() {
  clearTimeout(subTimer);
  els.popoverSub.hidden = true;
  els.popoverSub.innerHTML = '';
  els.popover.querySelectorAll('.model-row.sub-open').forEach(r => r.classList.remove('sub-open'));
}

function openPermPopover() {
  openPopover(els.chipPerm, () => {
    const id = active;
    const on = browserToolsOn();
    const setTools = v => { lsSet('browser_tools', v ? 'on' : 'off'); pets[id].say(v ? '以后的回答会带上内置浏览器的工具' : '以后的回答不带内置浏览器的工具', 2200); };
    return [{ title: '权限模式', items: AGENTS[id].perms.map(p => ({ name: p.name, desc: p.desc, selected: p.v === S[id].perm,
      onPick: () => updateSetting(id, 'perm', p.v, `权限模式：${p.name}`) })) },
    // 三位共用的开关：不做网页时可以关掉，每轮少带一组工具的说明（省一点上下文）
    { title: '内置浏览器工具', items: [
      { name: '带上', desc: '智能体能自己打开网页、截图、看控制台', selected: on, onPick: () => setTools(true) },
      { name: '不带', desc: '不做网页时可以关掉，省一点上下文', selected: !on, onPick: () => setTools(false) }] }];
  });
}

/** 工作空间分组上的「⋮」。 */
function openGroupMenu(id, g, anchor) {
  openPopover(anchor, () => [{ items: [
    { name: '在访达中打开', desc: prettyPath(g.key), onPick: () => postNative('openFolder', { path: g.key }) },
    { name: '删除项目…', desc: id === 'gpt' ? '归档这里的全部会话，文件夹不受影响' : '这里的全部会话移到废纸篓，文件夹不受影响',
      danger: true, stay: true, onPick: () => askDeleteProject(id, g.key) },
  ] }], { placement: 'bottom' });
}

// ===== 模型菜单跟着 CLI 走 =====
// 原生把 CLI 现在能用的模型报上来（Claude：initialize；Codex：model/list；Gemini：会话的配置项）。菜单换成它的，记在本地；
// 选着的模型如果不在新列表里（比如以前写死的旧条目），换成对应的那个。CLI 升级后有了新模型，这里自己就有了。
window.onAgentModels = data => {
  const id = data.agent;
  if (!AGENTS[id] || !Array.isArray(data.models) || !data.models.length) return;
  const list = mergeModels(BUILTIN_MODELS[id], data.models, Object.keys(EFFORTS));
  if (JSON.stringify(list) === JSON.stringify(AGENTS[id].models)) return;
  AGENTS[id].models = list;
  lsSet(`${id}_models`, JSON.stringify(list));
  const st = S[id];
  const next = migrateModel(st.model, list, MODEL_ALIASES, (data.models.find(m => m.isDefault) || {}).v || AGENTS[id].model);
  if (next !== st.model) {
    st.model = next;
    lsSet(`${id}_model`, next);
  }
  st.effort = effortOf(id, st.model);   // 新模型支持的思考强度可能不一样
  lsSet(`${id}_effort`, st.effort);
  if (id === active) renderComposer();
};
