/**
 * 用代码画的部分：脸（眼皮、视线、嘴、腮红、眼泪、汗滴、星星眼、眼镜）和道具特效（全息键盘、全息文字页、思考气泡、飘着的符号）。
 * 所有坐标都是 1024 母版里的像素（画布已经换好坐标系，见 Rig.drawCanvas）。
 *
 * 表情参数 F（都由动画控制器用弹簧平滑过去，所以表情是连续变化的）：
 *   open  0~1 眼睛睁开程度（1 = 原画）      happy 0~1 眯眼笑（∩ 形）      squeeze 0~1 “><” 紧闭
 *   gx gy  视线（-1~1）                    irisScale 瞳孔大小（吃惊时变小）  sparkle 0~1 星星眼
 *   mouthOpen 0~1  smile -1~1  wide 0.5~1.4  round 0~1（o 形）  cat 0~1（ω 猫嘴）  pout 0~1（委屈）
 *   blush 0~1  tears 0~1  sweat 0~1  glasses 0~1
 */

const rgb = (c, a = 1) => `rgba(${c[0]},${c[1]},${c[2]},${a})`;
const lerp = (a, b, t) => a + (b - a) * t;
const clamp01 = v => Math.max(0, Math.min(1, v));

export class FaceDrawer {
  constructor(face, base) {
    this.face = face;
    this.base = base;
    this.img = {};
    this.tmp = document.createElement('canvas');
  }

