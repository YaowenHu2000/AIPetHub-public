// DeepSeek：添加、续聊、工具/改动、补充、余额、停止、历史、移除。
const { out, check, note, skip, until, finish } = makeSuite('deepseek');
const id = 'deepseek', nativeSteps = [];
const saved = localStorage.getItem('aihub_enabled_agents');
const previousResponse = window.onAgentResponse, previousStep = window.onAgentStep;
let response;
window.onAgentResponse = data => { if (data.agent === id) response = data; previousResponse(data); };
window.onAgentStep = data => { if (data.agent === id) nativeSteps.push(data); previousStep(data); };
try {
  if (!AGENT_IDS.includes(id)) enableAgent(id);
  await until(() => pets[id] && S[id], 5000, '添加 DeepSeek');
  check('四位都有会话栏和角色卡片', AGENT_IDS.join() === 'gemini,claude,gpt,deepseek' && document.querySelectorAll('.hist-section').length === 4 && document.querySelectorAll('#stage-column .pet-card').length === 4, AGENT_IDS);
  setActive(id); setWorkspace(id, REPO, false); S[id].perm = FULL_PERM; renderComposer();
  const box = S[id].msgEl;
  const last = () => [...box.querySelectorAll('.msg.bot.turn')].at(-1);
  const answer = () => last()?.querySelector('.answer')?.textContent.trim() || '';
  const ask = async text => {
    response = null; nativeSteps.length = 0;
    els.input.value = text; send();
    await until(() => response || viewBusy(id), 8000, '开始回答');
  };
  const idle = async (ms = 180000) => {
    await until(() => response && !isBusy(id) && !box.querySelector('.msg.user.queued'), ms, '回答与队列结束');
    check('回合无错误', !response.error && !/^⚠️/.test(response.reply || ''), response);
  };
  await ask('只回复一个字：甲'); await idle();
  const cid = S[id].conversationId;
  check('首轮回答已显示', !!answer(), answer());
  check('有 DeepSeek 会话编号', /^session-/.test(cid), cid);
  check('模型菜单包含 dsh 的 Pro 和 Flash', ['deepseek-v4-pro', 'deepseek-v4-flash'].every(v => AGENTS[id].models.some(m => m.v === v)), AGENTS[id].models.map(m => m.v));
  check('默认 Flash + High', S[id].model === 'deepseek-v4-flash' && S[id].effort === 'high', { model: S[id].model, effort: S[id].effort });
  await ask('我上一句让你回复了哪个字？只回复那个字'); await idle();
  check('续聊保持同一会话且新增回答', S[id].conversationId === cid && box.querySelectorAll('.msg.bot.turn').length === 2 && !!answer(), { cid: S[id].conversationId, answer: answer() });
  const command = async (name, prompt, requireRunning = false) => {
    const running = () => [...new Map(nativeSteps.map(e => [e.index, e.step])).values()].some(s => s?.kind === 'command' && s.status === 'running');
    for (let attempt = 0; attempt < 2; attempt++) {
      await ask(prompt);
      await until(() => response || (requireRunning ? running() : nativeSteps.some(e => e.step?.kind === 'command')), 120000, '命令事件或最终回答');
      const issued = nativeSteps.some(e => e.step?.kind === 'command') && (!requireRunning || (!response && running()));
      if (issued) {
        check(name + '：原生命令显示成步骤', !!last()?.querySelector('.step-command'), nativeSteps.map(e => e.step));
        return true;
      }
      await idle(); note(name + '：模型实际回答 ' + (attempt + 1), answer());
    }
    skip(name, '模型没照做', { reply: response?.reply, steps: nativeSteps.map(e => e.step) });
    return false;
  };
  if (await command('命令与改文件', '先用终端运行 echo hi > note.txt，再把 note.txt 里的 hi 改成 ho，最后简短回复。')) {
    await idle();
    // 文件若确实被模型改动，App 必须给卡片；没有改动是模型前置没完成。
    const file = await readLocalFile(REPO + '/note.txt', REPO).catch(() => null);
    if ((file && !file.error) || response.files?.some(f => /note\.txt$/.test(f.path))) {
      await until(() => last()?.querySelector('.files-card'), 8000, 'DeepSeek 改动卡片');
      check('改动卡片包含 note.txt', last().querySelector('.files-card').textContent.includes('note.txt'));
    } else if (last()?.querySelector('.files-card')) {
      check('改动卡片包含 note.txt', last().querySelector('.files-card').textContent.includes('note.txt'));
      note('文件实际结果', file);
    } else skip('改动卡片', '模型没照做', { reply: answer(), file });
  }
  if (await command('中途补充', '先用终端运行 sleep 6（前台等它跑完），再用终端运行 echo done，最后简短回复。', true)) {
    const turnsBefore = box.querySelectorAll('.msg.bot.turn').length;
    els.input.value = '补充：回答最后加上「收到补充」。'; send();
    check('补充产生队列项', !!box.querySelector('.msg.user.queued'));
    await idle();
    check('补充显示在同一轮', box.querySelectorAll('.msg.bot.turn').length === turnsBefore && !!last()?.querySelector('.step-user'), { answer: answer(), turnsBefore, turnsAfter: box.querySelectorAll('.msg.bot.turn').length, hasUserStep: !!last()?.querySelector('.step-user') });
    check('补充后队列清空', !box.querySelector('.msg.user.queued'));
  }
  let usage;
  const previousUsage = window.onAgentUsage;
  window.onAgentUsage = data => { if (data.agent === id) usage = data; previousUsage?.(data); };
  try {
    postNative('loadUsage', { agent: id, force: true });
    await until(() => usage, 40000, 'DeepSeek 余额回调');
    check('账户余额返回数值', usage.items?.some(i => i.label === '账户余额' && /[\d.]+/.test(i.text || '')), usage);
  } finally { window.onAgentUsage = previousUsage; }
  if (await command('停止命令', '用终端运行 sleep 40（前台等它跑完，不要放后台），然后简短回复。', true)) {
    const at = Date.now(); stop(); await idle(30000);
    check('停止回调 cancelled 且15秒内完成', response.cancelled === true && Date.now() - at < 15000, response);
  }
  await ask('只回复：乙'); await idle();
  check('停止后可继续回答', !!answer() && !viewBusy(id), answer());
  const usersBefore = box.querySelectorAll('.msg.user:not(.queued)').length;
  const botsBefore = box.querySelectorAll('.msg.bot.turn').length;
  postNative('listConversations', { agent: id });
  await until(() => S[id].conversations?.some(c => c.id === cid), 20000, 'DeepSeek 历史会话出现');
  check('历史列表包含当前会话', S[id].conversations.some(c => c.id === cid));
  let loaded = 0;
  const previousLoaded = window.onConversationLoaded;
  window.onConversationLoaded = data => { previousLoaded(data); if (data.agent === id && data.conversationId === cid) loaded++; };
  try {
    S[id].loadedSig = ''; postNative('loadConversation', { agent: id, conversationId: cid });
    await until(() => loaded, 30000, 'DeepSeek 历史读取完成');
    check('历史问答数量保持', box.querySelectorAll('.msg.user:not(.queued)').length === usersBefore && box.querySelectorAll('.msg.bot.turn').length === botsBefore, { usersBefore, botsBefore, users: box.querySelectorAll('.msg.user:not(.queued)').length, bots: box.querySelectorAll('.msg.bot.turn').length });
    check('自己的会话没有标成别处运行', !box.querySelector('.work.elsewhere'));
  } finally { window.onConversationLoaded = previousLoaded; }
  disableAgent(id);
  await until(() => !AGENT_IDS.includes(id), 5000, '移除 DeepSeek');
  check('移除后回到三位并有添加按钮', AGENT_IDS.join() === 'gemini,claude,gpt' && !!document.querySelector('.pet-add'));
  out.conversation = cid;
} catch (error) { out.error = String(error); }
finally {
  window.onAgentResponse = previousResponse; window.onAgentStep = previousStep;
  if (saved === null) localStorage.removeItem('aihub_enabled_agents'); else localStorage.setItem('aihub_enabled_agents', saved);
}
return finish();
