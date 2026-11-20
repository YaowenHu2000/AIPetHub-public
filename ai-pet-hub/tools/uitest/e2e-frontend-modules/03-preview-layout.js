  // PV：预览面板——重开文件拿最新正文和本次改动、上下处改动按顺序走、切标签保留阅读位置、清空文件的增删数
  {
    const pvRead = readLocalFile, disk = { '/pv-fixture/notes.txt': 'old contents' };
    readLocalFile = async (path, base) => { const p = path.startsWith('/') ? path : `${base}/${path}`; return { path: p, content: disk[p] }; };
    const pvBody = () => pane.el.querySelector('.ed-body');
    const pvLine = n => [...pane.el.querySelectorAll('.ed-body > .ed-code .cl')].find(r => r.querySelector('.gn').textContent === String(n))?.querySelector('.tx').textContent;
    const pvInfo = () => pane.el.querySelector('.ed-diffinfo')?.textContent || '';
    closePreview(); openPreview({ path: '/pv-fixture/notes.txt', base: '' });
    await until(() => pvLine(1) === 'old contents', 'PV 旧正文');
    disk['/pv-fixture/notes.txt'] = 'new contents';
    openPreview({ path: 'notes.txt', base: '/pv-fixture', diff: '@@ -1 +1 @@\n-old contents\n+new contents' });
    await until(() => pane.tabs.length === 1, 'PV 合并同路径标签');
    check('PV 相对路径重开同一文件显示原生读到的新正文', pvLine(1) === 'new contents' && !pane.el.querySelector('.ed-unplaced'),
      { line1: pvLine(1), unplaced: !!pane.el.querySelector('.ed-unplaced'), info: pvInfo() });
    openPreview({ path: '/pv-fixture/notes.txt', base: '' });
    await sleep(100);   // 假的读文件是已兑现的 Promise，重读的结果在任何定时器之前就处理完，这里不会因为机器忙而等不够
    check('PV 从无改动的引用重开不留上次的增删标记', !pane.el.querySelector('.ed-diffinfo'), pvInfo());
    // 240 行、第 40 和 160 行各加一行：自动停在第一处后点「下一处改动」要依次走到第二处、再回到第一处
    disk['/pv-fixture/long.txt'] = Array.from({ length: 240 }, (_, i) => `line ${i + 1}`).join('\n');
    closePreview(); openPreview({ path: '/pv-fixture/long.txt', base: '', diff: '@@ -39,0 +40 @@\n+line 40\n@@ -158,0 +160 @@\n+line 160' });
    await until(() => pvLine(240) && pane.el.querySelectorAll('.ed-body .chg-start').length === 2, 'PV 两处改动');
    const pvAnchors = [...pane.el.querySelectorAll('.ed-body .chg-start')];
    const pvNext = () => { pvAnchors.forEach(a => a.classList.remove('flash')); [...pane.el.querySelectorAll('.ed-tool')].find(b => b.title === '下一处改动').click(); return pvAnchors.findIndex(a => a.classList.contains('flash')); };
    const pvFlashes = [pvNext()]; await sleep(400); pvFlashes.push(pvNext());   // 两次点击之间隔开一段，不是在等某件事发生；机器忙只会隔得更久
    check('PV 下一处改动依次走到第二处再回到第一处', pvFlashes.join() === '1,0', pvFlashes);
    // 长文本滚到 1300，切到短 Markdown 再点回来，阅读位置还在（经打开文件切走、经点标签切走都一样）
    disk['/pv-fixture/plain.txt'] = Array.from({ length: 400 }, (_, i) => `text ${i + 1}`).join('\n');
    disk['/pv-fixture/short.md'] = '# 短文\n\n一段。';
    closePreview(); openPreview({ path: '/pv-fixture/plain.txt', base: '' });
    await until(() => pvLine(400), 'PV 长文本');
    pvBody().scrollTop = 1300;
    openPreview({ path: '/pv-fixture/short.md', base: '' });
    await until(() => pane.el.querySelector('.ed-body .md-doc'), 'PV 短 Markdown');
    const pvTab = name => [...pane.el.querySelectorAll('.ed-tab')].find(t => t.querySelector('.ed-tab-name').textContent === name);
    pvTab('plain.txt').click();
    const pvBack1 = pvBody().scrollTop;
    pvTab('short.md').click(); pvTab('plain.txt').click();
    const pvBack2 = pvBody().scrollTop;
    check('PV 切走再切回保留滚动位置', Math.abs(pvBack1 - 1300) < 2 && Math.abs(pvBack2 - 1300) < 2, { viaOpen: pvBack1, viaClick: pvBack2 });
    // 经「查看全部改动」、内置浏览器切走再点回来，位置也要在
    openChanges({ agent: id, text: '', cwd: '/pv-fixture', files: [{ path: 'plain.txt', added: 0, removed: 0, diff: '' }] });
    pvTab('plain.txt').click();
    const pvBack3 = pvBody().scrollTop;
    openBrowser();
    pvTab('plain.txt').click();
    const pvBack4 = pvBody().scrollTop;
    check('PV 经全部改动或内置浏览器切走再切回保留滚动位置', Math.abs(pvBack3 - 1300) < 2 && Math.abs(pvBack4 - 1300) < 2, { viaChanges: pvBack3, viaBrowser: pvBack4 });
    // 文件被清空：三行删除都列出来，顶部也是 −3
    disk['/pv-fixture/emptied.txt'] = '';
    closePreview(); openPreview({ path: '/pv-fixture/emptied.txt', base: '', diff: '@@ -1,3 +0,0 @@\n-a\n-b\n-c' });
    await until(() => pane.el.querySelector('.ed-unplaced'), 'PV 清空文件');
    check('PV 清空文件的增删数按 diff 统计', pvInfo() === '+0 −3', pvInfo());
    readLocalFile = pvRead; closePreview();
  }
  // LY：窄窗口又放大字号时（1000 点宽、150% 缩放，网页只剩约 666 CSS 像素），收起舞台后侧栏、聊天、预览三栏仍放不下，
  // 预览的关闭按钮不能被挤到窗口外。放大字号和把窗口直接缩到同样的 CSS 宽度对布局是一回事，这里用后者模拟。
  {
    const lyW = innerWidth, lyH = innerHeight, lyRead = readLocalFile;
    readLocalFile = async path => ({path, content:'ly'});
    setSidebarHidden(false); setStageHidden(false); document.body.classList.remove('preview-max');
    closePreview(); openPreview({path:'/ly-fixture/a.js',base:''}); await until(() => activeTab()?.data, 'LY 预览');
    const lyClose = () => { const r = pane.el.querySelector('.ed-close').getBoundingClientRect(); return {left:Math.round(r.left), right:Math.round(r.right), width:Math.round(r.width), innerWidth}; };
    postNative('testResize',{width:666,height:720});
    await until(() => innerWidth <= 666, 'LY 缩窄窗口'); applyWidths();
    const narrow = lyClose();
    check('LY 窄窗口开预览时关闭按钮在窗口内', narrow.width > 0 && narrow.left >= 0 && narrow.right <= innerWidth, narrow);
    postNative('testResize',{width:500,height:720});   // 1000 点宽、最大 200% 缩放
    await until(() => innerWidth <= 500, 'LY 再缩窄窗口'); applyWidths();
    const narrowest = lyClose();
    check('LY 最窄时关闭按钮仍在窗口内', narrowest.width > 0 && narrowest.left >= 0 && narrowest.right <= innerWidth, narrowest);
    // 最窄时再点预览上的放大：侧栏最窄加预览最大化的最小宽度也放不下，关闭和放大按钮都不能跑出窗口
    pane.el.querySelector('.ed-max').click();
    const maxR = pane.el.querySelector('.ed-max').getBoundingClientRect(), maxedClose = {...lyClose(), maxRight:Math.round(maxR.right), maxed:document.body.classList.contains('preview-max')};
    check('LY 最窄时点放大后关闭和放大按钮仍在窗口内', maxedClose.maxed && maxedClose.width > 0 && maxedClose.left >= 0 && maxedClose.right <= innerWidth && maxedClose.maxRight <= innerWidth, maxedClose);
    pane.el.querySelector('.ed-max').click();
    postNative('testResize',{width:1400,height:720});
    await until(() => innerWidth >= 1400, 'LY 加宽窗口'); applyWidths();
    const chatR = document.getElementById('chat-column').getBoundingClientRect(), paneR = pane.el.getBoundingClientRect(), wide = lyClose();
    const wideLayout = {chat:Math.round(chatR.width), chatRight:Math.round(chatR.right), paneLeft:Math.round(paneR.left), pane:Math.round(paneR.width), previewW:getComputedStyle(document.documentElement).getPropertyValue('--preview-w'), close:wide};
    check('LY 宽窗口仍是聊天和预览并排', chatR.width >= 380 && paneR.left >= chatR.right && Math.round(paneR.width) === parseInt(wideLayout.previewW, 10) && wide.right <= innerWidth, wideLayout);
    closePreview(); readLocalFile = lyRead;
    postNative('testResize',{width:lyW,height:lyH});
    await until(() => Math.abs(innerWidth - lyW) <= 2, 'LY 还原窗口'); applyWidths();
  }
  // 先出了正文、随后 CLI 以非零退出码结束（outcome=failed，回复不以 ⚠️ 开头）：有「重试」的这一轮，桌宠也要失落而不是庆祝
  const msCelebrate = pets[id].celebrate, msMood = pets[id].moodEvent, msCalls = [];
  pets[id].celebrate = () => msCalls.push('celebrate');
  pets[id].moodEvent = name => msCalls.push('mood:' + name);
  const msAnswer = (reqId, outcome) => {
    const live = document.createElement('div'); S[id].msgEl.appendChild(live);
    S[id].runs.set(reqId, { reqId, agent: id, view: 'ms-view', text: '数一数', images: [], nodes: [], queue: [], live: { el: live, steps: [] } });
    msCalls.length = 0;
    window.onAgentResponse({ agent: id, reqId, conversationId: 'ms-view', reply: '1 2 3', outcome, cwd: '', files: [],
      steps: outcome === 'failed' ? [{ kind: 'error', title: '出错', status: 'error', detail: 'exit code 42' }] : [] });
    const turns = S[id].msgEl.querySelectorAll('.msg.bot.turn');
    return { calls: msCalls.slice(), retry: !!turns[turns.length - 1]?.querySelector('.answer-copy.retry') };
  };
  const msFailed = msAnswer('ms-failed', 'failed');
  check('MS 回答中途失败：有重试，桌宠失落不庆祝', msFailed.retry && msFailed.calls.includes('mood:error') && !msFailed.calls.includes('celebrate'), msFailed);
  const msDone = msAnswer('ms-done', 'completed');
  check('MS 正常完成的回答照常庆祝', !msDone.retry && msDone.calls.includes('celebrate') && !msDone.calls.includes('mood:error'), msDone);
  delete pets[id].celebrate; delete pets[id].moodEvent;   // 两个都在原型上，删掉替身就恢复原样
  if (pets[id].celebrate !== msCelebrate) pets[id].celebrate = msCelebrate;
  if (pets[id].moodEvent !== msMood) pets[id].moodEvent = msMood;
  // CI：重开会话后原图文件已移走、只剩记录里的图（只有 ref 没有 path），点「重试」要把 ref 一起交给原生；这次再停下，下一次重试也照样带上
  {
    const pixel = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';
    const ref = { agent: id, conversationId: 'ci-retry-fixture', id: '/tmp/ci-moved.png#0' };
    renderMessages(id, [{ role: 'user', text: '这张图是什么颜色', images: [{ src: pixel, w: 1, h: 1, ref, name: 'ci-moved.png' }] },
      { role: 'bot', text: '', outcome: 'interrupted', steps: [] }], '');
    const retryAsk = () => { const at = requests.length; [...S[id].msgEl.querySelectorAll('.answer-copy.retry')].at(-1)?.click(); return requests.slice(at).find(r => r.action === 'askAgent'); };
    const first = retryAsk();
    check('CI 重试带上只剩 ref 的历史图片', JSON.stringify(first?.imageRefs) === JSON.stringify([{...ref, index:0}]), first && { images: first.images, imageRefs: first.imageRefs });
    if (first) window.onAgentResponse({ agent: id, reqId: first.reqId, reply: '⚠️ 已停止', cancelled: true });
    const again = retryAsk();
    check('CI 重试那一轮再停下，下一次重试仍带着 ref', JSON.stringify(again?.imageRefs) === JSON.stringify([{...ref, index:0}]), again && { images: again.images, imageRefs: again.imageRefs });
    if (again) window.onAgentResponse({ agent: id, reqId: again.reqId, reply: '⚠️ 已停止', cancelled: true });
    // CI2：原文件还在、但发送之后被覆盖过（changed）：重试按 ref 发当时那张，不发磁盘上的新文件；没改过的那张照旧按路径发
    const changed = { agent: id, conversationId: 'ci2-retry-fixture', id: '/tmp/ci2-same.png#0@turn-a' };
    renderMessages(id, [{ role: 'user', text: '这两张图是什么颜色', images: [
      { src: pixel, w: 1, h: 1, path: '/tmp/ci2-same.png', ref: changed, name: 'ci2-same.png', changed: true },
      { src: pixel, w: 1, h: 1, path: '/tmp/ci2-kept.png' }] },
    { role: 'bot', text: '', outcome: 'interrupted', steps: [] }], '');
    const overwritten = retryAsk();
    check('CI2 原文件被覆盖过的图重试按 ref 发当时那张，没改过的仍按路径发',
      JSON.stringify(overwritten?.imageRefs) === JSON.stringify([{...changed, index:0}]) && JSON.stringify(overwritten?.images) === JSON.stringify(['/tmp/ci2-kept.png']),
      overwritten && { images: overwritten.images, imageRefs: overwritten.imageRefs });
    if (overwritten) window.onAgentResponse({ agent: id, reqId: overwritten.reqId, reply: '⚠️ 已停止', cancelled: true });
  }