  async load() {
    const load = src => new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = rej; i.src = src; });
    for (const e of this.face.eyes) {
      this.img['eye_' + e.name] = await load(this.base + `idle/eye_${e.name}.png`);
      this.img['lid_' + e.name] = await load(this.base + `idle/lid_${e.name}.png`);
      this.img['iris_' + e.name] = await load(this.base + `idle/iris_${e.name}.png`);
    }
    return this;
  }

  /** 和主画布同尺寸、同坐标系的临时画布（画一只眼睛的眼内 / 眼皮再裁剪后贴回去） */
  scratch(ctx) {
    const c = this.tmp;
    if (c.width !== ctx.canvas.width || c.height !== ctx.canvas.height) { c.width = ctx.canvas.width; c.height = ctx.canvas.height; }
    const t = c.getContext('2d');
    t.setTransform(1, 0, 0, 1, 0, 0);
    t.clearRect(0, 0, c.width, c.height);
    t.setTransform(ctx.getTransform());
    return t;
  }
  paste(ctx) {
    ctx.save(); ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.drawImage(this.tmp, 0, 0); ctx.restore();
  }

  draw(ctx, F, t) {
    for (const e of this.face.eyes) this.drawEye(ctx, e, F, t);
    this.drawBlush(ctx, F);
    this.drawMouth(ctx, F, t);
    if (F.glasses > 0.01) this.drawGlasses(ctx, F);
    if (F.tears > 0.01) this.drawTears(ctx, F, t);
    if (F.sweat > 0.01) this.drawSweat(ctx, F, t);
  }

  drawEye(ctx, e, F, t) {
    const [bx0, by0, bx1, by1] = e.box;
    const w = bx1 - bx0, h = by1 - by0;
    const pad = 14;
    const sx = bx0 - pad, sy = by0 - pad, sw = w + pad * 2, sh = h + pad * 2;
    // 1. 眼内：眼白 + 平移后的虹膜，裁到眼内
    const room = Math.max(4, w / 2 - e.irisR) * 0.7;
    const gx = F.gx * room, gy = F.gy * room * 0.55;
    const [ix, iy] = e.iris;
    const s = F.irisScale;
    let c = this.scratch(ctx);
    c.fillStyle = rgb(e.white);
    c.fillRect(sx, sy, sw, sh);
    c.save();
    c.translate(ix + gx, iy + gy); c.scale(s, s); c.translate(-ix, -iy);
    c.drawImage(this.img['iris_' + e.name], sx, sy, sw, sh, sx, sy, sw, sh);
    c.restore();
    if (F.sparkle > 0.01) {               // 星星眼：虹膜上两颗闪光
      c.save(); c.globalAlpha = F.sparkle;
      star(c, ix + gx - e.irisR * 0.3, iy + gy - e.irisR * 0.25, e.irisR * 0.42 * (0.85 + 0.15 * Math.sin(t * 6)), '#fff');
      star(c, ix + gx + e.irisR * 0.35, iy + gy + e.irisR * 0.3, e.irisR * 0.22, '#fff');
      c.restore();
    }
    c.globalCompositeOperation = 'destination-in';
    c.drawImage(this.img['eye_' + e.name], sx, sy, sw, sh, sx, sy, sw, sh);
    c.globalCompositeOperation = 'source-over';
    this.paste(ctx);

    // 2. 眼皮：从上往下盖皮肤，沿着眼内的上下沿合上；睫毛线跟着眼皮走
    const close = clamp01(Math.max(1 - F.open, F.happy, F.squeeze));
    if (close < 0.01) return;
    const cols = e.cols;
    const lidY = col => lerp(col[1] - 2, col[1] + (col[2] - col[1]) * 0.9, close);
    c = this.scratch(ctx);
    c.fillStyle = rgb(e.skin);
    c.beginPath();
    c.moveTo(cols[0][0] - pad, by0 - pad - 6);
    for (const col of cols) c.lineTo(col[0], col[1] - pad - 6);
    c.lineTo(cols[cols.length - 1][0] + pad, by0 - pad - 6);
    for (let i = cols.length - 1; i >= 0; i--) c.lineTo(cols[i][0], lidY(cols[i]));
    c.closePath(); c.fill();
    if (close > 0.97 || F.happy > 0.3 || F.squeeze > 0.3) c.fillRect(sx, sy, sw, sh);   // 完全合上：整只眼都盖上
    c.globalCompositeOperation = 'destination-in';
    c.drawImage(this.img['lid_' + e.name], sx, sy, sw, sh, sx, sy, sw, sh);
    c.globalCompositeOperation = 'source-over';
    this.paste(ctx);

    // 3. 睫毛线
    const outerLeft = e.iris[0] < 512;                 // 画面左边那只眼，外眼角在左
    ctx.save();
    ctx.strokeStyle = rgb(e.lash); ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    if (F.squeeze > 0.3) {                             // “><”
      const cx = (bx0 + bx1) / 2, cy = lerp(by0, by1, 0.55), r = w * 0.32;
      ctx.lineWidth = 5;
      ctx.globalAlpha = clamp01((F.squeeze - 0.3) / 0.4);
      ctx.beginPath();
      const d = outerLeft ? 1 : -1;
      ctx.moveTo(cx - d * r, cy - r * 0.55); ctx.lineTo(cx + d * r * 0.6, cy); ctx.lineTo(cx - d * r, cy + r * 0.55);
      ctx.stroke();
      ctx.restore();
      return;
    }
    const happy = F.happy;
    ctx.lineWidth = lerp(2.2, 3.6, close);
    ctx.beginPath();
    const n = cols.length;
    cols.forEach((col, i) => {
      const u = (i / (n - 1)) * 2 - 1;
      const y = lidY(col) - happy * (col[2] - col[1]) * 0.28 * (1 - u * u);
      if (i === 0) ctx.moveTo(col[0], y); else ctx.lineTo(col[0], y);
    });
    ctx.globalAlpha = clamp01(close * 1.6);
    ctx.stroke();
    // 外眼角一小撇睫毛
    const end = outerLeft ? cols[0] : cols[n - 1];
    const ey = lidY(end);
    ctx.lineWidth = lerp(1.8, 3, close);
    ctx.beginPath(); ctx.moveTo(end[0], ey); ctx.lineTo(end[0] + (outerLeft ? -7 : 7), ey - 3 - 2 * happy); ctx.stroke();
    ctx.restore();
  }

  drawMouth(ctx, F, t) {
    const m = this.face.mouth;
    const [cx, cy0] = m.center;
    const W = m.size[0] * 0.5 * F.wide, H = m.size[1];
    const inside = rgb(m.inside), line = rgb(m.line);
    const open = clamp01(F.mouthOpen), smile = F.smile, round = clamp01(F.round);
    const cy = cy0 - H * 0.28;
    ctx.save();
    ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    if (F.cat > 0.5 && open < 0.15) {                  // ω 猫嘴
      ctx.strokeStyle = line; ctx.lineWidth = 3;
      const r = W * 0.32;
      ctx.beginPath();
      ctx.arc(cx - r, cy + 2, r, 0.15 * Math.PI, 0.95 * Math.PI, false);
      ctx.moveTo(cx + 2 * r * Math.cos(0.05 * Math.PI) - r, cy + 2);
      ctx.arc(cx + r, cy + 2, r, 0.05 * Math.PI, 0.85 * Math.PI, false);
      ctx.stroke(); ctx.restore(); return;
    }
    if (F.pout > 0.5 && open < 0.2) {                  // 委屈：小小的波浪嘴
      ctx.strokeStyle = line; ctx.lineWidth = 3;
      const r = W * 0.22;
      ctx.beginPath();
      ctx.moveTo(cx - r * 2, cy + 6);
      ctx.quadraticCurveTo(cx - r, cy - 2, cx, cy + 4);
      ctx.quadraticCurveTo(cx + r, cy - 2, cx + r * 2, cy + 6);
      ctx.stroke(); ctx.restore(); return;
    }
    if (open < 0.06) {                                 // 闭嘴：一条弯线
      ctx.strokeStyle = line; ctx.lineWidth = 3;
      ctx.beginPath();
      ctx.moveTo(cx - W * 0.55, cy + 2 - smile * 4);
      ctx.quadraticCurveTo(cx, cy + 2 + smile * 9, cx + W * 0.55, cy + 2 - smile * 4);
      ctx.stroke(); ctx.restore(); return;
    }
    // 张嘴：上沿稍微往下弯（笑），下沿是深深的弧；o 形时两边往里收
    const hw = lerp(W, H * 0.3, round);
    const top = cy - smile * 3;
    const depth = H * lerp(0.3, 0.95, open) * lerp(1, 0.75, round);
    ctx.beginPath();
    if (round > 0.5) {
      ctx.ellipse(cx, top + depth * 0.45, hw, depth * 0.55, 0, 0, Math.PI * 2);
    } else {
      ctx.moveTo(cx - hw, top);
      ctx.quadraticCurveTo(cx, top + smile * 6 - 2, cx + hw, top);
      ctx.bezierCurveTo(cx + hw * 0.95, top + depth * 0.9, cx + hw * 0.4, top + depth * 1.05, cx, top + depth * 1.05);
      ctx.bezierCurveTo(cx - hw * 0.4, top + depth * 1.05, cx - hw * 0.95, top + depth * 0.9, cx - hw, top);
    }
    ctx.closePath();
    ctx.fillStyle = inside; ctx.fill();
    ctx.save(); ctx.clip();
    // 舌头
    ctx.fillStyle = 'rgba(244,138,140,1)';
    ctx.beginPath(); ctx.ellipse(cx + hw * 0.1, top + depth * 1.05, hw * 0.75, depth * 0.45, 0, 0, Math.PI * 2); ctx.fill();
    // 上排牙齿（开心张嘴时）
    if (smile > 0.2 && open > 0.3 && round < 0.5) {
      ctx.fillStyle = '#fffaf8';
      ctx.beginPath(); ctx.ellipse(cx, top - depth * 0.05, hw * 0.75, depth * 0.2, 0, 0, Math.PI * 2); ctx.fill();
    }
    ctx.restore();
    ctx.strokeStyle = line; ctx.lineWidth = 2.6; ctx.stroke();
    ctx.restore();
  }

  drawBlush(ctx, F) {
    const b = clamp01(F.blush);
    if (b < 0.01) return;
    ctx.save();
    for (const [x, y] of this.face.cheeks) {
      const g = ctx.createRadialGradient(x, y, 2, x, y, 30);
      g.addColorStop(0, `rgba(255,120,140,${0.28 * b})`);
      g.addColorStop(1, 'rgba(255,110,140,0)');
      ctx.fillStyle = g;
      ctx.beginPath(); ctx.ellipse(x, y, 32, 20, 0, 0, Math.PI * 2); ctx.fill();
      if (b > 0.75) {                                  // 害羞的几道斜线
        ctx.strokeStyle = `rgba(230,100,120,${(b - 0.75) * 1.6})`; ctx.lineWidth = 1.6; ctx.lineCap = 'round';
        for (let i = -1; i <= 1; i++) { ctx.beginPath(); ctx.moveTo(x + i * 9 - 4, y + 5); ctx.lineTo(x + i * 9 + 3, y - 5); ctx.stroke(); }
      }
    }
    ctx.restore();
  }

  drawTears(ctx, F, t) {
    ctx.save();
    for (const e of this.face.eyes) {
      const outerLeft = e.iris[0] < 512;
      const x = outerLeft ? e.box[0] + 8 : e.box[2] - 8, y0 = e.box[3] - 6;
      // 一道泪痕 + 一颗往下掉的泪珠
      // 眼角含着一小颗泪光（原画风格：不流成泪痕）
      const g = ctx.createRadialGradient(x, y0 - 2, 0, x, y0 - 2, 9);
      g.addColorStop(0, `rgba(235,248,255,${0.9 * F.tears})`); g.addColorStop(1, 'rgba(180,225,255,0)');
      ctx.fillStyle = g; ctx.beginPath(); ctx.ellipse(x, y0 - 2, 9, 6, 0, 0, Math.PI * 2); ctx.fill();
    }
    ctx.restore();
  }

  drawSweat(ctx, F, t) {
    const x = this.face.box[2] - 30, y = this.face.box[1] + 40 + Math.sin(t * 3) * 2;
    drop(ctx, x, y, 7 * F.sweat, `rgba(175,220,255,${0.8 * F.sweat})`, `rgba(110,165,225,${0.8 * F.sweat})`);
  }

  drawGlasses(ctx, F) {
    // 星星框的眼镜：每只眼睛外面画一个五角星框，中间一道鼻梁
    ctx.save();
    ctx.globalAlpha = clamp01(F.glasses);
    ctx.strokeStyle = 'rgba(190,160,255,0.95)'; ctx.lineWidth = 5; ctx.lineJoin = 'round';
    ctx.fillStyle = 'rgba(200,220,255,0.12)';
    const pts = [];
    for (const e of this.face.eyes) {
      const cx = (e.box[0] + e.box[2]) / 2, cy = (e.box[1] + e.box[3]) / 2 + 4, r = Math.max(e.box[2] - e.box[0], e.box[3] - e.box[1]) * 0.78;
      starPath(ctx, cx, cy, r, r * 0.62);
      ctx.fill(); ctx.stroke();
      pts.push([cx, cy, r]);
    }
    if (pts.length === 2) {
      ctx.beginPath(); ctx.moveTo(pts[0][0] + pts[0][2] * 0.55, pts[0][1] - 6); ctx.quadraticCurveTo((pts[0][0] + pts[1][0]) / 2, pts[0][1] - 18, pts[1][0] - pts[1][2] * 0.55, pts[1][1] - 6); ctx.stroke();
    }
    ctx.restore();
  }
}

