// DIR、AGENT、MODEL、FULL_PERM 由 run.sh 加在前面
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (cond, ms, what) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { const v = cond(); if (v) return v; await sleep(200); } throw new Error('等不到：' + what); };
const shot = name => { postNative('testSnapshot', { path: DIR + '/' + name + '.png' }); return sleep(700); };
const out = { steps: [] };
const note = (k, v) => { out.steps.push(k + ' = ' + JSON.stringify(v)); };
const id = AGENT;
try {
  setActive(id);
  setWorkspace(id, DIR + '/repo', false);
  S[id].model = MODEL; S[id].effort = 'low'; S[id].perm = FULL_PERM; renderComposer();
  const box = S[id].msgEl;
  els.input.value = '请用内置浏览器的工具做这件事：先用 browser_open 打开 ' + DIR + '/page.html ，再用 browser_eval 把页面上的按钮点两次，然后用 browser_screenshot 截图确认。最后只回答：页面上显示点了几次。';
  send();
  await until(() => viewBusy(id), 5000, '开始回答');
  await until(() => !isBusy(id), 240000, '回答结束');
  await sleep(800);
  const turn = [...box.querySelectorAll('.msg.bot.turn')].pop();
  turn.querySelector('.work-head')?.click();
  await sleep(300);
  note('回答', turn.querySelector('.answer')?.textContent.trim().replace(/\s+/g, ' ').slice(0, 80));
  note('用到的工具', [...turn.querySelectorAll('.step')].map(s => s.textContent.trim().replace(/\s+/g, ' ').slice(0, 46)).filter(t => /browser/i.test(t)));
  note('浏览器标签开着', !!pane.tabs.find(t => t.kind === 'browser') && !pane.el.hidden);
  note('地址栏', browser.url || browser.file || '');
  await shot('browser-' + id);
} catch (e) { out.error = String(e && e.message || e); await shot('error-' + id); }
return out;
