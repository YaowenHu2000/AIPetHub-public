/**
 * 精简版 2D 骨骼动画运行库（Live2D / Spine 的思路，three.js 实现）。
 *
 * 角色拆成若干图层（同尺寸的透明 PNG，静止时叠起来就是原图），每层挂在一根骨骼上：
 *   - 骨骼有层级（根 → 身体 → 头 / 手臂…），每根骨骼可以绕自己的支点转、平移、缩放；
 *   - 图层还可以有局部变形：
 *       bend   头发、尾巴、袖子：越往末端弯得越多，再叠一层沿长度传过去的波动（radial：按到根部的直线距离算“末端”）；
 *       flap   翅膀：以中线为界左右对称地扇；
 *       breath 身体：胸口那一段随呼吸起伏、变宽一点点；
 *       tap    敲键盘：支点左右两边的手轮流往下点一下；
 *   - 头部图层可以眨眼：只换眼睛那一块（半睁 / 闭眼图）；
 *   - 头部图层可以换表情：盖一张脸部补丁（眼睛、眉毛、嘴、脸颊变了的那一块），在眨眼闭眼的那一下换。
 * 所有参数每帧由外面的动画控制器给，图片本身永远是同一套，所以不会有一帧画得和另一帧不一样。
 *
 * 坐标：图里的位置用 0~1 的比例，y 向下；画布用 three.js 正交相机，x、y 都是 -1~1。
 */
import * as THREE from 'three';

const VERT = /* glsl */`
  uniform vec4 uBox;          // 这一层在图里的范围（x0, y0, x1, y1）
  uniform mat3 uM;            // 骨骼变换（图里坐标 → 图里坐标）
  uniform float uScale; uniform vec2 uOffset;
  uniform int uType;          // 0 无  1 bend  2 flap  3 breath  4 tap
  uniform vec2 uPivot; uniform vec2 uDir; uniform float uLen; uniform float uRadial;
  uniform float uBend, uWave, uFreq, uK, uPhase, uTime;
  uniform vec4 uBand; uniform vec2 uBreath;   // breath：胸口那一段（y0, y1, 中线 x, 无）和（抬高, 变宽）
  varying vec2 vTex;
  vec2 rot(vec2 p, vec2 c, float a) { float s = sin(a), k = cos(a); p -= c; return c + vec2(k * p.x - s * p.y, s * p.x + k * p.y); }
  uniform float uLocalTex;    // 1 = 贴图只覆盖 box（画布图层）
  void main() {
    vec2 p = mix(uBox.xy, uBox.zw, vec2(uv.x, 1.0 - uv.y));
    vTex = uLocalTex > 0.5 ? uv : vec2(p.x, 1.0 - p.y);
    if (uType == 1) {
      // 一般沿 dir 方向量到根部有多远；卷起来的东西（尾巴）按到根部的直线距离量
      float t = clamp((uRadial > 0.5 ? length(p - uPivot) : dot(p - uPivot, uDir)) / uLen, 0.0, 1.0);
      float a = uBend * pow(t, 1.5) + uWave * t * sin(uTime * uFreq - t * uK + uPhase);
      p = rot(p, uPivot, a);
    } else if (uType == 2) {
      float side = sign(p.x - uPivot.x);
      float t = clamp(abs(p.x - uPivot.x) / uLen, 0.0, 1.0);
      p = rot(p, uPivot, side * (uBend + uWave * sin(uTime * uFreq + uPhase)) * smoothstep(0.0, 1.0, t));
    } else if (uType == 4) {
      // 敲键盘：支点左右两边的手轮流往下点一下（离支点越远影响越小）
      float w = 1.0 - smoothstep(0.0, uLen, length((p - uPivot) * vec2(0.5, 1.0)));
      float side = p.x < uPivot.x ? 0.0 : 3.14159;
      p.y += uWave * w * max(0.0, sin(uTime * uFreq + side));
    } else if (uType == 3) {
      float band = smoothstep(uBand.x - 0.04, uBand.x + 0.03, p.y) * (1.0 - smoothstep(uBand.y - 0.03, uBand.y + 0.06, p.y));
      float above = 1.0 - smoothstep(uBand.x - 0.04, uBand.y, p.y);   // 胸口以上整体跟着抬
      p.y -= uBreath.x * max(band, above);
      p.x += (p.x - uBand.z) * uBreath.y * band;
    }
    vec2 q = (uM * vec3(p, 1.0)).xy;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(uOffset + uScale * vec2(q.x - 0.5, 0.5 - q.y), 0.0, 1.0);
  }`;

