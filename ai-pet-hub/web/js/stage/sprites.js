'use strict';

// 角色舞台的素材：逐帧图的加载和解码、各种循环用哪几帧、散步的计时。Pet 类在 pet.js 和 pet-*.js 里。
// 用 core/ 里的 S / AGENTS / active / lsGet 等；boot.js 在这之后创建 pets。

// ===== 舞台上的 AI 娘 =====
const rand = n => Math.floor(Math.random() * n);
// 逐帧素材的格式：源码里是 PNG 原图（tools/sprites 的出图和处理都用它）；build.sh 打包时转成 WebP 并把这一行改成 'webp'
const SPRITE_EXT = 'png';
const preloaded = new Set();
const keepAlive = [];
function preloadSkin(id, skin) {
  const key = `${id}/${skin}`;
  if (preloaded.has(key)) return;
  preloaded.add(key);
  FRAME_KEYS.forEach(f => decodeFrame(`sprites/${id}/${skin}/${f}.${SPRITE_EXT}`));
}

const frameSetState = new Map();   // "sprites/id/skin/名字" → true（都解码好了）| false（缺图）| Promise（加载中）
/** 一组帧能不能用：true / false / null（加载中，onDone 在加载完时回调）。用到时才加载，不在启动时解码全部。 */
function loadFrameSet(id, name, keys, onDone) {
  const base = `sprites/${id}/${S[id].skin}/`;
  const key = base + name;
  const st = frameSetState.get(key);
  if (st === true || st === false) return st;
  if (!st) {
    frameSetState.set(key, Promise.all(keys.map(k => decodeFrame(`${base}${k}.${SPRITE_EXT}`))).then(oks => {
      const ok = oks.every(Boolean);
      frameSetState.set(key, ok);
      return ok;
    }));
  }
  if (onDone) frameSetState.get(key).then(onDone);
  return null;
}
/**
 * 思考 / 查阅 / 施工可用的几套循环帧，排在前面的优先（都没有就放原来的 4 帧 <动作>_f0…f3）。
 * _g00…g11：在一个对话里连续画的 12 帧（见 tools/sprites）。不用程序插值补帧（拉伸变形像橡皮人）。
 */
const LOOP_SETS = [
  { name: '_g12', keys: phase => Array.from({ length: 12 }, (_, i) => `${phase}_g${String(i).padStart(2, '0')}`) },
];
/** fast 形态的那一套（tools/sprites/gen_fast.py）：6 帧，一张图里一次画出来再切开的。只有克劳蒂娜和吉佩缇有。 */
const FAST_SET = { name: '_fast', keys: phase => Array.from({ length: 6 }, (_, i) => `${phase}_fast_g0${i}`) };
/**
 * 被拖着时的小挣扎：两张只差一点点的（dragged_a 左脚轻抬、dragged_b 右脚轻抬）交替，
 * 幅度小、节奏慢一些，看着是委屈地扑腾，不是乱踢。
 */
// 不用原来那张 dragged：它是早先另一种方法抠的图，袖口半透明发暗，和新画的两张交替会一黑一白地闪
const STRUGGLE_KEYS = ['dragged_a', 'dragged_b'];
const STRUGGLE_MS = 170;
const loadStruggle = (id, onDone) => loadFrameSet(id, 'dragged', ['dragged_a', 'dragged_b'], onDone);
/** 同一个对话里连续画的 12 帧挣扎（dragged_g00…g11）。 */
const STRUGGLE12_KEYS = Array.from({ length: 12 }, (_, i) => `dragged_g${String(i).padStart(2, '0')}`);
/**
 * 12 帧挣扎来回播（00→11→01，再接回 00），每帧 100ms，直接换帧（不叠化：两帧叠在一起看着发虚、晃眼）。
 * AI 画的 12 帧越往后脚和身子会慢慢偏一点，从 11 直接跳回 00 时会猛地弹一下，看着像抽搐；来回播就没有这一下。
 */
const STRUGGLE12_ORDER = [...STRUGGLE12_KEYS, ...STRUGGLE12_KEYS.slice(1, -1).reverse()];
const STRUGGLE12_MS = 100;
/**
 * 吉佩缇的 12 帧腿踢得太大：只挑腿的位置最接近的 4 帧（10、03、07、08）来回播，
 * 每 4 个来回插一次眨眼（05 半睁 → 04 闭眼 → 05），每帧 130ms。
 */
