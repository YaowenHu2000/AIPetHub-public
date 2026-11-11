// 模型菜单跟着 `agy models` 走：不发话也能看到 agy 那边新出的模型（Usage.swift 的 refreshGeminiModels）。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const out = { steps: [], ok: true };
try {
  const before = AGENTS.gemini.models.map(m => m.v);
  postNative('loadUsage', { agent: 'gemini', force: true });
  for (let i = 0; i < 360 && !AGENTS.gemini.models.some(m => m.v === 'gemini-4-carbon'); i++) await sleep(250);
  const carbon = AGENTS.gemini.models.find(m => m.v === 'gemini-4-carbon');
  out.steps.push('之前：' + before.join());
  out.steps.push('之后：' + AGENTS.gemini.models.map(m => `${m.v}[${(m.efforts || []).join('/')}]`).join(' '));
  out.ok = !!carbon && (carbon.efforts || []).join() === 'low,medium,high';
  out.steps.push((out.ok ? '✓' : '✗') + ' gemini-4-carbon：' + JSON.stringify(carbon));
  out.steps.push('当前选的模型：' + S.gemini.model);
} catch (e) { out.ok = false; out.error = String(e && e.stack || e); }
return out;
