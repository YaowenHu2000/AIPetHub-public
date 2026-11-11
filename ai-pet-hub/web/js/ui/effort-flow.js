'use strict';

// 思考强度滑杆里流动的颜色和粒子（画在一块 canvas 上，模型面板开着的时候才在跑）。
//   · 颜色：不是一道色波从左扫到右，而是整条的颜色一直在慢慢变——从深到亮的大走向不变，
//     里面的明暗分布由几层快慢不一的缓波叠出来，一直往右淌，不重复，像水在流。
//   · 粒子：每一颗各自随机游走（上下左右都有，速度朝一个不断变的随机方向靠），各自一明一暗。
//   · 平时也看得出在流：颜色的明暗一直往右淌，粒子除了各自游走，还被水流带着慢慢往右漂；
//     fast 开着时整体快得多：从现在的速度起步慢慢加速（一开始几乎不动，越来越快），加到头就保持匀速，不是一快一慢的循环。
//     粒子跟着被带出一条小尾巴。

/** 把 CSS 颜色（可能是 color-mix(…) 这种）算成 [r, g, b]：借一个元素让浏览器算，再读回来。 */
function cssColor(el, value) {
  const probe = document.createElement('span');
  probe.style.color = value;
  el.appendChild(probe);
  const text = getComputedStyle(probe).color;
  probe.remove();
  const nums = (text.match(/-?[\d.]+(?:e-?\d+)?/g) || []).map(Number);
  // WebKit 把 color-mix 的结果写成 color(srgb 0.5 0.2 0.1)，分量是 0…1
  return text.startsWith('color(') ? nums.slice(0, 3).map(n => n * 255) : nums.slice(0, 3);
}

/**
 * 开始画。track：滑杆；canvas：铺满滑杆的画布（外面有一层按档位裁宽度的壳）；isFast()：现在是不是开着 fast。
 * 滑杆从页面上拿掉以后自己停。
 */
/**
 * 流到哪了、每颗粒子在哪、现在多快：记在外面，面板重画（开关 fast、换档、换模型都会重画）时新的画布接着上一张画，
 * 不重新洗牌。否则一点 fast，颜色和粒子全换了位置、速度也从头来，画面就跳一下。
 */
let effortFlowState = null;

