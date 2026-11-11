'use strict';

// 内置浏览器标签：地址栏、前进后退、和原生那边的浏览器视图对齐位置。

// ---------- 内置浏览器：预览本地网页、开发服务器（localhost） ----------
// 网页由原生的另一个 WKWebView 显示，盖在 .browser-host 占位区域上；这里负责地址栏、按钮和位置同步。
const browser = { url: '', title: '', file: '', canGoBack: false, canGoForward: false, loading: false, error: false, slow: false };

/** 本地开发服务器的网址：在内置浏览器里打开（其他网址仍用系统浏览器，那里有你的登录状态）。 */
function isLocalURL(u) {
  try {
    const h = new URL(u).hostname;
    return /^(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])$/i.test(h) || h.endsWith('.localhost') || h.endsWith('.local');
  } catch (_) { return false; }
}

/** 回答、文档里的网址链接：本地的进内置浏览器，其他交给系统浏览器。 */
function openLink(url) {
  if (!hasBridge()) { window.open(url); return; }
  if (isLocalURL(url)) openBrowser(url); else postNative('openURL', { url });
}

const browserTab = () => pane.tabs.find(t => t.kind === 'browser');

/** 在内置浏览器里打开网址或本地文件（base 是相对路径的起点）；什么都不给就只打开并聚焦地址栏。 */
function openBrowser(target = '', base = '') {
  let tab = browserTab();
  if (!tab) {
    tab = { id: ++pane.seq, kind: 'browser', raw: '网页预览' };
    pane.tabs.push(tab);
    if (pane.tabs.length > 8) pane.tabs.splice(pane.tabs.findIndex(t => t !== tab), 1);
  }
  pane.active = tab.id;
  setPaneVisible(true);
  renderPaneTabs();
  renderPaneBody();
  if (target) navigateBrowser(target, base);
  else pane.el.querySelector('.browser-url')?.focus();
}

function navigateBrowser(input, base = '') {
  let t = String(input || '').trim();
  if (!t) return;
  const at = { ...browserRect(), visible: true };
  if (/^https?:\/\//i.test(t)) { postNative('browserOpen', { url: t, ...at }); return; }
  if (/^file:\/\//i.test(t) || t.startsWith('/') || t.startsWith('~/') || /\.(html?|svg)$/i.test(t) || BROWSER_DOC_RE.test(t)) {
    postNative('browserOpen', { path: t, base, ...at });
    return;
  }
  if (/^\d{2,5}$/.test(t)) t = `localhost:${t}`;   // 只填了端口
  const url = (/^(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])/i.test(t) ? 'http://' : 'https://') + t;
  postNative('browserOpen', { url, ...at });
}

function browserRect() {
  const host = pane.el.querySelector('.browser-host');
  if (!host) return { x: 0, y: 0, w: 0, h: 0 };
  const r = host.getBoundingClientRect();
  return { x: r.left, y: r.top, w: r.width, h: r.height };
}

/** 原生浏览器摆到占位区域上；面板没开、不是浏览器标签、有弹出菜单时藏起来（原生视图会盖住界面上的菜单）。 */
function syncBrowser() {
  if (!hasBridge()) return;
  const tab = activeTab();
  // 文档转换超过一会儿（slow）时也先藏起来，露出下面的「正在生成预览」；看对话里的图片时也藏起来
  const show = !pane.el.hidden && tab && tab.kind === 'browser' && !browser.slow && !(typeof pop !== 'undefined' && pop)
    && !(typeof imageViewer !== 'undefined' && imageViewer);
  postNative('browserRect', show ? { ...browserRect(), visible: true } : { visible: false });
}

const browserResize = new ResizeObserver(() => syncBrowser());

