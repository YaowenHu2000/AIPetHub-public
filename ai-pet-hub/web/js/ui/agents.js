'use strict';

// 选用哪几位 AI：可以从界面上移除一位（桌宠卡片右上角的齿轮），也可以再加回来（桌宠那一列最下面的「＋」）。
//   · 移除只是不放在界面上：它的会话记录、设置都不动，加回来和原来一样。
//   · 添加之前先看本机装没装它的命令行工具，再真的给它发一句话；答得上来才加（装了但没登录、额度用完、网络不通，都在这一步露出来）。
//     验证不过也可以「仍然添加」。
//   · 增删之后左栏的分区、桌宠那一列、⌘1…⌘4 都跟着变。
//   · 第一次打开（还没存过名单）：自动找本机装了哪些，只启用找到的。

const agentProbe = {};      // id → { found, path }：本机装没装（原生查的）
const agentVerify = {};     // id → { state: 'running' | 'failed', error }：添加时的验证
const disabledAgents = () => ALL_AGENT_IDS.filter(id => !AGENT_IDS.includes(id));

/** 最下面的「＋」：还有没启用的才出现。 */
const addSlot = (() => {
  const btn = document.createElement('button');
  btn.className = 'pet-add';
  btn.title = '添加一位 AI';
  btn.innerHTML = `${UI.plus || '+'}<span>添加 AI</span>`;
  btn.addEventListener('click', e => { e.stopPropagation(); openAddAgentMenu(btn); });
  return btn;
})();

/** 按现在的启用名单把界面排一遍：左栏的分区和分隔条、桌宠那一列。 */
function layoutAgents() {
  els.sections.innerHTML = '';
  AGENT_IDS.forEach((id, i) => {
    if (i > 0) els.sections.appendChild(buildSplitter(i - 1));
    els.sections.appendChild(buildHistorySection(id));
  });
  if (sectionWeights.length !== AGENT_IDS.length) sectionWeights = AGENT_IDS.map(() => 1);
  ALL_AGENT_IDS.forEach(id => {
    if (AGENT_IDS.includes(id)) return;
    pets[id].detachRig();
    pets[id].card.remove();
    S[id].msgEl.hidden = true;
  });
  AGENT_IDS.forEach(id => { els.stage.appendChild(pets[id].card); pets[id].attachRig(); });
  els.stage.appendChild(addSlot);
  addSlot.classList.toggle('none-left', !disabledAgents().length);
  document.body.dataset.agents = String(AGENT_IDS.length);
  applySectionWeights();
  postNative('setEnabledAgents', { agents: AGENT_IDS });
}

function saveEnabledAgents() { lsSet('enabled_agents', JSON.stringify(AGENT_IDS)); }

/** 增删之后：重排、重画、桌宠回到卡片里。 */
function afterAgentsChanged() {
  saveEnabledAgents();
  lsSet('section_weights', '');
  layoutAgents();
  renderAllHistory();
  applyWidths();
  queueSectionFit();
}

function enableAgent(id) {
  if (!AGENTS[id] || AGENT_IDS.includes(id)) return;
  // 按「全部支持的」里的顺序插进去，位置固定，不看添加的先后
  const at = AGENT_IDS.filter(a => ALL_AGENT_IDS.indexOf(a) < ALL_AGENT_IDS.indexOf(id)).length;
  AGENT_IDS.splice(at, 0, id);
  afterAgentsChanged();
  postNative('listConversations', { agent: id });
  if (S[id].conversationId) postNative('loadConversation', { agent: id, conversationId: S[id].conversationId });
  setActive(id);
}

function disableAgent(id) {
  if (!AGENT_IDS.includes(id)) return;
  if (AGENT_IDS.length <= 1) { pets[id].say('至少要留一位呀', 1800); return; }
  if (isBusy(id)) { pets[id].say('我还在回答，等答完再移除吧', 2200); return; }
  closePopover();
  AGENT_IDS.splice(AGENT_IDS.indexOf(id), 1);
  if (active === id) setActive(AGENT_IDS[0], false);
  afterAgentsChanged();
  setActive(active, false);
}

// ===== 「添加 AI」菜单 =====
function addAgentStatus(id) {
  const v = agentVerify[id], p = agentProbe[id];
  if (v && v.state === 'running') return '正在验证：给它发一句话，等它回答…';
  if (v && v.state === 'failed') return `没验证通过：${v.error}。再点一次仍然添加`;
  if (!p) return '正在找它的命令行工具…';
  return p.found ? `已找到 ${AGENTS[id].cli}，点一下验证并添加` : `没找到 ${AGENTS[id].cli}，装好后再来添加`;
}

function openAddAgentMenu(anchor) {
  postNative('probeAgents', { agents: disabledAgents() });
  openPopover(anchor, () => [{
    title: '添加一位 AI',
    items: [...disabledAgents().map(id => ({
      name: `${AGENTS[id].name} · ${AGENTS[id].brand}`, desc: addAgentStatus(id), stay: true,
      onPick: () => {
        const v = agentVerify[id];
        if (v && v.state === 'running') return;
        if (v && v.state === 'failed') { delete agentVerify[id]; closePopover(); enableAgent(id); return; }   // 仍然添加
        if (agentProbe[id] && !agentProbe[id].found) return;
        agentVerify[id] = { state: 'running' };
        postNative('verifyAgent', { agent: id });
        refreshAddAgentMenu();
      },
    })), { name: '安装说明和权限…', desc: '再看一遍第一次打开时的引导页', onPick: () => openWelcome() }],
  }], { placement: 'top', keepOpen: true });
}

function refreshAddAgentMenu() {
  if (pop && pop.anchor === addSlot) { renderPopover(); positionPopover(); }
}

window.onAgentsProbed = data => {
  (data.items || []).forEach(it => { agentProbe[it.agent] = { found: !!it.found, path: it.path || '' }; });
  // 第一次打开：还没存过名单，只启用本机找得到的（一位都没找到就保持默认，让人看得到界面）
  if (!lsGet('enabled_agents') && (typeof welcome === 'undefined' || welcome.hidden)) {
    const found = ALL_AGENT_IDS.filter(id => agentProbe[id] && agentProbe[id].found && AGENTS[id].ready !== false);
    const probedAll = ALL_AGENT_IDS.every(id => agentProbe[id]);
    if (probedAll) {
      if (found.length && found.join() !== AGENT_IDS.join()) {
        AGENT_IDS.splice(0, AGENT_IDS.length, ...found);
        if (!AGENT_IDS.includes(active)) setActive(AGENT_IDS[0], false);
        afterAgentsChanged();
        setActive(active, false);
        AGENT_IDS.forEach(id => postNative('listConversations', { agent: id }));
      } else {
        saveEnabledAgents();
      }
    }
  }
  refreshAddAgentMenu();
};

window.onAgentVerified = data => {
  const id = data.agent;
  if (!AGENTS[id]) return;
  if (data.ok) {
    delete agentVerify[id];
    if (pop && pop.anchor === addSlot) closePopover();
    enableAgent(id);
    pets[id].say(`验证通过，用了 ${Math.max(1, Math.round(data.seconds || 0))} 秒～`, 2600);
  } else {
    agentVerify[id] = { state: 'failed', error: String(data.error || '没有答复').replace(/\s+/g, ' ').slice(0, 120) };
    refreshAddAgentMenu();
  }
};