const FRAG = /* glsl */`
  uniform sampler2D uTex, uHalf, uClosed, uExpr, uOv1, uOv2; uniform float uBH, uBC, uHasBlink, uAlpha, uExprOn, uOv1On, uOv2On; uniform vec4 uEye;
  varying vec2 vTex;
  float box(vec2 p, vec4 r, float f) {
    return smoothstep(r.x - f, r.x + f * 0.3, p.x) * (1.0 - smoothstep(r.z - f * 0.3, r.z + f, p.x))
         * smoothstep(r.y - f, r.y + f * 0.3, p.y) * (1.0 - smoothstep(r.w - f * 0.3, r.w + f, p.y));
  }
  void main() {
    vec4 c = texture2D(uTex, vTex);
    // 表情补丁：只盖脸上变了的那一块（贴图预乘透明度，直接“盖上去”）
    if (uExprOn > 0.5) { vec4 e = texture2D(uExpr, vTex); c = e + c * (1.0 - e.a); }
    // 另外两个补丁位：眼睛（眨眼 / 视线）、嘴（口型），盖在表情上面
    if (uOv1On > 0.5) { vec4 e = texture2D(uOv1, vTex); c = e + c * (1.0 - e.a); }
    if (uOv2On > 0.5) { vec4 e = texture2D(uOv2, vTex); c = e + c * (1.0 - e.a); }
    if (uHasBlink > 0.5) {
      float m = box(vec2(vTex.x, 1.0 - vTex.y), uEye, 0.015);
      c = mix(c, texture2D(uHalf, vTex), m * uBH);
      c = mix(c, texture2D(uClosed, vTex), m * uBC);
    }
    c *= uAlpha;   // 贴图是预乘透明度的，整体乘就是淡入淡出
    if (c.a < 0.003) discard;
    gl_FragColor = c;
  }`;

const WIRE_FRAG = /* glsl */`void main() { gl_FragColor = vec4(0.45, 0.95, 0.85, 0.28); }`;

/** 2D 仿射：a b c / d e f（x' = a x + b y + c） */
const I = () => [1, 0, 0, 0, 1, 0];
const mul = (m, n) => [
  m[0] * n[0] + m[1] * n[3], m[0] * n[1] + m[1] * n[4], m[0] * n[2] + m[1] * n[5] + m[2],
  m[3] * n[0] + m[4] * n[3], m[3] * n[1] + m[4] * n[4], m[3] * n[2] + m[4] * n[5] + m[5],
];
const apply = (m, x, y) => [m[0] * x + m[1] * y + m[2], m[3] * x + m[4] * y + m[5]];

export class Rig {
  /**
   * @param def  rig 定义：{ base, layers: [{ name, bone, deform? }], bones: { 名字: { parent?, pivot: [x, y] } }, blink? }
   * @param scene three.js 场景
   */
  constructor(def, scene) {
    this.def = def;
    this.scene = scene;
    this.scale = def.scale || 1.3;
    this.offset = new THREE.Vector2();
    this.time = 0;
    this.bones = {};
    for (const [name, b] of Object.entries(def.bones)) {
      this.bones[name] = { name, parent: b.parent || null, pivot: b.pivot, rot: 0, tx: 0, ty: 0, sx: 1, sy: 1, world: I() };
    }
    this.layers = [];
    this.blink = { half: 0, closed: 0 };
    this.wireVisible = false;
  }

