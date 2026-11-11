'use strict';

// 拖动调整布局：左栏三格的高度、左栏和角色舞台的宽度。

// ===== 左栏三格上下拖动 =====
let sectionWeights = (() => {
  const w = lsJson('section_weights', null);
  return Array.isArray(w) && w.length === AGENT_IDS.length && w.every(x => typeof x === 'number' && x > 0) ? w : AGENT_IDS.map(() => 1);
})();

/**
 * 左栏三格各占多高。不是死按比例分：哪一格的内容用不完它那一份，就只给它内容那么高，
 * 省下来的让给内容放不下的格（还是按比例分），这样不会一格下面空着一大片、另一格却挤得要滚。
 * 三格都放得下时，多出来的空白留在最下面那一格的下面。
 * byContent = false（正在拖分隔条）时就按比例来：手拖到哪就是哪，松手后再按内容收。
 */
function applySectionWeights(byContent = true) {
  const secs = AGENT_IDS.map(id => histSections[id]);
  const byWeight = () => secs.forEach((s, i) => { s.sec.style.flex = `${sectionWeights[i]} 1 0px`; });
  const total = secs.reduce((sum, s) => sum + s.sec.getBoundingClientRect().height, 0);
  if (!byContent || !(total > 0)) { byWeight(); queueTrimRows(); return; }
  // 每一格的内容要多高：标题那一行 + 列表里所有的行
  // （列表的 scrollHeight 不能用：列表比内容高的时候它等于列表自己的高度，量不出内容其实多矮）
  const need = secs.map(s => {
    const last = [...s.list.children].reverse().find(el => !el.classList.contains('row-ghost'));   // 正在淡出的行不算
    const rows = last ? last.getBoundingClientRect().bottom - s.list.getBoundingClientRect().top + s.list.scrollTop : 0;
    return Math.ceil(s.sec.querySelector('.hist-head').offsetHeight + rows + 8);   // 8 = 列表下面的留白
  });
  const heights = fitSections(need, sectionWeights, total);
  const capped = heights.map((h, i) => h >= need[i]);
  if (capped.every(Boolean)) capped[capped.length - 1] = false;   // 都放得下：最下面那一格吃掉剩下的
  secs.forEach((s, i) => { s.sec.style.flex = capped[i] ? `0 1 ${need[i]}px` : `${sectionWeights[i]} 1 0px`; });
  queueTrimRows();
}

/**
 * 每一格的底边不留「被切掉一半的行」：哪一行正好压在底边上（露出上半截、字被拦腰切断），就整行先不显示——
 * 把列表从那一行的顶上裁掉（只是裁掉显示，不改布局，所以不会抖）。滚动、拖分隔条、内容变了之后都重新看一遍。
 * 顶边靠滚动吸附对齐（sidebar.css 的 scroll-snap）：停下来时最上面总是一整行。
 */
function trimPartialRows() {
  AGENT_IDS.forEach(id => {
    const list = histSections[id] && histSections[id].list;
    if (!list || !list.isConnected) return;
    const box = list.getBoundingClientRect();
    let cut = 0;
    if (list.scrollHeight - list.scrollTop - list.clientHeight > 1) {   // 下面还有内容（到底了就不用裁，最后一行下面是留白）
      for (const row of list.querySelectorAll('.conv-row, .grp-head, .see-all')) {
        if (row.classList.contains('row-ghost')) continue;
        const r = row.getBoundingClientRect();
        if (r.bottom <= box.bottom + 0.5) continue;
        if (r.top < box.bottom - 0.5) cut = box.bottom - r.top;   // 这一行跨在底边上
        break;
      }
    }
    list.style.clipPath = cut > 0.5 ? `inset(0 0 ${cut.toFixed(1)}px 0)` : '';
  });
}
let trimQueued = false;
function queueTrimRows() {
  if (trimQueued) return;
  trimQueued = true;
  const run = () => { if (trimQueued) { trimQueued = false; trimPartialRows(); } };
  requestAnimationFrame(run);
  setTimeout(run, 80);
}

/** 内容变了（列表重画、展开折叠）之后重新分一次：攒到下一帧，一次重画里只算一遍。 */
let sectionFitQueued = false;
function queueSectionFit() {
  if (sectionFitQueued) return;
  sectionFitQueued = true;
  const run = () => { if (sectionFitQueued) { sectionFitQueued = false; applySectionWeights(); } };
  requestAnimationFrame(run);
  setTimeout(run, 80);   // 窗口被挡住时 requestAnimationFrame 不走
}

function buildSplitter(i) {
  const bar = document.createElement('div');
  bar.className = 'hist-splitter';
  bar.title = '上下拖动调整高度，双击平均分配';
  bar.addEventListener('pointerdown', e => {
    if (e.button !== 0) return;
    e.preventDefault();
    const heights = AGENT_IDS.map(id => histSections[id].sec.getBoundingClientRect().height);
    const startY = e.clientY;
    const MIN = 34;
    try { bar.setPointerCapture(e.pointerId); } catch (_) { /* 忽略 */ }
    bar.classList.add('dragging');
    document.body.classList.add('resizing-row');
    const move = ev => {
      const total = heights[i] + heights[i + 1];
      const a = clamp(heights[i] + ev.clientY - startY, MIN, total - MIN);
      const h = heights.slice();
      h[i] = a;
      h[i + 1] = total - a;
      sectionWeights = h.map(x => Math.max(1, Math.round(x)));
      applySectionWeights(false);
    };
    const up = () => {
      bar.removeEventListener('pointermove', move);
      bar.removeEventListener('pointerup', up);
      bar.removeEventListener('pointercancel', up);
      bar.classList.remove('dragging');
      document.body.classList.remove('resizing-row');
      lsSet('section_weights', JSON.stringify(sectionWeights));
      applySectionWeights();
    };
    bar.addEventListener('pointermove', move);
    bar.addEventListener('pointerup', up);
    bar.addEventListener('pointercancel', up);
  });
  bar.addEventListener('dblclick', () => {
    sectionWeights = AGENT_IDS.map(() => 1);
    applySectionWeights();
    lsSet('section_weights', '');
  });
  return bar;
}

