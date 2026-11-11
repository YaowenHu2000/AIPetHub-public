// GPT 模型面板的左右边缘对齐检查（只量网页坐标，不需要 CLI）。
// 运行：tools/uitest/run.sh gpt e2e-panel-align.js
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const until = async (cond, ms, what) => {
  const started = Date.now();
  while (Date.now() - started < ms) {
    const value = cond();
    if (value) return value;
    await sleep(150);
  }
  throw new Error('等不到：' + what);
};

const fixed = n => Number.isFinite(n) ? n.toFixed(1) : null;
const box = el => el && el.getBoundingClientRect();
const stylePx = (el, name) => parseFloat(getComputedStyle(el)[name]) || 0;
const out = { steps: [] };
const note = (name, value) => out.steps.push(name + ' = ' + JSON.stringify(value));

// #popover 的 padding 盒内沿（content box 的左右边界）：边框 + padding 之后，
// 正是滑杆、分隔线和用量文字要贴的两条线。
const contentEdges = pop => {
  const r = box(pop);
  return {
    left: r.left + stylePx(pop, 'border-left-width') + stylePx(pop, 'padding-left'),
    right: r.right - stylePx(pop, 'border-right-width') - stylePx(pop, 'padding-right'),
  };
};

const comparison = (name, el, edges, tolerance = 1, sides = ['left', 'right']) => {
  if (!el) return { 名称: name, 存在: false, 超差: ['元素不存在'] };
  const r = box(el);
  const result = { 名称: name, 左: fixed(r.left), 右: fixed(r.right), 误差: {}, 超差: [] };
  if (sides.includes('left')) {
    const d = r.left - edges.left;
    result.误差.左 = fixed(d);
    if (Math.abs(d) > tolerance + 1e-7) result.超差.push('左');
  }
  if (sides.includes('right')) {
    const d = r.right - edges.right;
    result.误差.右 = fixed(d);
    if (Math.abs(d) > tolerance + 1e-7) result.超差.push('右');
  }
  result.通过 = result.超差.length === 0;
  return result;
};

// SVG 的 getBBox() 在 SVG 自己的坐标系里；用 getScreenCTM() 把四个角换成
// 窗口（CSS）坐标后再取 min/max，就是图形本身的可见左右边。
const svgVisibleEdges = (name, svg, edges) => {
  if (!svg) return { 名称: name, 存在: false, 超差: ['SVG 不存在'] };
  let bb, matrix;
  try {
    bb = svg.getBBox();
    matrix = svg.getScreenCTM();
  } catch (e) {
    return { 名称: name, 存在: false, 超差: ['getBBox/getScreenCTM 失败：' + String(e)] };
  }
  if (!matrix) return { 名称: name, 存在: false, 超差: ['getScreenCTM 为空'] };
  const pts = [
    [bb.x, bb.y], [bb.x + bb.width, bb.y],
    [bb.x, bb.y + bb.height], [bb.x + bb.width, bb.y + bb.height],
  ].map(([x, y]) => ({
    x: matrix.a * x + matrix.c * y + matrix.e,
    y: matrix.b * x + matrix.d * y + matrix.f,
  }));
  const left = Math.min(...pts.map(p => p.x));
  const right = Math.max(...pts.map(p => p.x));
  const dl = left - edges.left, dr = right - edges.right;
  const over = [];
  if (Math.abs(dl) > 2 + 1e-7) over.push('左');
  if (Math.abs(dr) > 2 + 1e-7) over.push('右');
  return {
    名称: name,
    左: fixed(left),
    右: fixed(right),
    误差: { 左: fixed(dl), 右: fixed(dr) },
    容差: '2.0px',
    超差: over,
    通过: over.length === 0,
  };
};

