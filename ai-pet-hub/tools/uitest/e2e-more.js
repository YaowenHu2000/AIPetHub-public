// 图片附件、回答中改设置的提示、「再显示 300 条」、排着的多句话一句一句发、内置浏览器工具的开关、Codex 的 / 命令。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (cond, ms, what) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { const v = cond(); if (v) return v; await sleep(150); } throw new Error('等不到：' + what); };
const out = { steps: [] };
const note = (k, v) => { out.steps.push(k + ' = ' + JSON.stringify(v)); };
const id = AGENT;
try {
  setActive(id);
  setWorkspace(id, REPO, false);
  S[id].model = MODEL; S[id].effort = 'low'; S[id].perm = FULL_PERM; renderComposer();
  const box = S[id].msgEl;
  const lastAnswer = () => [...box.querySelectorAll('.msg.bot.turn')].pop()?.querySelector('.answer')?.textContent.trim().replace(/\s+/g, ' ').slice(0, 60);
  const ask = async text => { els.input.value = text; send(); await until(() => viewBusy(id), 5000, '开始回答'); await until(() => !isBusy(id), 200000, '回答结束'); await sleep(500); };

  // 图片附件：附一张纯红的图，问颜色
  addAttachments(id, [DIR + '/red.png'], false);
  note('附件栏里的图片', [...document.querySelectorAll('.attach-chip .attach-name')].map(e => e.textContent));
  await ask('这张图片是什么颜色？只回答颜色的名字。');
  note('问图片颜色的回答', lastAnswer());
  note('发出后附件栏清空', document.querySelectorAll('.attach-chip').length);
  note('气泡里有缩略图', !!box.querySelector('.msg.user img'));

  // 内置浏览器工具的开关
  // 同一个会话里先关再开：让它真的去调一次（只问「有没有」的话它常常不查就答），关着应该调不了，打开应该打得开测试页
  const openPage = '请调用 browser_open 这个工具打开 ' + PAGE + ' （不要改用别的办法）。打开了就只回答页面的标题；没有这个工具就只回答「没有这个工具」。';
  lsSet('browser_tools', 'off');
  await ask(openPage);
  note('关掉后让它打开测试页', lastAnswer());
  lsSet('browser_tools', 'on');
  await ask(openPage);
  note('再打开后让它打开测试页', lastAnswer());
  S[id].loadedSig = '';
  postNative('loadConversation', { agent: id, conversationId: S[id].conversationId });
  await sleep(2500);
  note('重读后用户消息里有没有应用自动加的说明', [...box.querySelectorAll('.msg.user')].some(e => e.textContent.includes('AIPetHub 提示')));
  note('/ 的命令个数', (agentCommands[id] || []).length);
  note('前几个命令', (agentCommands[id] || []).slice(0, 4).map(c => c.name));

  // 回答进行中改设置：提示下一句起生效；排着的多句话一句一句发
  const said = [];
  const realSay = pets[id].say.bind(pets[id]);
  pets[id].say = (t, ms) => { said.push(t); return realSay(t, ms); };
  els.input.value = '用终端命令运行：sleep 12; echo done 。然后只回答 done。'; send();
  await untilCommand(box);
  updateSetting(id, 'effort', S[id].effort, '思考强度不变');
  note('回答中改设置的提示', said.find(t => t.includes('下一句起生效')) || null);
  pets[id].say = realSay;
  els.input.value = '只回答：甲'; send();
  els.input.value = '只回答：乙'; send();
  await sleep(600);
  note('排队气泡', [...box.querySelectorAll('.msg.user.queued .queued-state')].map(e => e.textContent.slice(0, 12)));
  await until(() => !isBusy(id), 240000, '这一轮结束');
  await sleep(1500);
  await until(() => !isBusy(id), 240000, '排着的也答完');
  await sleep(1500);
  await until(() => !isBusy(id), 240000, '都答完');
  await sleep(600);
  const users = [...box.querySelectorAll('.msg.user:not(.queued)')].map(e => e.textContent.trim().slice(0, 10));
  note('最后几条用户消息', users.slice(-3));
  note('最后的回答', lastAnswer());
  note('还有排队气泡', box.querySelectorAll('.msg.user.queued').length);

  // 回答进行中补充一句，带一张图片：能送进去的连图一起送（Claude、Codex），送不进去的排着、之后连图一起发（Gemini）
  els.input.value = '用终端命令运行：sleep 6; echo ok 。然后只回答 ok。'; send();
  await untilCommand(box);
  addAttachments(id, [DIR + '/red.png'], false);
  els.input.value = '另外：我刚附的这张图片是什么颜色？回答里一定要写出颜色。'; send();
  await sleep(500);
  note('带图片的排队气泡', [...box.querySelectorAll('.msg.user.queued .queued-text')].map(e => e.textContent.replace(/\s+/g, ' ').slice(0, 40)));
  note('带图片那句的状态（送进去了还是排着）', [...box.querySelectorAll('.msg.user.queued .queued-state')].map(e => e.textContent.slice(0, 16)));
  await until(() => !isBusy(id), 240000, '这一轮结束');
  await sleep(1500);
  await until(() => !isBusy(id), 240000, '排着的也答完');
  await sleep(600);
  note('中途带图片补充后的回答', [...box.querySelectorAll('.msg.bot.turn')].slice(-2).map(t => t.querySelector('.answer')?.textContent.trim().replace(/\s+/g, ' ').slice(0, 50)));

  // 「再显示 300 条」：点了以后带着更大的条数重新读
  const posted = [];
  const realPost = window.postNative;
  window.postNative = (action, payload) => { posted.push([action, payload]); if (action !== 'loadConversation') realPost(action, payload); };
  renderMessages(id, [{ role: 'user', text: '旧消息' }, { role: 'bot', text: '旧回答' }], REPO, 420);
  const more = box.querySelector('.load-earlier');
  note('顶上的提示', more ? more.textContent : null);
  more.click();
  const call = posted.find(p => p[0] === 'loadConversation');
  note('点了以后请求的条数', call ? call[1].limit : null);
  window.postNative = realPost;
} catch (e) { out.error = String(e && e.message || e); }
return out;