function starPath(ctx, x, y, R, r) {
  ctx.beginPath();
  for (let i = 0; i < 10; i++) {
    const a = -Math.PI / 2 + i * Math.PI / 5, rr = i % 2 ? r : R;
    const px = x + Math.cos(a) * rr, py = y + Math.sin(a) * rr;
    if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
  }
  ctx.closePath();
}
function star(ctx, x, y, R, color) {
  ctx.fillStyle = color;
  ctx.beginPath();
  for (let i = 0; i < 8; i++) {
    const a = i * Math.PI / 4, rr = i % 2 ? R * 0.28 : R;
    ctx.lineTo(x + Math.cos(a) * rr, y + Math.sin(a) * rr);
  }
  ctx.closePath(); ctx.fill();
}
function drop(ctx, x, y, r, fill, stroke) {
  ctx.beginPath();
  ctx.moveTo(x, y - r * 1.8);
  ctx.bezierCurveTo(x + r * 0.9, y - r * 0.6, x + r, y + r * 0.2, x, y + r);
  ctx.bezierCurveTo(x - r, y + r * 0.2, x - r * 0.9, y - r * 0.6, x, y - r * 1.8);
  ctx.fillStyle = fill; ctx.fill();
  if (stroke) { ctx.strokeStyle = stroke; ctx.lineWidth = 2; ctx.stroke(); }
}

