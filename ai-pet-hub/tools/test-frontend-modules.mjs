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
console.log(`${checks - failures}/${checks} 通过`);
process.exitCode = failures ? 1 : 0;