try {
  const id = 'gpt';
  setActive(id);
  // 保持当前面板状态即可；这些值只是让按钮上的模型标签确定，不会启动 CLI。
  if (typeof MODEL === 'string' && MODEL) S[id].model = MODEL;
  S[id].effort = S[id].effort || 'low';
  renderComposer();
  await sleep(250);

  // 按要求从 composer 的按钮打开，而不是直接调用 openModelPopover。
  els.chipModel.click();
  await until(() => !els.popover.hidden && els.popover.classList.contains('model-pop'), 5000, 'GPT 模型面板打开');
  // 测试分支不启动后台轮询，主动请求一次用量。
  postNative('loadUsage', { agent: 'gpt' });
  await sleep(350); // 等面板的入场弹簧停下，避免把中间帧当作坐标。

  // 剩余用量是异步从原生层推回来的；等「正在查…」消失，保证用量区已经可量。
  const usageBox = await until(() => {
    const wrap = els.popover.querySelector('.usage-box[data-agent="gpt"]');
    if (!wrap) return null;
    const text = wrap.textContent.trim();
    return text && text !== '正在查…' ? wrap : null;
  }, 60000, 'GPT 剩余用量区');
  await sleep(180);

  const edges = contentEdges(els.popover);
  const entries = [];
  note('面板内容区（#popover padding 盒内沿）', { 左: fixed(edges.left), 右: fixed(edges.right) });

  const collect = (selector, label, sides = ['left', 'right']) => {
    const list = [...els.popover.querySelectorAll(selector)];
    if (!list.length) entries.push(comparison(label + '[0]', null, edges, 1, sides));
    else list.forEach((el, i) => entries.push(comparison(label + '[' + i + ']', el, edges, 1, sides)));
    return list;
  };
  collect('.mp-slider', '.mp-slider');
  collect('.pop-sep', '.pop-sep');
  collect('.usage-title', '.usage-title');
  collect('.usage-age', '.usage-age（右边）', ['right']);
  [...els.popover.querySelectorAll('.usage-row')].forEach((el, i) => {
    entries.push(comparison('.usage-row[' + i + ']', el, edges, 1));
    const rightmost = el.querySelector('.usage-reset') || el.querySelector('.usage-text');
    entries.push(comparison(
      '.usage-row[' + i + '] 最右元素（' + (rightmost?.className || '缺少 .usage-reset/.usage-text') + ' 的右边）',
      rightmost, edges, 1, ['right'],
    ));
  });
  if (!els.popover.querySelector('.usage-row')) {
    entries.push(comparison('.usage-row[0]', null, edges, 1));
    entries.push(comparison('.usage-row[0] 最右元素', null, edges, 1, ['right']));
  }

  const icons = [...els.popover.querySelectorAll('.mp-head .mp-icon')];
  const leftIcon = svgVisibleEdges('左侧 .mp-icon svg 图形可见左边', icons[0]?.querySelector('svg'), edges);
  leftIcon.超差 = leftIcon.超差.filter(x => x === '左');
  leftIcon.通过 = leftIcon.超差.length === 0;
  entries.push(leftIcon);
  const rightIcon = svgVisibleEdges('右侧 .mp-icon svg 图形可见右边', icons[1]?.querySelector('svg'), edges);
  rightIcon.超差 = rightIcon.超差.filter(x => x === '右');
  rightIcon.通过 = rightIcon.超差.length === 0;
  entries.push(rightIcon);

  entries.forEach(entry => note(entry.名称, entry));
  const regular = entries.filter(e => e.容差 !== '2.0px');
  const svg = entries.filter(e => e.容差 === '2.0px');
  const missing = entries.filter(e => e.存在 === false);
  const overRegular = regular.filter(e => e.超差?.length);
  const overSvg = svg.filter(e => e.超差?.length);
  note('对齐总判定', {
    普通元素容差: '1.0px',
    svg图形容差: '2.0px',
    普通元素超差数: overRegular.length,
    svg图形超差数: overSvg.length,
    未出现元素数: missing.length,
    通过: overRegular.length === 0 && overSvg.length === 0 && missing.length === 0,
  });
  note('实际用量区文字', usageBox.textContent.replace(/\s+/g, ' ').trim());
  closePopover();
} catch (e) {
  out.error = String(e && e.message || e);
}
return out;
