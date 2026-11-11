// 不用 CLI：「在别处运行中」的标记——出现、撤掉、后面有了新提问就不标。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const out = { steps: [], ok: true };
const check = (name, pass, got) => { out.steps.push(`${pass ? '✓' : '✗'} ${name}：${JSON.stringify(got)}`); if (!pass) out.ok = false; };
try {
  await sleep(800);
  const id = active, box = S[id].msgEl;
  renderMessages(id, [
    { role: 'user', text: '问题' },
    { role: 'bot', text: '中途说明', duration: 335, steps: [{ kind: 'think', title: '思考', status: 'done' }, { kind: 'command', title: '运行命令', status: 'done', detail: 'ls' }] },
  ], '');
  const label = () => box.querySelector('.work-label')?.textContent;
  const before = label();
  S[id].elsewhereAt = Date.now(); markElsewhere(id);
  const work = box.querySelector('.work');
  check('标上：标题换成「在别处运行中」', work.classList.contains('elsewhere') && label().startsWith('在别处运行中'), { before, after: label() });
  const cs = getComputedStyle(box.querySelector('.work-label'));
  check('有动效（扫光 + 跳动的点）', cs.animationName.includes('label-sweep') && getComputedStyle(box.querySelector('.work-label'), '::before').animationName.includes('pulse'), cs.animationName);
  S[id].elsewhereAt = 0; markElsewhere(id);
  check('撤掉：标题变回去', !work.classList.contains('elsewhere') && label() === before, label());
  renderOneMessage(id, { role: 'user', text: '又问了一句' }, undefined, '');
  S[id].elsewhereAt = Date.now(); markElsewhere(id);
  check('后面已经有新的提问：不标', !box.querySelector('.work.elsewhere'), label());
} catch (e) { out.ok = false; out.error = String(e && e.stack || e); }
return out;
