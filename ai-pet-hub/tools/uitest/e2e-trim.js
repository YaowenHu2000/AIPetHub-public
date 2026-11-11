// 不用 CLI：左栏每一格的底边不留「被切掉一半的行」——滚动、拖分隔条之后都是。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const out = { steps: [], ok: true };
const check = (name, pass, got) => { out.steps.push(`${pass ? '✓' : '✗'} ${name}：${JSON.stringify(got)}`); if (!pass) out.ok = false; };
/** 每一格里，露出来的部分只有一半（上半截在、下半截被底边切掉）的行。裁掉显示的那一段不算露出来。 */
const halfRows = () => AGENT_IDS.map(id => {
  const list = histSections[id].list, box = list.getBoundingClientRect();
  const clip = parseFloat((list.style.clipPath.match(/inset\(0(?:px)? 0(?:px)? ([\d.]+)px/) || [])[1] || 0);
  const edge = box.bottom - clip;
  const bad = [...list.querySelectorAll('.conv-row, .grp-head, .see-all')].filter(r => { const b = r.getBoundingClientRect(); return b.top < edge - 1 && b.bottom > edge + 1; });
  return { id, clip: Math.round(clip), half: bad.map(r => r.textContent.trim().slice(0, 12)), scrollable: list.scrollHeight > list.clientHeight + 1 };
});
try {
  await sleep(2500);
  // 造够多的会话，让每一格都放不下
  AGENT_IDS.forEach(id => {
    S[id].conversations = Array.from({ length: 40 }, (_, i) => ({ id: `t${id}${i}`, title: `测试会话 ${i}`, time: '', timestamp: Date.now() / 1000 - i * 600, cwd: `/tmp/proj${i % 4}` }));
    AGENT_IDS.forEach(() => 0);
    renderHistory(id);
  });
  queueSectionFit(); await sleep(500);
  let r = halfRows();
  check('内容放不下时，各格底边没有半行', r.every(x => x.half.length === 0) && r.some(x => x.scrollable), r);
  // 每一格各滚到几个不凑巧的位置
  let worst = [];
  for (const y of [7, 13, 22, 41, 77, 133, 201]) {
    AGENT_IDS.forEach(id => { histSections[id].list.scrollTop = y; });
    await sleep(260);
    r = halfRows();
    if (r.some(x => x.half.length)) worst.push({ y, r: r.filter(x => x.half.length) });
  }
  check('滚到各种位置，底边都没有半行', worst.length === 0, worst);
  // 拖分隔条：把第一格拖成各种高度
  worst = [];
  const bar = document.querySelector('.hist-splitter'), b = bar.getBoundingClientRect();
  const ev = (type, y) => bar.dispatchEvent(new PointerEvent(type, { bubbles: true, button: 0, pointerId: 7, clientX: b.left + 20, clientY: y }));
  ev('pointerdown', b.top + 3);
  for (const dy of [-37, -11, 5, 19, 46, 63]) {
    ev('pointermove', b.top + 3 + dy);
    await sleep(220);
    r = halfRows();
    if (r.some(x => x.half.length)) worst.push({ dy, r: r.filter(x => x.half.length) });
  }
  ev('pointerup', b.top + 3 + 63);
  await sleep(400);
  r = halfRows();
  check('拖分隔条的过程中和松手后，底边都没有半行', worst.length === 0 && r.every(x => x.half.length === 0), { during: worst, after: r });
  check('裁掉的不超过一行高', r.every(x => x.clip <= 30), r.map(x => x.clip));
  postNative('testSnapshot', { path: DIR + '/trim.png' }); await sleep(600);
  lsSet('section_weights', '');
} catch (e) { out.ok = false; out.error = String(e) + ' | ' + String(e && e.stack).slice(0, 300); }
return out;
