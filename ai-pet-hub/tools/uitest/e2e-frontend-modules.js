// 不用 CLI：输入草稿/建议、会话导航、预览标签与窄窗恢复、提问卡按题目 id 作答、AI 增删。
// tools/uitest/run.sh claude e2e-frontend-modules.js
// 正文按主题拆在同名目录 e2e-frontend-modules/ 里：run-suite.py 按文件名顺序把片段拼到下面的 //@parts 处，仍在同一个 try 里、共用一个作用域，
// 所以片段可以用前面片段定义的变量（比如 01 存下、08 还原的 savedConversations）；11-agents 会改 AGENT_IDS，要排在最后。
const sleep = ms => new Promise(r => setTimeout(r, ms));
const {out, check, until, finish} = makeSuite('frontend-modules');
const saved = (id, text) => until(() => lsGet(`${id}_draft`, '') === text, '草稿落盘：' + text);
const quiet = async (count, ms = 700) => { const at = Date.now(), n = count(); while (Date.now() - at < ms) { if (count() !== n) return false; await sleep(25); } return true; };
try {
  const native = postNative, requests = [];
  postNative = (action, data) => { requests.push({action, ...data}); if (action === 'testResize') native(action, data); };
  const type = value => { els.input.value = value; els.input.selectionStart = els.input.selectionEnd = value.length; els.input.dispatchEvent(new Event('input')); };
  const id = active, other = AGENT_IDS.find(a => a !== id);
  //@parts
} catch (e) { out.error = String(e && e.message ? `${e.message}\n${e.stack || ""}` : e); }   // WebKit 里 eval 脚本的 stack 常常只有「@」，消息要单独记
return finish();
