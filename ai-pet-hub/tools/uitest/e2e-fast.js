// fast 开关、fast 时桌宠的样子、模型菜单里的剩余用量、Codex 各模型的思考强度。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (cond, ms, what) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { const v = cond(); if (v) return v; await sleep(200); } throw new Error('等不到：' + what); };
const shot = name => { postNative('testSnapshot', { path: DIR + '/' + name + '.png' }); return sleep(700); };
const out = { steps: [] };
const note = (k, v) => { out.steps.push(k + ' = ' + JSON.stringify(v)); };
const id = AGENT;
try {
  setActive(id);
  setWorkspace(id, REPO, false);
  S[id].model = MODEL; S[id].effort = 'low'; S[id].perm = FULL_PERM; S[id].fast = false; renderComposer();
  const box = S[id].msgEl;

  // 模型面板：⚡ fast（模型有 fast 档才能点）、滑杆调思考强度、点模型名进选模型那一页、剩余用量
  openModelPopover();
  const fastBtn = els.popover.querySelector('.mp-fast:not(:disabled)');
  note('面板里 fast 能点', !!fastBtn);
  const usage = await until(() => { const rows = [...els.popover.querySelectorAll('.usage-row')]; return rows.length || els.popover.querySelector('.usage-note')?.textContent !== '正在查…' ? rows : null; }, 60000, '剩余用量');
  note('剩余用量', usage.map(r => r.textContent.replace(/\s+/g, ' ').trim()));
  note('没查到时的说明', els.popover.querySelector('.usage-note')?.textContent || null);
  // 滑杆：点最右边 → 这个模型的最高档；点最左边 → 最低档
  const slide = async frac => {
    const track = els.popover.querySelector('.mp-slider'), r = track.getBoundingClientRect();
    const at = { clientX: r.left + r.width * frac, clientY: r.top + r.height / 2, pointerId: 1, bubbles: true };
    track.dispatchEvent(new PointerEvent('pointerdown', at)); track.dispatchEvent(new PointerEvent('pointerup', at));
    await sleep(250);
    return [S[id].effort, els.popover.querySelector('.mp-effort').textContent];
  };
  note('滑杆拉到最右', await slide(0.99));
  await shot('panel-' + id);
  note('滑杆拉到最左', await slide(0.01));
  els.popover.querySelector('.mp-model').click(); await sleep(200);
  note('选模型那一页', [...els.popover.querySelectorAll('.model-row .mr-name')].map(e => e.textContent));
  const more = els.popover.querySelector('.more-row');
  if (more) { more.dispatchEvent(new MouseEvent('mouseenter')); await sleep(200); note('更多模型', [...els.popoverSub.querySelectorAll('.mr-name')].map(e => e.textContent)); }
  await shot('models-' + id);
  els.popover.querySelector('.mp-back').click(); await sleep(200);
  if (fastBtn) els.popover.querySelector('.mp-fast').click();
  await sleep(200);
  closePopover();
  note('顶上还有没有 CLI 标签', !!document.querySelector('#cli-pill'));
  note('点了之后 fast 开着', fastOn(id));
  note('输入框下面的选择器', els.chipModel.textContent.trim());
  if (id === 'gpt') {
    note('GPT-6-Astra 的思考强度', modelEfforts('gpt', find(AGENTS.gpt.models, 'gpt-6-astra')).map(e => e.name));
    note('GPT-6-Luna 的思考强度', modelEfforts('gpt', find(AGENTS.gpt.models, 'gpt-6-luna')).map(e => e.name));
    note('模型', AGENTS.gpt.models.map(m => m.name));
  }

  // fast 开着时预览动作：桌宠是 fast 的样子
  pets[id].statusEl.click(); await sleep(1500);
  note('预览时的样子', { fast: pets[id].card.classList.contains('fast-form'), 状态: pets[id].statusEl.textContent, 放的帧: pets[id].frameKey, 专门画的: pets[id].card.classList.contains('fast-art') });
  await shot('pet-fast-' + id);
  pets[id].demoPhase = null; pets[id].setState('idle'); await sleep(300);
  note('回到待机后', pets[id].card.classList.contains('fast-form'));

  // 真的问一句：回答进行中是 fast 的样子，答完恢复
  els.input.value = '用终端命令运行：sleep 4; echo fast-ok 。然后只回答输出的内容。'; send();
  await until(() => viewBusy(id), 5000, '开始回答');
  let sawFast = false;
  await until(() => { if (pets[id].card.classList.contains('fast-form')) sawFast = true; return !isBusy(id); }, 200000, '回答结束');
  await sleep(600);
  note('回答进行中是 fast 的样子', sawFast);
  note('回答', [...box.querySelectorAll('.msg.bot.turn')].pop()?.querySelector('.answer')?.textContent.trim().slice(0, 60));
  note('答完后', pets[id].card.classList.contains('fast-form'));
} catch (e) { out.error = String(e && e.message || e); await shot('error-' + id); }
return out;
