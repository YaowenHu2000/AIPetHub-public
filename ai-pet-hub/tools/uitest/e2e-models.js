// 模型菜单跟着 CLI 走：开始打字（触发预热）后，菜单换成 CLI 报上来的模型；选一个新出现的模型能正常回答。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (cond, ms, what) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { const v = cond(); if (v) return v; await sleep(150); } throw new Error('等不到：' + what); };
const out = { steps: [] };
const note = (k, v) => { out.steps.push(k + ' = ' + JSON.stringify(v)); };
const id = AGENT;
try {
  setActive(id);
  setWorkspace(id, REPO, false);
  S[id].effort = 'low'; S[id].perm = FULL_PERM; renderComposer();
  const before = JSON.stringify(AGENTS[id].models.map(m => m.name));
  note('一开始（写死的）', AGENTS[id].models.map(m => m.name));
  const saved = lsGet(`${id}_models`);   // 存进本地的那份：CLI 报上来以后会变
  els.input.value = '只'; els.input.dispatchEvent(new Event('input', { bubbles: true }));   // 开始打字 → 预热 → CLI 报模型
  if (id === 'gemini') {   // Gemini 的模型列表在会话接上时才报：先问一句
    els.input.value = '只回答：好'; send();
    await until(() => !isBusy(id) && S[id].runs.size === 0 && S[id].msgEl.querySelector('.msg.bot.turn:not(.live)'), 120000, '第一句答完');
  }
  // 等 CLI 报上来（存进本地的那份会变）；写死的那份本来就和 CLI 一样时名字不会变，这不算错
  await until(() => lsGet(`${id}_models`) !== saved, 30000, 'CLI 报上来的模型');
  note('和写死的那份名字一样', JSON.stringify(AGENTS[id].models.map(m => m.name)) === before);
  note('CLI 报上来之后', AGENTS[id].models.map(m => m.name).slice(0, 9));
  note('现在选着的', [S[id].model, find(AGENTS[id].models, S[id].model)?.name]);
  note('菜单按钮上的字', els.chipModel.textContent.replace(/\s+/g, ' ').trim());
  const want = { claude: 'fable', gpt: AGENTS[id].models[1]?.v, gemini: 'gemini-3.8-flash' }[id];
  const m = find(AGENTS[id].models, want);
  note('要选的模型', m ? [m.v, m.name, (m.efforts || []).join('/')] : null);
  chooseModel(id, want, 'low');
  els.input.value = '只回答：好'; send();
  await until(() => viewBusy(id), 5000, '开始回答');
  await until(() => !isBusy(id), 180000, '回答结束');
  await sleep(400);
  note('用它问一句的回答', [...S[id].msgEl.querySelectorAll('.msg.bot.turn')].pop()?.querySelector('.answer')?.textContent.trim().slice(0, 40));
} catch (e) { out.error = String(e && e.message || e); }
return out;
