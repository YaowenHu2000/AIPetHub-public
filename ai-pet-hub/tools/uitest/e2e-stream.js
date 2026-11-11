// 流式输出的节奏：让它写一段三百字的短文，记下正文每次变长的时间和字数。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (cond, ms, what) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { const v = cond(); if (v) return v; await sleep(50); } throw new Error('等不到：' + what); };
const out = {};
const id = AGENT;
try {
  setActive(id);
  setWorkspace(id, REPO, false);
  S[id].model = MODEL; S[id].effort = 'low'; S[id].perm = FULL_PERM; renderComposer();
  els.input.value = '用中文写一段大约 300 字的短文，介绍猫为什么喜欢晒太阳。直接写正文，不要用工具。';
  send();
  const answer = await until(() => S[id].msgEl.querySelector('.msg.bot.turn.live .live-answer'), 10000, '正文位置');
  const marks = []; let last = 0; const t0 = performance.now();
  const timer = setInterval(() => { const n = answer.textContent.length; if (n !== last) { marks.push([Math.round(performance.now() - t0), n - last]); last = n; } }, 16);
  await until(() => !isBusy(id), 180000, '回答结束');
  clearInterval(timer);
  const gaps = marks.slice(1).map((m, i) => m[0] - marks[i][0]);
  const steps = marks.map(m => m[1]);
  out.updates = marks.length;
  out.chars = last;
  out.seconds = marks.length ? ((marks[marks.length - 1][0] - marks[0][0]) / 1000).toFixed(1) : 0;
  out.avgGapMs = gaps.length ? Math.round(gaps.reduce((a, b) => a + b, 0) / gaps.length) : 0;
  out.maxGapMs = gaps.length ? Math.max(...gaps) : 0;
  out.avgCharsPerUpdate = steps.length ? Math.round(steps.reduce((a, b) => a + b, 0) / steps.length) : 0;
  out.maxCharsPerUpdate = steps.length ? Math.max(...steps) : 0;
} catch (e) { out.error = String(e && e.message || e); }
return out;