/**
 * 代码画的前臂：手离开袖口时，从袖口（A）到手腕（B）画一段皮肤色的手臂，带描边和一点明暗。
 * A、B 是 1024 图里的像素坐标（已经算上骨骼变换）。离得很近（手还在袖口）就不画。
 */
export function drawForearm(ctx, A, B, skin, line) {
  const dx = B[0] - A[0], dy = B[1] - A[1], len = Math.hypot(dx, dy);
  if (len < 5) return;
  const nx = -dy / len, ny = dx / len;
  const wA = 13, wB = 10;                       // 半宽：袖口那头粗一点
  ctx.save();
  ctx.beginPath();
  ctx.moveTo(A[0] + nx * wA, A[1] + ny * wA);
  ctx.lineTo(B[0] + nx * wB, B[1] + ny * wB);
  ctx.arc(B[0], B[1], wB, Math.atan2(ny, nx), Math.atan2(-ny, -nx), false);
  ctx.lineTo(A[0] - nx * wA, A[1] - ny * wA);
  ctx.arc(A[0], A[1], wA, Math.atan2(-ny, -nx), Math.atan2(ny, nx), false);
  ctx.closePath();
  const g = ctx.createLinearGradient(A[0] + nx * wA, A[1] + ny * wA, A[0] - nx * wA, A[1] - ny * wA);
  g.addColorStop(0, rgb(skin)); g.addColorStop(0.65, rgb(skin)); g.addColorStop(1, rgb([skin[0] - 18, skin[1] - 30, skin[2] - 30]));
  ctx.fillStyle = g; ctx.fill();
  ctx.strokeStyle = rgb(line, 0.85); ctx.lineWidth = 2.2; ctx.stroke();
  ctx.restore();
}

