// 量对齐：读出各处实际的坐标（不靠看截图）。不用 CLI。结果里的数字都是 CSS 像素。
//   左栏：三层的图标中心和文字左边各在第几像素（应该各自落在同一条竖线上）
//   基线：同一行里大小字的基线差（应该是 0）
//   底边：输入框、右栏最后一张卡片、左栏内容的底边离窗口底多远（应该一样）
//   半像素：桌宠头顶的气泡、工作标签的左边是不是整数
const sleep = ms => new Promise(r => setTimeout(r, ms));
const r1 = n => Math.round(n * 10) / 10;
const box = el => el.getBoundingClientRect();
/** 文字的基线在第几像素：在它里面放一个零高的行内块，行内块的底就是基线。 */
const baseline = el => {
  const probe = document.createElement('span');
  probe.style.cssText = 'display:inline-block;width:0;height:0;';
  el.appendChild(probe);
  const y = box(probe).bottom;
  probe.remove();
  return r1(y);
};
const out = {};
setActive('claude'); await sleep(2500);
const sec = histSections.claude.sec;
const grp = sec.querySelector('.grp-head'), row = sec.querySelector('.conv-row:not(.pending)');
const cx = el => el ? r1(box(el).left + box(el).width / 2) : null;
const lx = el => el ? r1(box(el).left) : null;
out['左栏图标中心 x'] = { 名字: cx(sec.querySelector('.hist-icon')), 文件夹: cx(grp?.querySelector('svg')) };
out['左栏文字左边 x'] = { 名字: lx(sec.querySelector('.hist-name')), 工作空间: lx(grp?.querySelector('.grp-name')), 会话标题: lx(row?.querySelector('.conv-title')) };
const dotRow = sec.querySelector('.conv-row'); dotRow.classList.add('unread');
out['左栏小圆点中心 x'] = r1(box(dotRow).left + parseFloat(getComputedStyle(dotRow, '::before').left) + 3); dotRow.classList.remove('unread');
out['左栏右边缘 x'] = { 加号: r1(box(sec.querySelector('.hist-head .icon-btn:last-child')).right), 数量: grp?.querySelector('.grp-count') ? r1(box(grp.querySelector('.grp-count')).right) : null, 时间: row?.querySelector('.conv-time') ? r1(box(row.querySelector('.conv-time')).right) : null };
out['基线差'] = {
  '名字 / 英文名': r1(baseline(sec.querySelector('.hist-name')) - baseline(sec.querySelector('.hist-brand'))),
  '会话标题 / 时间': row?.querySelector('.conv-time') ? r1(baseline(row.querySelector('.conv-title')) - baseline(row.querySelector('.conv-time'))) : null,
  '工作空间 / 数量': grp?.querySelector('.grp-count') ? r1(baseline(grp.querySelector('.grp-name')) - baseline(grp.querySelector('.grp-count'))) : null,
  '顶栏 名字 / 会话名': r1(baseline(els.name) - baseline(document.getElementById('conv-label'))),
  '顶栏 名字 / 工作空间': r1(baseline(els.name) - baseline(document.querySelector('.ws-crumb .ws-name'))),
  '顶栏 名字 / 分隔符': r1(baseline(els.name) - baseline(document.querySelector('.crumb-sep'))),
  '模型 / 思考强度': r1(baseline(els.chipModel.querySelector('.chip-label')) - baseline(els.chipModel.querySelector('.chip-sub'))),
};
// 左栏三格：每格现在多高、内容要多高、列表下面空了多少（应该只有最下面那一格可以有空）
applySectionWeights(); await sleep(100);
out['左栏三格'] = AGENT_IDS.map(id => {
  const { sec, list } = histSections[id], last = list.lastElementChild;
  const rows = last ? box(last).bottom - box(list).top + list.scrollTop : 0;
  return { 谁: id, 高: r1(box(sec).height), 内容要: Math.ceil(sec.querySelector('.hist-head').offsetHeight + rows + 8), 列表下面空: Math.max(0, r1(box(list).bottom - (last ? box(last).bottom : box(list).top) - 8)), 要滚动: list.scrollHeight > list.clientHeight + 1 };
});
const H = innerHeight, cards = [...document.querySelectorAll('.pet-card')];
out['底边离窗口底'] = { 输入框: r1(H - box(document.querySelector('.composer-box')).bottom), 最后一张桌宠卡片: r1(H - box(cards[cards.length - 1]).bottom), 左栏内容: r1(H - box(document.getElementById('hist-sections')).bottom) };
out['顶栏中心 y'] = { 搜索框: r1(box(document.querySelector('.search-field')).top + box(document.querySelector('.search-field')).height / 2), 头像: r1(box(els.badge).top + box(els.badge).height / 2), 桌宠卡片第一张顶: r1(box(cards[0]).top) };
const arrow = document.querySelector('#send-btn svg'), btn = document.getElementById('send-btn');
out['发送箭头相对按钮中心'] = { x: r1(cx(arrow) - cx(btn)), y: r1(box(arrow).top + box(arrow).height / 2 - box(btn).top - box(btn).height / 2) };
pets.claude.say('量一下', 3000); pets.claude.demoPhase = 'thinking'; pets.claude.setState('thinking'); pets.claude.renderStatus(); await sleep(700);
// 位置按「所在那块地面的左边 + 自己的 left」算：头顶正说着话时工作标签会缩小一点（scale），直接量外框会带上这个缩放
const floorLeft = box(pets.claude.card.querySelector('.pet-floor')).left;
out['半像素'] = { 地面左边: floorLeft, 气泡左边: floorLeft + parseFloat(pets.claude.bubbleEl.style.left), 工作标签左边: floorLeft + parseFloat(pets.claude.workBadgeEl.style.left) };
return out;
