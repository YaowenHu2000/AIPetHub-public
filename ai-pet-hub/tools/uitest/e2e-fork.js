// 分叉：克劳蒂娜的会话正开在别的程序里时，在这里发话不往同一个会话里塞副本，而是 claude --resume <id> --fork-session。
// 用法：先在外面起一个一直不退出的 claude 进程，拿到它的 session_id（A），再
//   sed "s/__SID__/$A/; s/__EXPECT__/fork/" tools/uitest/e2e-fork.js > tools/uitest/_fork_run.js && tools/uitest/run.sh claude _fork_run.js haiku 240
// 对照（把那个进程杀掉后）：把 __EXPECT__ 换成 nofork——这时不该有提示、不该分叉。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (cond, ms, what) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { const v = cond(); if (v) return v; await sleep(200); } throw new Error('等不到：' + what); };
const SID = '__SID__', EXPECT = '__EXPECT__';
const out = { expect: EXPECT, A: SID, steps: [], ok: true };
const check = (name, pass, got) => { out.steps.push(`${pass ? '✓' : '✗'} ${name}：${JSON.stringify(got)}`); if (!pass) out.ok = false; };
const id = 'claude';
try {
  await sleep(1500);
  out.start = { active, cid: S[id].conversationId, loaded: S[id].loadedId };   // 启动时这一位已经开着哪个会话（上次留下的）
  setActive(id, false);
  const st = S[id];
  st.model = MODEL; st.effort = 'low'; st.perm = FULL_PERM; renderComposer();
  // a) 列表里找到 A，点开
  postNative('listConversations', { agent: id });
  const item = await until(() => (st.conversations || []).find(c => c.id === SID), 30000, '会话列表里出现 A');
  check('列表里有 A', true, { title: item.title, cwd: item.cwd });
  openConversation(id, item);
  await until(() => st.loadedId === SID, 30000, '载入 A');
  check('载入 A', st.loadedId === SID, st.loadedId);
  const hint = () => document.getElementById('fork-hint');
  // b) 提示
  if (EXPECT === 'fork') {
    let shown = false; try { await until(() => hint() && !hint().hidden, 15000, '#fork-hint'); shown = true; } catch {}
    const txt = hint() ? hint().textContent.trim() : null;
    check('#fork-hint 显示且含「分支」', shown && (txt || '').includes('分支'), { exists: !!hint(), hidden: hint()?.hidden, text: txt });
  } else {
    await sleep(8000);
    check('#fork-hint 不出现', !hint() || hint().hidden, { exists: !!hint(), hidden: hint()?.hidden, text: hint()?.textContent.trim() });
  }
  // c) 发话
  const box = st.msgEl;
  els.input.value = '我上一句让你回复了哪个字？只回复那个字'; send();
  await until(() => st.runs.size > 0, 8000, '开始回答');
  await until(() => st.runs.size === 0, 120000, '回答结束');
  await sleep(1500);
  // d) 检查
  const B = st.conversationId;
  const bots = [...box.querySelectorAll('.msg.bot')];
  const last = bots.length ? bots[bots.length - 1].textContent.trim().replace(/\s+/g, ' ').slice(-200) : '';
  out.B = B; out.answer = last;
  const note = box.querySelector('.msg.sys.fork-note');
  postNative('listConversations', { agent: id }); await sleep(2500);
  const rowsText = [...document.querySelectorAll('.conv-row')].map(r => r.textContent.trim().slice(0, 30));
  const activeRow = document.querySelector('.conv-row.active');
  const aRow = (st.conversations || []).some(c => c.id === SID);
  if (EXPECT === 'fork') {
    check('conversationId 变成新的 B', !!B && B !== SID, B);
    check('有 .msg.sys.fork-note', !!note, note ? note.textContent.trim().slice(0, 80) : null);
    check('回答里有「甲」', last.includes('甲'), last);
    check("convForks['claude:'+B] === A", convForks['claude:' + B] === SID, convForks['claude:' + B]);
    check('B 那一行（.conv-row.active）有 .conv-fork', !!activeRow?.querySelector('.conv-fork'), activeRow ? { text: activeRow.textContent.trim().slice(0, 40), title: activeRow.querySelector('.conv-fork')?.title } : null);
    check('A 还在列表里', aRow, (st.conversations || []).filter(c => c.id === SID || c.id === B).map(c => c.id + ' ' + c.title));
  } else {
    check('conversationId 仍是 A（没分叉）', B === SID, B);
    check('没有 .fork-note', !box.querySelector('.fork-note'), note ? note.textContent.trim() : null);
    check('回答里有「甲」', last.includes('甲'), last);
  }
  out.rows = rowsText.slice(0, 8);
} catch (e) { out.ok = false; out.error = String(e && e.stack || e); }
return out;