  async load() {
    const loader = new THREE.TextureLoader();
    const tex = url => new Promise((res, rej) => loader.load(url, t => {
      t.colorSpace = THREE.NoColorSpace; t.premultiplyAlpha = true; t.anisotropy = 4; res(t);
    }, undefined, rej));
    const base = this.def.base;
    const blinkTex = this.def.blink ? await Promise.all([tex(base + this.def.blink.half), tex(base + this.def.blink.closed)]) : null;
    this.exprTex = {};
    for (const [name, file] of Object.entries({ ...(this.def.expressions || {}), ...(this.def.patches || {}) })) this.exprTex[name] = await tex(base + file);
    let order = 0;
    this.canvases = {};
    for (const L of this.def.layers) {
      // 画布图层：内容由页面代码每帧画（表情、道具、特效），按 2 倍分辨率建画布
      let t;
      if (L.canvas) {
        const [x0, y0, x1, y1] = L.px;
        const cv = document.createElement('canvas');
        cv.width = Math.round((x1 - x0) * 2); cv.height = Math.round((y1 - y0) * 2);
        t = new THREE.CanvasTexture(cv);
        t.colorSpace = THREE.NoColorSpace; t.premultiplyAlpha = true;
        this.canvases[L.name] = { canvas: cv, ctx: cv.getContext('2d'), tex: t, px: L.px, scale: 2 };
      } else {
        t = await tex(base + (L.file || L.name + '.png'));
      }
      const d = L.deform || {};
      const uniforms = {
        uTex: { value: t }, uHalf: { value: blinkTex ? blinkTex[0] : t }, uClosed: { value: blinkTex ? blinkTex[1] : t },
        uBH: { value: 0 }, uBC: { value: 0 }, uHasBlink: { value: L.blink && blinkTex ? 1 : 0 }, uAlpha: { value: L.group ? 0 : 1 },
        uExpr: { value: t }, uExprOn: { value: 0 }, uOv1: { value: t }, uOv1On: { value: 0 }, uOv2: { value: t }, uOv2On: { value: 0 },
        uLocalTex: { value: L.canvas ? 1 : 0 },
        uEye: { value: new THREE.Vector4(...(this.def.blink?.eye || [0, 0, 0, 0])) },
        uBox: { value: new THREE.Vector4(...L.box) }, uM: { value: new THREE.Matrix3() },
        uScale: { value: this.scale }, uOffset: { value: this.offset },
        uType: { value: { bend: 1, flap: 2, breath: 3, tap: 4 }[d.type] || 0 },
        uPivot: { value: new THREE.Vector2(...(d.pivot || [0.5, 0.5])) },
        uDir: { value: new THREE.Vector2(...(d.dir || [0, 1])).normalize() },
        uLen: { value: d.len || 0.5 }, uRadial: { value: d.radial ? 1 : 0 },
        uBend: { value: 0 }, uWave: { value: 0 }, uFreq: { value: d.freq || 1.5 }, uK: { value: d.k ?? 3 }, uPhase: { value: d.phase || 0 },
        uTime: { value: 0 },
        uBand: { value: new THREE.Vector4(...(d.band || [0, 0, 0.5, 0])) }, uBreath: { value: new THREE.Vector2() },
      };
      const seg = L.seg || 40;
      const geo = new THREE.PlaneGeometry(1, 1, seg, seg);
      const mat = new THREE.ShaderMaterial({ uniforms, vertexShader: VERT, fragmentShader: FRAG, transparent: true, premultipliedAlpha: true, depthTest: false, depthWrite: false });
      const mesh = new THREE.Mesh(geo, mat);
      mesh.renderOrder = order * 2;
      mesh.frustumCulled = false;
      const wire = new THREE.Mesh(new THREE.PlaneGeometry(1, 1, 12, 12),
        new THREE.ShaderMaterial({ uniforms, vertexShader: VERT, fragmentShader: WIRE_FRAG, transparent: true, wireframe: true, depthTest: false, depthWrite: false }));
      wire.renderOrder = order * 2 + 1;
      wire.visible = false;
      wire.frustumCulled = false;
      this.scene.add(mesh, wire);
      this.layers.push({ def: L, mesh, wire, uniforms, bend: 0, wave: d.wave || 0, breath: [0, 0], alpha: L.group ? 0 : 1, pop: 1 });
      order++;
    }
    return this;
  }

  layer(name) { return this.layers.find(l => l.def.name === name); }

  /**
   * 换姿势：group 为这个姿势的层出现，别的姿势的层消失；待机手臂在有姿势手臂的动作里隐藏。
   * 手臂直接换（不叠化，两套手臂叠在一起会重影）；道具、眼镜、特效 0.2 秒淡入淡出。
   */
  setPose(pose) { this.pose = pose; }

  /** 换表情（null = 母版的表情）。只在头部图层上生效；最好在眨眼闭眼的那一下调用，看着就是眨眼间换了表情。 */
  setExpression(name) {
    this.expression = name && this.exprTex[name] ? name : null;
    for (const l of this.layers) {
      if (!l.def.blink) continue;
      l.uniforms.uExprOn.value = this.expression ? 1 : 0;
      if (this.expression) l.uniforms.uExpr.value = this.exprTex[this.expression];
    }
  }
  canBlink() { return !(this.def.noBlink || []).includes(this.expression); }

