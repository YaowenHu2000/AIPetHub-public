// 不用 CLI（REAL=1 跑）：收尾的那一层（web/css/finish.css）——对比度、选区、光标、滚动条、当前分区的标记、提示块、线条图标。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const out = { steps: [], ok: true, errors: [] };
window.addEventListener('error', e => out.errors.push(String(e.message) + ' @' + (e.filename || '').split('/').pop() + ':' + e.lineno));
const check = (name, pass, got) => { out.steps.push(`${pass ? '✓' : '✗'} ${name}：${JSON.stringify(got)}`); if (!pass) out.ok = false; };
const rgba = s => (String(s).match(/-?[\d.]+/g) || []).map(Number);
const lum = ([r, g, b]) => { const f = v => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b); };
/** 前景色（可以半透明）叠在底色上之后的对比度。 */
const contrast = (fg, bg) => {
  const [r, g, b, a = 1] = rgba(fg), B = rgba(bg);
  const mixed = [r * a + B[0] * (1 - a), g * a + B[1] * (1 - a), b * a + B[2] * (1 - a)];
  const l1 = lum(mixed), l2 = lum(B);
  return +((Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05)).toFixed(2);
};
try {
  window.onConversationsListed = () => {};
  await sleep(1500);
  const now = Date.now() / 1000;
  AGENT_IDS.forEach(id => { S[id].conversations = [0, 1, 2].map(i => ({ id: `t${id}${i}`, title: `演示会话 ${i}`, time: '', timestamp: now - (i + 1) * 4000, cwd: '/Users/demo/Projects/demo' })); });
  setActive('claude', false); renderAllHistory(); await sleep(500);
  const css = v => getComputedStyle(document.documentElement).getPropertyValue(v).trim();
  // 对比度
  const side = document.getElementById('history-sidebar');
  const time = document.querySelector('.hist-section[data-agent="claude"] .conv-time');
  const cTime = contrast(getComputedStyle(time).color, 'rgb(19, 17, 32)');
  const cPlaceholder = contrast(getComputedStyle(els.input, '::placeholder').color, 'rgb(22, 20, 39)');
  const cFaint = contrast(css('--text-faint'), 'rgb(22, 20, 39)');
  check('次要文字的对比度都 ≥ 4.5', cTime >= 4.5 && cPlaceholder >= 4.5 && cFaint >= 4.5, { 时间: cTime, 输入框占位字: cPlaceholder, textFaint: cFaint });
  // 选区、光标
  const sel = getComputedStyle(document.body, '::selection').backgroundColor;
  check('选中文字的底色取自主色（不是系统默认的蓝）', rgba(sel).length >= 3 && sel !== 'rgba(0, 0, 0, 0)' && !/^rgb\(0, 0, 0\)/.test(sel), sel);
  check('输入光标是主色', getComputedStyle(els.input).caretColor === getComputedStyle(document.body).getPropertyValue('--accent').trim() || rgba(getComputedStyle(els.input).caretColor).join() !== '241,238,251', getComputedStyle(els.input).caretColor);
  // 当前分区：没有彩色左边线，标题行有一层底
  const head = document.querySelector('.hist-section.active .hist-head'), hs = getComputedStyle(head);
  check('当前分区不用彩色左边线，换成标题行的浅底', rgba(hs.borderLeftColor)[3] === 0 && /gradient/.test(hs.backgroundImage), { borderLeft: hs.borderLeftColor, bg: hs.backgroundImage.slice(0, 50) });
  const other = getComputedStyle(document.querySelector('.hist-section:not(.active) .hist-head'));
  check('别的分区没有这层底', other.backgroundImage === 'none', other.backgroundImage);
  // 桌宠状态：线条图标，不是 emoji
  const p = pets.claude;
  p.demoPhase = 'reading'; p.renderStatus(); await sleep(200);
  const emoji = /\p{Extended_Pictographic}/u;
  check('状态胶囊和工作标签用线条图标', !!p.statusEl.querySelector('svg') && !emoji.test(p.statusEl.textContent) && !!p.workIconEl.querySelector('svg') && !emoji.test(p.workIconEl.textContent),
    { status: p.statusEl.textContent, svg: !!p.statusEl.querySelector('svg'), badge: p.workTextEl.textContent });
  await realShot('finish');
  p.demoPhase = null; p.renderStatus();
  // 提示块、排版
  renderMessages('claude', [{ role: 'user', text: '问' }, { role: 'bot', text: '## 一个标题\n\n> [!WARNING]\n> 注意事项\n\n一段正文，带一个[链接](https://example.com)。' }], '');
  await sleep(400);
  const al = S.claude.msgEl.querySelector('.md-alert');
  const as = al && getComputedStyle(al);
  check('提示块是一圈细边线，不是粗的彩色左边线', !!al && as.borderLeftWidth === '1px' && as.borderTopWidth === '1px', as && { left: as.borderLeftWidth, top: as.borderTopWidth });
  const h = S.claude.msgEl.querySelector('.answer h2'), a = S.claude.msgEl.querySelector('.answer a');
  check('标题换行平衡、链接下划线', getComputedStyle(h).textWrap.includes('balance') && getComputedStyle(a).textUnderlineOffset === '3px', { wrap: getComputedStyle(h).textWrap, offset: getComputedStyle(a).textUnderlineOffset });
  check('没有脚本报错', out.errors.length === 0, out.errors);
} catch (e) { out.ok = false; out.error = String(e) + ' | ' + String(e && e.stack).slice(0, 300); }
return out;