const STRUGGLE_PICK = {
  gpt: { loop: [10, 3, 7, 8], blink: [5, 4, 5], blinkEvery: 4, ms: 130 },
  // 大肥鱼的 12 帧是左右手脚交替扑腾，全放的话一秒十下，太闹：挑相邻的 4 帧慢一点来回
  deepseek: { loop: [0, 1, 2, 3], blink: [5, 6, 5], blinkEvery: 4, ms: 150 },
};
function struggleOrder(id) {
  const pick = STRUGGLE_PICK[id];
  if (!pick) return { keys: STRUGGLE12_ORDER, ms: STRUGGLE12_MS };
  const key = i => STRUGGLE12_KEYS[i];
  const pingpong = [...pick.loop, ...pick.loop.slice(1, -1).reverse()].map(key);
  const keys = [];
  for (let r = 0; r < pick.blinkEvery; r++) keys.push(...pingpong);
  keys.push(...pick.blink.map(key));
  return { keys, ms: pick.ms };
}
const loadStruggle12 = (id, onDone) => loadFrameSet(id, 'dragged_g12', STRUGGLE12_KEYS, onDone);
/**
 * 睡觉 / 开心的 12 帧循环（<状态>_g00…g11，同一个对话里连续画的）。没有这套图就停在原来那一张。
 * 睡觉放得慢（每帧 300ms、帧间叠化），看着是安稳地睡；开心放得快、直接换帧。
 */
const STATE_LOOP = { sleep: { ms: 300, fade: 220 }, happy: { ms: 95, fade: 0 } };
const stateLoopKeys = state => Array.from({ length: 12 }, (_, i) => `${state}_g${String(i).padStart(2, '0')}`);
const loadStateLoop = (id, state, onDone) => loadFrameSet(id, `${state}_g12`, stateLoopKeys(state), onDone);
/** 入睡 / 醒来的过渡帧：打哈欠（yawn_0 刚张嘴、yawn_1 张到最大）、揉眼睛（wake_0）、伸懒腰（wake_1）。缺图就用原来的眨眼 → 蹲下。 */
const NAP_KEYS = ['yawn_0', 'yawn_1', 'wake_0', 'wake_1'];
const loadNap = (id, onDone) => loadFrameSet(id, 'nap', NAP_KEYS, onDone);
/** 睡觉素材里画着的 zZZ 在立绘框里的位置（横、纵各占多少）：飘出来的小 z 从这儿起飞 */
const SLEEP_Z_AT = { gpt: [0.84, 0.2], claude: [0.88, 0.1], gemini: [0.86, 0.06], deepseek: [0.8, 0.11] };

/**
 * 帧图解码好了才换上去：没解码完就换，会有一瞬间是空的（一闪）。
 * 返回是否成功；失败的不记下来，下次再试，这次就留在当前帧，不换成破图。
 */
const decodedFrames = new Set();
const decodingFrames = new Map();
function decodeFrame(url) {
  if (decodedFrames.has(url)) return Promise.resolve(true);
  if (!decodingFrames.has(url)) {
    const img = new Image();
    img.src = url;
    const loaded = img.decode ? img.decode() : new Promise((res, rej) => { img.onload = res; img.onerror = rej; });
    decodingFrames.set(url, loaded.then(() => {
      decodedFrames.add(url);
      keepAlive.push(img);
      return true;
    }, () => false).finally(() => decodingFrames.delete(url)));
  }
  return decodingFrames.get(url);
}

let walkLoopRunning = false;
let lastStepTs = 0;
function ensureWalkLoop() {
  if (walkLoopRunning) return;
  walkLoopRunning = true;
  lastStepTs = performance.now();
  const step = ts => {
    const dt = Math.min(0.05, (ts - lastStepTs) / 1000);
    lastStepTs = ts;
    let anyMoving = false;
    AGENT_IDS.forEach(a => { if (pets[a].step(dt)) anyMoving = true; });
    if (anyMoving) requestAnimationFrame(step);
    else walkLoopRunning = false;
  };
  requestAnimationFrame(step);
}
