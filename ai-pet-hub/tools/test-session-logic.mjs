// 会话同步的纯逻辑与页面重载请求编号，离线运行：node tools/test-session-logic.mjs
// --baseline 只检验旧编号分配器的跨页碰撞（用 git show 读取 HEAD，不改工作区）。
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import vm from 'node:vm';

const baseline = process.argv.includes('--baseline');
const source = file => baseline
  ? execFileSync('git', ['show', 'HEAD:ai-pet-hub/web/js/' + file], { encoding: 'utf8' })
  : readFileSync(new URL('../web/js/' + file, import.meta.url), 'utf8');
let failed = 0, checked = 0;
function test(name, f) {
  checked++;
  try { f(); console.log('  ✓ ' + name); }
  catch (error) { failed++; console.log('  ✗ ' + name + ': ' + error.message); }
}
const state = source('core/state.js');
const allocation = state.slice(state.indexOf('let reqCounter ='), state.indexOf('const pets ='));
const saved = new Map();
function page(now) {
  const ctx = vm.createContext({
    Date: { now: () => now }, lsGet: (k, d) => saved.get(k) ?? d, lsSet: (k, v) => saved.set(k, v),
  });
  vm.runInContext(allocation + '\nglobalThis.allocate = () => typeof nextRequestId === "function" ? nextRequestId() : ++reqCounter;', ctx);
  return ctx.allocate;
}
const now = 1794910000000, first = page(now);
const oldIds = Array.from({ length: 4096 }, first);
const last = oldIds.at(-1), reloaded = page(now), newId = reloaded();
test('N10 同一毫秒重载，旧响应不会命中新请求', () => assert.ok(newId > last && !oldIds.includes(newId)));
test('N10 时钟回拨仍不复用请求号', () => assert.ok(page(now - 10000)() > newId));
test('N10 编号保持 JavaScript/原生桥可无损表示的整数', () => assert.ok(Number.isSafeInteger(newId)));

