// 不怎么用 CLI（只验证一次 claude）：AI 可增删——移除、自动换当前这一位、至少留一位、找 CLI、发一句话验证后加回来、布局跟着变。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const out = { steps: [], ok: true };
const check = (name, pass, got) => { out.steps.push(`${pass ? '✓' : '✗'} ${name}：${JSON.stringify(got)}`); if (!pass) out.ok = false; };
const snap = () => ({
  ids: AGENT_IDS.join(), sections: document.querySelectorAll('#hist-sections .hist-section, .hist-section').length,
  splitters: document.querySelectorAll('.hist-splitter').length, cards: document.querySelectorAll('#stage-column .pet-card').length,
  add: !!document.querySelector('#stage-column .pet-add'), active, body: document.body.dataset.agent,
  saved: localStorage.getItem('aihub_enabled_agents'),
});
const savedBefore = localStorage.getItem('aihub_enabled_agents');
try {
  await sleep(1500);
  AGENT_IDS.splice(0, AGENT_IDS.length, 'gemini', 'claude', 'gpt'); afterAgentsChanged(); setActive('claude', false);
  let s = snap();
  check('开始：三位', s.ids === 'gemini,claude,gpt' && s.sections === 3 && s.cards === 3 && s.splitters === 2 && !s.add, s);

  disableAgent('gpt'); await sleep(300); s = snap();
  check('移除 gpt', s.ids === 'gemini,claude' && s.sections === 2 && s.splitters === 1 && s.cards === 2 && s.add && s.saved === '["gemini","claude"]', s);
  const secs = [...document.querySelectorAll('.hist-section')];
  const total = els.sections.getBoundingClientRect().height;
  const sum = secs.reduce((n, x) => n + x.getBoundingClientRect().height, 0) + [...document.querySelectorAll('.hist-splitter')].reduce((n, x) => n + x.getBoundingClientRect().height, 0);
  check('左栏两格占满，没空出一格', Math.abs(total - sum) < 3, { total: Math.round(total), sum: Math.round(sum) });
  const stage = els.stage.getBoundingClientRect(), cards = [...document.querySelectorAll('#stage-column .pet-card')].map(c => Math.round(c.getBoundingClientRect().height));
  check('两张卡片分掉桌宠列的高度', cards.every(h => h > 190), { stage: Math.round(stage.height), cards });

  disableAgent('claude'); await sleep(300); s = snap();
  check('移除当前这一位：自动换到 gemini', s.ids === 'gemini' && s.active === 'gemini' && s.body === 'gemini' && s.cards === 1, s);
  check('聊天区只显示 gemini 的', !S.gemini.msgEl.hidden && S.claude.msgEl.hidden && S.gpt.msgEl.hidden, [S.gemini.msgEl.hidden, S.claude.msgEl.hidden, S.gpt.msgEl.hidden]);

  disableAgent('gemini'); await sleep(200); s = snap();
  check('最后一位不让移除', s.ids === 'gemini', s);

  // 「添加」菜单：找 CLI
  document.querySelector('.pet-add').click(); await sleep(400);
  for (let i = 0; i < 40 && !(agentProbe.claude && agentProbe.gpt); i++) await sleep(250);
  check('找到 claude / gpt 的 CLI', agentProbe.claude?.found && agentProbe.gpt?.found, { claude: agentProbe.claude, gpt: agentProbe.gpt });
  const rows = [...els.popover.querySelectorAll('.pop-item')].map(r => r.textContent.replace(/\s+/g, ' ').trim());
  check('菜单里列出两位和状态', rows.length === 2 && rows.every(t => t.includes('已找到')), rows);

  // 点第一项（claude）：验证后加回来
  const t0 = Date.now();
  els.popover.querySelector('.pop-item').click(); await sleep(300);
  const running = els.popover.querySelector('.pop-item')?.textContent.includes('正在验证');
  for (let i = 0; i < 440 && !AGENT_IDS.includes('claude') && agentVerify.claude?.state !== 'failed'; i++) await sleep(250);
  s = snap();
  check('验证时显示「正在验证」', running, running);
  check('验证通过后 claude 加回来，排在 gemini 后面，并切到它', s.ids === 'gemini,claude' && s.active === 'claude' && s.cards === 2, { ...s, seconds: Math.round((Date.now() - t0) / 1000), verify: agentVerify.claude });

  enableAgent('gpt'); await sleep(300); s = snap();
  check('加回 gpt：恢复三位，「添加」消失', s.ids === 'gemini,claude,gpt' && s.sections === 3 && s.cards === 3 && !s.add && s.saved === '["gemini","claude","gpt"]', s);
  const names = [...document.querySelectorAll('.hist-section')].map(x => x.dataset.agent).join();
  check('左栏顺序', names === 'gemini,claude,gpt', names);
  postNative('testSnapshot', { path: DIR + '/agents.png' }); await sleep(600);
} catch (e) { out.ok = false; out.error = String(e && e.stack || e); }
if (savedBefore === null) localStorage.removeItem('aihub_enabled_agents'); else localStorage.setItem('aihub_enabled_agents', savedBefore);
return out;