/* ───────── 道具和特效 ───────── */

/** 全息键盘：微微透视的发光面板，三排键；手敲到的地方键会亮一下 */
export function drawKeyboard(ctx, box, P, t, taps) {
  const a = clamp01(P.show);
  if (a < 0.01) return;
  const [x0, y0, x1, y1] = box;
  const cx = (x0 + x1) / 2, w = (x1 - x0) * 0.86, top = y0 + (y1 - y0) * 0.3, bot = y1 - 14;
  const tw = w * 0.82;
  ctx.save();
  ctx.globalAlpha = a;
  const quad = () => { ctx.beginPath(); ctx.moveTo(cx - tw / 2, top); ctx.lineTo(cx + tw / 2, top); ctx.lineTo(cx + w / 2, bot); ctx.lineTo(cx - w / 2, bot); ctx.closePath(); };
  const g = ctx.createLinearGradient(0, top, 0, bot);
  g.addColorStop(0, 'rgba(200,140,255,0.45)'); g.addColorStop(1, 'rgba(140,100,255,0.7)');
  ctx.shadowColor = 'rgba(200,140,255,0.9)'; ctx.shadowBlur = 18;
  quad(); ctx.fillStyle = g; ctx.fill();
  ctx.shadowBlur = 0;
  ctx.strokeStyle = `rgba(245,215,255,${0.85 + 0.15 * Math.sin(t * 3)})`; ctx.lineWidth = 4; quad(); ctx.stroke();
  // 键
  const rows = 3, colsN = 10;
  for (let r = 0; r < rows; r++) {
    const v0 = (r + 0.15) / rows, v1 = (r + 0.85) / rows;
    for (let c = 0; c < colsN; c++) {
      const u0 = (c + 0.12) / colsN, u1 = (c + 0.88) / colsN;
      const P4 = [[u0, v0], [u1, v0], [u1, v1], [u0, v1]].map(([u, v]) => {
        const y = lerp(top, bot, v), half = lerp(tw, w, v) / 2;
        return [cx - half + u * half * 2, y];
      });
      let lit = 0;
      for (const tp of taps) {
        const kx = P4[0][0] + (P4[1][0] - P4[0][0]) / 2, ky = (P4[0][1] + P4[2][1]) / 2;
        const age = t - tp.t;
        if (age >= 0 && age < 0.35 && Math.abs(kx - tp.x) < 26 && Math.abs(ky - tp.y) < 22) lit = Math.max(lit, 1 - age / 0.35);
      }
      ctx.beginPath(); P4.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y))); ctx.closePath();
      ctx.fillStyle = `rgba(${lerp(215, 255, lit)},${lerp(190, 250, lit)},255,${0.5 + 0.5 * lit})`;
      ctx.fill();
    }
  }
  ctx.restore();
}

