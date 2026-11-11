// 输入和浏览相关的零碎：↑ 翻发过的话、/ 命令、@ 文件、消息上的「编辑」、搜索正文、切回窗口时只追加不重画、停止后按钮可用。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (cond, ms, what) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { const v = cond(); if (v) return v; await sleep(150); } throw new Error('等不到：' + what); };
const out = { steps: [] };
const note = (k, v) => { out.steps.push(k + ' = ' + JSON.stringify(v)); };
const key = k => els.input.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
const type = v => { els.input.value = v; els.input.selectionStart = els.input.selectionEnd = v.length; els.input.dispatchEvent(new Event('input', { bubbles: true })); };
const id = AGENT;
try {
  setActive(id);
  setWorkspace(id, REPO, false);
  S[id].model = MODEL; S[id].effort = 'low'; S[id].perm = FULL_PERM; renderComposer();
  const box = S[id].msgEl;
  const ask = async text => { els.input.value = text; send(); await until(() => viewBusy(id), 5000, '开始回答'); await until(() => !isBusy(id), 200000, '回答结束'); await sleep(500); };

  // @ 文件
  type('看一下 @kee');
  const fileRow = await until(() => document.querySelector('.suggest-box:not([hidden]) .suggest-row'), 6000, '@ 文件的候选');
  note('@ 的候选', [...document.querySelectorAll('.suggest-row .suggest-name')].map(e => e.textContent));
  key('Enter');
  note('选了之后输入框', els.input.value);
  type('');

  await ask('请在回答里原样写出这个词：紫藤萝瀑布。只写这个词。');
  await ask('只回答：第二句');

  // ↑ ↓ 翻发过的话
  type('');
  key('ArrowUp'); const up1 = els.input.value;
  key('ArrowUp'); const up2 = els.input.value;
  key('ArrowDown'); const down1 = els.input.value;
  key('ArrowDown'); const down2 = els.input.value;
  note('↑ ↑ ↓ ↓', [up1.slice(0, 12), up2.slice(0, 12), down1.slice(0, 12), down2]);

  // / 命令（CLI 报上来的；预热或第一次回答后就有）
  type('/');
  await sleep(300);
  let rows = [...document.querySelectorAll('.suggest-box:not([hidden]) .suggest-row .suggest-name')].map(e => e.textContent);
  note('/ 的候选个数', rows.length);
  type('/comp');
  await sleep(200);
  rows = [...document.querySelectorAll('.suggest-box:not([hidden]) .suggest-row .suggest-name')].map(e => e.textContent);
  note('/comp 的候选', rows.slice(0, 4));
  if (rows.length) { key('Enter'); note('选了之后输入框', els.input.value); }
  type('');

  // 消息上的「编辑」
  const firstUser = box.querySelector('.msg.user');
  firstUser.querySelector('.msg-edit').click();
  note('点编辑后输入框', els.input.value.slice(0, 16));
  type('');

  // 切回窗口时的同步：页面和记录对得上就不重画（节点还是原来那个）
  const turn = [...box.querySelectorAll('.msg.bot.turn')].pop();
  turn.dataset.marker = 'same-node';
  S[id].loadedSig = 'force';
  S[id].syncing = true;
  postNative('loadConversation', { agent: id, conversationId: S[id].conversationId });
  await sleep(2500);
  note('同步后回答还是原来的节点', [...box.querySelectorAll('.msg.bot.turn')].pop().dataset.marker === 'same-node');
  note('同步后消息条数', box.querySelectorAll('.msg.user, .msg.bot.turn').length);

  // 搜索正文：标题里没有、只在回答里出现的词
  const search = document.getElementById('hist-search');
  search.value = '藤萝瀑'; search.dispatchEvent(new Event('input', { bubbles: true }));
  await sleep(1500);
  note('搜正文找到的会话数', document.querySelectorAll(`#hist-sections .hist-item, #hist-sections .conv-row`).length || document.querySelector('#hist-sections').textContent.includes('紫藤萝') );
  note('这一位的正文命中', S[id].bodyHits ? S[id].bodyHits.size : null);
  search.value = ''; search.dispatchEvent(new Event('input', { bubbles: true }));

  // 停止后发送按钮马上可用
  // 不靠它去跑命令（模型有时不照做）：让它写一段很长的东西，开始出字了就停
  els.input.value = '从 1 数到 400，每个数字单独占一行，不要省略，不要用工具。'; send();
  await until(() => (box.querySelector('.msg.bot.turn.live .live-answer')?.textContent.length || 0) > 20, 120000, '开始出字');
  stop();
  await until(() => !isBusy(id), 15000, '停下来');
  note('停止后按钮可用', !els.sendBtn.disabled);
} catch (e) { out.error = String(e && e.message || e); }
return out;
