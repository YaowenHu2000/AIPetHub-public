// 不用 CLI（REAL=1 跑，能截到画布）：拖拽时每一位都还看得见，气泡跟着她、不跑到一边。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const out = { steps: [], ok: true, errors: [] };
window.addEventListener('error', e => out.errors.push(String(e.message) + ' @' + (e.filename || '').split('/').pop() + ':' + e.lineno));
window.addEventListener('unhandledrejection', e => out.errors.push('rejection: ' + String(e.reason && e.reason.stack || e.reason).slice(0, 300)));
const check = (name, pass, got) => { out.steps.push(`${pass ? '✓' : '✗'} ${name}：${JSON.stringify(got)}`); if (!pass) out.ok = false; };
/** 画布上有多少像素不透明（看她是不是真的画出来了）。 */
const inked = canvas => {
  try {
    const c = document.createElement('canvas'); c.width = 64; c.height = 64;
    const g = c.getContext('2d'); g.drawImage(canvas, 0, 0, 64, 64);
    const d = g.getImageData(0, 0, 64, 64).data; let n = 0;
    for (let i = 3; i < d.length; i += 4) if (d[i] > 40) n++;
    return n;
  } catch (e) { return 'err ' + e.message; }
};
const look = p => {
  const canvas = p.body.querySelector('.pet-rig-canvas');
  const front = p.front, fr = front.getBoundingClientRect();
  const w = p.walker.getBoundingClientRect(), b = p.bubbleEl.getBoundingClientRect(), f = p.floor.getBoundingClientRect();
  return {
    state: p.state, rig: !!p.rig, cls: p.body.className, frame: p.frameKey,
    canvas: canvas ? { display: getComputedStyle(canvas).display, w: canvas.width, h: canvas.height, ink: inked(canvas) } : null,
    front: { vis: getComputedStyle(front).visibility, op: getComputedStyle(front).opacity, w: Math.round(fr.width), src: (front.currentSrc || front.src).split('/').slice(-2).join('/'), ok: front.complete && front.naturalWidth > 0 },
    petCenter: Math.round(w.left + w.width / 2 - f.left), bubbleCenter: Math.round(b.left + b.width / 2 - f.left), bubbleL: Math.round(b.left - f.left), bubbleR: Math.round(f.right - b.right), bubbleW: Math.round(b.width),
  };
};
try {
  await sleep(2500);
  for (const id of AGENT_IDS) {
    const p = pets[id];
    const idle = look(p);
    p.pointer = { id: 1, startX: 0, startY: 0, x0: p.x, y0: p.y };
    p.startDrag();
    const { maxX, maxLift } = p.bounds();
    for (let i = 1; i <= 10; i++) { const nx = maxX * i / 10; if (p.rig) p.rig.dragMove(nx - p.x); p.x = nx; p.y = -maxLift * 0.5 * i / 10; p.applyPosition(); await sleep(40); }
    await sleep(700);
    const drag = look(p);
    await realShot('drag-' + id);
    // 画布是 WebGL 的，读不出像素；这里只看「画布在、没被藏」或者「逐帧图在、看得见」，真看见没有以截图为准
    const seen = drag.canvas && drag.canvas.display !== 'none' && drag.cls.includes('rigged') && !drag.cls.includes('rig-off') ? true : (drag.front.ok && drag.front.vis === 'visible' && Number(drag.front.op) > 0.5);
    check(`${id} 拖着时看得见`, seen, drag);
    check(`${id} 气泡在卡片里，中心离她不超过半个气泡宽`, drag.bubbleL >= 0 && drag.bubbleR >= 0 && Math.abs(drag.bubbleCenter - drag.petCenter) <= Math.max(12, drag.bubbleW / 2), { pet: drag.petCenter, bubble: drag.bubbleCenter, L: drag.bubbleL, R: drag.bubbleR, w: drag.bubbleW });
    out.steps.push(`  ${id} 待机时：` + JSON.stringify(idle));
    p.pointer = null; p.endDrag(); await sleep(1500);
    p.x = 0; p.y = 0; p.applyPosition();
  }
  // 移除再加回来之后：骨骼重新建好，拖她还看得见
  const saved = localStorage.getItem('aihub_enabled_agents');
  const last = AGENT_IDS[AGENT_IDS.length - 1], q = pets[last];
  disableAgent(last); await sleep(600);
  check(`移除 ${last}：骨骼收掉`, !q.rig && !q.body.querySelector('.pet-rig-canvas') && !q.body.classList.contains('rigged'), q.body.className);
  enableAgent(last); await sleep(3000);
  check(`加回 ${last}：骨骼重新建好`, !!q.rig && !!q.body.querySelector('.pet-rig-canvas'), { rig: !!q.rig, cls: q.body.className });
  q.pointer = { id: 1, startX: 0, startY: 0, x0: q.x, y0: q.y }; q.startDrag(); q.y = -q.bounds().maxLift * 0.4; q.applyPosition(); await sleep(700);
  const again = look(q); await realShot('drag-readded');
  check(`加回后拖 ${last}：画布在、没有被藏起来`, again.canvas && again.canvas.display !== 'none' && again.cls.includes('rigged'), again);
  q.pointer = null; q.endDrag(); await sleep(800); q.x = 0; q.y = 0; q.applyPosition();
  if (saved === null) localStorage.removeItem('aihub_enabled_agents'); else localStorage.setItem('aihub_enabled_agents', saved);
  check('没有脚本报错', out.errors.length === 0, out.errors);
} catch (e) { out.ok = false; out.error = String(e && e.stack || e); }
return out;
