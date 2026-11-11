// REAL=1：截取整窗并记录左栏底色与会话标题颜色。
// 颜色平均值从脚本生成的 sidebar.png 用外部像素读取工具计算，避免浏览器截图缩放影响。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const r1 = n => Math.round(n * 10) / 10;
const box = el => {
  const r = el.getBoundingClientRect();
  return { left: r1(r.left), top: r1(r.top), right: r1(r.right), bottom: r1(r.bottom), width: r1(r.width), height: r1(r.height) };
};
const parseRgb = s => {
  const m = String(s || '').match(/rgba?\(\s*([\d.]+)[, ]+\s*([\d.]+)[, ]+\s*([\d.]+)/i);
  return m ? m.slice(1, 4).map(Number) : s;
};
const out = { steps: [] };
const note = (k, v) => { out.steps.push(k + ' = ' + JSON.stringify(v)); };
try {
  setActive('gpt');
  await sleep(1800);
  const sidebar = document.getElementById('history-sidebar');
  const row = sidebar.querySelector('.conv-row:not(.pending)') || sidebar.querySelector('.conv-row');
  const title = row?.querySelector('.conv-title');
  const sr = sidebar.getBoundingClientRect();
  const cs = getComputedStyle(sidebar);
  const titleColor = title ? getComputedStyle(title).color : null;
  note('左栏 DOM 几何', box(sidebar));
  note('左栏背景计算样式', { background: cs.backgroundColor, image: cs.backgroundImage, sideGlass: getComputedStyle(document.documentElement).getPropertyValue('--side-glass').trim() });
  note('会话标题文字颜色', { css: titleColor, rgb: parseRgb(titleColor), element: title ? box(title) : null });
  // 在左栏内搜集不落在文字/按钮/会话行上的候选空白点，供截图像素平均使用。
  const points = [];
  for (let y = Math.ceil(sr.top + 8); y < sr.bottom - 8; y += 7) {
    for (let x = Math.ceil(sr.left + 8); x < sr.right - 8; x += 11) {
      const els = document.elementsFromPoint(x, y);
      const hasContent = els.some(e => e.matches?.('.conv-row, .conv-row *, input, button, .search-field, .search-field *'));
      if (!hasContent && els.some(e => e === sidebar || e.closest?.('#history-sidebar') === sidebar)) {
        points.push({ x: r1(x), y: r1(y) });
      }
    }
  }
  note('左栏截图空白候选点', points.slice(0, 80));
  await realShot('sidebar');
  await sleep(500);
} catch (e) {
  out.error = String(e && e.message || e);
  try { await realShot('sidebar-error'); } catch (_) {}
}
return out;
