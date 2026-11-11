// 这个会话的上下文用了多少、是什么占的（模型面板里），以及「压缩」按钮。会真的问两句很短的话，再压缩一次。
// 这样跑：REAL=1 tools/uitest/run.sh <claude|gpt|deepseek|gemini> e2e-context.js [模型]（Gemini 的 CLI 不报用量：只有「压缩」按钮，没有数字）
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (cond, ms, what) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { const v = cond(); if (v) return v; await sleep(200); } throw new Error('等不到：' + what); };
const out = { steps: [], ok: true, errors: [] };
window.addEventListener('error', e => out.errors.push(String(e.message) + ' @' + (e.filename || '').split('/').pop() + ':' + e.lineno));
const check = (name, pass, got) => { out.steps.push(`${pass ? '✓' : '✗'} ${name}：${JSON.stringify(got)}`); if (!pass) out.ok = false; };
const id = AGENT;
const saved = localStorage.getItem('aihub_enabled_agents');
try {
  await sleep(1200);
  if (!AGENT_IDS.includes(id)) { enableAgent(id); await sleep(1500); }
  setActive(id); setWorkspace(id, REPO, false);
  if (MODEL) S[id].model = MODEL;
  S[id].perm = FULL_PERM; renderComposer();
  const box = S[id].msgEl;
  const ask = async text => { els.input.value = text; send(); await until(() => viewBusy(id), 10000, '开始回答'); await until(() => !isBusy(id), 240000, '回答结束'); await sleep(600); };
  const lastBot = () => { const t = [...box.querySelectorAll('.msg.bot')].pop(); return (t?.querySelector('.answer') || t)?.textContent.trim().slice(0, 160) || ''; };
  const ctx = () => agentContext[`${id}:${S[id].conversationId}`];
  await ask('请用三四句话介绍一下什么是 git 的 rebase。不要使用任何工具，直接回答。');
  await ask('再用三四句话说说它和 merge 的区别。不要使用任何工具，直接回答。');
  const needParts = id !== 'gemini';
  const got = await until(() => ctx(), needParts ? 12000 : 3000, '上下文用量').catch(() => null);
  check('答完以后报了上下文用量', !needParts || (!!got && got.used > 0 && got.max >= got.used), got && { used: got.used, max: got.max, estimated: got.estimated });
  check('带了「是什么占的」明细', !needParts || (got?.parts || []).length >= 2, (got?.parts || []).map(p => `${p.id}:${p.tokens}`));
  if (got && !got.estimated && needParts) {
    const sum = got.parts.filter(p => p.kind !== 'buffer').reduce((n, p) => n + p.tokens, 0);
    check('各项加起来等于已用', Math.abs(sum - got.used) <= Math.max(50, got.used * 0.02), { sum, used: got.used });
  }
  openModelPopover(); await sleep(500);
  const panel = document.getElementById('popover'), cbox = panel.querySelector('.ctx-box');
  const rows = [...(cbox?.querySelectorAll('.ctx-part') || [])].map(r => r.textContent);
  const segs = [...(cbox?.querySelectorAll('.ctx-mix i') || [])];
  const mixW = cbox?.querySelector('.ctx-mix')?.getBoundingClientRect().width || 0, segW = segs.reduce((n, s) => n + s.getBoundingClientRect().width, 0);
  check('面板里有这一栏：分段的条（各段正好铺满一条）、一行一类的明细', !!cbox && (!needParts || (rows.length >= 2 && segs.length >= 2 && segW <= mixW + 0.5 && segW > mixW * 0.9)), { rows, segs: segs.length, label: cbox?.querySelector('.usage-label')?.textContent, total: cbox?.querySelector('.usage-reset')?.textContent });
  const pr = panel.getBoundingClientRect();
  check('面板没有超出窗口', pr.top >= 0 && pr.bottom <= innerHeight && pr.left >= 0 && pr.right <= innerWidth, { top: pr.top, bottom: pr.bottom, h: innerHeight });
  const btn = cbox?.querySelector('.ctx-compact');
  check('有「压缩」按钮，空闲时能点', !!btn && !btn.disabled, { has: !!btn, disabled: btn?.disabled });
  postNative('testWindowShot', { path: `${DIR}/context-${id}.png` }); await sleep(500);
  if (btn) {
    const before = got?.used, users = box.querySelectorAll('.msg.user').length;
    const onResp = window.onAgentResponse;
    window.onAgentResponse = d => { out.resp = (d.reply || '').slice(0, 120); onResp(d); };
    btn.click();
    await until(() => viewBusy(id), 10000, '开始压缩');
    const said = [...box.querySelectorAll('.msg.user')].pop()?.textContent.trim();
    check('点了以后面板收起、发出一句压缩命令', pop === null && /^\/(compact|compress)$/.test(said) && box.querySelectorAll('.msg.user').length - users === 1, { said: [...box.querySelectorAll('.msg.user')].pop()?.textContent.trim().slice(0, 30), users: box.querySelectorAll('.msg.user').length - users });
    openModelPopover(); await sleep(400);
    check('压缩进行中：按钮点不了', document.querySelector('#popover .ctx-compact')?.disabled === true, { disabled: document.querySelector('#popover .ctx-compact')?.disabled });
    closePopover();
    await until(() => !isBusy(id), 300000, '压缩结束'); await sleep(600);
    window.onAgentResponse = onResp;
    const note = () => [...box.querySelectorAll('.compact-note')].pop()?.textContent || '';
    const state = () => ({ note: note(), users: box.querySelectorAll('.msg.user').length, turns: box.querySelectorAll('.msg.bot.turn').length });
    const s1 = state();
    check('压缩完：收成一条提示，不留一问一答', !!s1.note && !s1.note.startsWith('⚠️') && s1.users === users && s1.turns === 2, { ...s1, resp: out.resp });
    // 等一次同步（重读 CLI 的记录）：提示还在，前面两轮也没有被重画掉
    S[id].syncing = true; postNative('loadConversation', { agent: id, conversationId: S[id].conversationId }); await sleep(3500);
    const s2 = state();
    check('同步之后：提示还在，对话没变', s2.note === s1.note && s2.users === users && s2.turns === 2, s2);
    out.after = ctx() && { before, used: ctx().used, max: ctx().max, parts: (ctx().parts || []).map(p => `${p.id}:${p.tokens}`) };
    await ask('只回复两个字：收到。');
    check('压缩之后还能接着聊', /收到/.test(lastBot()), { reply: lastBot() });
    out.afterNext = ctx() && { used: ctx().used };
  }
  check('没有脚本报错', out.errors.length === 0, out.errors);
} catch (e) { out.ok = false; out.steps.push('✗ 脚本出错：' + String(e)); }
if (saved === null) localStorage.removeItem('aihub_enabled_agents'); else localStorage.setItem('aihub_enabled_agents', saved);
return out;
