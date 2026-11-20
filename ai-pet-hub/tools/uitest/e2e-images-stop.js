// 图片与停止：发图片、回答中带图补充、停止后同步与重试按钮。
// 从 e2e-input-history.js 拆出来，两套同时跑。
const { out, check, note, skip, until, finish } = makeSuite('images-stop');
const id = AGENT;
const { events, sent, restore, key, type, box, response, lastTurn, start, done, ask, load, held, holdHistory, releaseHistory, ctx } = chatHarness(id, { check, note, until });
try {
  setActive(id); newChat(id, true, REPO); setWorkspace(id, REPO, false);
  // 测试工作区在临时文件夹里，会话归进默认折叠的「任务会话」组；展开它，才看得到这些会话的历史行
  S[id].groupState[TASK_GROUP] = 0;
  S[id].model = MODEL; S[id].effort = 'low'; S[id].perm = FULL_PERM; renderComposer();
  addAttachments(id, [DIR + '/red.png'], false);
  check('附件栏显示图片', [...document.querySelectorAll('.attach-name')].some(e => e.textContent.includes('red.png')));
  const imageReply = await ask('这张图片是什么颜色？只回答颜色的名字。'), cid = S[id].conversationId;
  check('所选模型随真实提问发给原生', sent.some(e => e.action === 'askAgent' && e.payload.model === MODEL && e.payload.images?.includes(DIR + '/red.png')));
  check('发送后附件栏清空', document.querySelectorAll('.attach-chip').length === 0);
  await until(() => box.querySelector('.msg.user img'), '用户消息缩略图');
  check('图片消息保留缩略图', !!box.querySelector('.msg.user img')); note('图片实际回答', imageReply.reply);

  // 回答进行中带图片补充；原生是否接收、气泡和图片是否清理才是断言，不判颜色词。
  let imageRound = null;
  const attempts = [];
  for (let attempt = 0; attempt < 2 && !imageRound; attempt++) {
    const req = await start('用终端命令运行：sleep 6; echo ok。请在前台等它结束，然后只回答 ok。');
    await until(() => events.some(e => e.name === 'onAgentStep' && e.data.reqId === req && e.data.step?.kind === 'command' && e.data.step.status === 'running') || response(req), '带图补充前的命令');
    if (!response(req)) imageRound = req;
    else { const r = await done(req); attempts.push(r); if (/^⚠️/.test(r.reply || '')) throw new Error('图片补充前置命令返回 CLI 错误'); }
  }
  if (!imageRound) skip('中途带图片补充', '模型没照做', attempts);
  else {
    addAttachments(id, [DIR + '/red.png'], false); const text = '另外：我刚附的这张图片是什么颜色？回答里一定要写出颜色。';
    type(text); send();
    const q = box.querySelector('.msg.user.queued');
    check('中途图片补充即时显示图片数量', !!q?.querySelector('.queued-text')?.textContent.includes('1 张图片'), q?.textContent);
    check('中途图片路径交给原生 steer', sent.some(e => e.action === 'steerAgent' && e.payload.reqId === imageRound && e.payload.images?.includes(DIR + '/red.png')));
    await done(imageRound);
    check('中途图片补充结束后没有附件及队列残留', !box.querySelector('.msg.user.queued') && !document.querySelector('.attach-chip'));
  }

  // 原 misc 停止后可重新发送，并进一步确认对账不会丢重试按钮。
  const stopReq = await start('从 1 数到 400，每个数字单独占一行，不要省略，不要用工具。');
  await until(() => (box.querySelector('.live-answer')?.textContent.length || 0) > 20 || response(stopReq), '流式回答开始');
  if (!response(stopReq)) {
    stop(); await until(() => !isBusy(id), '停止完成');
    check('停止后发送按钮可用', !els.sendBtn.disabled);
    const stopped = lastTurn(), retry = stopped?.querySelector('.answer-copy.retry');
    check('停止回答有重试按钮', !!retry);
    // 两次同步都已读取，再一起交付；第一份不能消费第二份的同步标记。
    holdHistory();
    const reads = [nextRequestId(), nextRequestId()];
    S[id].loadedSig = 'force';
    reads.forEach(reqId => postNative('loadConversation', { agent: id, conversationId: cid, sync: true, reqId }));
    await until(() => reads.every(reqId => held.has(reqId)), '两份停止后的历史都已读完');
    await releaseHistory();
    check('停止回答同步后节点保留', lastTurn() === stopped);
    check('停止回答同步后重试按钮保留', !!retry?.isConnected);
  } else skip('停止后按钮与同步', '模型没照做', response(stopReq));
} catch (e) { out.error = String(e.message || e); }
finally { restore(); }
return finish();
