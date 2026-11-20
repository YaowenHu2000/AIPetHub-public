// 离线测试 web/js/core/logic.js：界面里不碰页面元素的那部分逻辑（排队、同步、翻历史、/ 和 @、匀速显示…）。
// 用法：node tools/test-logic.mjs（tools/test.sh 会一起跑）。
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'web', 'js', 'core', 'logic.js'), 'utf8');
const L = vm.createContext({});
vm.runInContext(src + '\nglobalThis.api = { matchExtras, planHistoryRows, localAsksInHistory, pushPrompt, promptStep, slashQuery, mentionQuery, rankCommands, mergeCommands, revealStep, queueAction, queuedLabel, mergeModels, migrateModel, splitModels, fitSections };', L);
const { matchExtras, planHistoryRows, localAsksInHistory, pushPrompt, promptStep, slashQuery, mentionQuery, rankCommands, mergeCommands, revealStep, queueAction, queuedLabel, mergeModels, migrateModel, splitModels, fitSections } = L.api;

let failures = 0, checks = 0;
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
function eq(name, got, want) { checks++; if (!same(got, want)) { failures++; console.log(`  ✗ ${name}\n      应为 ${JSON.stringify(want)}\n      实际 ${JSON.stringify(got)}`); } }
const u = text => ({ role: 'user', text }), b = text => ({ role: 'bot', text });

console.log('· 会话重读后把这次运行里的改动接回去');
{
  const A = { text: '改一下' }, B = { text: '再改' }, C = { text: '改一下' };
  const msgs = [u('旧的'), b('…'), u('改一下'), b('好'), u('再改'), b('好'), u('改一下'), b('好')];
  eq('按前面那句提问配，同一句话问过两次各配各的', [...matchExtras([A, B, C], msgs)].map(([i, ex]) => [i, ex === A ? 'A' : ex === B ? 'B' : 'C']), [[7, 'C'], [5, 'B'], [3, 'A']]);
  eq('记录里找不到那句提问的就不配', matchExtras([{ text: '没有这句' }], msgs).size, 0);
  eq('提问后面还没有回答（正在答）的不配', matchExtras([{ text: '新问的' }], [u('新问的')]).size, 0);
  eq('提问前后的空白不影响', matchExtras([{ text: '改一下' }], [u('  改一下\n'), b('好')]).size, 1);
  const img = {role:'user',text:'',images:[{ref:{agent:'claude',id:'行#0'}}]};
  for (const [label,entry,user] of [
    ['最早的纯图卡只保存空提问',{text:'',at:0},img],
    ['旧纯图卡有原路径而历史只剩内嵌引用',{text:'请看这张图片。',images:['/旧图.png'],at:0},img],
    ['旧纯图卡和单次模式的路径文字',{text:'请看这张图片。',images:['/旧图.png'],at:0},u('请看这张图片。\n\n/旧图.png')],
    ['旧记录的警告前缀',{text:'问',replyKey:L.replyFingerprint('⚠️ 完成'),at:0},u('问')],
  ]) eq(label,[...matchExtras([entry],[user,b('完成')]).keys()],[1]);

}

