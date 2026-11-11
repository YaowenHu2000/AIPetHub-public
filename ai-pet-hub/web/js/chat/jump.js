'use strict';

// 长对话里跳转：聊天区右下角的两个小按钮——「上一句我说的话」和「下一句 / 回到底部」。
// 内容一屏放得下时不出现；已经在最底下时「往下」那个变淡。

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

function syncJumpNav() {
  const box = S[active].msgEl;
  const room = box.scrollHeight - box.clientHeight;
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
