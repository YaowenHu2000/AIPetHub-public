// 真实窗口才测得出来的东西（REAL=1）：红绿灯和顶栏对没对齐、顶栏上的东西真的点不点得动、整个窗口长什么样。
// 不用 CLI。脚本里的 element.click() 是直接调网页的，绕过了窗口那一层；这里的 realClick 是真的鼠标事件，
// 标题栏或者别的原生视图要是挡住了网页上的按钮，这里会点不动。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const out = { steps: [] };
const note = (k, v) => { out.steps.push(k + ' = ' + JSON.stringify(v)); };
const mid = el => { const r = el.getBoundingClientRect(); return Math.round((r.top + r.height / 2) * 10) / 10; };
try {
  setActive('claude'); await sleep(2000);
  const chrome = await trafficLights();
  note('红绿灯', chrome && chrome.lights.map(l => ({ 左: l.left, 右: l.right, 中心离顶: l.centerY, 不见了: !!l.hidden })));
  note('顶栏里各样东西的中心离顶', { 搜索框: mid(document.querySelector('.search-field')), 收起按钮: mid(document.getElementById('btn-hide-sidebar')), 头像: mid(els.badge), 顶栏高: document.getElementById('chat-header').offsetHeight });
  note('搜索框左边 / 红绿灯最右', [Math.round(document.querySelector('.search-field').getBoundingClientRect().left), chrome && chrome.lights.length ? chrome.lights[chrome.lights.length - 1].right : null]);
  await realShot('window');
  // 改一下窗口大小再量：系统重排标题栏以后红绿灯还得在原位
  postNative('testResize', { width: innerWidth + 90, height: innerHeight - 60 }); await sleep(700);
  const after = await trafficLights();
  note('改了窗口大小以后的红绿灯', after && after.lights.map(l => ({ 左: l.left, 中心离顶: l.centerY, 不见了: !!l.hidden })));
  await realShot('window-resized');

  // 真的点：搜索框（聚焦）、内置浏览器按钮（预览面板打开）、收起左栏、展开左栏、模型按钮（面板打开）
  await realClick(document.getElementById('hist-search'));
  note('点搜索框：聚焦了', document.activeElement === document.getElementById('hist-search'));
  document.getElementById('hist-search').blur();
  await realClick(document.getElementById('btn-browser')); await sleep(400);
  note('点内置浏览器按钮：预览面板开了', !document.getElementById('preview-pane').hidden);
  await realClick(document.getElementById('btn-browser')); await sleep(300);
  await realClick(document.getElementById('btn-hide-sidebar')); await sleep(300);
  note('点收起按钮：左栏收起了', document.body.classList.contains('sidebar-hidden'));
  await realShot('window-sidebar-hidden');
  await realClick(document.getElementById('btn-show-sidebar')); await sleep(300);
  note('点展开按钮：左栏回来了', !document.body.classList.contains('sidebar-hidden'));
  // 打开一个有内容的会话，再开面板：看毛玻璃后面的字是不是模糊着透上来（而不是清清楚楚地透上来）
  const row = [...histSections.claude.list.querySelectorAll('.conv-row:not(.pending)')][1]; if (row) row.click();
  await sleep(2500);
  await realClick(els.chipModel); await sleep(900);
  note('点模型按钮：面板开了', !els.popover.hidden);
  await realShot('window-panel');
  closePopover();
} catch (e) { out.error = String(e && e.message || e); }
return out;