// 从真实收尾入口写入缓存，再用持久化的副本认领历史；同一张卡只允许出现在期望的回答上。
console.log('· 四位助手的改动卡按原问与回答认领');
const changesSource = readFileSync(new URL('../web/js/chat/changes.js', import.meta.url), 'utf8');
for (const agent of ['claude','gpt','gemini','deepseek']) {
  let storage = '';
  const cid = '改动矩阵';
  const env = vm.createContext({window:{}, S:{[agent]:{conversationId:cid}},
    lsJson:(_,fallback)=>storage ? JSON.parse(storage) : fallback, lsSet:(_,v)=>{ storage = v; }});
  vm.runInContext(src + changesSource,env);
  const ask = u('继续'), done = b('完成'), pic = '/图.png', file = {path:'命令.txt',diff:'+一行'};
  const step = {kind:'user',detail:'补充'};
  const rows = [
    ['实时收尾，重开保留命令补丁',{}, {}, [ask,done], [1]],
    ['连续同文，只有首轮有卡',{}, {}, [ask,done,ask,done], [1]],
    ['压缩提示后的分页', {historyStart:4}, {}, [{role:'compact'},ask,done], [2],3],
    ['只发图', {text:'',prompt:'请看这张图片。',images:[pic]}, {}, [{...u(''),images:[{path:pic}]},done], [1]],
    ['单次模式实际发送的图片副本', {images:[pic],sentPaths:{[pic]:'/副本.png'}}, {}, [u('继续\n\n/副本.png'),done], [1]],
    ['编辑同文换图', {images:[pic],imageKeys:['首图']}, {}, [{...ask,images:[{path:pic,imageKey:'新图'}]},done], []],
    ['重试历史图片引用', {imageRefs:[{id:'old',agent}],restoredPaths:['/恢复.png']}, {},
      [{...ask,images:[{path:'/恢复.png'}]},done], [1]],
    ['旧分支原位同问异答',{}, {}, [ask,b('新答')], []],
    ['未同步就切走，另一实例原位同问同答',{}, {}, [{...ask,createdAt:12},done], []],
    ['只读到提问，下一问同答',{}, {}, [ask,u('另一问'),done], []],
    ['压缩失败后只留下带重试的回答', {text:'/compact',prompt:'/compact'}, {outcome:'failed'},
      [{...done,outcome:'failed',retryPrompt:'/compact'}], [0]],
    ['成功压缩只显示一条提示', {text:'/compact',prompt:'/compact'}, {}, [{role:'compact',text:'完成'}], []],
    ['压缩行不是回答',{}, {reply:''}, [ask,{role:'compact'}], []],
    ['停止与重试同答',{}, {cancelled:true}, [ask,{...done,outcome:'completed'}], []],
    ['崩溃补记同请求后来写全',{}, {outcome:'failed'}, [ask,{...b('完整回答'),outcome:'failed',endingReqId:42}], [1]],
    ['外部写了不同请求的同文失败',{}, {outcome:'failed'}, [ask,{...done,outcome:'failed',endingReqId:99}], []],
    ['同轮补充再接独立同文后问',{}, {steps:[step]}, [ask,{...done,steps:[step]},u('补充'),done], [1]],
    ['重新挂接活动请求，原位置未知且两问两答完全相同', {historyStart:null}, {}, [ask,done,ask,done], []],
    ['切回时历史仅有更早的同问同答', {}, {}, [{...ask,createdAt:7},done], []],
    ['协议已给原问编号，同毫秒发生同问同答', {}, {turnKey:'原问'}, [{...ask,turnKey:'新问'},done], []],
    ['已知位置被编辑，前面同文同答不能认领',{historyStart:2},{},[ask,done,u('改问'),done],[]],
    ['页首同文但缺编号，原问编号已移到后面',{}, {turnKey:'原问'},[ask,done,{...ask,turnKey:'原问'},done],[3]],
    ['原位置无编号，同文末轮有本次失败补记',{}, {outcome:'failed'},
      [ask,{...done,outcome:'failed'},ask,{...done,outcome:'failed',endingReqId:42}],[3]],
    ['命令仅有工具步骤，外部改写成有正文的回答', {}, {reply:''}, [ask,done], []],
    ['分支变化后较早的原问仍在窗口内', {historyStart:4}, {turnKey:'原问'}, [{...ask,turnKey:'原问'},done], [1]],
    ['读取期间发送的新问还在页尾之外', {historyStart:4}, {}, [ask,done], []],
    ['只有提问留在分页外',{}, {}, [ask,done], [],2],
  ];
  if (agent === 'gemini' || agent === 'deepseek') {
    const split = agent === 'gemini' ? [u('补充'),done] : [{...done,steps:[step]}];
    rows.push(['首段未写回答就消费补充',{}, {steps:[step]}, [ask,u('补充'),done], [2]]);
    rows.push(['连续同文补充分段',{}, {steps:[step,step]}, [ask,{...b('前段'),steps:[step]},...split], [1+split.length]]);
    rows.push(['补充拆段',{}, {steps:[step]}, [ask,b('前段'),...split], [1+split.length]]);
    const second = {kind:'user',detail:'再补一句'};
    rows.push(['实时首段与恢复的末段分别留有补充',{live:{steps:[step]}}, {steps:[second]},
      [ask,b('前段'),u(step.detail),b('中段'),u(second.detail),done], [5]]);
    rows.push(['断线回读收尾只有工具，仍认已经消费的补充',{live:{steps:[step]}}, {steps:[{kind:'command'}]}, [ask,b('前段'),...split], [1+split.length]]);
    rows.push(['收尾缺步骤时从实时步骤恢复补充',{live:{steps:[step]}}, {}, [ask,b('前段'),...split], [1+split.length]]);
  }
  for (const [name,fields,data,messages,want,omitted=0] of rows) {
    vm.runInContext('turnExtras.clear()',env);
    storage = '';
    const run = {agent,text:'继续',prompt:'继续',reqId:42,since:9000,endedAt:11000,historyStart:0,...fields};
    const response = {reqId:42,conversationId:cid,reply:'完成',files:[file],...data};
    const live = env.rememberTurn(agent,run,response,'/工作');
    const stored = env.readTurnExtras().get(agent+':'+cid);
    eq(agent+' '+name,[live.files[0].diff,...env.matchExtras(stored,messages,omitted).keys()],['+一行',...want]);
  }
  const longText = '问'.repeat(510000);
  env.rememberTurn(agent,{text:longText,prompt:longText,historyStart:0},{conversationId:cid,files:[file]},'');
  eq(agent+' 长提问在原有缓存预算内仍可恢复补丁',env.readTurnExtras().get(agent+':'+cid)?.at(-1)?.text.length, longText.length);

}

