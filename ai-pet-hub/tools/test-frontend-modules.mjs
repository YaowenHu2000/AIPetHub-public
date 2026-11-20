// 离线回归：diff、Markdown、忙碌逐帧循环。node tools/test-frontend-modules.mjs
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
const src = p => readFileSync(new URL('../web/js/' + p, import.meta.url), 'utf8');
let checks = 0, failures = 0;
function eq(name, got, want) {
  checks++;
  if (JSON.stringify(got) !== JSON.stringify(want)) { failures++; console.log(`✗ ${name}: ${JSON.stringify(got)}，应为 ${JSON.stringify(want)}`); }
}
const ctx = vm.createContext({ window: {}, escapeHtml: s => String(s).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;'), looksLikeFile: () => true, fileChip: (p, label) => `<file path="${p}">${label}</file>` });
vm.runInContext(src('preview/diff.js') + '\n' + src('core/markdown.js'), ctx);
const run = s => vm.runInContext(s, ctx);
ctx.diff = '--- a/a\n+++ b/a\n@@ -1 +1 @@\n---old\n+++new\n';
eq('F07 hunk 内的 --- 和 +++ 是正文', run('parseHunks(diff)[0].lines'), [{t:'-',s:'--old'}, {t:'+',s:'++new'}]);
ctx.diff = '@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n';
eq('F08 无末尾换行也能定位', run('annotateFile("new", diff).unplaced.length'), 0);
eq('F08 切分末尾不产生空上下文', run('parseHunks(diff)[0].lines.length'), 2);
ctx.diff = '--- a/a\n+++ b/a\n@@ -0,0 +1,2 @@\n+one\n+\n--- a/b\n+++ b/b\n@@ -1,2 +0,0 @@\n-old\n-\n';
eq('hunk 行数结束后识别下一文件头、保留真正的空正文', run('parseHunks(diff).map(h => h.lines)'), [[{t:'+',s:'one'},{t:'+',s:''}],[{t:'-',s:'old'},{t:'-',s:''}]]);
eq('无 hunk 头的旧格式仍可用', run('parseHunks("-old\\n+new")[0].lines.length'), 2);
eq('CLI 裸 @@ 分段仍可逐段定位', run('parseHunks("@@\\n---old\\n+++new\\n@@\\n-second\\n+next").map(h => h.lines)'), [[{t:'-',s:'--old'},{t:'+',s:'++new'}],[{t:'-',s:'second'},{t:'+',s:'next'}]]);
eq('F09 角括号文件路径去掉括号、保留空格', run('mdInline("[报告](</tmp/my report.md>)", {chips:true})'), '<file path="/tmp/my report.md">报告</file>');
eq('F09 角括号网址支持空格与标题', run('mdInline(\'[官网](<https://example.com/my page> "标题")\')').includes('data-url="https://example.com/my page"'), true);
for (const cell of ['`a|b`', '``a`|b``', '$P(A|B)$', '$$P(A|B)$$', '\\(P(A|B)\\)', '\\[x_{A|B}\\]']) {
  ctx.row = `| ${cell} | conditional |`;
  eq('F20 表格保护 ' + cell, run('splitRow(row)'), [cell, 'conditional']);
}
eq('表格转义竖线', run('splitRow("| a\\\\|b | c |")'), ['a\\|b', 'c']);
// 使用真实 Pet 方法，注入时钟和帧素材；无需 GPU、图像解码或等定时器。
let now = 0, tick, shown = [];
const petCtx = vm.createContext({ document: { hidden: true }, Date: { now: () => now }, PHASE_META: {thinking:{frameMs:100}}, FAST_FORM_SPEED:2, FAST_SET:{}, loadFrameSet:()=>true, setInterval: fn => {tick = fn; return 1;}, clearInterval:()=>{}, setTimeout:()=>{} });
vm.runInContext(src('stage/pet.js') + '\nglobalThis.proto = Pet.prototype;', petCtx);
const pet = Object.assign(Object.create(petCtx.proto), {state:'thinking', busyFrame:0, usesRig:()=>false, loopSets:()=>[{name:'test',keys:()=>['a','b','c','d']}], card:{offsetWidth:100,classList:{toggle:()=>{}}}, showFrame:key=>shown.push(key)});
pet.startBusyLoop('thinking');
now = 100; tick();
eq('F17 页面 hidden 时不绘制', shown.length, 0);
eq('F17 页面 hidden 时不推进帧', pet.busyFrame, 0);
petCtx.document.hidden = false; pet.card.offsetWidth = 0; now = 200; tick();
eq('F17 舞台不可见时不绘制', shown.length, 0);
pet.card.offsetWidth = 100; now = 650; tick();
eq('F17 恢复时按经过时间接到相应帧', shown.at(-1), 'c');
const requests = [], redraws = [];
const menu = vm.createContext({ window: {}, Spring: class {}, lsJson: () => ({}), lsSet: () => {},
  els: { chipModel: {} }, active: 'gpt', AGENTS: { gpt: { models: [] }, gemini: { models: [] } },
  S: { gpt: {}, gemini: {} }, BUILTIN_MODELS: {}, EFFORTS: {}, MODEL_ALIASES: {},
  mergeModels: (_, list) => list, migrateModel: (_, list) => list[0].v, effortOf: () => 'low',
  postNative: (name, data) => requests.push([name, data.agent]), redraws,
});
vm.runInContext(['ui/menus.js', 'ui/model-menu.js', 'ui/usage-panel.js'].map(src).join('\n') + `
  openPopover = anchor => { pop = pop ? null : { anchor }; };
  renderComposer = () => {};
  renderPopover = () => redraws.push(modelView);
  positionPopover = hideSubmenu = () => {};
  els.popover = { style: {}, getBoundingClientRect: () => ({}) };
  agentUsage.gpt = agentUsage.gemini = { items: [] };
  openModelPopover(); modelView = 'list';
  window.onAgentModels({agent:'gpt', models:[{v:'future'}]});
  openModelPopover(); openModelPopover(); openModelPopover();
  active = 'gemini'; window.onAgentModels({agent:'gemini', models:[{v:'fresh'}]}); openModelPopover();
`, menu);
eq('首次打开用缓存立即展示并查 CLI，重复打开或已预热时不再查询', requests, [['loadUsage', 'gpt']]);
eq('模型返回时当前打开的列表即时刷新', redraws, ['list']);
vm.runInContext(`
  openModelPopover();
  active = 'claude';
  AGENTS.claude = {models:[]}; S.claude = {}; agentUsage.claude = {items:[]};
  window.onAgentModels({agent:'claude', models:[{v:'partial'}], complete:false});
  openModelPopover(); openModelPopover(); openModelPopover();
`, menu);
eq('会话只报部分模型时补查完整列表，等待答复时反复打开只查一次', requests.at(-1), ['loadUsage', 'claude']);
eq('三位的查询各自去重', requests.length, 2);
const sendContext = (used, at, history, parts = []) => menu.window.onAgentContext({ agent: 'claude', conversationId: 'current', used, max: 100, at, history, estimated: history, parts });
const savedContext = () => vm.runInContext("agentContext['claude:current']", menu);
sendContext(12, 200, false, [{id:'skills', tokens:5}]);
sendContext(11, 200, true);
eq('同一轮的记录不覆盖实时总数', savedContext().used, 12);
sendContext(20, 300, true);
eq('更新的历史总数不沿用旧一轮的明细', [savedContext().used, savedContext().parts], [20, []]);
sendContext(3, 100, true);
eq('晚到的旧记录不能覆盖更新的记录', savedContext().used, 20);
sendContext(50, 400, true, [{id:'cached_input', tokens:20}]);
sendContext(40, 350, false);
eq('较早的实时回包也不能回滚已更新的历史', savedContext().used, 50);
sendContext(60, 450, false);
eq('实时回包缺少明细时不能借用旧的历史估算', savedContext().parts, []);
vm.runInContext("agentContext['claude:current'] = {used:9, max:100, parts:[{id:'skills',tokens:5}]}", menu);
sendContext(20, 300, true);
eq('无时间戳的旧版实时缓存保留已有数字', savedContext().used, 9);
sendContext(30, 400, true);
eq('下一轮外部更新可替换旧版缓存', savedContext().used, 30);
// 同一份草稿的前后台只差显示位置。重开时只给模块磁盘里的值，不能借到上页的附件数组。
const storage = new Map();
const draftUI = vm.createContext({ S:{}, active:'', ALL_AGENT_IDS:[], clearTimeout, setTimeout,
  lsSet:(key,value)=>storage.set(key,value), lsJson:(key,fallback)=>JSON.parse(storage.get(key) || 'null') ?? fallback,
  closeSuggest() {}, viewKey:id=>draftUI.S[id].conversationId, runsOf:()=>[] });
vm.runInContext(src('ui/drafts.js'),draftUI);
for (const id of ['claude','gpt','gemini','deepseek']) {
  const files = Array.from({length:9},(_,i)=>'/'+i+'.zip');
  const origin = {view:'甲',workspace:''}, st = draftUI.S[id] = {
    conversationId:'乙',draft:'乙稿',attach:[],runs:new Map(),returnedDrafts:{owner:'',parked:{}}};
  const merge = (paths,mode) => draftUI.mergeDraft(draftUI.draftTarget(id,origin),[{paths,pasted:paths.slice(-1)}],mode);
  eq(id+' 后台新增只接收前八个',merge(files,'add'),files.slice(0,8));
  eq(id+' 手动撤回放不下整条保留',merge(files.slice(-1),'withdraw'),null);
  eq(id+' 已接收的队列自动退回不截断',merge(files.slice(-1),'return'),files.slice(-1));
  eq(id+' 退回不改正在看的草稿',st.draft,'乙稿');
  st.returnedDrafts = draftUI.lsJson(id+'_returnedDrafts',null);
  st.conversationId = '甲'; draftUI.syncReturnedDraft(id);
  draftUI.loadAttachments(id);
  eq(id+' 重载后旧附件仍排在草稿前并保留清理标记',
    [st.attach.map(a=>a.path),st.attach.filter(a=>a.pasted).map(a=>a.path)],[[files[8],...files.slice(0,8)],[files[8]]]);
}
// 两个窗口共用同一份存储，各自内存里的记录是打开时读的。另一窗口取消选文件或认领草稿，都不能抹掉这里刚退回的那份。
function twoWindows(id) {
  const shared = new Map(), windows = [];
  for (const name of ['甲','乙']) {
    let seq = 0;
    const win = vm.createContext({ S:{}, active:id, ALL_AGENT_IDS:[id], clearTimeout, setTimeout, pets:{}, els:{input:{value:''}},
      lsSet:(key,value)=>value ? shared.set(key,value) : shared.delete(key), lsJson:(key,fallback)=>JSON.parse(shared.get(key) || 'null') ?? fallback,
      closeSuggest() {}, renderAttachments() {}, autosize() {}, viewKey:k=>win.S[k].conversationId, runsOf:()=>[], nextRequestId:()=>++seq });
    win.S[id] = {conversationId:name+'会话',workspace:'/ws',draft:'',attach:[],runs:new Map(),returnedDrafts:{owner:'',parked:{}}};
    vm.runInContext(src('ui/drafts.js'),win);
    windows.push(win);
  }
  return [...windows, () => JSON.parse(shared.get(id+'_returnedDrafts') || '{}').parked || {}];
}
const open = (win, id, view) => { win.S[id].conversationId = view; win.syncReturnedDraft(id); };
const shownDraft = (win, id) => [win.S[id].draft,win.S[id].attach.map(x=>x.path)];
for (const id of ['claude','gpt','gemini','deepseek']) {
  const [a,b,stored] = twoWindows(id);
  a.mergeDraft(a.draftTarget(id,{view:'protected',workspace:'/ws'}),[{text:'未发送的修改要求',paths:['/ws/brief.pdf']}]);
  const cancel = b.beginAttachment(id,{file:true,picker:true});
  b.finishPaste(cancel,{paths:[]});
  eq(id+' 另一窗口取消选文件不碰已退回的草稿',stored()['session:protected']?.paths,['/ws/brief.pdf']);
  b.claimDraft(id);
  b.mergeDraft(b.draftTarget(id,{view:'另一会话',workspace:'/ws'}),[{text:'乙窗口退回',paths:[]}]);
  eq(id+' 另一窗口写记录时只改自己那一项',Object.keys(stored()).sort(),['session:protected','session:另一会话']);
  b.S[id].conversationId = 'protected'; b.syncReturnedDraft(id);
  eq(id+' 另一窗口切到该会话时取到最新退回的草稿',[b.S[id].draft,b.S[id].attach.map(x=>x.path)],['未发送的修改要求',['/ws/brief.pdf']]);
}
// 离开普通输入时暂存的文字只属于这个窗口：两个窗口各自进过有退回草稿的会话，回来都还是自己写的那份。
for (const id of ['claude','gpt','gemini','deepseek']) {
  const [a,b] = twoWindows(id);
  for (const view of ['退回甲','退回乙']) a.mergeDraft(a.draftTarget(id,{view,workspace:'/ws'}),[{text:view+'的原问',paths:[]}]);
  a.setDraft(id,'甲普通'); open(a,id,'退回甲');
  b.setDraft(id,'乙普通'); open(b,id,'退回乙');
  open(a,id,'new:甲'); open(b,id,'new:乙');
  eq(id+' 两个窗口暂存的普通草稿互不覆盖',[a.S[id].draft,b.S[id].draft],['甲普通','乙普通']);
  open(a,id,'退回甲'); open(b,id,'退回乙');
  eq(id+' 两个窗口回到各自的会话仍是那份退回草稿',[a.S[id].draft,b.S[id].draft],['退回甲的原问','退回乙的原问']);
}
// 退回按条目内容合并：另一窗口刚退回到某会话的文字和附件，本窗口离开该会话或同时写同一会话都不能整项盖掉，顺序和同一窗口先后收到时一样。
for (const id of ['claude','gpt','gemini','deepseek']) {
  const [a,b,stored] = twoWindows(id), view = 'P', origin = {view,workspace:'/ws'};
  open(a,id,view); a.setDraft(id,'甲在P里写的'); a.S[id].attach = [{path:'/ws/甲.png'}]; a.claimDraft(id);
  b.mergeDraft(b.draftTarget(id,origin),[{text:'乙在P的提问失败退回',paths:['/ws/brief.pdf']}]);
  open(a,id,'R');
  const both = ['乙在P的提问失败退回\n\n甲在P里写的',['/ws/brief.pdf','/ws/甲.png']];
  eq(id+' 占着会话的窗口离开时留下另一窗口刚退回的那份',[stored()['session:P']?.text,stored()['session:P']?.paths],both);
  open(a,id,view);
  eq(id+' 回到该会话时两份都在',shownDraft(a,id),both);
  open(a,id,'R'); open(b,id,'R');
  const stale = a.draftTarget(id,origin);
  b.mergeDraft(b.draftTarget(id,origin),[{text:'乙后退回',paths:['/ws/乙.zip']}]);
  a.mergeDraft(stale,[{text:'甲后退回',paths:['/ws/甲.zip']}]);
  eq(id+' 两个窗口同时退回到同一会话都保留',[stored()['session:P']?.text,stored()['session:P']?.paths],
    ['乙后退回\n\n甲后退回\n\n'+both[0],['/ws/乙.zip','/ws/甲.zip',...both[1]]]);
  open(b,id,view);
  eq(id+' 另一窗口进该会话取到合并后的整份',shownDraft(b,id)[1],['/ws/乙.zip','/ws/甲.zip',...both[1]]);
}
// 冷启动：Codex 的 / 候选沿用上次存下的技能，不能被启动时只有 compact 的默认值盖掉。
for (const [stored, want] of [[[{name:'compact',desc:'压缩'},{name:'fixture',desc:'夹具'}], ['compact','fixture']], [[], ['compact']]]) {
  const stub = () => new Proxy(function () {}, { get: () => stub(), apply: () => stub() });
  const page = vm.createContext({ window: {}, ALL_AGENT_IDS: ['claude','gpt','gemini','deepseek'], lsJson: key => key === 'gpt_commands' ? stored : [],
    lsGet: () => '', els: stub(), document: stub(), UI: {}, renderComposer: () => {}, active: 'gpt' });
  vm.runInContext(src('ui/composer.js') + '\nglobalThis.names = agentCommands.gpt.map(c => c.name);', page);
  eq('Codex 冷启动的 / 候选：' + want.join('、'), page.names, want);
}
// Codex 切项目：/ 候选取当前项目自己的技能（项目级技能只在自己的目录里认，点了别的项目的会按普通文字发出）；
// 没查过的项目只列压缩，等预热查到再补；重开 App 后各项目的候选还在。
{
  const stub = () => new Proxy(function () {}, { get: () => stub(), apply: () => stub() });
  const store = {}, compact = {name:'compact',desc:'压缩'};
  const open = () => {
    const page = vm.createContext({ window: {}, ALL_AGENT_IDS: ['claude','gpt','gemini','deepseek'], AGENTS: {gpt:{}},
      lsJson: (key, d) => key in store ? JSON.parse(store[key]) : d, lsSet: (key, v) => { store[key] = v; }, lsGet: () => '',
      els: {...stub(), input: {value:'', addEventListener() {}}}, document: stub(), UI: {}, renderComposer: () => {}, active: 'gpt',
      S: {gpt: {workspace: ''}}, clearTimeout });
    vm.runInContext(src('core/logic.js') + '\n' + src('ui/composer.js') +
      '\nglobalThis.slashNames = ws => { S.gpt.workspace = ws; els.input.value = "/skill"; let got = null; showSuggest = (kind, items) => { got = items.map(c => c.name); }; updateSuggest(); return got; };', page);
    return page;
  };
  const a = open();
  a.window.onAgentCommands({agent:'gpt', workspace:'/B', commands:[compact,{name:'skill-b',desc:'B'}]});
  a.window.onAgentCommands({agent:'gpt', workspace:'/A', commands:[compact,{name:'skill-a',desc:'A'}]});
  eq('Codex 切回 B 后 / 候选只列 B 的技能', a.slashNames('/B'), ['skill-b']);
  eq('Codex 在 A 里 / 候选列 A 的技能', a.slashNames('/A'), ['skill-a']);
  eq('Codex 没查过的项目不列别的项目的技能', a.slashNames('/C'), []);
  eq('Codex 重开后各项目的 / 候选还在', open().slashNames('/B'), ['skill-b']);
}
console.log(`${checks - failures}/${checks} 通过`);
process.exitCode = failures ? 1 : 0;
