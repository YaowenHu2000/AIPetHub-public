// 上下文与压缩：上下文用量和明细、压缩按钮的流程、压缩前读出的历史晚到时不能冲掉压缩提示、压缩后还能接着答。
// 压缩本身要一分钟左右（CLI 要把对话写成摘要），所以单独一套，和 e2e-input-history / e2e-images-stop 同时跑。
const { out, check, note, skip, until, finish } = makeSuite('compact');
const id = AGENT;
const { events, sent, restore, key, type, box, response, lastTurn, start, done, ask, load, held, holdHistory, releaseHistory, ctx } = chatHarness(id, { check, note, until });
try {
  setActive(id); newChat(id, true, REPO); setWorkspace(id, REPO, false);
  // 测试工作区在临时文件夹里，会话归进默认折叠的「任务会话」组；展开它，才看得到这些会话的历史行
  S[id].groupState[TASK_GROUP] = 0;
  S[id].model = MODEL; S[id].effort = 'low'; S[id].perm = FULL_PERM; renderComposer();
  const first = '请在回答里原样写出这个词：紫藤萝瀑布。只写这个词。';
  await ask(first);   // 先有一轮对话，才有上下文可压缩
  const cid = S[id].conversationId;
  // 上下文数字、明细和压缩流程；像素、分段宽度、面板边界不属于核心回归。
  if (id !== 'gemini') {
    await until(() => ctx(), '上下文用量');
    check('上下文用量有效且有明细', ctx().used > 0 && ctx().max >= ctx().used && ctx().parts?.length >= 2, ctx());
    if (!ctx().estimated) {
      const sum = ctx().parts.filter(p => p.kind !== 'buffer').reduce((n, p) => n + p.tokens, 0);
      check('上下文明细加起来等于已用量', Math.abs(sum - ctx().used) <= Math.max(50, ctx().used * .02), { sum, used: ctx().used });
    }
  }
  openModelPopover();
  const compactBtn = els.popover.querySelector('.ctx-compact');
  check('空闲时压缩按钮可用', !!compactBtn && !compactBtn.disabled);
  if (compactBtn) {
    // 补充后的历史可能已读完、尚未交给网页，此时用户又完成了压缩。
    holdHistory();
    const oldRead = nextRequestId();
    postNative('loadConversation', { agent: id, conversationId: cid, afterSteer: true, reqId: oldRead });
    await until(() => held.has(oldRead), '压缩前的历史已读完');
    const users = box.querySelectorAll('.msg.user').length, turns = box.querySelectorAll('.msg.bot.turn').length;
    compactBtn.click(); const run = await until(() => runsOf(id, viewKey(id))[0], '压缩开始');
    check('压缩按钮关闭菜单并发送压缩命令', pop === null && /^\/(compact|compress)$/.test(run.text));
    openModelPopover(); check('压缩进行中按钮禁用', els.popover.querySelector('.ctx-compact')?.disabled === true); closePopover();
    const r = await done(run.reqId);
    check('压缩结束收成提示并去掉临时问答', !!box.querySelector('.compact-note') && box.querySelectorAll('.msg.user').length === users && box.querySelectorAll('.msg.bot.turn').length === turns, r.reply);
    const compactNode = box.querySelector('.compact-note'), compactNote = compactNode?.textContent;
    await releaseHistory();
    const synced = await load(true);
    // 下面两条的前提是 CLI 的记录里有压缩前那一轮。agy 1.5.11 新建会话时偶尔建不起会话库（它自己的日志记
    // 「failed to create persistent trajectory … trajectory db schema init: database is locked」，多个窗口同时跑时常见），
    // 第一轮只留在那次进程的内存里，/compact 落在空会话上被当成普通提问作答，记录从「/compact」起头。
    // 这时页面按记录重画是对的，两条检查不判，记成跳过并带上读到的记录
    if (!(synced.messages || []).some(m => m.role === 'user' && m.text === first)) {
      skip('同步后压缩提示与问答保持不变', 'CLI 的记录里没有压缩前那一轮', (synced.messages || []).map(m => [m.role, (m.text || '').slice(0, 20)]));
    } else {
      check('压缩前读出的历史晚到仍保留同一个提示节点', !!compactNode?.isConnected);
      check('同步后压缩提示与问答数不变', box.querySelector('.compact-note')?.textContent === compactNote && box.querySelectorAll('.msg.user').length === users && box.querySelectorAll('.msg.bot.turn').length === turns);
    }
    await ask('只回复两个字：收到。'); check('压缩之后还能继续回答', !!lastTurn()?.querySelector('.answer')?.textContent.trim());
  }

} catch (e) { out.error = String(e.message || e); }
finally { restore(); }
return finish();