console.log('· 切回窗口时的同步');
{
  const msgs = [u('a'), b('1'), u('b'), b('2')];
  const changes = rows => planHistoryRows(rows.map(m=>({role:m.role, sig:L.messageSignature(m)})),msgs).map(change=>change.kind);
  eq('一模一样：不动', changes(msgs), []);
  eq('记录里多了两条（在终端里接着聊过）：接在后面', changes(msgs.slice(0,2)), ['append','append']);
  eq('页面比记录多：删除记录中已消失的尾部', changes([...msgs,u('旧尾')]), ['remove']);
  eq('角色顺序对不上：从变化处重画', changes([msgs[0],msgs[1],b('拆段')]), ['remove','append','append']);
  eq('页面是空的：重画', changes([]), Array(4).fill('append'));
}

console.log('· 打开历史前就发出的几轮是否已写进记录');
{
  const ask = text => ({ text, prompt: text, images: [] });
  const old = [u('旧问'), b('旧答')];
  eq('记录里还没有本页的提问：一句都不算', localAsksInHistory([ask('新问')], old), []);
  eq('答完的一轮已写在末尾：认出它的位置', localAsksInHistory([ask('新问')], [...old, u('新问'), b('新答')]), [2]);
  eq('两轮都写进去：依次认出', localAsksInHistory([ask('一'), ask('二')], [...old, u('一'), b('1'), u('二')]), [2, 4]);
  eq('只写进了第一轮：只认第一句', localAsksInHistory([ask('一'), ask('二')], [...old, u('一'), b('1')]), [2]);
  eq('同一句话以前问过、这次还没写进去：后面还有别的提问，不认旧的那句', localAsksInHistory([ask('旧问')], [u('旧问'), b('旧答'), u('别的'), b('…')]), []);
  eq('本页没有发过：空', localAsksInHistory([], [...old, u('新问')]), []);
  // 记录末尾本来就是同一句短话：读取在发问之前开始的回包不可能含这一轮，不能把旧的那句认成本页发的
  const at = since => ({ ...ask('继续'), since });
  const cont = [u('开始'), b('旧答一'), u('继续'), b('旧答二')];
  eq('读取早于发问：同句的旧提问不算', localAsksInHistory([at(2000)], cont, 1000), []);
  eq('读取晚于发问、记录末尾是这句：认出它', localAsksInHistory([at(1000)], [...cont, u('继续')], 2000), [4]);
  eq('读取在第一轮之后、第二轮之前：只认第一轮', localAsksInHistory([at(1000), { ...ask('二'), since: 3000 }], [...cont, u('继续'), b('新答')], 2000), [4]);
}

console.log('· ↑ / ↓ 翻发过的话');
{
  eq('重复的挪到最后', pushPrompt(['a', 'b', 'c'], 'a'), ['b', 'c', 'a']);
  eq('最多留 50 句', pushPrompt(Array.from({ length: 50 }, (_, i) => 'p' + i), 'new').length, 50);
  const list = ['一', '二', '三'];
  eq('空输入框按 ↑：最近的一句', promptStep(list, -1, '', -1), { at: 2, value: '三' });
  eq('接着按 ↑：更早的', promptStep(list, 2, '三', -1), { at: 1, value: '二' });
  eq('到头了再按 ↑：停在最早的', promptStep(list, 0, '一', -1), { at: 0, value: '一' });
  eq('按 ↓：往后', promptStep(list, 1, '二', 1), { at: 2, value: '三' });
  eq('最后一句再按 ↓：清空', promptStep(list, 2, '三', 1), { at: -1, value: '' });
  eq('自己打了字：不管（光标正常上下移）', promptStep(list, -1, '我在打字', -1), null);
  eq('翻出来以后改了内容：不再翻', promptStep(list, 2, '三改了', -1), null);
  eq('没在翻的时候按 ↓：不管', promptStep(list, -1, '', 1), null);
  eq('一句都没发过：不管', promptStep([], -1, '', -1), null);
}