/** 全息文字页：半透明的青色面板，文字行慢慢往上滚；隔一会儿翻一页（横向压扁再展开） */
export function drawPage(ctx, box, P, t) {
  const a = clamp01(P.show);
  if (a < 0.01) return;
  const [x0, y0, x1, y1] = box;
  const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
  const flip = P.flip;   // 0~1：翻页进度
  const sx = Math.abs(Math.cos(flip * Math.PI));
  ctx.save();
  ctx.globalAlpha = a;
  ctx.translate(cx, cy); ctx.rotate(-0.06 + 0.02 * Math.sin(t * 0.8)); ctx.scale(Math.max(0.04, sx), 1); ctx.translate(-cx, -cy);
  const w = (x1 - x0) * 0.78, h = (y1 - y0) * 0.86, l = cx - w / 2, tp = cy - h / 2;
  ctx.shadowColor = 'rgba(140,200,255,0.9)'; ctx.shadowBlur = 16;
  roundRect(ctx, l, tp, w, h, 12); ctx.fillStyle = 'rgba(150,190,255,0.22)'; ctx.fill();
  ctx.shadowBlur = 0; ctx.strokeStyle = 'rgba(200,225,255,0.9)'; ctx.lineWidth = 3; ctx.stroke();
  ctx.save(); roundRect(ctx, l + 6, tp + 6, w - 12, h - 12, 8); ctx.clip();
  const lineH = 14, scroll = (t * 12) % lineH;
  for (let i = -1; i < h / lineH + 1; i++) {
    const y = tp + 18 + i * lineH - scroll;
    const seed = Math.floor(i + t * 12 / lineH) + (P.pageNo || 0) * 37;
    const len = 0.35 + 0.55 * frac(Math.sin(seed * 12.9898) * 43758.5453);
    ctx.fillStyle = 'rgba(225,240,255,0.75)';
    roundRect(ctx, l + 16, y, (w - 32) * len, 5, 2.5); ctx.fill();
  }
  ctx.restore();
  starPath(ctx, l + w - 22, tp + 22, 10, 4.5); ctx.fillStyle = 'rgba(255,230,140,0.95)'; ctx.fill();
  ctx.restore();
}