// ===== 左右拖动：历史栏宽度、桌宠活动空间 =====
const COLUMNS = {
  sidebar: { key: 'sidebar_w', def: 260, min: 200, max: 480, cssVar: '--sidebar-w' },
  stage: { key: 'stage_w', def: 330, min: 240, max: 760, cssVar: '--stage-w' },
  preview: { key: 'preview_w', def: 560, min: 340, max: 1600, cssVar: '--preview-w' },
};
const widths = {
  sidebar: parseInt(lsGet('sidebar_w', ''), 10) || COLUMNS.sidebar.def,
  stage: parseInt(lsGet('stage_w', ''), 10) || COLUMNS.stage.def,
  preview: parseInt(lsGet('preview_w', ''), 10) || COLUMNS.preview.def,
};

function applyWidths() {
  const sidebarOn = !document.body.classList.contains('sidebar-hidden');
  const paneEl = document.getElementById('preview-pane');
  const previewOn = !!paneEl && !paneEl.hidden;
  const maxed = previewOn && document.body.classList.contains('preview-max');
  let sw = clamp(widths.sidebar, COLUMNS.sidebar.min, COLUMNS.sidebar.max);
  let tw = clamp(widths.stage, COLUMNS.stage.min, COLUMNS.stage.max);
  let pw = clamp(widths.preview, COLUMNS.preview.min, COLUMNS.preview.max);
  const room = window.innerWidth - (maxed ? 0 : 380) - 15;   // 中间聊天至少留 380px
  const used = () => (sidebarOn ? sw : 0) + tw + (previewOn && !maxed ? pw : 0);
  // 放不下时先缩预览，再缩舞台，最后缩左栏
  if (previewOn && !maxed && used() > room) pw = Math.max(COLUMNS.preview.min, pw - (used() - room));
  if (used() > room) tw = Math.max(COLUMNS.stage.min, tw - (used() - room));
  if (sidebarOn && used() > room) sw = Math.max(COLUMNS.sidebar.min, sw - (used() - room));
  // 还放不下（窗口很窄又开着预览）：先把桌宠舞台收起来，窗口变宽后自动回来，聊天和预览优先
  const squeezed = used() > room;
  document.body.classList.toggle('stage-squeezed', squeezed);
  if (squeezed) tw = 0;
  document.documentElement.style.setProperty('--sidebar-w', `${sw}px`);
  document.documentElement.style.setProperty('--stage-w', `${tw}px`);
  document.documentElement.style.setProperty('--preview-w', `${pw}px`);
  AGENT_IDS.forEach(a => pets[a] && pets[a].clampPosition());
  if (typeof syncBrowser === 'function') syncBrowser();   // 内置浏览器跟着预览面板移动
}

function setupColumnResizer(el, which) {
  el.addEventListener('pointerdown', e => {
    if (e.button !== 0) return;
    e.preventDefault();
    const target = which === 'sidebar' ? els.sidebar : (which === 'stage' ? els.stage : document.getElementById('preview-pane'));
    const startX = e.clientX;
    const startW = target.getBoundingClientRect().width;
    try { el.setPointerCapture(e.pointerId); } catch (_) { /* 忽略 */ }
    el.classList.add('dragging');
    document.body.classList.add('resizing-col');
    closePopover();
    let snapped = false;
    const move = ev => {
      const dx = ev.clientX - startX;
      let w = which === 'sidebar' ? startW + dx : startW - dx;
      // 靠近默认宽度时吸过去（差 9px 以内），吸上的那一下触控板轻轻一震；要再拖开得多拖出这一小段
      const near = Math.abs(w - COLUMNS[which].def) <= 9;
      if (near) w = COLUMNS[which].def;
      if (near && !snapped) postNative('haptic', {});
      snapped = near;
      widths[which] = w;
      applyWidths();
    };
    const up = () => {
      el.removeEventListener('pointermove', move);
      el.removeEventListener('pointerup', up);
      el.removeEventListener('pointercancel', up);
      el.classList.remove('dragging');
      document.body.classList.remove('resizing-col');
      widths[which] = Math.round(target.getBoundingClientRect().width);
      lsSet(COLUMNS[which].key, widths[which]);
    };
    el.addEventListener('pointermove', move);
    el.addEventListener('pointerup', up);
    el.addEventListener('pointercancel', up);
  });
  el.addEventListener('dblclick', () => {
    widths[which] = COLUMNS[which].def;
    lsSet(COLUMNS[which].key, '');
    applyWidths();
  });
}

function setSidebarHidden(hidden) {
  document.body.classList.toggle('sidebar-hidden', hidden);
  lsSet('sidebar_hidden', hidden ? '1' : '');
  applyWidths();
}

/** 没有原生标题栏，这些空白处按住可拖动窗口、双击缩放。 */
function makeDragRegion(el, onlySelf = false) {
  const blocked = e => e.button !== 0 || (onlySelf && e.target !== el) || !!e.target.closest('button, input, textarea, select, a');
  el.addEventListener('mousedown', e => { if (!blocked(e)) postNative('startWindowDrag'); });
  el.addEventListener('dblclick', e => { if (!blocked(e)) postNative('zoomWindow'); });
}
