/**
 * App 里的桌宠骨骼动画控制器：每位桌宠一块 WebGL 画布，盖在原来的立绘位置上（四周多留 20%，摆动、特效不被裁掉）。
 *
 * 对外（window.PetRig）：
 *   PetRig.create(id, bodyEl) → Promise<controller | null>   没有这位的模型数据（window.__PET_RIGS[id]）就返回 null，App 继续用逐帧
 *   controller.setState(state)   idle / walk / happy / sleep / thinking / reading / working / dragged
 *   controller.dragMove(dx, dy)  拖拽时鼠标每次移动的像素（驱动钟摆）
 *   controller.talk(ms)          说话：这段时间里嘴巴一张一合
 *   controller.dispose()
 *
 * 模型数据由 tools/rig/export_rig.py 导出：web/rig/<id>/rig.js（rig.json 的内容）+ 图层 / 脸部补丁（WebP）。
 * 美术来自 AI 在原画上“一层层剥”出来的分层图和脸部补丁；骨骼、弹簧物理、过渡、键盘 / 气泡 / 符号由这里的代码驱动。
 */
import * as THREE from 'three';
import { Rig } from './runtime.js';
import { drawKeyboard, drawBubble, drawFx } from './draw.js';
import { Mood } from './mood.js';

const deg = Math.PI / 180;
const rand = (a, b) => a + Math.random() * (b - a);
const pick = a => a[Math.floor(Math.random() * a.length)];
const EXPAND = 1.4;           // 画布比立绘框大多少（四周各多 20%）

class Spring {
  constructor(v = 0, k = 60, z = 1) { this.v = v; this.vel = 0; this.k = k; this.z = z; }
  step(target, dt) { const c = 2 * this.z * Math.sqrt(this.k); this.vel += (this.k * (target - this.v) - c * this.vel) * dt; this.v += this.vel * dt; return this.v; }
}

/* 所有桌宠共用一个 requestAnimationFrame */
const live = new Set();
let rafOn = false;
function loop(now) {
  for (const c of live) c.frame(now / 1000);
  if (live.size) requestAnimationFrame(loop); else rafOn = false;
}
function startLoop() { if (!rafOn) { rafOn = true; requestAnimationFrame(loop); } }


/** 姿势手臂弯：肩膀不动、手那头动。施工两手轮流敲键，查阅右手翻页、左手托着轻晃，思考手指点下巴，拖拽乱挥，待机手轻轻摆 */
function armBendValue(name, t, st) {
  const L = name.endsWith('_arm_l') || name === 'arm_l' || name === 'hand_l', d = Math.PI / 180;
  if (!name.startsWith(st + '_') && !(st === 'idle' && /^arm_[lr]$/.test(name))) return null;
  switch (st) {
    case 'working': { const k = Math.max(0, Math.sin(t * 9 + (L ? 0 : Math.PI))); return (L ? 1 : -1) * 6 * d * k * k; }
    case 'reading': return L ? 2 * d * Math.sin(t * 1.3) : -7 * d * Math.max(0, Math.sin(t * 0.9)) ** 3;
    case 'thinking': return L ? 4 * d * Math.max(0, Math.sin(t * 4.2)) : 1.5 * d * Math.sin(t * 1.1);
    case 'dragged': return (L ? 1 : -1) * 12 * d * Math.sin(t * 7 + (L ? 0 : 1.3));
    case 'idle': return (L ? 3 : -4) * d * Math.sin(t * 1.6 + (L ? 0 : 1));
    default: return null;
  }
}