/** 思考气泡：几个圆拼成的云，里面一个弹跳的问号和星座点线；往头那边一串小泡泡 */
export function drawBubble(ctx, box, P, t) {
  const a = clamp01(P.show);
  if (a < 0.01) return;
  const [x0, y0, x1, y1] = box;
  const cx = x0 + (x1 - x0) * 0.42, cy = y0 + (y1 - y0) * 0.38 + Math.sin(t * 1.6) * 4;
  const R = (x1 - x0) * 0.26 * (0.96 + 0.04 * Math.sin(t * 2.2)) * (0.6 + 0.4 * a);
  ctx.save();
  ctx.globalAlpha = a;
  ctx.shadowColor = 'rgba(190,140,255,0.8)'; ctx.shadowBlur = 14;
  ctx.fillStyle = 'rgba(95,70,170,0.82)';
  ctx.beginPath();
  for (const [dx, dy, r] of [[-0.7, 0.1, 0.62], [-0.25, -0.35, 0.72], [0.35, -0.3, 0.7], [0.75, 0.12, 0.6], [0.2, 0.35, 0.68], [-0.35, 0.38, 0.6]]) {
    ctx.moveTo(cx + dx * R + r * R, cy + dy * R); ctx.arc(cx + dx * R, cy + dy * R, r * R, 0, Math.PI * 2);
  }
  ctx.fill();
  ctx.shadowBlur = 0;
  // 星座
  const pts = [[-0.6, -0.1], [-0.3, 0.2], [0.05, -0.2], [0.5, 0.05], [0.7, -0.3]].map(([dx, dy]) => [cx + dx * R, cy + dy * R]);
  ctx.strokeStyle = 'rgba(220,200,255,0.7)'; ctx.lineWidth = 1.5; ctx.beginPath(); pts.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y))); ctx.stroke();
  pts.forEach(([x, y], i) => star(ctx, x, y, 5 + 2 * Math.sin(t * 4 + i), 'rgba(255,240,200,0.95)'));
  // 问号
  const qy = cy + Math.sin(t * 3.2) * 6;
  ctx.fillStyle = '#ffe58a'; ctx.font = `bold ${R * 0.9}px -apple-system, sans-serif`; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  ctx.save(); ctx.translate(cx + R * 0.1, qy); ctx.rotate(0.15 * Math.sin(t * 2)); ctx.fillText('?', 0, 0); ctx.restore();
  // 小泡泡往右下（头）那边
  for (let i = 0; i < 3; i++) {
    const k = (i + 1) / 4;
    ctx.beginPath(); ctx.arc(cx + R * (0.9 + i * 0.45), cy + R * (0.9 + i * 0.5), R * (0.16 - i * 0.04), 0, Math.PI * 2);
    ctx.fillStyle = `rgba(110,85,190,${0.8 - k * 0.3})`; ctx.fill();
  }
  ctx.restore();
}

/** 飘着的符号和光点：施工时往上飘的 </> { } 01，其它时候是零星的光点 */
export function drawFx(ctx, box, P, t, particles) {
  ctx.save();
  for (const p of particles) {
    const age = t - p.t0, life = p.life;
    if (age < 0 || age > life) continue;
    const k = age / life;
    const x = p.x + p.vx * age + Math.sin(age * 2 + p.ph) * 6, y = p.y + p.vy * age;
    ctx.globalAlpha = Math.sin(k * Math.PI) * p.a;
    if (p.text) {
      ctx.fillStyle = p.color; ctx.font = `bold ${p.size}px Menlo, monospace`; ctx.textAlign = 'center';
      ctx.fillText(p.text, x, y);
    } else {
      star(ctx, x, y, p.size * (0.7 + 0.3 * Math.sin(age * 8 + p.ph)), p.color);
    }
  }
  ctx.restore();
}

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r); ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath();
}
const frac = v => v - Math.floor(v);
