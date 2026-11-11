// 离线测试 web/js/core/logic.js：界面里不碰页面元素的那部分逻辑（排队、同步、翻历史、/ 和 @、匀速显示…）。
// 用法：node tools/test-logic.mjs（tools/test.sh 会一起跑）。
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'web', 'js', 'core', 'logic.js'), 'utf8');
const L = vm.createContext({});
vm.runInContext(src + '\nglobalThis.api = { matchExtras, syncPlan, pushPrompt, promptStep, slashQuery, mentionQuery, rankCommands, mergeCommands, revealStep, queueAction, queuedLabel, mergeModels, migrateModel, splitModels, fitSections };', L);
const { matchExtras, syncPlan, pushPrompt, promptStep, slashQuery, mentionQuery, rankCommands, mergeCommands, revealStep, queueAction, queuedLabel, mergeModels, migrateModel, splitModels, fitSections } = L.api;

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
}

console.log('· 切回窗口时的同步');
{
  const msgs = [u('a'), b('1'), u('b'), b('2')];
  eq('一模一样：不动', syncPlan([true, false, true, false], msgs), 0);
  eq('记录里多了两条（在终端里接着聊过）：接在后面', syncPlan([true, false], msgs), 2);
  eq('页面比记录多：重画', syncPlan([true, false, true, false, true], msgs), -1);
  eq('角色顺序对不上（中途补充过的回答在记录里是拆开的）：重画', syncPlan([true, false, false], msgs), -1);
  eq('页面是空的：重画', syncPlan([], msgs), -1);
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
