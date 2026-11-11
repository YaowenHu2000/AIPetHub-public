'use strict';

// 长对话里跳转：聊天区右下角的两个小按钮——「上一句我说的话」和「下一句 / 回到底部」。
// 内容一屏放得下时不出现；已经在最底下时「往下」那个变淡。
// 右边缘另有一列小圆点：我说过的每一句一个点，现在看到的那一句是亮的；点一下跳到那一句，鼠标停上去显示那句话的开头。

const jumpNav = document.createElement('div');
jumpNav.className = 'jump-nav';
jumpNav.hidden = true;
jumpNav.innerHTML = `<button class="jump-up" title="上一句我说的话">${UI.arrowUp}</button><button class="jump-down" title="下一句我说的话；后面没有了就回到底部">${UI.arrowUp}</button>`;
els.chatStack.appendChild(jumpNav);

/** 我说过的每一句（排着还没发的不算）在聊天区里从上往下的位置。 */
function myMessageTops(box) {
  const top = box.getBoundingClientRect().top - box.scrollTop;
  return [...box.querySelectorAll('.msg.user:not(.queued)')].map(el => el.getBoundingClientRect().top - top);
}

const jumpRail = document.createElement('div');
jumpRail.className = 'jump-rail';
jumpRail.hidden = true;
els.chatStack.appendChild(jumpRail);
const jumpTip = document.createElement('div');
jumpTip.className = 'jump-tip';
jumpTip.hidden = true;
els.chatStack.appendChild(jumpTip);
let railKey = '';

/** 圆点条：有几句就几个点（句子变了才重画），亮的是现在正在看的这一轮的那一句（点哪个点，跳过去以后亮的就是它）。 */
function syncJumpRail(box, room) {
  const mine = [...box.querySelectorAll('.msg.user:not(.queued)')];
  jumpRail.hidden = room < 80 || mine.length < 2;
  if (jumpRail.hidden) { jumpTip.hidden = true; railKey = ''; return; }
  const key = `${active}|${mine.length}|${mine[mine.length - 1].textContent.length}`;
  if (key !== railKey) {
    railKey = key;
    jumpRail.replaceChildren(...mine.map((el, i) => {
      const b = document.createElement('button');
      b.className = 'jump-dot';
      b.dataset.i = i;
      b.dataset.text = el.textContent.trim().replace(/\s+/g, ' ').slice(0, 80) || '（图片）';
      return b;
    }));
  }
  const tops = myMessageTops(box);
  let at = 0;
  if (room - box.scrollTop < 8) at = tops.length - 1;                              // 在最底下：最后一句
  else tops.forEach((t, i) => { if (t <= box.scrollTop + 60) at = i; });           // 否则：顶上正在看的这一轮是哪一句问出来的
  [...jumpRail.children].forEach((b, i) => b.classList.toggle('on', i === at));
  // 点太多、一列放不下时：让亮的那个待在中间
  const on = jumpRail.children[at];
  if (on && jumpRail.scrollHeight > jumpRail.clientHeight) jumpRail.scrollTop = on.offsetTop - jumpRail.clientHeight / 2;
}
jumpRail.addEventListener('click', e => {
  const b = e.target.closest('.jump-dot'); if (!b) return;
  const box = S[active].msgEl, top = myMessageTops(box)[+b.dataset.i];
  if (top !== undefined) box.scrollTo({ top: Math.min(box.scrollHeight - box.clientHeight, Math.max(0, top - 12)), behavior: 'smooth' });
});
jumpRail.addEventListener('mouseover', e => {
  const b = e.target.closest('.jump-dot'); if (!b) return;
  jumpTip.textContent = b.dataset.text;
  jumpTip.hidden = false;
  const r = b.getBoundingClientRect(), base = els.chatStack.getBoundingClientRect();
  jumpTip.style.top = `${r.top + r.height / 2 - base.top}px`;
});
jumpRail.addEventListener('mouseleave', () => { jumpTip.hidden = true; });

function syncJumpNav() {
  const box = S[active].msgEl;
  const room = box.scrollHeight - box.clientHeight;
  syncJumpRail(box, room);
  jumpNav.hidden = room < 80;
  jumpNav.querySelector('.jump-down').classList.toggle('dim', room - box.scrollTop < 8);
  jumpNav.querySelector('.jump-up').classList.toggle('dim', !myMessageTops(box).some(t => t < box.scrollTop - 8));
}

function jumpTo(direction) {
  const box = S[active].msgEl;
  const tops = myMessageTops(box);
  const here = box.scrollTop;
  // 往上：现在这一屏顶上再往前的最近一句；往下：往后的最近一句，没有就到底
  const target = direction < 0 ? tops.filter(t => t < here - 8).pop() : tops.find(t => t > here + 24);
  const bottom = box.scrollHeight - box.clientHeight;
  box.scrollTo({ top: target === undefined ? (direction < 0 ? 0 : bottom) : Math.min(bottom, Math.max(0, target - 12)), behavior: 'smooth' });
}

jumpNav.querySelector('.jump-up').addEventListener('click', () => jumpTo(-1));
jumpNav.querySelector('.jump-down').addEventListener('click', () => jumpTo(1));
document.addEventListener('scroll', e => { if (e.target === S[active].msgEl) syncJumpNav(); }, true);
// 内容变多变少（新回答、切会话、切到另一位）时也要更新：盯着聊天区里的变化，攒到下一帧算一次
let jumpQueued = false;
new MutationObserver(() => {
  if (jumpQueued) return;
  jumpQueued = true;
  setTimeout(() => { jumpQueued = false; syncJumpNav(); }, 120);
}).observe(els.chatStack, { childList: true, subtree: true, attributes: true, attributeFilter: ['hidden'] });
window.addEventListener('resize', syncJumpNav);
