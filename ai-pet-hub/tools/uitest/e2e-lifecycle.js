// 冷启动、大图、预热接手、立即停止、命令随停止结束；辅助探测超时与退出由 lifecycle.py 分阶段运行。
// 单一入口：tools/uitest/run.sh claude e2e-lifecycle.js haiku 560
const { out, check, note, skip, until, finish } = makeSuite('进程生命周期/' + LIFECYCLE_PHASE);
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const previousReply = window.onAgentResponse, previousFile = window.onFileRead;
const replies = new Map(), reads = new Map();
let fileSeq = 980000;
window.onAgentResponse = data => {
  replies.set(data.reqId, data);
  if (data.reqId < 910000 || data.reqId > 970000) previousReply?.(data);
};
window.onFileRead = data => {
  if (reads.has(data.reqId)) reads.get(data.reqId)(data);
  else previousFile?.(data);
};
const read = path => new Promise((resolve, reject) => {
  const reqId = ++fileSeq;
  const timer = setTimeout(() => { reads.delete(reqId); reject(Error('文件桥无响应：' + path)); }, WAIT);
  reads.set(reqId, data => { clearTimeout(timer); reads.delete(reqId); resolve(data); });
  postNative('readFile', { path, reqId });
});
const waitFile = async (path, predicate, limit = WAIT) => {
  const end = Date.now() + limit;
  let data;
  do {
    data = await read(path);
    if (predicate(data)) return data;
    await pause(100);
  } while (Date.now() < end);
  return data;
};
const request = (reqId, extra = {}) => ({ agent: AGENT, reqId, prompt: '简短问候一句。', model: MODEL,
  effort: 'low', permissionMode: FULL_PERM, workspace: REPO, conversationId: '', browserTools: false, ...extra });
