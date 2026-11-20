  // 原 agents：本地增删和当前 AI 切换；CLI 的添加验证留在 DeepSeek 套件。
  AGENT_IDS.splice(0, AGENT_IDS.length, 'gemini', 'claude', 'gpt'); afterAgentsChanged(); setActive('claude', false);
  disableAgent('gpt');
  check('移除 AI 同步移除历史区与桌宠', AGENT_IDS.join() === 'gemini,claude' && document.querySelectorAll('.hist-section').length === 2 && document.querySelectorAll('#stage-column .pet-card').length === 2, AGENT_IDS.slice());
  disableAgent('claude');
  check('移除当前 AI 自动切到剩余 AI', active === 'gemini' && document.body.dataset.agent === 'gemini' && !S.gemini.msgEl.hidden && S.claude.msgEl.hidden && S.gpt.msgEl.hidden, active);
  disableAgent('gemini'); check('最后一位不允许移除', AGENT_IDS.join() === 'gemini', AGENT_IDS.slice());
  enableAgent('claude'); enableAgent('gpt');
  check('加回 AI 恢复固定顺序并保存', AGENT_IDS.join() === 'gemini,claude,gpt' && lsGet('enabled_agents') === JSON.stringify(AGENT_IDS), AGENT_IDS.slice());
  check('历史区顺序跟随 AI 名单', [...document.querySelectorAll('.hist-section')].map(x => x.dataset.agent).join() === AGENT_IDS.join(), AGENT_IDS.slice());
