// README 用的界面截图：全是演示数据，不读本机的任何会话。用 tools/uitest/shot-readme.sh 跑（空的主目录里起 App）。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const out = { ok: true };
try {
  window.onConversationsListed = () => {};   // 不让原生那边的（空）列表盖掉演示数据
  postNative('testResize', { width: 1480, height: 920 }); await sleep(900);
  window.onAgentsProbed = () => {};           // 空主目录里一个 CLI 都找不到：别让第一次打开的自动检测把名单改掉
  await sleep(1500);
  AGENT_IDS.splice(0, AGENT_IDS.length, ...ALL_AGENT_IDS);
  afterAgentsChanged();
  await sleep(600);
  const now = Date.now() / 1000, ago = m => now - m * 60;
  const P = '/Users/demo/Projects';
  const lists = {
    gemini: [['g1', '首页首屏加载优化', 'landing-page', 95], ['g2', '暗色主题的配色方案', 'landing-page', 1500], ['g3', '解释 Raft 共识算法', '', 4300]],
    claude: [['c1', '待办列表支持拖拽排序', 'todo-app', 1], ['c2', '登录页表单校验', 'todo-app', 180], ['c3', '流式事件解析器', 'todo-app', 1440], ['c4', 'Swift 并发入门笔记', 'notes', 2900]],
    gpt: [['x1', '订单接口单元测试', 'api-server', 40], ['x2', '依赖升级与告警修复', 'api-server', 1450], ['x3', '照片批量重命名脚本', 'scripts', 5600]],
    deepseek: [['d1', '定时任务失败排查', 'data-pipeline', 12], ['d2', '慢查询优化', 'data-pipeline', 2000]],
  };
  Object.entries(lists).forEach(([id, rows]) => {
    S[id].conversations = rows.map(([cid, title, proj, m]) => ({ id: cid, title, time: '', timestamp: ago(m), cwd: proj ? `${P}/${proj}` : '' }));
  });
  setActive('claude', false);
  S.claude.conversationId = 'c1'; S.claude.loadedId = 'c1';
  S.claude.workspace = `${P}/todo-app`;
  const W = `${P}/todo-app/src`;
  const diff1 = '@@ -12,6 +12,18 @@\n   const list = document.querySelector(".todo-list");\n+  let dragging = null;\n+  list.addEventListener("dragstart", e => {\n+    dragging = e.target.closest(".todo");\n+    dragging.classList.add("is-dragging");\n+  });\n+  list.addEventListener("dragover", e => {\n+    e.preventDefault();\n+    const after = closestBelow(list, e.clientY);\n+    list.insertBefore(placeholder, after);\n+  });';
  renderMessages('claude', [
    { role: 'user', text: '给待办列表加上拖拽排序：拖动时显示一条占位线，松手后把新顺序存起来。' },
    { role: 'bot', duration: 74, text: '已完成，待办列表现在可以拖拽排序：\n\n- **拖动时**原位置变淡，鼠标下方出现一条蓝色占位线，提示会插到哪里\n- **松手后**按新顺序重排，并写回 `localStorage`，刷新页面后顺序还在\n- 键盘用户可以用 **Alt + ↑ / ↓** 调整顺序\n\n新增了 3 个测试，`npm test` 全部通过（24 / 24）。',
      steps: [
        { kind: 'think', title: '思考', status: 'ok', detail: '先看列表是怎么渲染的，再决定拖拽状态放在哪里。' },
        { kind: 'read', title: '读取 TodoList.js', path: `${W}/TodoList.js`, status: 'ok' },
        { kind: 'read', title: '读取 storage.js', path: `${W}/storage.js`, status: 'ok' },
        { kind: 'edit', title: '修改 TodoList.js', path: `${W}/TodoList.js`, status: 'ok' },
        { kind: 'edit', title: '修改 styles.css', path: `${W}/styles.css`, status: 'ok' },
        { kind: 'write', title: '写入 reorder.test.js', path: `${W}/reorder.test.js`, status: 'ok' },
        { kind: 'command', title: '运行测试', detail: 'npm test', output: 'Tests: 24 passed, 24 total', status: 'ok' },
      ],
      files: [
        { path: `${W}/TodoList.js`, kind: 'edit', added: 46, removed: 3, diff: diff1 },
        { path: `${W}/styles.css`, kind: 'edit', added: 14, removed: 0 },
        { path: `${W}/reorder.test.js`, kind: 'create', added: 38, removed: 0 },
      ] },
  ], `${P}/todo-app`);
  renderAllHistory(); renderHeader(); renderComposer();
  queueSectionFit();
  // 舞台：一位在查资料，其余空闲
  pets.gpt.setState('reading');
  await sleep(2500);
  S.claude.msgEl.scrollTop = 0;
  await realShot('readme');
} catch (e) { out.ok = false; out.error = String(e) + ' | ' + String(e && e.stack).slice(0, 300); }
return out;
