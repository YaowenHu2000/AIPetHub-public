// 不用 CLI：思考强度滑杆的流动——开 fast 的那一下画面不能跳（颜色和粒子接着原来的位置），速度从零慢慢加上去。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const out = { steps: [], ok: true, errors: [] };
window.addEventListener('error', e => out.errors.push(String(e.message)));
const check = (name, pass, got) => { out.steps.push(`${pass ? '✓' : '✗'} ${name}：${JSON.stringify(got)}`); if (!pass) out.ok = false; };
try {
  await sleep(1500);
  setActive('claude', false);
  S.claude.model = 'opus'; S.claude.fast = false; renderComposer();
  els.chipModel.click();
  await sleep(900);
  const st = () => effortFlowState;
  check('面板开着、在画', !!st() && !!els.popover.querySelector('.mp-fill canvas'), { state: !!st() });
  check('40 颗粒子', st().dots.length === 40, st().dots.length);
  const snap = () => ({ phase: st().phase, speed: st().speed, dots: st().dots.map(d => [d.x, d.y]) });
  // 平时也在流：一秒里颜色往前走、粒子整体往右漂
  const a = snap(); await sleep(1000); const b = snap();
  const driftIdle = b.dots.reduce((s, d, i) => s + ((d[0] - a.dots[i][0] + 1.5) % 1 - 0.5), 0) / 40;
  check('平时颜色在流、粒子往右漂', b.phase - a.phase > 0.05 && driftIdle > 0, { dPhase: +(b.phase - a.phase).toFixed(3), drift: +driftIdle.toFixed(4), speed: +b.speed.toFixed(3) });
  // 点 fast 的那一下：画面不跳
  const canvasBefore = els.popover.querySelector('.mp-fill canvas');
  const before = snap();
  els.popover.querySelector('.mp-fast').click();
  await sleep(50);
  const after = snap();
  // 正好漂出右边、从左边重新进来的那一颗不算（它在条的外面换的高度，看不见）
  const jump = Math.max(...after.dots.map((d, i) => (before.dots[i][0] > 0.97 || d[0] < 0.03) ? 0 : Math.hypot(d[0] - before.dots[i][0], d[1] - before.dots[i][1])));
  check('点 fast 的那一下：粒子没有换位置', jump < 0.02, { maxMove: +jump.toFixed(4) });
  check('点 fast 的那一下：颜色没有跳', Math.abs(after.phase - before.phase) < 0.02, { dPhase: +(after.phase - before.phase).toFixed(4) });
  check('点 fast 的那一下：速度还几乎是零（不是凭空有了速度）', after.speed < 0.03, { speed: +after.speed.toFixed(4) });
  check('fast 开了，按钮亮着，画布没有换', S.claude.fast === true && els.popover.querySelector('.mp-fast').classList.contains('on') && els.popover.querySelector('.mp-fill canvas') === canvasBefore, { fast: S.claude.fast });
  // 之后慢慢加速，越来越快，最后匀速
  const speeds = [];
  for (const t of [250, 250, 500, 1000, 1500]) { await sleep(t); speeds.push(+st().speed.toFixed(2)); }
  check('速度从零慢慢加上去，最后到全速', speeds[0] < 0.3 && speeds.every((v, i) => i === 0 || v >= speeds[i - 1]) && speeds[4] > 0.95, speeds);
  // 关掉：慢慢收下来，画面也不跳
  const b2 = snap();
  els.popover.querySelector('.mp-fast').click();
  await sleep(50);
  const a2 = snap();
  check('关 fast 的那一下：速度没有突然掉下来', a2.speed > 0.9, { before: +b2.speed.toFixed(2), after: +a2.speed.toFixed(2) });
  await sleep(3500);
  check('之后慢慢收到平时的样子', st().speed < 0.06, +st().speed.toFixed(3));
  check('没有脚本报错', out.errors.length === 0, out.errors);
  S.claude.fast = false; lsSet('claude_fast', ''); closePopover();
} catch (e) { out.ok = false; out.error = String(e) + ' | ' + String(e && e.stack).slice(0, 300); }
return out;