const response = async (name, req) => {
  const at = Date.now();
  postNative('askAgent', req);
  await until(() => replies.has(req.reqId), name + '收到结束回调');
  const reply = replies.get(req.reqId);
  check(name + '正常结束并返回正文', !reply.cancelled && !!reply.reply?.trim() && !/^⚠️/.test(reply.reply.trim()), reply);
  note(name + '耗时', (Date.now() - at) / 1000);
  return reply;
};
try {
  if (LIFECYCLE_PHASE.startsWith('exit')) {
    postNative('loadUsage', { agent: 'claude', force: true });
    const data = await waitFile(LIFECYCLE_FIXTURE + '.pids', d => (d.content || '').trim().split(/\s+/).length >= 2);
    check('退出前辅助命令及孙进程确实启动', (data.content || '').trim().split(/\s+/).length >= 2, data.content);
    check('等待用量时原生主线程响应', (await trafficLights()) !== null);
    // 故意等着被 lifecycle.py 发 SIGTERM 打断，不是在等某件事发生：期限要短于这一段 40 秒的总上限，所以写明
    if (LIFECYCLE_PHASE === 'exit-signal') await until(() => false, 30000, '外部跟踪器发 SIGTERM');
  } else if (LIFECYCLE_PHASE === 'helper') {
    const req = request(940001, { agent: 'claude' });
    const pending = response('能力探测超时后真实提问', req);
    const marker = await waitFile(LIFECYCLE_FIXTURE + '.pid', d => !!d.content?.trim());
    check('挂起的能力探测确实启动', !!marker.content?.trim(), marker.content);
    check('能力探测挂起时主线程响应', (await trafficLights()) !== null);
    await pending;
    const state = await waitFile(DIR + '/command-state.json', d => { try { const s = JSON.parse(d.content); return s.started && s.remaining.length === 0; } catch { return false; } });
    let parsed; try { parsed = JSON.parse(state.content); } catch { parsed = {}; }
    check('超时的辅助命令及孙进程结束', parsed.started && parsed.remaining?.length === 0, parsed);
  } else {
    // 两次冷启动均绕过网页预热；不要求模型逐字回答某个词或颜色。
    await response('冷启动短回答', request(960001));
    const image = await read(PDF_FILE);
    check('大图片超过管道容量', image.size > 1024 * 1024, { path: PDF_FILE, size: image.size });
    await response('冷启动大图片', request(930001, { prompt: '这张图片主要是什么颜色？', images: [PDF_FILE] }));
    const warm = request(950001);
    const oldCommands = window.onAgentCommands, oldModels = window.onAgentModels;
    let initialized = false, warmState = null;
    window.onAgentCommands = data => { if (data.agent === AGENT) initialized = true; oldCommands?.(data); };
    window.onAgentModels = data => { if (data.agent === AGENT) initialized = true; oldModels?.(data); };
    window.onTestWarmState = data => { if (data.agent === AGENT) warmState = data; };
    const askWarmState = async () => {
      warmState = null;
      postNative('testWarmState', { agent: AGENT });
      await until(() => warmState, '预热状态回包');
      return warmState;
    };
    try {
      const before = (await askWarmState()).adopted;
      postNative('prewarmAgent', warm);
      // Claude 握手带回命令、Codex 握手后查模型，网页都有回调；agy 的 initialize 答复只有协议能力，App 收下后只把阶段记成 1。
      // 两种都是 App 确认握手完成的结果，任一到了就算预热好了。
      await until(async () => initialized || (await askWarmState()).stage >= 1, '预热进程完成握手').catch(() => null);
      check('预热进程完成握手', initialized || warmState?.stage >= 1, warmState);
      await response('预热后接手回答', warm);
      const after = (await askWarmState()).adopted;
      check('回答接手了预热的进程', after === before + 1, { before, after });
    } finally { window.onAgentCommands = oldCommands; window.onAgentModels = oldModels; delete window.onTestWarmState; }
    for (const all of [false, true]) {
      const ids = all ? [910001, 910002] : [910000];
      ids.forEach(reqId => postNative('askAgent', request(reqId)));
      postNative('cancelAgent', { agent: AGENT, ...(all ? {} : { reqId: ids[0] }) });
      await until(() => ids.every(id => replies.has(id)), all ? '全部立即停止回调' : '立即停止回调');
      ids.forEach(id => check((all ? '全部' : '单轮') + '立即停止返回cancelled/' + id, replies.get(id)?.cancelled === true, replies.get(id)));
    }
    setActive(AGENT); setWorkspace(AGENT, REPO, false);
    S[AGENT].model = MODEL; S[AGENT].effort = 'low'; S[AGENT].perm = FULL_PERM; renderComposer();
    const box = S[AGENT].msgEl;
    let exercised = false;
    const attempts = [];
    for (let attempt = 0; attempt < 2 && !exercised; attempt++) {
      els.input.value = '请用终端工具原样前台执行这一条命令，不要放后台：echo $$ > lifecycle-command.pid; sleep 120; echo unexpected > stop-marker.txt 。等它结束再回复。';
      send();
      await until(() => viewBusy(AGENT), '停止场景开始回答');
      const end = Date.now() + WAIT;
      let state = {};
      while (Date.now() < end) {
        const file = await read(DIR + '/command-state.json');
        try { state = JSON.parse(file.content); } catch { state = {}; }
        if (state.started && state.commandReady && state.remaining?.length) { exercised = true; break; }
        if (!isBusy(AGENT)) break;
        await pause(100);
      }
      if (exercised) {
        // CLI 先起命令进程、再发「命令开始」事件，网页再画出这一步：看到进程时步骤可能还差一瞬，等它出现（期限只防卡死）
        await until(() => box.querySelector('.msg.bot.turn.live .step-command'), '命令步骤出现').catch(() => null);
        check('真实命令在执行时出现命令步骤', !!box.querySelector('.msg.bot.turn.live .step-command'), state);
        const at = Date.now(); stop();
        await until(() => !isBusy(AGENT), '停止后结束回答');
        check('停止后显示已停止', [...box.querySelectorAll('.msg.sys')].some(e => e.textContent.includes('已停止')));
        check('停止后发送按钮恢复', !els.sendBtn.disabled);
        // 门槛不用统一上限：坏路径是停止只杀了 shell、sleep 120 成了孤儿自己跑完，等满 WAIT 会照样判过；取它的一半 60 秒
        const stopped = await waitFile(DIR + '/command-state.json', d => { try { return JSON.parse(d.content).remaining.length === 0; } catch { return false; } }, 60000);
        let result; try { result = JSON.parse(stopped.content); } catch { result = {}; }
        check('停止时命令及子进程一起结束', result.started && result.remaining?.length === 0, result);
        const marker = await read(REPO + '/stop-marker.txt');
        check('停止后没有执行命令尾部', !!marker.error, marker.content);
        note('停止耗时', (Date.now() - at) / 1000);
      } else {
        const text = [...box.querySelectorAll('.msg.bot.turn')].at(-1)?.querySelector('.answer')?.textContent || '';
        if (isBusy(AGENT)) { stop(); await until(() => !isBusy(AGENT), '清理超时轮次'); throw Error('等待上限内未确认命令运行且模型尚未返回，不能判作模型没照做'); }
        attempts.push(text);
        if (/^⚠️/.test(text.trim())) throw Error('CLI返回错误：' + text);
      }
    }
    if (!exercised) skip('停止时命令一起结束', '模型没照做：两次均未启动带PID标记的前台命令', attempts);
  }
} catch (error) { out.error = String(error?.message || error); }
finally {
  for (const reqId of [960001, 930001, 950001, 940001, 910000, 910001, 910002]) {
    if (!replies.has(reqId)) postNative('cancelAgent', { agent: AGENT, reqId });
  }
  if (isBusy(AGENT)) stop();
  window.onAgentResponse = previousReply; window.onFileRead = previousFile;
}
return finish();