class PetRigController {
  constructor(id, bodyEl, def, base) {
    this.id = id;
    this.def = def;
    this.canvas = document.createElement('canvas');
    this.canvas.className = 'pet-rig-canvas';
    bodyEl.appendChild(this.canvas);
    bodyEl.classList.add('rigged');
    this.body = bodyEl;
    this.renderer = new THREE.WebGLRenderer({ canvas: this.canvas, antialias: true, alpha: true, premultipliedAlpha: true });
    this.renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
    this.renderer.outputColorSpace = THREE.LinearSRGBColorSpace;
    this.scene = new THREE.Scene();
    this.camera = new THREE.OrthographicCamera(-1, 1, 1, -1, -1, 1);
    def.base = base;
    def.scale = 2 / EXPAND;               // 立绘正好填满原来的立绘框
    this.rig = new Rig(def, this.scene);
    this.state = 'idle';
    this.modeT = 0;
    const sp = (k, z) => new Spring(0, k, z);
    this.S = {
      head: sp(30), headTy: sp(60), foreL: sp(55, 0.75), foreR: sp(55, 0.75), handL: sp(90, 0.6), handR: sp(90, 0.6),
      poseL: sp(70, 0.6), poseR: sp(70, 0.6), poseLy: sp(120, 0.7), poseRy: sp(120, 0.7), bodyTy: sp(90, 0.5), rootRot: sp(40, 0.6),
      legL: sp(80, 0.6), legR: sp(80, 0.6), earL: sp(160, 0.35), earR: sp(160, 0.35), sleeveL: sp(25, 0.45), sleeveR: sp(25, 0.45),
    };
    this.prop = { kb: new Spring(0, 30), bubble: new Spring(0, 25) };
    this.phys = { theta: 0, omega: 0, ax: 0, vx: 0 };
    this.face = { expr: null, pending: undefined, blinkT: -1, nextBlink: 1.2, gaze: null, nextGaze: 1, talkUntil: 0, nextTalk: 5, mouthT: 0, mouth: null, idleVariant: null, nextVariant: 6 };
    this.ev = { nextEar: 2, earKick: 0, nextGlyph: 0, nextTwinkle: 0, nextZ: 0, lastTap: 0 };
    this.taps = [];
    this.particles = [];
    this.last = performance.now() / 1000;
    this.ro = new ResizeObserver(() => this.resize());
    this.ro.observe(this.canvas);
  }

  async load() {
    await this.rig.load();
    this.resize();
    live.add(this);
    startLoop();
    return this;
  }

  resize() {
    const r = this.canvas.getBoundingClientRect();
    if (r.width > 0) this.renderer.setSize(r.width, r.height, false);
  }

  setState(state) {
    if (state === this.state) return;
    this.state = state;
    this.modeT = 0;
  }

  /** 拖拽时鼠标移动（像素）：换算成画布坐标里的加速度，推钟摆 */
  dragMove(dx) {
    const w = this.canvas.clientWidth || 200;
    this.phys.pendingDx = (this.phys.pendingDx || 0) + (dx / w) * 2 * EXPAND;
  }

  talk(ms) { this.face.talkUntil = performance.now() / 1000 + ms / 1000; }

  /**
   * App 里发生的事给心情推一把（不是直接换表情）：
   *   reply 回答完了 → 开心（偶尔兴奋）；praise 被夸 / 庆祝 → 兴奋；pat 被摸头 → 害羞；
   *   error 出错 → 失落；dropped 被放下 → 不高兴一下；sent 你发了消息 → 开心；wake 刚醒 → 平静
   */
  event(name) {
    const t = performance.now() / 1000, m = this.mood;
    if (!m) return;
    const map = { reply: Math.random() < 0.3 ? ['excited', 8] : ['happy', 12], praise: ['excited', 10], pat: ['shy', 8],
      error: ['sad', 10], dropped: ['sulky', 6], sent: ['happy', 6], wake: ['calm', 1] };
    const [mood, sec] = map[name] || [];
    if (mood) m.push(mood, sec, t);
  }

  has(n) { return !!this.rig.bones[n]; }
  patch(name) { return !!(this.def.patches || {})[name]; }
  box(name) { return this.def.layers.find(l => l.name === name)?.px; }

