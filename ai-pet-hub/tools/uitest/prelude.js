// 各个测试脚本共用的小工具（run.sh 会把它接在每个脚本前面）。
// 等这一轮开始跑命令。等不到时，把这一轮实际做了哪些步骤、最后答了什么写进报错里——
// 多半是模型这次没按要求跑命令（直接答了、或者先问了一句），有了这些就能分清是模型没照做，还是界面没把步骤显示出来。
const untilCommand = async (box, ms = 120000) => {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (box.querySelector('.msg.bot.turn.live .step-command')) return;
    await new Promise(r => setTimeout(r, 200));
  }
  const live = box.querySelector('.msg.bot.turn.live');
  const last = [...box.querySelectorAll('.msg.bot.turn')].pop();
  const steps = live ? [...live.querySelectorAll('.step')].map(n => n.textContent.trim().replace(/\s+/g, ' ').slice(0, 40)) : null;
  throw new Error('等不到命令开始。这一轮实际的步骤：' + JSON.stringify(steps) + '；最后一条回答：' + (last ? last.textContent.trim().replace(/\s+/g, ' ').slice(0, 100) : '（没有）'));
};

// 真实窗口模式（run.sh 前面加 REAL=1）才有意义的三个：
/** 把整个窗口截下来（连红绿灯、毛玻璃），存在结果目录里。 */
const realShot = async name => { postNative('testWindowShot', { path: DIR + '/' + name + '.png' }); await new Promise(r => setTimeout(r, 900)); };
/** 在一个元素的正中真的点一下（事件从窗口那一层走，会经过标题栏和原生视图）。 */
const realClick = async el => {
  const r = el.getBoundingClientRect();
  postNative('testClick', { x: r.left + r.width / 2, y: r.top + r.height / 2 });
  await new Promise(res => setTimeout(res, 450));
};
/** 红绿灯的位置：[{ left, right, centerY, hidden }]（CSS 像素）。 */
const trafficLights = () => new Promise(resolve => {
  window.onTestChrome = data => resolve(data);
  postNative('testChrome', {});
  setTimeout(() => resolve(null), 3000);
});
