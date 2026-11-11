// 不用 CLI（REAL=1 跑）：动效和细节的那套规矩（web/css/craft.css）——顶栏下的渐隐、时间写法、引导页。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const out = { steps: [], ok: true, errors: [] };
window.addEventListener('error', e => out.errors.push(String(e.message) + ' @' + (e.filename || '').split('/').pop() + ':' + e.lineno));
const check = (name, pass, got) => { out.steps.push(`${pass ? '✓' : '✗'} ${name}：${JSON.stringify(got)}`); if (!pass) out.ok = false; };
try {
  window.onConversationsListed = () => {};
  postNative('testResize', { width: 1680, height: 940 }); await sleep(1200);
  setActive('claude', false);
  // 造一轮内容
  const P = '/Users/demo/Projects/todo-app';
  S.claude.workspace = P;
  renderMessages('claude', [
    { role: 'user', text: '给待办列表加上拖拽排序：拖动时显示一条占位线，松手后把新顺序存起来。' },
    { role: 'bot', duration: 74, text: '已完成，待办列表现在可以拖拽排序。'.repeat(14), steps: [{ kind: 'command', title: '运行测试', detail: 'npm test', output: 'ok', status: 'ok' }],
      files: [{ path: P + '/src/TodoList.js', kind: 'edit', added: 46, removed: 3 }] },
  ], P);
  await sleep(500);
  const box = S.claude.msgEl;
  const fade = getComputedStyle(document.getElementById('chat-stack'), '::before');
  check('内容在顶栏下面渐隐（盖一条渐变，不用遮罩）', /linear-gradient/.test(fade.backgroundImage) && getComputedStyle(box).webkitMaskImage === 'none', { fade: fade.backgroundImage.slice(0, 40), mask: getComputedStyle(box).webkitMaskImage });
  await realShot('craft-wide');
  // 时间：一周内相对，一周以前写日期
  const now = Date.now() / 1000;
  const old = new Date((now - 40 * 86400) * 1000);
  check('时间写法', relTime(now - 30) === '刚刚' && relTime(now - 3 * 86400) === '3天' && relTime(now - 40 * 86400) === `${old.getMonth() + 1}月${old.getDate()}日` || old.getFullYear() !== new Date().getFullYear(),
    [relTime(now - 30), relTime(now - 3 * 86400), relTime(now - 40 * 86400), relTime(now - 500 * 86400)]);
  // 引导页：能打开，卡片居中
  postNative('testResize', { width: 1480, height: 920 }); await sleep(900);
  openWelcome(); await sleep(1200);
  const card = document.querySelector('#welcome .wl-card').getBoundingClientRect();
  check('引导页打开，卡片居中、完全显示', !welcome.hidden && Math.abs((card.left + card.right) / 2 - innerWidth / 2) < 2 && Number(getComputedStyle(document.querySelector('#welcome .wl-card')).opacity) === 1, { w: Math.round(card.width) });
  await realShot('craft-welcome');
  welcome.hidden = true;
  check('没有脚本报错', out.errors.length === 0, out.errors);
} catch (e) { out.ok = false; out.error = String(e) + ' | ' + String(e && e.stack).slice(0, 300); }
return out;
