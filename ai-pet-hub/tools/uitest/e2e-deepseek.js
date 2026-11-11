// 第四位：DeepSeek（走 dsh 的本机服务）。会真的调用 DeepSeek（几轮很短的对话）。
// DIR、REPO、AGENT、MODEL、FULL_PERM 由 run.sh 加在前面：tools/uitest/run.sh deepseek e2e-deepseek.js
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (cond, ms, what) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { const v = cond(); if (v) return v; await sleep(200); } throw new Error('等不到：' + what); };
const out = { steps: [], ok: true };
const check = (name, pass, got) => { out.steps.push(`${pass ? '✓' : '✗'} ${name}：${JSON.stringify(got)}`); if (!pass) out.ok = false; };
const id = 'deepseek';
const saved = localStorage.getItem('aihub_enabled_agents');
try {
  await sleep(1200);
  // 加进来：四位都在，左栏四格、桌宠四张卡片、第四位是鲸鱼娘（逐帧，没有骨骼）
  if (!AGENT_IDS.includes(id)) enableAgent(id);
  await sleep(1500);
  const p = pets[id];
  check('四位都在', AGENT_IDS.join() === 'gemini,claude,gpt,deepseek' && document.querySelectorAll('.hist-section').length === 4 && document.querySelectorAll('#stage-column .pet-card').length === 4,
    { ids: AGENT_IDS.join(), sections: document.querySelectorAll('.hist-section').length, cards: document.querySelectorAll('#stage-column .pet-card').length, bodyAgents: document.body.dataset.agents });
  await until(() => p.front.complete && p.front.naturalWidth > 0, 8000, '鲸鱼娘的图').catch(() => 0);
  check('鲸鱼娘显示出来了（逐帧）', p.front.naturalWidth > 0 && !p.rig && getComputedStyle(p.front).visibility === 'visible',
    { src: (p.front.currentSrc || p.front.src).split('/').slice(-3).join('/'), w: p.front.naturalWidth, rig: !!p.rig });
  const cards = [...document.querySelectorAll('#stage-column .pet-card')].map(c => Math.round(c.getBoundingClientRect().height));
  const stage = els.stage;
  check('四张卡片排得下、不用滚动', stage.scrollHeight <= stage.clientHeight + 2, { cards, scroll: stage.scrollHeight, client: stage.clientHeight });
  postNative('testSnapshot', { path: DIR + '/four.png' }); await sleep(700);

  setActive(id);
  setWorkspace(id, REPO, false);
  S[id].perm = 'danger-full-access'; renderComposer();
  const box = S[id].msgEl;
  const ask = async text => { els.input.value = text; send(); await until(() => viewBusy(id), 8000, '开始回答'); };
  const idle = (ms = 150000) => until(() => !isBusy(id), ms, '回答结束');
  const lastTurn = () => [...box.querySelectorAll('.msg.bot.turn')].pop();
  const answer = () => (lastTurn()?.querySelector('.answer')?.textContent || '').trim();

  // ① 一问一答
  let t0 = Date.now();
  await ask('只回复一个字：甲');
  await idle();
  await sleep(600);
  const cid = S[id].conversationId;
  check('① 回答', answer().includes('甲'), { answer: answer().slice(0, 40), seconds: Math.round((Date.now() - t0) / 1000) });
  check('① 有会话编号', /^session-/.test(cid), cid);
  check('模型菜单跟着 dsh 报的走，Flash 一直留着', AGENTS[id].models.some(m => m.v === 'deepseek-v4-pro') && AGENTS[id].models.some(m => m.v === 'deepseek-v4-flash'), AGENTS[id].models.map(m => `${m.v}[${(m.efforts || []).join('/')}]`));
  check('默认是 Flash + High', S[id].model === 'deepseek-v4-flash' && S[id].effort === 'high', { model: S[id].model, effort: S[id].effort });

  // ② 续聊：记得上一句
  await ask('我上一句让你回复了哪个字？只回复那个字');
  await idle();
  await sleep(600);
  check('② 续聊答得出', answer().includes('甲') && S[id].conversationId === cid, { answer: answer().slice(0, 40), sameConversation: S[id].conversationId === cid });

  // ③ 跑命令、改文件：有步骤，有改动卡片
  await ask('先用终端运行 echo hi > note.txt，再把 note.txt 里的 hi 改成 ho，最后只回复「好了」。');
  await idle(200000);
  await sleep(800);
  const kinds = [...lastTurn().querySelectorAll('.step')].map(s => [...s.classList].find(c => c.startsWith('step-') && c !== 'step-head') || s.className);
  check('③ 有命令步骤', !!lastTurn().querySelector('.step-command'), kinds);
  check('③ 回答', answer().includes('好了'), answer().slice(0, 40));
  check('③ 改动卡片里有 note.txt', (lastTurn().querySelector('.files-card')?.textContent || '').includes('note.txt'), (lastTurn().querySelector('.files-card')?.textContent || '').replace(/\s+/g, ' ').slice(0, 80));
  postNative('testSnapshot', { path: DIR + '/steps.png' }); await sleep(700);

  // ③b 中途补充：它在下一步开始前看到，不用等这一轮结束
  await ask('先用终端运行 sleep 6（前台等它跑完），再用终端运行 echo done，最后只回复「睡醒了」。');
  await until(() => box.querySelector('.msg.bot.turn.live .step-command'), 60000, '开始跑命令').catch(() => 0);
  els.input.value = '补充：回答的最后请加上「收到补充」这四个字。'; send();
  await idle(200000);
  await sleep(800);
  const said = [...lastTurn().querySelectorAll('.step')].some(s => s.textContent.includes('你补充说'));
  check('③b 补充的话进了这一轮（不是排到下一轮）', said && answer().includes('收到补充'), { stepInTurn: said, answer: answer().slice(0, 60), userBubbles: box.querySelectorAll('.msg.user:not(.queued)').length });

  // ③c 账户余额
  window.__usage = null;
  const prevUsage = window.onAgentUsage;
  window.onAgentUsage = d => { if (d.agent === id) window.__usage = d; prevUsage && prevUsage(d); };
  postNative('loadUsage', { agent: id, force: true });
  await until(() => window.__usage && (window.__usage.items || []).length, 40000, '余额').catch(() => 0);
  window.onAgentUsage = prevUsage;
  const labels = ((window.__usage || {}).items || []).map(i => i.label);
  check('③c 查到账户余额', labels.includes('账户余额') && /[\d.]+/.test(String(((window.__usage || {}).items || [])[0]?.text || '')), { labels, error: (window.__usage || {}).error });

  // ④ 停止
  await ask('用终端运行 sleep 40（前台等它跑完，不要放到后台），然后回复「睡醒了」。');
  await until(() => box.querySelector('.msg.bot.turn.live .step'), 60000, '开始做事').catch(() => 0);
  await sleep(1500);
  t0 = Date.now();
  stop();
  await idle(30000);
  check('④ 停得下来', Date.now() - t0 < 15000 && !answer().includes('睡醒了'), { seconds: Math.round((Date.now() - t0) / 1000), answer: answer().slice(0, 30) });
  await sleep(1500);
  await ask('只回复：乙');
  await idle();
  await sleep(500);
  check('④ 停止之后还能接着聊', answer().includes('乙'), answer().slice(0, 30));

  // ⑤ 历史：列表里有这个会话，重新读进来回合数对得上
  postNative('listConversations', { agent: id });
  await sleep(7000);   // 等后台同步跑过两轮：这里自己答的不该被标成「在别处运行中」
  check('自己答的不标「在别处运行中」', !box.querySelector('.work.elsewhere'), [...box.querySelectorAll('.work-label')].map(n => n.textContent));
  const item = await until(() => (S[id].conversations || []).find(c => c.id === cid), 20000, '历史列表里出现这个会话').catch(() => null);
  check('⑤ 历史列表里有它', !!item, item && { title: item.title, cwd: item.cwd, time: item.time });
  S[id].loadedId = ''; S[id].loadedSig = '';
  postNative('loadConversation', { agent: id, conversationId: cid });
  await until(() => S[id].loadedId === cid, 30000, '会话读进来');
  await sleep(1200);
  const users = box.querySelectorAll('.msg.user:not(.queued)').length, bots = box.querySelectorAll('.msg.bot.turn').length;
  check('⑤ 读回来：6 问（补充的那句算在它那一轮里），回答都在', users === 6 && bots >= 5 && box.textContent.includes('甲') && !!box.querySelector('.step-command'), { users, bots });

  // ⑥ 移除：回到三位
  disableAgent(id); await sleep(500);
  check('⑥ 移除后回到三位，出现「添加 AI」', AGENT_IDS.join() === 'gemini,claude,gpt' && !!document.querySelector('.pet-add'), AGENT_IDS.join());
  out.conversation = cid;
} catch (e) { out.ok = false; out.error = String(e) + ' | ' + String(e && e.stack).slice(0, 300); }
if (saved === null) localStorage.removeItem('aihub_enabled_agents'); else localStorage.setItem('aihub_enabled_agents', saved);
return out;
