// DIR、AGENT、MODEL、ASK_PERM、FULL_PERM 由 run.sh 加在前面

const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (cond, ms, what) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { const v = cond(); if (v) return v; await sleep(200); } throw new Error('等不到：' + what); };
const shot = name => { postNative('testSnapshot', { path: DIR + '/' + name + '.png' }); return sleep(700); };
const out = { steps: [] };
const note = (k, v) => { out.steps.push(k + ' = ' + JSON.stringify(v)); };
const id = AGENT;
try {
  setActive(id);
  setWorkspace(id, REPO, false);
  S[id].model = MODEL; S[id].effort = 'low';
  const box = S[id].msgEl;
  const ask = async text => { els.input.value = text; send(); await until(() => viewBusy(id), 5000, '开始回答'); };
  const idle = (ms = 200000) => until(() => !isBusy(id), ms, '回答结束');

  // ①② 只有能来问的才测（Claude、Codex；菜单里没有「每次询问」，这里直接指定权限）
  if (ASK_PERM) {
    // ① 来问 → 卡片 → 点「允许」→ 改了 3 个文件 → 「查看全部改动」→ 会话重读后改动卡片还在
    S[id].perm = ASK_PERM; renderComposer();
    await ask('用终端命令运行这一条（一条命令，不要拆开）：echo a > made1.txt; echo b > made2.txt; echo more >> keep.txt 。运行完只回答「好了」。');
    const card = await until(() => box.querySelector('.req-card.req-permission'), 120000, '审批卡片');
    note('审批卡片标题', card.querySelector('.req-title').textContent);
    note('卡片里的命令', (card.querySelector('.req-detail') || card.querySelector('.req-diff') || {}).textContent || '');
    await shot('1-approval');
    card.querySelector('.req-btn.primary').click();
    await idle();
    await sleep(600);
    const lastTurn = () => [...box.querySelectorAll('.msg.bot.turn')].pop();
    note('允许后的回答', lastTurn().querySelector('.answer')?.textContent.trim().slice(0, 40));
    note('卡片收走了', box.querySelectorAll('.req-card').length === 0);
    note('改动卡片', lastTurn().querySelector('.files-head')?.textContent.replace(/\s+/g, ' '));
    lastTurn().querySelector('.files-all').click();
    await sleep(500);
    note('全部改动标签里的文件', [...document.querySelectorAll('.chg-file .chg-name')].map(e => e.textContent));
    note('全部改动里有 diff 行', document.querySelectorAll('.chg-file .cl.add').length);
    await shot('2-changes');
    S[id].loadedSig = '';
    postNative('loadConversation', { agent: id, conversationId: S[id].conversationId });
    await sleep(2500);
    note('重读后还有改动卡片', lastTurn().querySelector('.files-head')?.textContent.replace(/\s+/g, ' '));

    // ② 来问 → 点「拒绝」并说明
    await ask('用终端命令运行：echo no > denied.txt 。如果没被同意就不要再试，只回答「被拒绝了」。');
    const card2 = await until(() => box.querySelector('.req-card.req-permission'), 120000, '第二张审批卡片');
    card2.querySelector('.req-input').value = '不要建这个文件';
    card2.querySelector('.req-btn.danger').click();
    await idle();
    await sleep(400);
    note('拒绝后的回答', [...box.querySelectorAll('.msg.bot.turn')].pop().querySelector('.answer')?.textContent.trim().slice(0, 60));
  }

  // ③ 最高权限，回答进行中再发一句
  S[id].perm = FULL_PERM; renderComposer();
  // 从这里开始盯着：最高权限下整段过程里不该出现审批卡片（卡片答完会被收走，所以要边跑边看，不能只在最后看）
  let sawCard = false;
  const watcher = new MutationObserver(() => { if (box.querySelector('.req-card')) sawCard = true; });
  watcher.observe(box, { childList: true, subtree: true });
  await ask('用终端命令依次运行这三条，每条单独运行：sleep 4; echo one  然后 sleep 4; echo two  然后 sleep 4; echo three 。最后告诉我三个输出。');
  await until(() => box.querySelector('.msg.bot.turn.live .step'), 120000, '第一步出现');
  await sleep(2500);
  els.input.value = '补充：回答的最后请加上「收到补充」这四个字。'; send();
  await sleep(800);
  const q = box.querySelector('.msg.user.queued');
  note('排队气泡', q ? q.querySelector('.queued-state').textContent : null);
  await shot('4-steer');
  await idle();
  await sleep(1500);
  await until(() => !isBusy(id), 200000, '排队的话也答完');
  const turns = [...box.querySelectorAll('.msg.bot.turn')];
  note('最后的回答', turns[turns.length - 1].querySelector('.answer')?.textContent.trim().replace(/\s+/g, ' ').slice(0, 120));
  note('回答个数', turns.length);
  note('有「你补充说」这一步', !!box.querySelector('.step-user'));
  note('还有排队气泡', box.querySelectorAll('.msg.user.queued').length);
  await shot('5-done');

  // ④ 停止
  await ask('用终端命令运行：sleep 60; echo done 。然后告诉我输出。');
  await untilCommand(box);
  await sleep(2000);
  const t0 = Date.now();
  stop();
  await idle(15000);
  note('停止用了几秒', ((Date.now() - t0) / 1000).toFixed(1));
  note('显示已停止', [...box.querySelectorAll('.msg.sys')].some(e => e.textContent.includes('已停止')));
  watcher.disconnect();
  note('最高权限下全程出现过审批卡片', sawCard);
} catch (e) { out.error = String(e && e.message || e); await shot('error'); }
return out;