console.log('· / 命令和 @ 文件');
{
  eq('刚打了 /', slashQuery('/'), '');
  eq('/comp', slashQuery('/comp'), 'comp');
  eq('带冒号、横线的命令名', slashQuery('/plugin:do-it'), 'plugin:do-it');
  eq('打了空格以后不再是在选命令', slashQuery('/compact 现在'), null);
  eq('不在开头的 / 不算', slashQuery('看 /tmp'), null);
  eq('路径不算命令', slashQuery('/Users/me/a.txt'), null);
  eq('@ 在开头', mentionQuery('@ke'), { q: 'ke', start: 0 });
  eq('@ 在一句话中间', mentionQuery('看一下 @src/ma'), { q: 'src/ma', start: 4 });
  eq('刚打了 @', mentionQuery('看 @'), { q: '', start: 2 });
  eq('邮箱里的 @ 不算', mentionQuery('发给 a@b.com'), null);
  eq('@ 后面已经打了空格：结束了', mentionQuery('看 @a.txt 然后'), null);
  const all = [{ name: 'compact' }, { name: 'autocompact' }, { name: 'clear' }, { name: 'code-review' }];
  eq('名字以它开头的在前，其次名字里有的', rankCommands(all, 'comp').map(c => c.name), ['compact', 'autocompact']);
  eq('不分大小写', rankCommands(all, 'CL').map(c => c.name), ['clear']);
  eq('空的：全部（最多 12 个）', rankCommands(Array.from({ length: 30 }, (_, i) => ({ name: 'c' + i })), '').length, 12);
  eq('新列表没带说明的沿用旧的', mergeCommands([{ name: 'compact', desc: '压缩' }, { name: 'gone', desc: 'x' }], [{ name: 'compact', desc: '' }, { name: 'new', desc: '新的' }]),
    [{ name: 'compact', desc: '压缩' }, { name: 'new', desc: '新的' }]);
}

console.log('· 匀速显示');
{
  eq('没有落后：不放', revealStep(0, 16), 0);
  eq('落后一点：每帧至少 1 个字', revealStep(3, 16), 1);
  eq('落后很多：放得快', revealStep(900, 16), 32);
  eq('两帧之间隔了很久（窗口被挡住）：按 0.3 秒算，不会一下全放完', revealStep(90, 5000), 60);
  let left = 16, frames = 0;   // 一撮 16 个字，每帧 16 毫秒
  while (left > 0) { left -= revealStep(left, 16); frames++; }
  eq('一撮 16 个字分十几帧放完（不是一下蹦出来）', frames >= 10 && frames <= 20, true);
}

console.log('· 一轮结束时排着的话怎么办');
{
  const base = { cancelled: false, failed: false, here: true, busy: false, jump: false };
  eq('正常答完：接着发', queueAction(base), 'send');
  eq('被停止的：放回输入框', queueAction({ ...base, cancelled: true }), 'restore');
  eq('出错的：放回输入框', queueAction({ ...base, failed: true }), 'restore');
  eq('点「立即发送」插队才停的：接着发', queueAction({ ...base, cancelled: true, jump: true }), 'send');
  eq('已经切到别的会话：放回输入框', queueAction({ ...base, here: false, jump: true }), 'restore');
  eq('那个会话又在回答：放回输入框', queueAction({ ...base, busy: true }), 'restore');
  eq('气泡：排着', queuedLabel('waiting', false, false), '排着，这一轮结束后自动发');
  eq('气泡：已送达但命令没跑完', queuedLabel('sent', true, false), '已经送到；它手头的命令跑完才会看到');
  eq('气泡：正在插队', queuedLabel('sent', true, true), '正在停下手头的事，马上发…');
}