  /** 表情：骨骼状态（待机、走路）跟着心情走；被拎着时委屈；其余状态是逐帧，不盖表情 */
  wantExpression(t) {
    if (!this.mood) this.mood = new Mood(new Set(Object.keys(this.def.patches || {})));
    const m = this.mood.step(t);           // 心情每帧都在走（逐帧状态里也走，回到骨骼时接得上）
    switch (this.state) {
      case 'dragged': return 'pout';
      case 'idle': case 'walk': return m;
      default: return null;
    }
  }

  faceStep(t, dt) {
    const F = this.face, rig = this.rig;
    const want = this.wantExpression(t);
    if (want !== F.expr && F.pending === undefined) F.pending = want;
    const asleep = this.state === 'sleep' && this.modeT > 1.2;
    if (F.blinkT < 0 && (t > F.nextBlink || F.pending !== undefined)) { F.blinkT = 0; F.nextBlink = t + rand(2.2, 5); if (Math.random() < 0.18) F.nextBlink = t + 0.35; }
    let eye = null;
    if (F.blinkT >= 0) {
      F.blinkT += dt;
      if (F.blinkT < 0.11) { eye = 'eyes_closed'; if (F.pending !== undefined) { F.expr = F.pending; F.pending = undefined; rig.setPatch(0, F.expr && this.patch(F.expr) ? F.expr : null); } }
      else F.blinkT = -1;
      if (['smile', 'wink'].includes(F.expr) && eye) eye = null;   // 眯眼笑、眨单眼时不再另外眨眼
    }
    if (asleep) eye = 'eyes_closed';
    rig.setPatch(1, eye && this.patch(eye) ? eye : null);
    // 嘴：说话时一张一合；待机偶尔自言自语
    if (this.state === 'idle' && t > F.nextTalk) { F.talkUntil = Math.max(F.talkUntil, t + rand(1.2, 2.4)); F.nextTalk = t + rand(8, 14); }
    let mouth = null;
    if ((this.state === 'thinking' || this.state === 'reading') && !F.expr) mouth = Math.sin(t * 0.7) > 0.6 ? 'mouth_o' : null;
    if (!F.expr && !mouth && t < F.talkUntil) {
      if (t > F.mouthT) { F.mouth = pick(['mouth_small', 'mouth_wide', 'mouth_o', 'mouth_closed', 'mouth_small']); F.mouthT = t + rand(0.09, 0.16); }
      mouth = F.mouth;
    }
    rig.setPatch(2, mouth && this.patch(mouth) ? mouth : null);
  }

