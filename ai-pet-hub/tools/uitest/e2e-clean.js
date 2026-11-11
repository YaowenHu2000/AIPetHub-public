// 模拟一台干净的机器（用 tools/uitest/clean-machine.sh 跑：空的主目录、最小的 PATH）。MODEL 传进来的是场景：
//   none：一个 CLI 都没装；path：装在登录 shell 的 PATH 里（像 nvm 那样），但都没登录。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (cond, ms, what) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { const v = cond(); if (v) return v; await sleep(200); } throw new Error('等不到：' + what); };
const out = { steps: [], ok: true, errors: [], scene: MODEL };
window.addEventListener('error', e => out.errors.push(String(e.message) + ' @' + (e.filename || '').split('/').pop() + ':' + e.lineno));
const check = (name, pass, got) => { out.steps.push(`${pass ? '✓' : '✗'} ${name}：${JSON.stringify(got)}`); if (!pass) out.ok = false; };
const verify = id => new Promise(res => {
  const prev = window.onAgentVerified;
  window.onAgentVerified = d => { if (d.agent === id) { window.onAgentVerified = prev; res(d); } else prev && prev(d); };
  postNative('verifyAgent', { agent: id });
  setTimeout(() => res({ timeout: true }), 115000);
});
try {
  await sleep(1500);
  check('页面起来了，四位都认得', ALL_AGENT_IDS.join() === 'gemini,claude,gpt,deepseek', ALL_AGENT_IDS);
  openWelcome();
  await until(() => ALL_AGENT_IDS.every(id => agentProbe[id]), 30000, '检测完');
  await sleep(400);
  const states = Object.fromEntries(ALL_AGENT_IDS.map(id => [id, agentProbe[id]]));
  const rows = [...document.querySelectorAll('#welcome .wl-agent')].map(r => r.textContent.trim());
  const hows = [...document.querySelectorAll('#welcome .wl-how')].map(r => r.textContent.trim().slice(0, 60));
  out.probe = states;
  // 装在 App 里的（比如 ChatGPT.app 自带的 codex）在这台机器上照样找得到：这是对的，算「已装」
  const inApp = id => /\.app\//.test(agentProbe[id].path || '');
  const missing = ALL_AGENT_IDS.filter(id => !agentProbe[id].found);
  if (MODEL === 'none') {
    check('主目录和 PATH 里的都找不到（App 自带的除外）', ALL_AGENT_IDS.every(id => !agentProbe[id].found || inApp(id)), states);
    check('引导页：没装的标「没有装」并带安装说明，装了的标「已找到」', rows.length === 4 && hows.length === missing.length
      && ALL_AGENT_IDS.every((id, i) => rows[i].includes(agentProbe[id].found ? '已找到' : '没有装')), { rows, hows });
    const note = document.querySelector('#welcome .wl-note').textContent;
    check('底部提示和找到的个数对得上', missing.length === 4 ? note.includes('一位都没找到') : note.includes(`${4 - missing.length} 位`), note);
  } else {
    check('四位都找到了（在登录 shell 的 PATH 里，或 App 自带的）', ALL_AGENT_IDS.every(id => agentProbe[id].found && (agentProbe[id].path.includes('/fakebin/') || inApp(id))), states);
    check('引导页四位都标「已找到」', rows.length === 4 && rows.every(t => t.includes('已找到')) && hows.length === 0, rows);
  }
  await realShot('welcome-' + MODEL);
  // 选「保守」再开始
  document.querySelector('#welcome .wl-opt[data-safe="1"]').click();
  document.querySelector('#welcome .wl-go').click();
  await sleep(800);
  check('引导页关掉了，记住看过', document.getElementById('welcome').hidden && lsGet('welcomed') === '1', { hidden: document.getElementById('welcome').hidden });
  check('权限换成了各位的保守档', ALL_AGENT_IDS.every(id => S[id].perm === AGENTS[id].safePerm), Object.fromEntries(ALL_AGENT_IDS.map(id => [id, S[id].perm])));
  if (MODEL === 'none') check('只启用找到的那几位（一位都没有就保持默认三位）', AGENT_IDS.join() === (ALL_AGENT_IDS.filter(id => agentProbe[id].found).join() || 'gemini,claude,gpt'), AGENT_IDS);
  else check('四位都启用', AGENT_IDS.join() === 'gemini,claude,gpt,deepseek' && document.querySelectorAll('.hist-section').length === 4, AGENT_IDS);
  // 历史：没有任何数据目录时也不出错，列表是空的
  AGENT_IDS.forEach(id => postNative('listConversations', { agent: id }));
  await sleep(4000);
  check('历史列表都是空的、没报错', AGENT_IDS.every(id => Array.isArray(S[id].conversations) && S[id].conversations.length === 0), Object.fromEntries(AGENT_IDS.map(id => [id, (S[id].conversations || 'null').length])));
  // 桌宠的图都在包里
  const imgs = AGENT_IDS.map(id => [id, pets[id].front.naturalWidth]);
  check('桌宠的图都显示出来了', imgs.every(([, w]) => w > 0), imgs);
  // 「添加 AI」验证：没装的说清楚没找到；装了没登录的给出能看懂的原因、不会卡住
  const v = {};
  for (const id of MODEL === 'none' ? ['claude'] : ['claude', 'gpt', 'deepseek']) {
    const t0 = Date.now();
    const r = await verify(id);
    v[id] = { ok: r.ok, seconds: Math.round((Date.now() - t0) / 1000), error: String(r.error || (r.timeout ? '超时' : '')).slice(0, 160) };
  }
  out.verify = v;
  check('验证：不会误报能用，也不会卡住（20 秒内给出原因）', Object.values(v).every(x => !x.ok && x.seconds < 20 && x.error), v);
  if (MODEL === 'path') check('验证的原因说人话：没登录就说没登录、怎么登录', ['claude', 'gpt', 'deepseek'].every(id => /登录|密钥/.test(v[id].error)), v);
  // 发一句话：没装 / 没登录时，回答里是一句能看懂的提示，不是一直转圈
  setActive('claude'); S.claude.model = 'haiku';
  els.input.value = '只回复：甲'; send();
  await until(() => !isBusy('claude') && S.claude.msgEl.querySelector('.msg.bot'), 120000, '回答结束');
  await sleep(600);
  const reply = (S.claude.msgEl.querySelector('.msg.bot:last-child')?.textContent || '').replace(/\s+/g, ' ').slice(0, 200);
  check('没装 / 没登录时发话：给出提示，不卡住', reply.includes('⚠️') && /登录|login|api key|找到/i.test(reply) && !reply.includes('reclaude'), reply);
  await realShot('after-' + MODEL);
  check('没有脚本报错', out.errors.length === 0, out.errors);
} catch (e) { out.ok = false; out.error = String(e) + ' | ' + String(e && e.stack).slice(0, 300); }
return out;
