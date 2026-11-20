// 内置浏览器：工具开关、真实 MCP 打开/执行/截图、面板与历史提示过滤。
const { out, check, note, skip, until, finish } = makeSuite('browser');
const id = AGENT, events = [], requests = [];
const previousStep = window.onAgentStep, previousResponse = window.onAgentResponse, previousPost = window.postNative;
let response;
window.onAgentStep = data => { if (data.agent === id) events.push(data); previousStep(data); };
window.onAgentResponse = data => { if (data.agent === id) response = data; previousResponse(data); };
window.postNative = (action, payload) => { if (action === 'askAgent') requests.push(payload); previousPost(action, payload); };
try {
  setActive(id); setWorkspace(id, REPO, false);
  S[id].model = MODEL; S[id].effort = 'low'; S[id].perm = FULL_PERM; renderComposer();
  const box = S[id].msgEl;
  const ask = async text => {
    events.length = 0; response = null;
    els.input.value = text; send();
    await until(() => response || viewBusy(id), '开始回答');
    await until(() => response && !isBusy(id), '回答结束');
    check('CLI 回合完成且无错误', !response.error && !response.cancelled && !/^⚠️/.test(response.reply || ''), response);
    const turn = [...box.querySelectorAll('.msg.bot.turn')].at(-1);
    check('回答显示在会话里', !!turn?.querySelector('.answer')?.textContent.trim());
    return turn;
  };
  lsSet('browser_tools', 'off');
  await ask('请调用 browser_open 打开 ' + PAGE + '，不要改用别的办法；没有工具就直接说明。');
  check('关闭开关后请求不带浏览器工具', requests.at(-1)?.browserTools === false, requests.at(-1)?.browserTools);
  check('关闭时没有浏览器工具步骤', !events.some(e => /browser_(open|eval|screenshot)/.test(e.step?.title || '')), events.map(e => e.step?.title));
  check('关闭时没有打开浏览器标签', !pane.tabs.some(t => t.kind === 'browser'));
  note('关闭时的实际回答', response.reply);
  lsSet('browser_tools', 'on');
  let exercised = false;
  for (let attempt = 0; attempt < 2; attempt++) {
    const turn = await ask('请用内置浏览器工具：browser_open 打开 ' + PAGE + '，browser_eval 执行 document.querySelector("#b").click(); document.querySelector("#b").click(); return document.querySelector("#n").textContent; 然后 browser_screenshot 截图。最后说明页面状态。');
    check('重新开启后请求带浏览器工具', requests.at(-1)?.browserTools === true, requests.at(-1)?.browserTools);
    const titles = events.map(e => e.step?.title || '');
    note('开启时实际工具与回答（尝试 ' + (attempt + 1) + '）', { titles, reply: response.reply });
    // 模型必须先实际发出工具调用；发出后卡片/面板/地址错误均属于 App 失败。
    const called = name => events.some(e => (e.step?.title || '').includes(name));
    if (called('browser_open')) {
      check('browser_open 的工具步骤显示', [...turn.querySelectorAll('.step')].some(s => s.textContent.includes('browser_open')));
      await until(() => pane.tabs.some(t => t.kind === 'browser') && !pane.el.hidden, '浏览器面板打开');
      check('浏览器地址指向测试页', decodeURI(browser.file || browser.url || '').endsWith('/page.html'), browser.file || browser.url);
    }
    for (const name of ['browser_eval', 'browser_screenshot']) {
      if (called(name)) check(name + ' 的工具步骤显示', [...turn.querySelectorAll('.step')].some(s => s.textContent.includes(name)));
    }
    const toolErrors = events.filter(e => /browser_/.test(e.step?.title || '') && e.step?.status === 'error');
    // eval 的语法/未定义变量错误来自模型写的脚本；导航、截图、桥接错误仍失败。
    const modelErrors = toolErrors.filter(e => /browser_eval/.test(e.step?.title || '') && /脚本出错/.test(e.step?.output || '') && /SyntaxError|Unexpected|Can't find variable|is not defined/.test(e.step?.output || ''));
    if (modelErrors.length) note('模型执行脚本错误', modelErrors);
    const appErrors = toolErrors.filter(e => !modelErrors.includes(e));
    check('已调用的浏览器工具没有 App 错误', appErrors.length === 0, appErrors);
    if (!modelErrors.length && ['browser_open', 'browser_eval', 'browser_screenshot'].every(called)) { exercised = true; break; }
  }
  if (!exercised) skip('打开、点击与截图完整链路', '模型没照做', { reply: response.reply, steps: events.map(e => e.step) });
  let loaded = false;
  const previous = window.onConversationLoaded;
  window.onConversationLoaded = data => { previous(data); if (data.agent === id && data.conversationId === S[id].conversationId) loaded = true; };
  try {
    S[id].loadedSig = ''; postNative('loadConversation', { agent: id, conversationId: S[id].conversationId });
    await until(() => loaded, '浏览器会话历史读回');
    check('历史用户消息不泄漏 App 自动提示', ![...box.querySelectorAll('.msg.user')].some(e => e.textContent.includes('AIPetHub 提示')));
  } finally { window.onConversationLoaded = previous; }
} catch (error) { out.error = String(error); }
finally { window.onAgentStep = previousStep; window.onAgentResponse = previousResponse; window.postNative = previousPost; }
return finish();