  frame(t) {
    const dt = Math.min(0.033, Math.max(0.001, t - this.last)); this.last = t;
    if (!this.canvas.isConnected) { this.dispose(); return; }
    if (!this.canvas.offsetWidth) {          // 藏起来的时候（思考、施工、睡觉用逐帧）不画，省电；心情照样往前走
      if (!this.mood) this.mood = new Mood(new Set(Object.keys(this.def.patches || {})));
      this.mood.step(t);
      return;
    }
    this.modeT += dt;
    const { rig, S, phys, ev } = this, B = rig.bones, has = n => this.has(n), st = this.state;
    if (t > ev.nextEar) { ev.earKick = Math.random() < 0.5 ? 1 : -1; ev.nextEar = t + rand(2, 6); }

    // 呼吸（睡觉时慢而深）
    const period = st === 'sleep' ? 4.6 : 3.4, amp = st === 'sleep' ? 1.6 : 1;
    const br = 0.5 - 0.5 * Math.cos(t * Math.PI * 2 / period);
    // 二次元骨骼的呼吸：躯干是刚体、不变形；只有头和手臂跟着肩膀一起轻轻抬一点点
    B.head.ty = S.headTy.step(-0.0022 * br * amp, dt);
    for (const n of ['foreL', 'foreR', 'poseL', 'poseR', 'armL', 'armR', 'arms']) if (has(n)) B[n].ty = B.head.ty * 0.8;

    let headT = 1.3 * Math.sin(t * 0.8), hL = 0, hR = 0, fL = 0, fR = 0, pL = 0, pR = 0, pLy = 0, pRy = 0, lL = 0, lR = 0, eL = 0, eR = 0, bodyTy = 0, rootRot = 0;
    let aL = 0, aR = 0, aBoth = 0;
    if (st === 'idle') {
      hL = 7 * Math.sin(t * 3.1); hR = -7 * Math.sin(t * 3.1 + 1.4);
      fL = 2.5 * Math.sin(t * 1.2); fR = -2.5 * Math.sin(t * 1.2 + 0.8);
      aL = 1.5 * Math.sin(t * 1.3); aR = 2.5 * Math.sin(t * 1.1 + 1); aBoth = 1.2 * Math.sin(t * 1.2);
    } else if (st === 'walk') {
      const w = t * Math.PI * 2 / 0.76;                    // 一步 0.38 秒
      lL = 12 * Math.sin(w); lR = -12 * Math.sin(w);
      bodyTy = -0.006 * Math.abs(Math.sin(w));
      headT = 2 * Math.sin(w * 0.5);
      hL = 6 * Math.sin(w); hR = -6 * Math.sin(w); fL = 4 * Math.sin(w); fR = -4 * Math.sin(w);
      aL = 4 * Math.sin(w); aR = -4 * Math.sin(w); aBoth = 2 * Math.sin(w);
      rootRot = 1.2 * Math.sin(w);
    } else if (st === 'happy') {
      const w = t * Math.PI * 2 / 0.72;
      bodyTy = -0.012 * Math.max(0, Math.sin(w));
      hL = 12 * Math.sin(t * 6); hR = -12 * Math.sin(t * 6 + 1); fL = 5 * Math.sin(t * 3); fR = -5 * Math.sin(t * 3 + 1);
      aL = -6 + 5 * Math.sin(t * 6); aR = -6 - 5 * Math.sin(t * 6 + 1); aBoth = 3 * Math.sin(t * 5);
      headT = 4 * Math.sin(t * 2.4);
    } else if (st === 'sleep') {
      headT = 7 + 1.5 * Math.sin(t * 0.5);
      eL = 10; eR = -10;                                   // 耳朵耷拉下来
    } else if (st === 'thinking') {
      headT = -4 + 1.0 * Math.sin(t * 0.6);
      pL = 1.2 * Math.max(0, Math.sin(t * 4.2)); pR = 0.8 * Math.sin(t * 0.9);
    } else if (st === 'reading') {
      headT = -2 + 1.0 * Math.sin(t * 0.45);
      pL = 1.0 * Math.sin(t * 0.9); pR = 1.0 * Math.sin(t * 0.9 + 0.5); pLy = 0.002 * Math.sin(t * 1.1);
    } else if (st === 'working') {
      headT = 2 + 0.8 * Math.sin(t * 0.9);
      const pl = Math.max(0, Math.sin(t * 9.0)), pr = Math.max(0, Math.sin(t * 9.0 + Math.PI));
      pL = 1.4 * pl; pR = -1.4 * pr; pLy = 0.006 * pl; pRy = 0.006 * pr;
      const kb = this.box('kb');
      if (kb && (pl > 0.95 || pr > 0.95) && t - ev.lastTap > 0.1) {
        ev.lastTap = t;
        this.taps.push({ t, x: pl > 0.95 ? rand(kb[0] + 60, (kb[0] + kb[2]) / 2 - 10) : rand((kb[0] + kb[2]) / 2 + 10, kb[2] - 60), y: rand(kb[1] + 70, kb[3] - 30) });
      }
    } else if (st === 'dragged') {
      headT = 0;
      pL = -5 * Math.sin(t * 6.5); pR = 5 * Math.sin(t * 6.5 + 1.1);
      lL = 12 * Math.sin(t * 5.6); lR = -12 * Math.sin(t * 5.6 + 0.9);
      eL = -14; eR = 14;
      aL = -6 + 6 * Math.sin(t * 6.1); aR = -8 - 6 * Math.sin(t * 6.1 + 1.2);
    }
    B.head.rot = S.head.step(headT * deg, dt);
    if (has('handL')) { B.handL.rot = S.handL.step(hL * deg, dt); B.handR.rot = S.handR.step(hR * deg, dt); B.foreL.rot = S.foreL.step(fL * deg, dt); B.foreR.rot = S.foreR.step(fR * deg, dt); }
    if (has('armL')) { B.armL.rot = S.foreL.step(aL * deg, dt); B.armR.rot = S.foreR.step(aR * deg, dt); }
    if (has('arms')) B.arms.rot = S.foreL.step(aBoth * deg, dt);
    if (has('poseL')) { B.poseL.rot = S.poseL.step(pL * deg, dt); B.poseR.rot = S.poseR.step(pR * deg, dt); B.poseL.ty += S.poseLy.step(pLy, dt); B.poseR.ty += S.poseRy.step(pRy, dt); }
    if (has('legL')) { B.legL.rot = S.legL.step(lL * deg, dt); B.legR.rot = S.legR.step(lR * deg, dt); }
    if (has('earL')) { if (ev.earKick) { S.earL.vel += ev.earKick * 6; S.earR.vel -= ev.earKick * 4; ev.earKick = 0; } B.earL.rot = S.earL.step(eL * deg, dt); B.earR.rot = S.earR.step(eR * deg, dt); }
    if (has('cloud')) { B.cloud.ty = 0.012 * Math.sin(t * 1.6); B.cloud.rot = 3 * deg * Math.sin(t * 1.25 + 1); }
    if (has('sparkles')) { B.sparkles.ty = 0.008 * Math.sin(t * 1.1); B.sparkles.sx = B.sparkles.sy = 1 + 0.01 * Math.sin(t * 1.7); }
    B.body.ty = S.bodyTy.step(bodyTy, dt);
    if (has('fx')) { B.fx.ty = 0.006 * Math.sin(t * 1.3); B.fx.sx = B.fx.sy = 1 + 0.006 * Math.sin(t * 1.9); }

    // 被拎着：钟摆（鼠标左右甩得越快，摆得越大）；松手后慢慢回正
    if (st === 'dragged') {
      const dx = phys.pendingDx || 0; phys.pendingDx = 0;
      const v = dx / dt;
      const ax = (v - phys.vx) / dt; phys.vx = v;
      phys.ax += (ax - phys.ax) * (1 - Math.exp(-dt * 25));
      const alpha = -26 * Math.sin(phys.theta) - 2.4 * phys.omega - phys.ax * 0.045 / 0.7 * Math.cos(phys.theta) + 0.6 * Math.sin(t * 3.1);
      phys.omega += alpha * dt;
      phys.theta = Math.max(-0.5, Math.min(0.5, phys.theta + phys.omega * dt));
    } else {
      phys.theta *= Math.exp(-dt * 6); phys.omega *= Math.exp(-dt * 6); phys.vx = 0; phys.ax = 0; phys.pendingDx = 0;
    }
    B.root.rot = -phys.theta + S.rootRot.step(rootRot * deg, dt);

    // 袖子往下垂；头发、尾巴、袖子慢半拍
    if (has('sleeveL')) {
      const wb = rig.worldAngle('body');
      S.sleeveL.vel += S.foreL.vel * 0.02; S.sleeveR.vel += S.foreR.vel * 0.02;
      B.sleeveL.rot = S.sleeveL.step(0, dt) - wb * 0.85; B.sleeveR.rot = S.sleeveR.step(0, dt) - wb * 0.85;
    }
    const lag = phys.omega * 0.12 - S.head.vel * 0.25;
    const swing = st === 'dragged' ? 1.7 : st === 'idle' || st === 'walk' || st === 'happy' ? 1 : 0.6;
    for (const l of rig.layers) {
      const d = l.def.deform;
      if (!d || d.type !== 'bend') continue;
      l.bend = (d.lag || 0) * lag;
      l.wave = (d.wave || 0) * swing;
    }
    this.armBend(t, st);

    this.faceStep(t, dt);

    // 道具和特效
    const kbP = this.prop.kb.step(st === 'working' ? 1 : 0, dt), bbP = this.prop.bubble.step(st === 'thinking' ? 1 : 0, dt);
    const P = this.particles;
    if (st === 'working' && t > ev.nextGlyph) {
      ev.nextGlyph = t + rand(0.12, 0.3);
      P.push({ t0: t, life: rand(1.4, 2.2), x: rand(330, 700), y: rand(560, 620), vx: rand(-8, 8), vy: rand(-90, -60), text: pick(['</>', '{ }', '01', '=>', '#', '()', ';']), size: rand(16, 24), color: Math.random() < 0.5 ? '#e7c6ff' : '#ffe59a', a: 0.9, ph: rand(0, 6) });
    }
    if (st === 'sleep' && this.modeT > 1 && t > ev.nextZ) {
      ev.nextZ = t + rand(0.9, 1.4);
      P.push({ t0: t, life: 2.6, x: rand(600, 660), y: 300, vx: rand(10, 25), vy: -45, text: 'z', size: rand(22, 34), color: '#cfd8ff', a: 0.9, ph: rand(0, 6) });
    }
    if ((st === 'idle' || st === 'happy') && t > ev.nextTwinkle) {
      ev.nextTwinkle = t + (st === 'happy' ? rand(0.08, 0.2) : rand(0.4, 0.9));
      P.push({ t0: t, life: rand(1, 1.8), x: rand(230, 800), y: rand(280, 720), vx: 0, vy: rand(-12, -4), size: rand(5, 9), color: '#fff3c4', a: 0.85, ph: rand(0, 6) });
    }
    while (P.length && t - P[0].t0 > 3) P.shift();
    while (this.taps.length && t - this.taps[0].t > 1) this.taps.shift();
    if (this.box('kb')) rig.drawCanvas('kb', ctx => drawKeyboard(ctx, this.box('kb'), { show: kbP }, t, this.taps));
    if (this.box('bubble')) rig.drawCanvas('bubble', ctx => drawBubble(ctx, this.box('bubble'), { show: bbP }, t));
    if (this.box('fx')) rig.drawCanvas('fx', ctx => drawFx(ctx, this.box('fx'), {}, t, P));

    const pose = ['thinking', 'reading', 'working', 'dragged'].includes(st) ? st : 'idle';
    rig.setPose(pose);
    rig.stepVisibility(dt);
    rig.update(t);
    this.renderer.render(this.scene, this.camera);
  }

