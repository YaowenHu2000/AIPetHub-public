/**
 * 桌宠的心情：表情跟着心情走，像宠物一样有一点随机，但不会乱跳。
 *
 * - 心情是一张图上的几个点，只能沿着边一步一步走（开心 ↔ 平静 ↔ 失落），不会上一秒笑、下一秒哭；
 *   每走一步至少要停一会儿（MIN_STAY），所以从「兴奋」到「失落」要好几秒，中间会经过平静。
 * - 事件（回答完、出错、被摸头、被拎起来……）只是给某个心情“推一把”（设一个目标心情 + 想维持多久），
 *   心情一步步走过去；目标过期后慢慢回到平静。
 * - 同一个心情里有几个表情，隔几秒随机换一个，偶尔是原样的脸。
 * - 平静的时候，偶尔自己有点小情绪（往相邻的心情走一步，过一会儿再回来）。
 */

/** 心情图：每个心情能直接走到哪些心情 */
export const MOOD_EDGES = {
  calm: ['happy', 'shy', 'sulky'],
  happy: ['calm', 'excited', 'shy'],
  excited: ['happy'],
  shy: ['calm', 'happy'],
  sulky: ['calm', 'sad'],
  sad: ['sulky'],
};

/** 每个心情里的表情（null = 原画的脸）和权重 */
export const MOOD_EXPRESSIONS = {
  calm: [[null, 6], ['wink', 1]],
  happy: [['smile', 4], [null, 2], ['wink', 2], ['sparkle', 1]],
  excited: [['sparkle', 3], ['heart', 2], ['surprise', 2], ['smile', 2]],
  shy: [['blush', 5], [null, 1], ['smile', 1]],
  sulky: [['puff', 4], [null, 1]],
  sad: [['pout', 4], ['touched', 2]],
};

const MIN_STAY = 3.5;                 // 每个心情至少待几秒才能走下一步
const rand = (a, b) => a + Math.random() * (b - a);

/** 在心情图上找从 a 到 b 的下一步（广度优先） */
function nextStep(a, b) {
  if (a === b) return a;
  const prev = { [a]: null };
  const q = [a];
  while (q.length) {
    const x = q.shift();
    for (const y of MOOD_EDGES[x]) {
      if (y in prev) continue;
      prev[y] = x;
      if (y === b) {
        let s = y;
        while (prev[s] !== a) s = prev[s];
        return s;
      }
      q.push(y);
    }
  }
  return a;
}

function pickWeighted(list, avoid) {
  const opts = list.filter(([e]) => e !== avoid || list.length === 1);
  let sum = opts.reduce((s, [, w]) => s + w, 0), r = Math.random() * sum;
  for (const [e, w] of opts) { if ((r -= w) <= 0) return e; }
  return opts[0][0];
}

export class Mood {
  /** @param available 这位桌宠有哪些表情补丁（没有的表情会被跳过） */
  constructor(available) {
    this.has = e => e === null || available.has(e);
    this.mood = 'calm';
    this.target = 'calm';
    this.targetUntil = 0;
    this.enteredAt = 0;
    this.expr = null;
    this.nextExpr = 0;
    this.nextWhim = 8;
  }

  /** 事件给心情推一把：目标心情 + 想维持多少秒 */
  push(mood, seconds, t) {
    this.target = mood;
    this.targetUntil = t + seconds;
  }

  /** 每帧调用，返回现在想要的表情 */
  step(t) {
    // 目标过期：回到平静
    if (t > this.targetUntil && this.target !== 'calm') this.target = 'calm';
    // 平静时偶尔有点小情绪
    if (this.target === 'calm' && this.mood === 'calm' && t > this.nextWhim) {
      this.push(Math.random() < 0.75 ? 'happy' : (Math.random() < 0.5 ? 'shy' : 'sulky'), rand(5, 10), t);
      this.nextWhim = t + rand(18, 40);
    }
    // 沿心情图走一步（每步至少停 MIN_STAY 秒）
    if (this.mood !== this.target && t - this.enteredAt > MIN_STAY) {
      this.mood = nextStep(this.mood, this.target);
      this.enteredAt = t;
      this.nextExpr = t;                     // 换心情时马上换一个这个心情的表情
    }
    // 同一心情里隔几秒随机换表情
    if (t >= this.nextExpr) {
      const list = MOOD_EXPRESSIONS[this.mood].filter(([e]) => this.has(e));
      this.expr = list.length ? pickWeighted(list, this.expr) : null;
      this.nextExpr = t + rand(5, 11);
    }
    return this.expr;
  }
}
