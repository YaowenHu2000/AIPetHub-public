'use strict';

// 第一次打开的引导页：本机找到了哪几位、缺的怎么装，以及默认权限说明（默认最高权限，可以一键改成保守的档）。
// 只在全新安装时出现（还没存过启用名单、也没看过引导）；以后从「添加 AI」菜单最下面能再打开。

const welcome = (() => {
  const el = document.createElement('div');
  el.id = 'welcome';
  el.hidden = true;
  document.body.appendChild(el);
  return el;
})();
let welcomeSafe = false;   // 用户在引导页上选了「保守」

function renderWelcome() {
  const found = ALL_AGENT_IDS.filter(id => agentProbe[id]?.found);
  const probing = ALL_AGENT_IDS.some(id => !agentProbe[id]);
  welcome.innerHTML = `
    <div class="wl-card">
      <div class="wl-title">欢迎使用 AIPetHub</div>
      <div class="wl-sub">AIPetHub 把本机装好的编程智能体放进同一个窗口。它自己不调用模型、不保存凭据，所有对话都交给各家的命令行工具。</div>
      <div class="wl-section">本机的智能体</div>
      <div class="wl-agents"></div>
      <div class="wl-section">权限</div>
      <div class="wl-perm">
        <button class="wl-opt" data-safe="0"><b>最高权限（默认）</b><span>不问你，直接执行命令、读写本机任何文件。用起来最顺，但做错了也不会先停下来。</span></button>
        <button class="wl-opt" data-safe="1"><b>保守一些</b><span>改文件或跑命令前先问你，或者只能改当前工作空间（各家的档位不同）。之后可以在输入框右下角随时换。</span></button>
      </div>
      <div class="wl-foot">
        <button class="confirm-btn wl-recheck">重新检测</button>
        <span class="wl-note"></span>
        <button class="confirm-btn wl-go">开始使用</button>
      </div>
    </div>`;
  const list = welcome.querySelector('.wl-agents');
  ALL_AGENT_IDS.forEach(id => {
    const a = AGENTS[id], p = agentProbe[id], row = document.createElement('div');
    row.className = 'wl-agent' + (p?.found ? ' ok' : '');
    row.innerHTML = `<span class="wl-icon">${ICONS[id]}</span><span class="wl-name"></span><span class="wl-state"></span>`;
    row.querySelector('.wl-name').textContent = `${a.name} · ${a.brand}`;
    row.querySelector('.wl-state').textContent = !p ? '正在找…' : (p.found ? `已找到 ${a.cli}` : '没有装');
    list.appendChild(row);
    if (p && !p.found && a.install) {
      const how = document.createElement('div');
      how.className = 'wl-how';
      if (a.install.cmd) {
        const cmd = document.createElement('button');
        cmd.className = 'wl-cmd';
        cmd.title = '点一下拷贝';
        cmd.textContent = a.install.cmd;
        cmd.addEventListener('click', () => copyText(a.install.cmd, cmd));
        how.appendChild(cmd);
      }
      const text = document.createElement('span');
      text.textContent = a.install.how;
      how.appendChild(text);
      if (a.install.url) {
        const link = document.createElement('a');
        link.textContent = '说明';
        link.href = '#';
        link.addEventListener('click', e => { e.preventDefault(); postNative('openURL', { url: a.install.url }); });
        how.appendChild(link);
      }
      list.appendChild(how);
    }
  });
  welcome.querySelectorAll('.wl-opt').forEach(b => {
    b.classList.toggle('on', (b.dataset.safe === '1') === welcomeSafe);
    b.addEventListener('click', () => { welcomeSafe = b.dataset.safe === '1'; renderWelcome(); });
  });
  welcome.querySelector('.wl-note').textContent = probing ? '' : (found.length ? `会启用找到的 ${found.length} 位` : '一位都没找到：先装上至少一个，再点「重新检测」');
  welcome.querySelector('.wl-recheck').addEventListener('click', () => {
    ALL_AGENT_IDS.forEach(id => delete agentProbe[id]);
    renderWelcome();
    postNative('probeAgents', { agents: ALL_AGENT_IDS });
  });
  welcome.querySelector('.wl-go').addEventListener('click', closeWelcome);
}

function openWelcome() {
  welcomeSafe = ALL_AGENT_IDS.some(id => S[id].perm === AGENTS[id].safePerm && AGENTS[id].safePerm !== AGENTS[id].perm);
  renderWelcome();
  welcome.hidden = false;
  if (ALL_AGENT_IDS.some(id => !agentProbe[id])) postNative('probeAgents', { agents: ALL_AGENT_IDS });
}

function closeWelcome() {
  // 权限：选了「保守」就把每位换到各自的保守档；选「最高」就换回默认
  ALL_AGENT_IDS.forEach(id => {
    const want = welcomeSafe ? AGENTS[id].safePerm : AGENTS[id].perm;
    if (want && S[id].perm !== want) { S[id].perm = want; lsSet(`${id}_perm`, want); }
  });
  renderComposer();
  // 启用名单：找到了几位就用那几位（一位都没找到就先保持原样，界面还看得到）
  const found = ALL_AGENT_IDS.filter(id => agentProbe[id]?.found);
  if (found.length && found.join() !== AGENT_IDS.join()) {
    AGENT_IDS.splice(0, AGENT_IDS.length, ...found);
    if (!AGENT_IDS.includes(active)) setActive(AGENT_IDS[0], false);
    afterAgentsChanged();
    setActive(active, false);
    AGENT_IDS.forEach(id => postNative('listConversations', { agent: id }));
  } else {
    saveEnabledAgents();
  }
  lsSet('welcomed', '1');
  welcome.hidden = true;
}

// 检测结果到了：引导页开着的话刷新一下
const welcomeProbed = window.onAgentsProbed;
window.onAgentsProbed = data => {
  welcomeProbed(data);
  if (!welcome.hidden) renderWelcome();
};