console.log('· 模型菜单跟着 CLI 走');
{
  const builtin = [{ v: 'claude-opus-5-5', name: 'Claude Opus 5.5 [1M]', keep: true }, { v: 'claude-fable-5-1[1m]', name: 'Claude Fable' }, { v: 'haiku', name: 'Claude Haiku', tip: '最快' }];
  const fresh = [{ v: 'fable', name: 'Fable 5.2', desc: '最强', efforts: ['low', 'high', 'weird'] }, { v: 'haiku', name: 'Haiku 5.5', desc: '' }, { v: 'opus', name: 'Opus 5.5' }];
  const list = mergeModels(builtin, fresh, ['low', 'medium', 'high']);
  eq('以 CLI 的为准，标了 keep 的留在最前', list.map(m => m.v), ['claude-opus-5-5', 'fable', 'haiku', 'opus']);
  eq('CLI 里有的新模型出现了（Fable 5.2）', list[1], { v: 'fable', name: 'Fable 5.2', tip: '最强', efforts: ['low', 'high'] });
  eq('名字用 CLI 的，说明沿用写死的', list[2], { v: 'haiku', name: 'Haiku 5.5', tip: '最快' });
  eq('有 fast 档的模型带上标记和说明', mergeModels([], [{ v: 'a', name: 'A', fast: true, fastDesc: '2x speed' }, { v: 'b', name: 'B' }], []), [{ v: 'a', name: 'A', fast: true, fastDesc: '2x speed' }, { v: 'b', name: 'B' }]);
  {
    const ms = [{ v: 'default', name: '默认（Opus 5.5）' }, { v: 'opus', name: 'Opus 5.5' }, { v: 'claude-fable-5-2', name: 'Fable 5.2' }, { v: 'sonnet', name: 'Sonnet 5.5' }, { v: 'fable', name: 'Fable 5.1' }, { v: 'claude-opus-5', name: 'Opus 5' }];
    const parts = splitModels(ms);
    eq('常用：每个系列排最前面的那个', parts.main.map(m => m.v), ['opus', 'claude-fable-5-2', 'sonnet']);
    eq('更多：「默认」和同系列的旧版本', parts.more.map(m => m.v), ['default', 'fable', 'claude-opus-5']);
    eq('版本号在中间的也按系列分', splitModels([{ v: 'a', name: 'Gemini 4 Argon' }, { v: 'b', name: 'Gemini 3.8 Flash' }, { v: 'c', name: 'Gemini 3 Argon' }]).more.map(m => m.v), ['c']);
  }
  eq('写死的旧条目不在 CLI 列表里：去掉', list.some(m => m.v === 'claude-fable-5-1[1m]'), false);
  eq('坏数据（没有 v、重复的）不进菜单', mergeModels([], [{ v: 'a', name: 'A' }, { name: '没有 v' }, null, { v: 'a', name: '重复' }, { v: '', name: '空' }], []).map(m => m.name), ['A']);
  const aliases = { 'claude-fable-5-1[1m]': 'fable' };
  eq('选着的还在：不变', migrateModel('haiku', list, aliases, 'opus'), 'haiku');
  eq('选着旧的 Fable 条目：换成 CLI 的 fable', migrateModel('claude-fable-5-1[1m]', list, aliases, 'opus'), 'fable');
  eq('选着的没了、也没有对应的：用默认的', migrateModel('gone', list, aliases, 'opus'), 'opus');
  eq('默认的也不在：用第一个', migrateModel('gone', list, aliases, 'nope'), 'claude-opus-5-5');
}

console.log('· 左栏三格按内容分高度');
{
  eq('都放不下：按比例分', fitSections([900, 900, 900], [1, 1, 1], 600), [200, 200, 200]);
  eq('最下面一格用不完：省下的给上面两格', fitSections([900, 900, 100], [1, 1, 1], 600), [250, 250, 100]);
  eq('两格用不完：都让给剩下那一格', fitSections([50, 900, 100], [1, 1, 1], 600), [50, 450, 100]);
  eq('让出来以后又有一格够了：接着让', fitSections([230, 900, 100], [1, 1, 1], 600), [230, 270, 100]);
  eq('都放得下：各自要多少给多少', fitSections([100, 150, 50], [1, 1, 1], 600), [100, 150, 50]);
  eq('比例不一样时按比例分剩下的', fitSections([900, 900, 100], [3, 1, 1], 600), [375, 125, 100]);
}

console.log(failures ? `${failures} / ${checks} 项没通过` : `全部通过（${checks} 项）`);
process.exit(failures ? 1 : 0);