  /**
   * 脸部补丁的三个位置：0 表情、1 眼睛（眨眼 / 视线）、2 嘴（口型）；name 为 null 就是不盖。
   * 每个位置直接换（只盖脸上一小块，不叠化，没有重影）。
   */
  setPatch(slot, name) {
    const tex = name && this.exprTex[name];
    const [texKey, onKey] = [['uExpr', 'uExprOn'], ['uOv1', 'uOv1On'], ['uOv2', 'uOv2On']][slot];
    for (const l of this.layers) {
      if (!l.def.blink) continue;
      l.uniforms[onKey].value = tex ? 1 : 0;
      if (tex) l.uniforms[texKey].value = tex;
    }
    if (slot === 0) this.expression = tex ? name : null;
  }
  stepVisibility(dt) {
    const k = 1 - Math.exp(-dt / 0.07);
    for (const l of this.layers) {
      const g = l.def.group;
      const want = g ? g === this.pose : !(l.def.hideIn || []).includes(this.pose);
      const instant = /arm|hand|sleeve/.test(l.def.name);   // 手臂、手、袖子直接换，不叠化（两套手臂叠着会重影）
      l.alpha = instant ? (want ? 1 : 0) : l.alpha + ((want ? 1 : 0) - l.alpha) * k;
      l.mesh.visible = l.alpha > 0.003;
      l.wire.visible = this.wireVisible && l.mesh.visible;
      l.uniforms.uAlpha.value = l.alpha;
    }
  }

  setWire(v) { this.wireVisible = v; for (const l of this.layers) l.wire.visible = v; }

  /** 画布图层：draw(ctx, toCanvas) 里画；toCanvas(x, y) 把 1024 图里的像素坐标换成画布坐标。 */
  drawCanvas(name, draw) {
    const c = this.canvases[name];
    if (!c) return;
    const [x0, y0] = c.px, k = c.scale;
    c.ctx.setTransform(1, 0, 0, 1, 0, 0);
    c.ctx.clearRect(0, 0, c.canvas.width, c.canvas.height);
    c.ctx.setTransform(k, 0, 0, k, -x0 * k, -y0 * k);   // 之后直接用 1024 图里的像素坐标画
    draw(c.ctx);
    c.tex.needsUpdate = true;
  }

  /** 挂在某根骨骼上的点（1024 图里的像素）现在在图里的位置（同样是 1024 像素，和画布图层的坐标一致）。 */
  pointImage(bone, x, y) {
    const [qx, qy] = apply(this.bones[bone].world, x / 1024, y / 1024);
    return [qx * 1024, qy * 1024];
  }

  /** 骨骼在世界里的累计转角（给“袖子始终往下垂”这种反向转用）。 */
  worldAngle(name) {
    let a = 0, b = this.bones[name];
    while (b) { a += b.rot; b = b.parent ? this.bones[b.parent] : null; }
    return a;
  }

  /** 根据骨骼参数算每根骨骼的世界变换，再写进每层的 uniform。 */
  update(time) {
    this.time = time;
    const done = new Set();
    const solve = b => {
      if (done.has(b.name)) return b.world;
      const parent = b.parent ? solve(this.bones[b.parent]) : I();
      const [px, py] = b.pivot;
      const c = Math.cos(b.rot), s = Math.sin(b.rot);
      // T(pivot + t) · R · S · T(-pivot)
      const local = mul(mul([1, 0, px + b.tx, 0, 1, py + b.ty], [c * b.sx, -s * b.sy, 0, s * b.sx, c * b.sy, 0]), [1, 0, -px, 0, 1, -py]);
      b.world = mul(parent, local);
      done.add(b.name);
      return b.world;
    };
    for (const b of Object.values(this.bones)) solve(b);
    for (const l of this.layers) {
      const m = this.bones[l.def.bone].world;
      l.uniforms.uM.value.set(m[0], m[1], m[2], m[3], m[4], m[5], 0, 0, 1);
      l.uniforms.uTime.value = time;
      l.uniforms.uBend.value = l.bend;
      l.uniforms.uWave.value = l.wave;
      l.uniforms.uBreath.value.set(l.breath[0], l.breath[1]);
      l.uniforms.uBH.value = this.blink.half;
      l.uniforms.uBC.value = this.blink.closed;
    }
  }

  /** 图里某点（挂在某根骨骼上）现在在画布上的位置，用来画骨骼、做拖拽抓点。 */
  toCanvas(bone, x, y) {
    const [qx, qy] = apply(this.bones[bone].world, x, y);
    return [this.offset.x + this.scale * (qx - 0.5), this.offset.y + this.scale * (0.5 - qy)];
  }
}
