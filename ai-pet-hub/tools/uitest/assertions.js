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
  const until = async (condition, ms, what) => {
    const deadline = Date.now() + ms;
    do {
      const value = await condition();
      if (value) return value;
      await new Promise(resolve => setTimeout(resolve, 50));
    } while (Date.now() < deadline);
    throw new Error('等不到：' + what + '（' + ms + 'ms）');
  };
  const finish = () => {
    out.ok = !out.error && out.checks.length > 0 && out.checks.every(item => item.ok);
    out.status = !out.ok ? 'failed' : out.skips.length ? 'skipped' : 'passed';
    out.seconds = (Date.now() - started) / 1000;
    return out;
  };
  return { out, check, note, skip, until, finish };
}
