// 离线测试 web/js/core/markdown.js：回答里的 Markdown 转成 HTML 的结果（转义、链接、代码块、表格、列表、公式）。
// 用法：node tools/test-markdown.mjs（tools/test.sh 会一起跑）。不需要浏览器：markdown.js 用到的别的文件里的几个函数从源码里取出来。
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const web = join(dirname(fileURLToPath(import.meta.url)), '..', 'web', 'js');
// markdown.js 用到的几个函数分散在这几个文件里，拼起来再按名字取
const app = ['chat/messages.js', 'chat/turn.js', 'chat/live-steps.js', 'ui/menus.js'].map(f => readFileSync(join(web, f), 'utf8')).join('\n');

/** 从界面脚本里取出一段顶层定义：从 start 那一行到第一个只有 end 的行尾。 */
function take(start, end) {
  const i = app.indexOf('\n' + start);
  if (i < 0) throw new Error(`没找到：${start}`);
  const j = app.indexOf(end, i);
  if (j < 0) throw new Error(`没找到 ${start} 的结尾`);
  return app.slice(i + 1, j + end.length);
}

const ctx = vm.createContext({ window: {}, console });
vm.runInContext([
  take('function escapeHtml(', '\n}'),
  take('const FILE_EXTS = ', ".split(' '));"),
  take('function looksLikeFile(', '\n}'),
  take('const baseName = ', ';'),
  take('function fileChip(', '\n}'),
  "const UI = { file: '', copy: '', check: '' };",
  readFileSync(join(web, 'core', 'markdown.js'), 'utf8'),
  'globalThis.render = (s, o) => renderMarkdown(s, o);',
  'globalThis.streamSplit = streamSplit;',
].join('\n'), ctx);
const render = (s, o = { chips: true }) => ctx.render(s, o);

let failures = 0, checks = 0;
function check(name, ok, got) {
  checks++;
  if (!ok) { failures++; console.log(`  ✗ ${name}\n      实际：${got}`); }
}
const has = (name, src, want, opts) => { const h = render(src, opts); check(name, h.includes(want), h); };
const lacks = (name, src, bad, opts) => { const h = render(src, opts); check(name, !bad.test(h), h); };

console.log('· 转义：回答里的 HTML 只当文字显示');
lacks('script 标签', '<script>alert(1)</script>', /<script/i);
lacks('img onerror', '<img src=x onerror=alert(1)>', /<img/i);
lacks('标题里的标签', '# <b onclick=x>标题</b>', /<b /i);
lacks('表格里的标签', '| a |\n|---|\n| <svg onload=x> |', /<svg/i);
lacks('列表里的标签', '- <iframe src=x>', /<iframe/i);
lacks('引用里的标签', '> <style>*{}</style>', /<style/i);
has('代码块里的标签原样显示', '```html\n<script>x</script>\n```', '&lt;script&gt;');
has('行内代码里的标签原样显示', '`<b>`', '&lt;b&gt;');
has('<br> 可以换行', '一<br>二', '<br/>');

