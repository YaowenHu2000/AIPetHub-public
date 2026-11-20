// 所有核心脚本共用的结果协议；note 不参与通过判定。
function makeSuite(name) {
  const started = Date.now();
  const out = { suite: name, checks: [], skips: [], notes: [] };
  const snapshot = value => value === undefined ? null : JSON.parse(JSON.stringify(value));
  const check = (name, condition, actual) => {
    out.checks.push({ name, ok: !!condition, ...(actual === undefined ? {} : { actual: snapshot(actual) }) });
    return !!condition;
  };
  const note = (name, actual) => out.notes.push({ name, actual: snapshot(actual) });
  const skip = (name, reason, actual) => out.skips.push({ name, status: 'skipped', reason, actual: snapshot(actual) });
  // 等「某件事发生」：条件一成立就返回，期限只防卡死（用户 2026-11-18 定）。统一用 WAIT（run-suite.py 注入，UITEST_WAIT 可改，默认 240 秒），
  // 调用处写 until(条件, '说明')、不写数字；只有故意等着被外部打断的那一处写明期限 until(条件, 毫秒, '说明')。
  const until = async (condition, ...rest) => {
    const [ms, what] = typeof rest[0] === 'number' ? rest : [WAIT, rest[0]];
    const deadline = Date.now() + ms;
    do {
      const value = await condition();
      if (value) return value;
      await new Promise(resolve => setTimeout(resolve, 50));
    } while (Date.now() < deadline);
    throw new Error('等不到：' + what + '（' + ms + 'ms）');
  };
  // 一段场景出了异常就记成这一段失败，后面的段照跑
  const section = async (name, fn) => { try { await fn(); } catch (e) { check(name, false, String(e.message || e) + '\n' + String(e.stack || '')); } };
  const finish = () => {
    out.ok = !out.error && out.checks.length > 0 && out.checks.every(item => item.ok);
    out.status = !out.ok ? 'failed' : out.skips.length ? 'skipped' : 'passed';
    out.seconds = (Date.now() - started) / 1000;
    return out;
  };
  return { out, check, note, skip, until, section, finish };
}
