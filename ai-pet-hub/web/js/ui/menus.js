'use strict';

// 输入框底部的选择器、弹出面板、权限菜单和工作空间分组菜单（模型面板在 model-menu.js，上下文和剩余用量在 usage-panel.js）。

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
  if (!pop || !pop.anchor.isConnected) return;   // 面板已经收起（晚到的刷新）；或者左栏刚刷新、锚点已被替换：留在原处
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
