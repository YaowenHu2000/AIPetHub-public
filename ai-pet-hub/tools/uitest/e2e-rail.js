// 不用 CLI：聊天区右边缘的圆点条——我说过的每一句一个点，现在看到的那一句是亮的，点一下跳过去，鼠标停上去显示那句话的开头。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const out = { steps: [], ok: true, errors: [] };
window.addEventListener('error', e => out.errors.push(String(e.message) + ' @' + (e.filename || '').split('/').pop() + ':' + e.lineno));
const check = (name, pass, got) => { out.steps.push(`${pass ? '✓' : '✗'} ${name}：${JSON.stringify(got)}`); if (!pass) out.ok = false; };
try {
  await sleep(1500);
  setActive('claude', false);
  const box = S.claude.msgEl, rail = document.querySelector('.jump-rail'), tip = document.querySelector('.jump-tip');
  const dots = () => [...rail.querySelectorAll('.jump-dot')], onAt = () => dots().findIndex(d => d.classList.contains('on'));
  appendMessage('claude', 'user', '只有一句的时候');
  appendMessage('claude', 'bot', '回答。');
  await sleep(400);
  check('只有一句、一屏放得下：不出现', rail.hidden, { hidden: rail.hidden });
  for (let i = 2; i <= 30; i++) {
    appendMessage('claude', 'user', `第 ${i} 句：请解释一下第 ${i} 个问题`);
    appendMessage('claude', 'bot', Array.from({ length: 6 }, (_, k) => `第 ${i} 个回答的第 ${k + 1} 段，写得长一点好让聊天区能滚动起来。`).join('\n\n'));
  }
  await sleep(500);
  check('三十句：三十个点，只有一个是亮的', !rail.hidden && dots().length === 30 && rail.querySelectorAll('.on').length === 1, { hidden: rail.hidden, dots: dots().length });
  check('在最底下：亮的是最后一个', onAt() === 29, { on: onAt() });
  const r = rail.getBoundingClientRect(), b = box.getBoundingClientRect(), last = [...box.querySelectorAll('.msg.user')].pop().getBoundingClientRect();
  check('贴在右边缘、竖着居中，不压住气泡也不压住滚动条', r.right <= b.right - 8 + 0.5 && r.left >= last.right - 0.5 && Math.abs((r.top + r.bottom) / 2 - (b.top + b.bottom) / 2) < 2, { rail: [r.left, r.right], boxRight: b.right, bubbleRight: last.right });
  postNative('testWindowShot', { path: `${DIR}/rail-bottom.png` }); await sleep(300);
  box.scrollTop = 0; await sleep(300);
  check('滚到最上面：亮的是第一个', onAt() === 0, { on: onAt() });
  dots()[11].click(); await sleep(1100);
  const target = box.querySelectorAll('.msg.user')[11].getBoundingClientRect().top - b.top;
  check('点第 12 个点：第 12 句到了顶上', Math.abs(target - 12) < 3, { top: target });
  check('这时亮的就是第 12 个', onAt() === 11, { on: onAt() });
  dots()[11].dispatchEvent(new MouseEvent('mouseover', { bubbles: true })); await sleep(100);
  const t = tip.getBoundingClientRect(), d = dots()[11].getBoundingClientRect();
  check('鼠标停在点上：左边显示那句话的开头', !tip.hidden && tip.textContent.startsWith('第 12 句') && t.right <= d.left && Math.abs((t.top + t.bottom) / 2 - (d.top + d.bottom) / 2) < 2, { text: tip.textContent, tipRight: t.right, dotLeft: d.left });
  postNative('testWindowShot', { path: `${DIR}/rail-tip.png` }); await sleep(300);
  rail.dispatchEvent(new MouseEvent('mouseleave')); await sleep(50);
  check('鼠标移开：提示收起', tip.hidden, { hidden: tip.hidden });
  // 点很多：一列放不下，亮的那个留在看得见的地方
  for (let i = 31; i <= 140; i++) { appendMessage('claude', 'user', `第 ${i} 句`); appendMessage('claude', 'bot', '好的。\n\n再多一段。'); }
  await sleep(500);
  const on = rail.querySelector('.on').getBoundingClientRect(), rr = rail.getBoundingClientRect();
  check('一百四十句：圆点条不超出聊天区，亮的点在看得见的范围里', rr.top >= b.top && rr.bottom <= b.bottom && on.top >= rr.top - 1 && on.bottom <= rr.bottom + 1, { rail: [rr.top, rr.bottom], on: [on.top, on.bottom], box: [b.top, b.bottom] });
  setActive('gemini', false); await sleep(400);
  check('切到没有内容的另一位：不出现', rail.hidden, { hidden: rail.hidden });
  check('没有脚本报错', out.errors.length === 0, out.errors);
} catch (e) { out.ok = false; out.steps.push('✗ 脚本出错：' + String(e)); }
return out;
