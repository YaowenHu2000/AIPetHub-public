'use strict';

// 弹簧：界面上会动的东西（弹出面板、滑杆、按下松开、浮现）都按弹簧来动，不用固定时长的缓动曲线。
// 弹簧有速度：起步快、收尾柔，带一点回弹；而且随时可以打断——动到一半改了目标，带着当时的速度拐过去，不会跳一下。
//
// 两种用法：
//   · Spring：脚本里一帧一帧算（质量、刚度、阻尼），改目标时速度接着用。弹出面板的出现 / 收回、面板变形、滑杆用它。
//   · springCurve()：把同一个弹簧算成 CSS 的 linear() 缓动，写进 --spring-* 变量，样式里的 transition 用它
//     （按钮按下松开、悬停浮现这些）。CSS 的过渡被打断时从当前位置接着走，只是不带速度。

/** 质量是 1。stiffness 越大越快，damping 越小越弹。 */
class Spring {
  constructor({ value = 0, stiffness = 420, damping = 34, onUpdate, onRest }) {
    this.value = value;
    this.target = value;
    this.velocity = 0;
    this.stiffness = stiffness;
    this.damping = damping;
    this.onUpdate = onUpdate;
    this.onRest = onRest;
    this.running = false;
  }

  /** 直接放到这个值上，不带动画（手拖着的时候用）。velocity：当时拖得多快，松手后接着用。 */
  set(value, velocity = 0) {
    this.value = value;
    this.target = value;
    this.velocity = velocity;
    if (this.onUpdate) this.onUpdate(value);
  }

  /** 朝新的目标去。正在动的话带着现在的速度过去。 */
  to(target, { stiffness, damping, velocity } = {}) {
    this.target = target;
    if (stiffness) this.stiffness = stiffness;
    if (damping) this.damping = damping;
    if (velocity !== undefined) this.velocity = velocity;
    if (this.running) return;
    this.running = true;
    this.last = performance.now();
    this.tick();
  }

  /** 排下一帧。窗口被挡住时 requestAnimationFrame 不走，所以同时排一个定时器，谁先到用谁。 */
  tick() {
    let fired = false;
    const run = () => {
      if (fired) return;
      fired = true;
      cancelAnimationFrame(raf);
      clearTimeout(timer);
      this.step(performance.now());
    };
    const raf = requestAnimationFrame(run);
    const timer = setTimeout(run, 120);
  }

  step(now) {
    if (!this.running) return;
    let dt = Math.min(0.3, (now - this.last) / 1000);
    this.last = now;
    // 小步长一步步积分：数值稳，帧率低也不会飞出去
    while (dt > 0) {
      const h = Math.min(dt, 1 / 240);
      const force = -this.stiffness * (this.value - this.target) - this.damping * this.velocity;
      this.velocity += force * h;
      this.value += this.velocity * h;
      dt -= h;
    }
    if (Math.abs(this.velocity) < 0.002 && Math.abs(this.value - this.target) < 0.0008) {
      this.value = this.target;
      this.velocity = 0;
      this.running = false;
      if (this.onUpdate) this.onUpdate(this.value);
      if (this.onRest) this.onRest(this.value);
      return;
    }
    if (this.onUpdate) this.onUpdate(this.value);
    this.tick();
  }
}

/** 把一个弹簧从 0 到 1 的过程算成 CSS 的 linear() 缓动和它的时长（毫秒）。 */
function springCurve(stiffness, damping) {
  const pts = [];
  let x = 0, v = 0, t = 0;
  const h = 1 / 480;
  while (t < 3) {
    if (Math.round(t / h) % 8 === 0) pts.push(x);   // 每 1/60 秒记一个点
    v += (-stiffness * (x - 1) - damping * v) * h;
    x += v * h;
    t += h;
    if (Math.abs(v) < 0.004 && Math.abs(x - 1) < 0.001) break;
  }
  pts.push(1);
  return { ms: Math.round(t * 1000), css: `linear(${pts.map(p => +p.toFixed(4)).join(', ')})` };
}

// 样式里用的三种弹簧：--spring-snappy（跟手，几乎不弹）、--spring-bouncy（松手回弹）、--spring-gentle（慢一点、柔一点）
// SPRING_EASE.snappy 这样取到 { css, ms }，脚本里的 element.animate() 用
const SPRING_EASE = {};
const SPRING_CSS = CSS.supports('transition-timing-function', 'linear(0, 0.5, 1)');
[['snappy', 560, 42, 'cubic-bezier(0.2, 0.9, 0.3, 1)'], ['bouncy', 420, 21, 'cubic-bezier(0.3, 1.45, 0.5, 1)'], ['gentle', 190, 24, 'cubic-bezier(0.22, 1, 0.36, 1)']]
  .forEach(([name, k, c, fallback]) => {
    const curve = springCurve(k, c);
    SPRING_EASE[name] = { css: SPRING_CSS ? curve.css : fallback, ms: curve.ms };
    document.documentElement.style.setProperty(`--spring-${name}`, SPRING_CSS ? curve.css : fallback);
    document.documentElement.style.setProperty(`--spring-${name}-ms`, `${curve.ms}ms`);
  });