function renderBrowser(bar, body) {
  body.classList.add('browser-mode');
  const cmd = (icon, title, name) => toolButton(icon, title, () => postNative('browserCommand', { cmd: name }));
  const back = cmd(UI.chevron, '后退', 'back');
  back.classList.add('browser-back', 'flip-h');
  const fwd = cmd(UI.chevron, '前进', 'forward');
  fwd.classList.add('browser-fwd');
  back.disabled = !browser.canGoBack;
  fwd.disabled = !browser.canGoForward;
  const reload = toolButton(browser.loading ? UI.close : UI.refresh, browser.loading ? '停止' : '刷新',
    () => postNative('browserCommand', { cmd: browser.loading ? 'stop' : 'reload' }));
  reload.classList.add('browser-reload');
  const input = document.createElement('input');
  input.className = 'browser-url';
  input.placeholder = '网址或端口：localhost:5173、3000、/路径/index.html';
  input.value = browserAddress();
  input.spellcheck = false;
  input.addEventListener('keydown', e => {
    if (e.key !== 'Enter' || e.isComposing) return;
    e.preventDefault();
    navigateBrowser(input.value, (S[active] && S[active].workspace) || '');
    input.blur();
  });
  const ext = cmd(UI.external, browser.file ? '用默认应用打开' : '在系统浏览器中打开', 'external');
  ext.classList.add('browser-ext');
  bar.append(back, fwd, reload, input, ext);
  const host = document.createElement('div');
  host.className = 'browser-host';
  if (browser.slow) host.innerHTML = '<div class="browser-empty browser-wait">正在生成预览…</div>';
  else if (!browser.url) host.innerHTML = '<div class="browser-empty browser-hint">在上面输入网址；回答里的本地链接（localhost）、HTML 文件的「在内置浏览器中预览」，以及 PDF、Word、Excel、PPT 也会在这里打开</div>';
  body.appendChild(host);
  browserResize.disconnect();
  browserResize.observe(host);
}

/** 地址栏显示的内容：本地文件显示路径（~/…），网页显示网址。 */
function browserAddress() {
  if (browser.file) return prettyPath(browser.file);
  return browser.url && browser.url !== 'about:blank' ? browser.url : '';
}

window.onBrowserState = data => {
  const wasSlow = browser.slow;
  Object.assign(browser, { file: '', slow: false }, data);
  const tab = browserTab();
  if (tab) {
    tab.title = data.title || (data.file ? baseName(data.file) : data.url ? data.url.replace(/^https?:\/\//, '') : '网页预览');
    renderPaneTabs();
  }
  if (activeTab() === tab) updatePaneActions();
  const input = pane.el.querySelector('.browser-url');
  if (input && document.activeElement !== input) input.value = browserAddress();
  const back = pane.el.querySelector('.browser-back');
  const fwd = pane.el.querySelector('.browser-fwd');
  const reload = pane.el.querySelector('.browser-reload');
  if (back) back.disabled = !data.canGoBack;
  if (fwd) fwd.disabled = !data.canGoForward;
  if (reload) { reload.innerHTML = data.loading ? UI.close : UI.refresh; reload.title = data.loading ? '停止' : '刷新'; }
  if (data.url) pane.el.querySelector('.browser-hint')?.remove();
  if (browser.slow !== wasSlow) {   // 转换慢：盖上「正在生成预览」；好了再露出浏览器
    const host = pane.el.querySelector('.browser-host');
    host?.querySelector('.browser-wait')?.remove();
    if (host && browser.slow) host.insertAdjacentHTML('beforeend', '<div class="browser-empty browser-wait">正在生成预览…</div>');
    syncBrowser();
  }
};

// ---------- 面板上的按钮 ----------
(() => {
  postNative('browserRect', { visible: false });
  const el = pane.el;
  const q = sel => el.querySelector(sel);
  q('.ed-reveal').innerHTML = UI.reveal;
  q('.ed-open').innerHTML = UI.external;
  q('.ed-max').innerHTML = UI.expand;
  q('.ed-close').innerHTML = UI.close;
  q('.ed-reveal').addEventListener('click', () => { const f = paneTarget(activeTab()); if (f) postNative('revealFile', f); });
  q('.ed-open').addEventListener('click', () => {
    const t = activeTab();
    if (t && t.kind === 'browser' && !browser.file) { postNative('browserCommand', { cmd: 'external' }); return; }   // 网页：系统浏览器
    const f = paneTarget(t);
    if (f) postNative('openFile', f);
  });
  q('.ed-max').addEventListener('click', () => { document.body.classList.toggle('preview-max'); applyWidths(); });
  q('.ed-close').addEventListener('click', closePreview);
  // 预览里的链接：文件标签在面板里打开（相对路径按当前文件所在目录算），网址用浏览器打开
  q('.ed-body').addEventListener('click', e => {
    const chip = e.target.closest('.file-chip');
    if (chip) { const t = activeTab(); openPreview({ path: chip.dataset.path, base: t ? dirOf(t.resolved || t.raw) : '' }); return; }
    const link = e.target.closest('.ext-link');
    if (link) openLink(link.dataset.url);
  });
})();