if (!baseline) {
  test('桌面只读提示复用输入框上方的提示，退出桌面后收起', () => {
    const hint = {}, cid = 'desktop:both';
    const ui = vm.createContext({ window: {}, active: 'gemini', S: { gemini: { conversationId: cid } },
      viewBusy: () => false, lsJson: () => ({}), setInterval() {},
      document: { createElement: () => hint, getElementById: () => ({ insertBefore() {} }) } });
    vm.runInContext(source('chat/fork.js'), ui);
    const data = { agent: 'gemini', conversationId: cid, live: true };
    ui.window.onSessionLive({ ...data, status: 'readOnly' });
    assert.equal(hint.hidden, false);
    assert.match(hint.textContent, /桌面版.*只读/);
    ui.window.onSessionLive({ ...data, status: 'idle' });
    assert.match(hint.textContent, /关闭那边的会话/);
    ui.window.onSessionLive({ ...data, live: false });
    assert.equal(hint.hidden, true);
  });
  for (const batch of [false, true]) test((batch ? '批量' : '单条') + '删除拦截显示原生提供的原因', () => {
    let message;
    const ui = vm.createContext({ window: {}, active: 'gemini', S: { gemini: {} }, renderHeader() {}, renderHistory() {},
      forgetWorkspace() {}, pets: { gemini: { say: text => { message = text; } } } });
    vm.runInContext(source('native-callbacks.js') + source('ui/project-delete.js'), ui);
    const reason = '⚠️ 桌面版可能把会话写回。';
    if (batch) {
      vm.runInContext("projectDelete = { id: 'gemini', deleting: true }", ui);
      ui.window.onConversationsDeleted({ agent: 'gemini', failed: ['desktop:both'], reason });
    } else ui.window.onConversationDeleted({ agent: 'gemini', ok: false, reason });
    assert.equal(message, reason);
  });
  const ctx = vm.createContext({});
  vm.runInContext(source('core/logic.js') + '\nglobalThis.api = { messageSignature, liveHistoryCut };', ctx);
  const { messageSignature, liveHistoryCut } = ctx.api;
  const user = (text, images) => ({ role: 'user', text, images }), bot = text => ({ role: 'bot', text });
  test('F02 等长正文不同', () => assert.notEqual(messageSignature(bot('aaa')), messageSignature(bot('bbb'))));
  // 原生发来的同一条消息，字段先后每次都可能不同：指纹不能跟着变（变了就会一直被当成「别处还在写」）
  test('字段先后不同、内容相同：指纹相同', () => assert.equal(
    messageSignature({ role: 'bot', text: 'a', steps: [{ kind: 'command', title: '运行命令', detail: 'ls', status: 'ok' }], files: [{ path: '/a', kind: 'edit' }] }),
    messageSignature({ files: [{ kind: 'edit', path: '/a' }], steps: [{ status: 'ok', detail: 'ls', title: '运行命令', kind: 'command' }], text: 'a', role: 'bot' })));
  test('F02 步骤状态/输出不同', () => assert.notEqual(
    messageSignature({ ...bot('answer'), steps: [{ status: 'running', output: 'aaa' }] }),
    messageSignature({ ...bot('answer'), steps: [{ status: 'ok', output: 'bbb' }] }),
  ));
  test('长思考保持运行，状态变化但正文相同也立刻撤标；崩溃与旧格式有期限', () => {
    let clock = now;
    function classes(...names) {
      const values = new Set(names);
      return { contains: name => values.has(name), add: name => values.add(name), remove: name => values.delete(name) };
    }
    const label = { textContent: '工作过程' };
    const step = { classList: classes('step-error'), querySelector: () => ({textContent:'未完成'}) };
    const work = { classList: classes(), dataset: {}, querySelector: s => s === '.work-label' ? label : step,
      querySelectorAll: () => step.classList.contains('pending-elsewhere') ? [step] : [] };
    const bot = { querySelector: () => work };
    const st = { conversationId: 'test', loadedId: 'test', msgEl: { lastElementChild: bot,
      querySelectorAll: s => s.startsWith('.msg.bot') ? [bot] : (work.classList.contains('elsewhere') ? [work] : []) } };
    // active 设成别的位：桌宠跟随（setElsewherePet）只管选中的那位，它的行为由窗口测试 e2e-ui.js 覆盖
    const ui = vm.createContext({ Date: { now: () => clock }, setInterval: () => {}, viewBusy: () => false, active: 'claude',
      durationText: secs => String(secs),
      S:{gpt:st}, window:{}, messageSignature: m=>m, noteListedStamp:()=>{}, renderMessages:()=>{}, askSessionLive:()=>{}, jumpToSearchHit:()=>{},
      runsOf:()=>[], viewKey:()=>'', isCompactCommand:()=>false, syncAppend:()=>true, nearBottom:()=>true,
    });
    vm.runInContext(source('chat/elsewhere.js') + source('native-callbacks.js') + '\nglobalThis.on = elsewhereOn;', ui);
    const read = (running, at = now / 1000) => {
      st.historyReads = new Map([[1, 'sync']]);
      ui.window.onConversationLoaded({agent:'gpt',conversationId:'test',reqId:1,messages:[],lastTurn:{running,updatedAt:at}});
    };
    read(true); clock += 354000;
    assert.equal(ui.on('gpt'), true);
    read(true);
    assert.match(label.textContent, /在别处运行中/);
    assert.equal(step.classList.contains('pending-elsewhere'), true);
    read(false); assert.equal(ui.on('gpt'), false);
    assert.equal(label.textContent, '工作过程');
    assert.equal(step.classList.contains('pending-elsewhere'), false);
    read(true, now / 1000 - 86400); assert.equal(ui.on('gpt'), false);
    st.elsewhereAt = clock;
    read(undefined);
    assert.equal(ui.on('gpt'), true);
    clock += 180001;
    assert.equal(ui.on('gpt'), false);
  });
  test('桌面版无项目会话和同目录普通项目分组不同，续聊目录仍在', () => {
    const cwd = '/fixture/Documents/Codex/2026-11-17/example';   // 不用 /tmp：临时文件夹里的会话会归进「任务会话」
    const items = [{ id: 'desktop', cwd }, { id: 'project', cwd }];
    const history = source('ui/history.js');
    const groups = vm.runInNewContext(history.slice(history.indexOf('const TASK_GROUP'), history.indexOf('function isCollapsed')) + '\nbuildGroups("gpt",items,true)',
      { S: { gpt: { projectlessIds: new Set(['desktop']) } }, items, wsKey: path => path });
    assert.equal(groups.find(g => g.key === '').list[0].cwd, cwd);
    assert.equal(groups.find(g => g.key === cwd).list[0].id, 'project');
  });
  const run = { historyStart: 2, text: 'repeat', prompt: 'repeat', images: [] };
  test('F10 本轮未入历史，不向前找同句', () => assert.equal(liveHistoryCut(run, [user('repeat'), bot('old')]), -1));
  test('F10 起始位置不确定时不猜', () => assert.equal(liveHistoryCut({ ...run, historyStart: null }, [user('repeat')]), -1));
  test('F10 改变分页窗口，位置随 omitted 换算', () => assert.equal(liveHistoryCut({ ...run, historyStart: 302 }, [user('older'), bot('older'), user('repeat')], 300), 2));
  const imgRun = { historyStart: 0, text: '', prompt: '请看这张图片。', images: ['/tmp/a.png'] };
  test('F10 纯图真实 prompt + path 匹配', () => assert.equal(liveHistoryCut(imgRun, [user(imgRun.prompt, [{ path: '/tmp/a.png' }])]), 0));
  test('F10 历史纯图正文为空时按图片匹配', () => assert.equal(liveHistoryCut(imgRun, [user('', [{ ref: { id: '/tmp/a.png' } }])]), 0));
  test('F10 同文但图片不同，不接', () => assert.equal(liveHistoryCut(imgRun, [user(imgRun.prompt, [{ path: '/tmp/b.png' }])]), -1));
  test('F10 图片身份缺失，不接', () => assert.equal(liveHistoryCut(imgRun, [user(imgRun.prompt, [{ src: 'thumbnail' }])]), -1));
  test('F10 多了其他图片也不接', () => assert.equal(liveHistoryCut(imgRun, [user(imgRun.prompt, [{ path: '/tmp/a.png' }, { path: '/tmp/b.png' }])]), -1));
}
console.log(`${checked - failed}/${checked} 项通过`);
process.exitCode = failed ? 1 : 0;
