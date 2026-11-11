'use strict';

// 正在写的回答怎么显示：只重画最后还在变的一截（markdown.js 的 streamSplit）、按帧匀着放出来。接在 native-callbacks.js 后面加载。

/**
 * 正在写的回答显示到 el 里。文字是一点点变长的：前面已经定下来的段落（见 markdown.js 的 streamSplit）只渲染一次，留在原地，
 * 每次只重新渲染最后还在变的那一截；以前每次都把整段回答（公式、代码高亮）从头渲染，回答越长越慢。
 * 写完（final）时整段重新渲染一遍，和回答完成后显示的完全一样。
 */
function renderStreamingAnswer(el, text, final) {
  const st = el._stream;
  if (final || !text) {
    el.innerHTML = text ? renderRich(text) : '';
    el._stream = null;
    return;
  }
  const split = streamSplit(text);
  let done = 0;   // 已经渲染好留在 el 里的那一截有多长
  if (st && split >= st.src.length && text.startsWith(st.src)) {
    while (el.childNodes.length > st.count) el.lastChild.remove();   // 去掉上次还在变的那一截
    done = st.src.length;
  } else {
    el.innerHTML = '';
  }
  if (split > done) el.insertAdjacentHTML('beforeend', renderRich(text.slice(done, split)));
  el._stream = { src: text.slice(0, split), count: el.childNodes.length };
  el.insertAdjacentHTML('beforeend', renderRich(text.slice(split)));
}

/**
 * 正在写的回答按帧匀着显示。模型给字是一小撮一小撮的（隔两三百毫秒来十几个字），照到了就显示的话，字是一顿一顿蹦出来的；
 * 这里每帧往前放一点，追上最新的内容，看起来是连续在写。窗口不在前台、或者这个会话没显示着时不做动画，直接显示。
 */
function streamTo(run, text, final) {
  const live = run.live;
  const st = live.typing || (live.typing = { shown: 0, text: '', final: false, raf: 0, timer: 0, at: 0 });
  const unschedule = () => { cancelAnimationFrame(st.raf); clearTimeout(st.timer); st.raf = st.timer = 0; };
  if (!text.startsWith(st.text.slice(0, st.shown))) st.shown = 0;   // 内容换了，不是接着写
  st.text = text;
  st.final = final;
  if (!text || !live.el.isConnected || document.hidden) {
    unschedule();
    st.shown = text.length;
    renderStreamingAnswer(live.answer, text, final);
    return;
  }
  if (st.raf || st.timer) return;
  const tick = () => {
    unschedule();
    const now = performance.now();
    const dt = now - st.at;
    st.at = now;
    const left = st.text.length - st.shown;
    // 速度跟着「还差多少」走：差得多放得快。追得不急（约半秒），下一撮字到的时候手里还有没放完的，所以中间不会停顿
    st.shown += revealStep(left, dt);
    const done = st.shown >= st.text.length;
    const box = S[run.agent].msgEl;
    const stick = live.el.isConnected && nearBottom(box);
    renderStreamingAnswer(live.answer, done ? st.text : st.text.slice(0, st.shown), done && st.final);
    if (stick) scrollToBottom(box);
    if (!done && live.el.isConnected) schedule();
  };
  // 平时跟着屏幕刷新走；窗口被挡住时屏幕不刷新（requestAnimationFrame 不来），靠定时器接着显示，不会停住
  const schedule = () => { st.raf = requestAnimationFrame(tick); st.timer = setTimeout(tick, 120); };
  st.at = performance.now() - 16;
  schedule();
}

/** 正在写的回答在「工作过程」里的那一步：这时它是藏着的（显示在正文位置），先放个空壳，不白渲染一遍；要显示时再补上。 */
function lazyTextStep() {
  const el = document.createElement('div');
  el.className = 'step step-text running';
  el.dataset.lazy = '1';
  return el;
}