  armBend(t, st) {
    for (const l of this.rig.layers) {
      if (!l.def.deform || l.def.deform.type !== 'bend') continue;
      const v = armBendValue(l.def.name, t, st);
      if (v !== null) l.bend += v;
    }
  }

  dispose() {
    live.delete(this);
    this.ro.disconnect();
    this.renderer.dispose();
    this.canvas.remove();
    this.body.classList.remove('rigged');
  }
}

/** 加载一位桌宠的模型数据脚本（web/rig/<id>/rig.js 里设置 window.__PET_RIGS[id]） */
function loadData(id, base) {
  window.__PET_RIGS = window.__PET_RIGS || {};
  if (window.__PET_RIGS[id]) return Promise.resolve(window.__PET_RIGS[id]);
  return new Promise(resolve => {
    const s = document.createElement('script');
    s.src = base + 'rig.js';
    s.onload = () => resolve(window.__PET_RIGS[id] || null);
    s.onerror = () => resolve(null);
    document.head.appendChild(s);
  });
}

window.PetRig = {
  async create(id, bodyEl, root = 'rig/') {
    const base = `${root}${id}/`;
    try {
      const data = await loadData(id, base);
      if (!data) return null;
      const def = JSON.parse(JSON.stringify(data));
      return await new PetRigController(id, bodyEl, def, base).load();
    } catch (e) {
      console.warn('骨骼动画加载失败，继续用逐帧：', id, e);
      bodyEl.querySelector('.pet-rig-canvas')?.remove();
      bodyEl.classList.remove('rigged');
      return null;
    }
  },
};
window.dispatchEvent(new Event('petrig-ready'));