console.log('· 链接和图片');
has('网址链接', '[官网](https://example.com/a?b=1)', 'data-url="https://example.com/a?b=1"');
lacks('javascript: 不是链接', '[点我](javascript:alert(1))', /javascript:/i);
lacks('链接里的引号不能跑出属性', '[x](https://a.com/"onmouseover="alert(1))', /"onmouseover=/i);
lacks('图片地址里的引号不能跑出属性', '![x](https://a.com/"onerror="alert(1))', /"onerror=/i, { remoteImages: true });
lacks('聊天里不自动加载网络图片', '![图](https://a.com/x.png)', /<img/i);
has('文件预览里显示网络图片', '![图](https://a.com/x.png)', '<img class="md-img" src="https://a.com/x.png"', { remoteImages: true });
has('本地图片交给原生读', '![图](./a.png)', 'data-local="./a.png"');
has('行内代码里的文件路径变成文件标签', '看 `src/main.swift:12`', 'class="file-chip"');
lacks('不像文件的行内代码不变标签', '用 `let x = 1`', /file-chip/);

console.log('· 结构');
has('标题', '## 小节', '<h2');
has('粗体', '这是**重点**', '<strong>重点</strong>');
has('表格', '| 名字 | 值 |\n|---|---|\n| a | 1 |', '<table');
has('无序列表', '- 一\n- 二', '<ul');
has('有序列表', '1. 一\n2. 二', '<ol');
has('嵌套列表', '- 一\n  - 一点一', '<ul');
has('代码块', '```swift\nlet x = 1\n```', '<pre class="md-code">');
has('提示块', '> [!TIP]\n> 小提示', '提示');
has('没有 KaTeX 时公式原样显示', '质能方程 $E=mc^2$', 'E=mc^2');
check('「$5 和 $10」不当公式', !/math/.test(render('花了 $5 和 $10')), render('花了 $5 和 $10'));
check('空内容不报错', render('') === '' || typeof render('') === 'string', render(''));
check('没写完的代码块不报错（回答还在生成）', typeof render('```js\nconst a =') === 'string', '');

console.log('· 流式显示：分段渲染和整段渲染结果一样');
// 模拟回答一点点变长：每次只渲染新定下来的段落和最后还在变的一截（和 chat/stream.js 的 renderStreamingAnswer 同一个办法），
// 每一步拼出来的 HTML 都必须和把当时的全文整段渲染完全相同。
const STREAM_DOCS = {
  '段落和标题': '# 标题\n\n第一段，有**粗体**和 `code`。\n第二行。\n\n## 小节\n\n第二段。\n\n---\n\n结尾。',
  '代码块里有空行': '先看代码：\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\n然后是说明。\n\n~~~\n```\n\n不是结尾\n~~~\n\n完。',
  '列表隔着空行': '步骤：\n\n1. 第一步\n\n2. 第二步\n\n   第二步的补充\n\n3. 第三步\n\n- 甲\n  - 甲一\n\n- 乙\n\n之后的段落。',
  '表格和引用': '| 名字 | 值 |\n|---|---|\n| a | 1 |\n\n> 引用一\n\n> 引用二\n\n> [!TIP]\n> 提示\n\n| 又一张 |\n|---|\n| x |\n\n完。',
  '公式': '行内 $a^2$ 和 \\(b\\)。\n\n$$\nE = mc^2\n\n+ 1\n$$\n\n\\[\nx = \\frac{1}{2}\n\\]\n\n$$ 一行的 $$\n\n花了 $5 和 $10。\n\n完。',
  '没闭合的东西': '开头。\n\n```js\nconst a = 1;\n\n还没写完',
  '缩进和 HTML': '段落。\n\n    缩进的一行\n\n<div>标签</div>\n\n![图](./a.png) 和 [链接](https://a.com)\n\n完。',
};
for (const [name, doc] of Object.entries(STREAM_DOCS)) {
  let src = '', stable = '', bad = null, splits = 0;
  for (let n = 1; n <= doc.length && !bad; n++) {
    const text = doc.slice(0, n).trimEnd();   // 原生层推过来的文字去掉了结尾的空白
    if (!text) continue;
    const split = ctx.streamSplit(text);
    if (!(split >= src.length && text.startsWith(src))) { src = ''; stable = ''; }
    if (split > src.length) { stable += render(text.slice(src.length, split)); splits++; }
    src = text.slice(0, split);
    const got = stable + render(text.slice(split));
    if (got !== render(text)) bad = `写到第 ${n} 个字（切在 ${split}）：\n      分段：${got}\n      整段：${render(text)}`;
  }
  check(name, !bad, bad);
  if (name === '段落和标题') check('  （确实分了段，不是每次整段渲染）', splits >= 4, `只切了 ${splits} 次`);
}
check('代码块里的空行不切', ctx.streamSplit('```\na\n\nb') === 0, ctx.streamSplit('```\na\n\nb'));
check('列表项之间不切', ctx.streamSplit('- 一\n\n- 二') === 0, ctx.streamSplit('- 一\n\n- 二'));
check('段落之间切在下一段开头', ctx.streamSplit('一\n\n二') === 3, ctx.streamSplit('一\n\n二'));

console.log(failures ? `${failures} / ${checks} 项没通过` : `全部通过（${checks} 项）`);
process.exit(failures ? 1 : 0);
