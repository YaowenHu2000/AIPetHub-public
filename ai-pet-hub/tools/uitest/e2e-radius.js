// 圆角回归：验证 squircle.css 里的 --r 值，以及每个目标元素的曲线是否会相交。
// 运行：tools/uitest/run.sh gpt e2e-radius.js
const sleep = ms => new Promise(r => setTimeout(r, ms));
const round1 = n => Math.round(n * 10) / 10;
const rectOf = el => {
  const r = el.getBoundingClientRect();
  return { left: round1(r.left), top: round1(r.top), width: round1(r.width), height: round1(r.height) };
};
const cssRadius = el => {
  const raw = getComputedStyle(el).getPropertyValue('--r').trim();
  const value = parseFloat(raw);
  return { raw, px: Number.isFinite(value) ? round1(value) : null };
};
const expectedFor = label => label === '#popover' || label === '.composer-box' ? 18 : label === '.composer-box .chip' ? 9 : 10;
const measure = (label, el, index = null) => {
  const radius = cssRadius(el);
  const rect = rectOf(el);
  const shortEdge = Math.min(rect.width, rect.height);
  const lhs = radius.px == null ? null : round1(1.53 * radius.px);
  const limit = round1(shortEdge / 2);
  const geometryPass = lhs != null && lhs <= limit + 1e-6;
  const expected = expectedFor(label);
  const radiusPass = radius.px != null && Math.abs(radius.px - expected) <= 1e-6;
  return {
    selector: label,
    index,
    radius: radius.px,
    radiusCSS: radius.raw,
    expectedRadius: expected,
    rect,
    shortEdge,
    curveLimit: limit,
    curveNeed: lhs,
    radiusPass,
    geometryPass,
    pass: radiusPass && geometryPass,
  };
};

const out = { agent: 'gpt', phases: [], violations: [], pass: false };
try {
  // 该回归固定在 gpt 的模型面板上跑，保证面板和 .pop-item 都实际进入布局。
  setActive('gpt');
  await sleep(600);

  // 打开模型面板；usage-box 是面板的最后一块，出现后再量，避免量到空面板。
  els.chipModel.click();
  const t0 = Date.now();
  while (Date.now() - t0 < 10000 && (els.popover.hidden || !els.popover.querySelector('.usage-box'))) await sleep(100);
  await sleep(650); // 等 popSpring / 可能的 usage 重排收住

  const initial = [];
  const pop = document.getElementById('popover');
  const composer = document.querySelector('.composer-box');
  if (pop) initial.push(measure('#popover', pop));
  if (composer) initial.push(measure('.composer-box', composer));
  document.querySelectorAll('.composer-box .chip').forEach((el, i) => initial.push(measure('.composer-box .chip', el, i)));
  out.phases.push({ name: 'panel', elements: initial });

  // 模型面板第一页没有 .pop-item；切到模型列表页后把每个 .pop-item 都纳入检查。
  const modelButton = els.popover.querySelector('.mp-model');
  if (modelButton) {
    modelButton.click();
    await sleep(700);
  }
  const list = [];
  if (pop) list.push(measure('#popover', pop));
  if (composer) list.push(measure('.composer-box', composer));
  document.querySelectorAll('.composer-box .chip').forEach((el, i) => list.push(measure('.composer-box .chip', el, i)));
  const popItems = els.popover.querySelectorAll('.pop-item');
  popItems.forEach((el, i) => list.push(measure('.pop-item', el, i)));
  out.phases.push({ name: 'model-list', elements: list });

  out.elements = out.phases.flatMap(phase => phase.elements.map(e => ({ phase: phase.name, ...e })));
  out.presence = {
    popover: !!pop,
    composerBox: !!composer,
    composerChips: document.querySelectorAll('.composer-box .chip').length,
    popItems: popItems.length,
  };
  out.violations = out.elements.filter(e => !e.pass).map(e => ({
    phase: e.phase,
    selector: e.selector,
    index: e.index,
    reason: [
      !e.radiusPass ? `--r=${e.radiusCSS || '(空)'}，期望 ${e.expectedRadius}px` : null,
      !e.geometryPass ? `1.53×r=${e.curveNeed}px > 短边一半=${e.curveLimit}px` : null,
    ].filter(Boolean),
    radius: e.radius,
    rect: e.rect,
    shortEdge: e.shortEdge,
    curveNeed: e.curveNeed,
    curveLimit: e.curveLimit,
  }));
  if (!pop || !composer || out.presence.composerChips < 1 || out.presence.popItems < 1) {
    out.violations.push({
      selector: 'required selectors',
      reason: [
        !pop ? '#popover 缺失' : null,
        !composer ? '.composer-box 缺失' : null,
        out.presence.composerChips < 1 ? '.composer-box .chip 缺失' : null,
        out.presence.popItems < 1 ? '.pop-item 未进入模型列表布局' : null,
      ].filter(Boolean),
    });
  }
  out.pass = out.elements.length > 0 && out.violations.length === 0;
  if (typeof closePopover === 'function') closePopover();
} catch (e) {
  out.error = String(e && e.message || e);
}
return out;