function startEffortFlow(track, canvas, isFast) {
  const ctx = canvas.getContext('2d');
  const mix = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
  const STOPS = 30;
  let W = 0, H = 0, palette = null, paletteKey = '';
  const fresh = !effortFlowState;
  const st = effortFlowState || (effortFlowState = {
    speed: 0,                             // 0 = 平时，1 = fast 的全速
    accel: 0,                             // speed 现在变得多快（从 0 起步，所以开 fast 是慢慢加上去的，不是一下子有了速度）
    phase: Math.random() * 50,            // 颜色流到哪了
    at: 0,                                // 上一帧是什么时候画的
    dots: Array.from({ length: 40 }, (_, i) => ({
      x: Math.random(), y: Math.random(),   // 位置（占宽、高的比例）
      vx: 0, vy: 0,                         // 自己游走的速度（像素 / 秒）
      r: i % 6 === 0 ? 1.1 + Math.random() * 0.7 : 0.4 + Math.random() * 0.75,   // 大小：六颗里有一颗大的、近的
      a: 0.4 + Math.random() * 0.6,         // 最亮时有多亮
      tw: 0.5 + Math.random() * 1.6, ph: Math.random() * 6.283,   // 一明一暗的快慢和起点
      drift: 0.28 + Math.random() * 0.34,   // fast 时被带着走多快（每秒几个条宽）：有快有慢，有远近感
    })),
  });
  // 面板是刚打开的（不是接着上一张画）：速度直接就是现在该有的样子，不演一遍加速
  if (fresh || performance.now() - st.at > 400) { st.speed = isFast() ? 1 : 0; st.accel = 0; }
  st.owner = canvas;                      // 只有最新的这张画布在画（旧的那张被换下来，下一帧自己停）
  const dots = st.dots;
  let last = performance.now();

  function frame(now) {
    if (st.owner !== canvas) return;
    if (!track.isConnected) { if (now - last > 600) return; requestAnimationFrame(frame); return; }   // 还没放到页面上：等一下
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    const w = track.clientWidth, h = track.clientHeight;
    if (!w || !h) { requestAnimationFrame(frame); return; }
    if (w !== W || h !== H) {
      W = w; H = h;
      const dpr = window.devicePixelRatio || 1;
      canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
      canvas.style.width = `${W}px`; canvas.style.height = `${H}px`;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    // 换了档位（最高档是另一套颜色）或者换了一位：重新取颜色
    const key = `${document.body.dataset.agent}|${track.closest('#popover')?.className}`;
    if (key !== paletteKey) {
      paletteKey = key;
      const cs = getComputedStyle(track);
      palette = ['--s1', '--s2', '--s3'].map(v => cssColor(track, cs.getPropertyValue(v)));
    }

    // 速度：像推一个有分量的东西——先是加速度从 0 涨起来，速度跟着慢慢起步、越来越快，快到头时收住，之后匀速（约 2.5 秒到全速）。
    // 以前是直接朝目标靠（一开始变得最快），看着像突然得了一个初速度。关掉 fast 也是这样慢慢收下来。
    st.accel += (((isFast() ? 1 : 0) - st.speed) * 4.5 - st.accel * 4.2) * dt;
    st.speed = Math.max(0, st.speed + st.accel * dt);
    st.phase += dt * (0.085 + st.speed * 0.55);   // 平时也在淌（一圈十来秒），看得出方向
    st.at = now;
    const speed = st.speed, phase = st.phase;

    // 整条的颜色：左深右亮的大走向，叠上三层往右淌的缓波
    const grad = ctx.createLinearGradient(0, 0, W, 0);
    for (let i = 0; i < STOPS; i++) {
      const u = i / (STOPS - 1);
      const wave = 0.5
        + 0.3 * Math.sin(6.283 * (u * 0.85 - phase))
        + 0.19 * Math.sin(6.283 * (u * 1.9 - phase * 1.63) + 1.3)
        + 0.11 * Math.sin(6.283 * (u * 3.3 - phase * 0.71) + 4.1);
      const k = Math.min(1, Math.max(0, u * 0.5 + wave * 0.56 - 0.04));   // 明暗的起伏占的份量大一些，流动看得更清楚
      const c = k < 0.5 ? mix(palette[0], palette[1], k * 2) : mix(palette[1], palette[2], (k - 0.5) * 2);
      grad.addColorStop(u, `rgb(${c[0] | 0}, ${c[1] | 0}, ${c[2] | 0})`);
    }
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, W, H);

    // 粒子
    const kick = Math.sqrt(dt) * 13;
    ctx.lineCap = 'round';
    for (const d of dots) {
      d.vx += -d.vx * 1.4 * dt + (Math.random() - 0.5) * kick;
      d.vy += -d.vy * 1.4 * dt + (Math.random() - 0.5) * kick;
      const carried = (0.045 + speed) * d.drift * W;   // 被流带着往右的速度：平时也慢慢漂，fast 时快得多
      d.x += (d.vx + carried) * dt / W;
      d.y += d.vy * dt / H;
      if (d.x > 1.03) { d.x = -0.03; d.y = Math.random(); }
      if (d.x < -0.03) d.x = 1.03;
      if (d.y < 0.1) { d.y = 0.1; d.vy = Math.abs(d.vy); }
      if (d.y > 0.9) { d.y = 0.9; d.vy = -Math.abs(d.vy); }
      const alpha = d.a * (0.55 + 0.45 * Math.sin(now * 0.001 * d.tw + d.ph));
      const x = d.x * W, y = d.y * H, tail = speed * d.drift * W * 0.03;   // 尾巴只在 fast 时有
      ctx.strokeStyle = `rgba(255, 255, 255, ${alpha})`;
      ctx.lineWidth = d.r * 2;
      ctx.beginPath();
      ctx.moveTo(x - tail, y);
      ctx.lineTo(x + 0.01, y);
      ctx.stroke();
    }
    requestAnimationFrame(frame);
  }
  // 第一帧马上画（已经在页面上的话），别让新画布空着亮一帧
  if (track.isConnected) frame(performance.now()); else requestAnimationFrame(frame);
}
