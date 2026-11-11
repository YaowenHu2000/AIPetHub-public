// 排队的话插队：回答进行中发一句（送不进去、排着的那种），点「立即发送」→ 正在做的停下，这一句马上发出去。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (cond, ms, what) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { const v = cond(); if (v) return v; await sleep(200); } throw new Error('等不到：' + what); };
const out = { steps: [] };
const note = (k, v) => { out.steps.push(k + ' = ' + JSON.stringify(v)); };
const id = AGENT;
try {
  setActive(id);
  setWorkspace(id, REPO, false);
  S[id].model = MODEL; S[id].effort = 'low'; S[id].perm = FULL_PERM; renderComposer();
  const box = S[id].msgEl;
  // 说清楚要等它跑完：有的 CLI（agy）会把久的命令放到后台、这一轮马上结束，那样就没有「正在做的」可以插队了
  els.input.value = '用终端命令运行：sleep 60; echo done 。要在前台等它跑完（不要放到后台、不要提前回答），跑完再告诉我输出。'; send();
  await untilCommand(box);
  await sleep(1500);
  els.input.value = '算了，直接回答：1+1 等于几？只答数字。'; send();
  const q = await until(() => box.querySelector('.msg.user.queued.can-jump'), 8000, '排着的气泡');
  note('排队气泡', q.querySelector('.queued-state').textContent);
  const t0 = Date.now();
  q.querySelector('.queued-now').click();
  await until(() => [...box.querySelectorAll('.msg.user:not(.queued)')].some(e => e.textContent.includes('1+1')), 15000, '插队的话发出去');
  note('点了之后几秒发出去', ((Date.now() - t0) / 1000).toFixed(1));
  await until(() => !isBusy(id), 120000, '回答结束');
  await sleep(500);
  const turns = [...box.querySelectorAll('.msg.bot.turn')];
  note('插队那句的回答', turns[turns.length - 1].querySelector('.answer')?.textContent.trim().slice(0, 30));
  note('输入框是空的', els.input.value === '');
  note('还有排队气泡', box.querySelectorAll('.msg.user.queued').length);
} catch (e) { out.error = String(e && e.message || e); }
return out;
