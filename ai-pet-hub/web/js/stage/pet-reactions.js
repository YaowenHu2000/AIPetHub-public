'use strict';

// 桌宠的反应：说话气泡、粒子、被点和摸头、跟着回答的进度换动作、庆祝、状态胶囊、换皮肤。

/**
 * 把头顶的气泡 / 工作标签水平居中，左边落在整像素上。
 * 用 left: 50% 加 translate(-50%) 居中的话，宽度不是偶数时左边会落在半个、四分之一个像素上，字就发虚。
 */
Pet.prototype.centerOnFloor = function (el) {
  const floor = el.offsetParent;
  if (!floor) return;
  // 以她现在的位置为中心（她在卡片正中时 x = 0）；靠边时停在卡片里，不伸出去
  const w = el.offsetWidth, room = floor.clientWidth;
  const left = Math.max(6, Math.min(room - w - 6, (room - w) / 2 + (this.x || 0)));
  el.style.left = `${Math.round(left)}px`;
};

Pet.prototype.say = function (text, ms = 2000) {
  if (this.rig) this.rig.talk(Math.min(ms, 2200));
  this.bubbleEl.textContent = text;
  this.centerOnFloor(this.bubbleEl);
  this.bubbleEl.classList.add('show');
  this.card.classList.add('speaking');
  clearTimeout(this.bubbleTimer);
  this.bubbleTimer = setTimeout(() => {
    this.bubbleEl.classList.remove('show');
    this.card.classList.remove('speaking');
  }, ms);
};

Pet.prototype.particles = function (symbols, count = 5) {
  const rect = this.walker.getBoundingClientRect();
  const cardRect = this.card.getBoundingClientRect();
  const cx = rect.left - cardRect.left + rect.width / 2;
  const cy = rect.top - cardRect.top + rect.height * 0.3;
  for (let i = 0; i < count; i++) {
    const p = document.createElement('div');
    p.className = 'particle';
    p.textContent = symbols[rand(symbols.length)];
    p.style.left = `${cx + (Math.random() - 0.5) * 60}px`;
    p.style.top = `${cy + (Math.random() - 0.5) * 30}px`;
    p.style.setProperty('--dx', `${(Math.random() - 0.5) * 90}px`);
    p.style.setProperty('--dy', `${-(35 + Math.random() * 55)}px`);
    this.card.appendChild(p);
    setTimeout(() => p.remove(), 900);
  }
};

Pet.prototype.touch = function () {
  this.lastInteraction = Date.now();
  if (this.state === 'sleep') {
    this.setState(this.restingState());
    this.moodEvent('wake');
    this.say('醒啦 ✨', 1800);
  }
};

Pet.prototype.headpat = function () {
  if (this.state === 'sleep') { this.touch(); return; }
  this.lastInteraction = Date.now();
  this.moodEvent('pat');
  this.setState('happy', 2200);
  const lines = AGENTS[this.id].clickLines;
  this.say(lines[rand(lines.length)], 2000);
  this.particles(AGENTS[this.id].particles);
};

Pet.prototype.syncBusyState = function () {
  const info = busyInfo(this.id);
  if (info) this.demoPhase = null;
  if (!this.dragging && !this.falling) {
    if (info) {
      if (this.state !== info.phase && this.state !== 'happy') {
        const prev = this.state;
        this.setState(info.phase);
        if (BUSY_STATES.has(prev) && info.phase === 'working') {
          this.particles(AGENTS[this.id].workParticles, 2);
        } else if (BUSY_STATES.has(prev) && info.phase === 'reading') {
          this.particles(AGENTS[this.id].readParticles, 2);
        }
      }
    } else if (this.demoPhase) {
      if (this.state !== this.demoPhase) this.setState(this.demoPhase);
    } else if (BUSY_STATES.has(this.state)) {
      this.setState('idle');
    }
  }
  this.renderStatus();
};

Pet.prototype.setBusy = function (busy) {
  this.lastInteraction = Date.now();
  if (busy) this.demoPhase = null;
  const wasBusy = BUSY_STATES.has(this.state);
  if (this.dragging || this.falling) {
    // 落地时会按 restingState() 进入思考/查阅/施工或空闲
  } else if (busy) {
    const info = busyInfo(this.id);
    const nextPhase = info ? info.phase : 'thinking';
    if (this.state !== nextPhase) this.setState(nextPhase);
    if (!wasBusy) this.say(AGENTS[this.id].thinkLine, 2200);
  } else if (wasBusy && !this.demoPhase) {
    this.setState('idle');
  }
  this.renderStatus();
};

Pet.prototype.cyclePose = function () {
  if (isBusy(this.id)) {
    this.say('正在忙活中，动作随实时步骤自动切换哟 ✨', 1800);
    return;
  }
  this.lastInteraction = Date.now();
  const order = [null, 'thinking', 'reading', 'working'];
  const idx = order.indexOf(this.demoPhase);
  const next = order[(idx + 1) % order.length];
  this.demoPhase = next;
  if (next) {
    this.setState(next);
    if (next === 'thinking') this.particles(AGENTS[this.id].particles, 3);
    else if (next === 'reading') this.particles(AGENTS[this.id].readParticles, 3);
    else if (next === 'working') this.particles(AGENTS[this.id].workParticles, 4);
  } else {
    this.setState('idle');
  }
};

Pet.prototype.celebrate = function () {
  this.moodEvent('reply');
  if (this.dragging || this.falling) { this.say(AGENTS[this.id].doneLine, 1800); return; }
  this.setState('happy', 2600);
  this.say(AGENTS[this.id].doneLine, 1800);
  this.particles(['✦', '✨', '💡']);
};

/** fast 时动作快多少（不只是加速：换成专门画的 fast 那一套帧，见 sprites.js 的 FAST_SET 和 stage.css 的 .fast-form）。 */
const FAST_FORM_SPEED = 1.3;

/**
 * fast 的样子：这一轮开着 fast、正在思考 / 查阅 / 施工时换上（点右上角预览动作时，fast 开着也按这个样子预览）。
 * 换成专门画的那一套：高马尾被风吹向身后、闪电发夹、眼神更锐利，手上的动作也更猛；
 * 另外离地悬着小幅冲刺，背后有横向的速度线，光晕变成电光的黄色，时不时冒 ⚡。
 */
Pet.prototype.syncFastForm = function (info) {
  const on = BUSY_STATES.has(this.state) && !this.dragging && !this.falling
    && (info ? info.fast : (!!this.demoPhase && fastOn(this.id)));
  if (on === this.fastForm) return;
  this.fastForm = on;
  this.card.classList.toggle('fast-form', on);
  if (!on) this.card.classList.remove('fast-art');
  if (on) this.particles(['⚡', '⚡', '✦'], 4);
  if (BUSY_STATES.has(this.state)) this.startBusyLoop(this.state);   // 循环按新的快慢重新排
};

Pet.prototype.renderStatus = function () {
  const st = S[this.id];
  const info = busyInfo(this.id);
  this.syncFastForm(info);
  let text = '空闲';
  let cls = '';
  if (info) {
    const meta = info.meta;
    const label = info.kind === 'text' ? '回答中' : meta.label;
    text = `${info.fast ? '⚡ ' : ''}${meta.icon} ${label} ${elapsedSince(info.since)}${info.count > 1 ? ` · ${info.count} 个会话` : ''}`;
    cls = `busy phase-${info.phase}`;
    this.card.dataset.phase = info.phase;
    if (this.workBadgeEl) {
      this.workBadgeEl.hidden = false;
      this.workBadgeEl.dataset.phase = info.phase;
      this.workIconEl.textContent = info.icon;
      this.workTextEl.textContent = info.title;
    }
  } else if (this.demoPhase) {
    const meta = PHASE_META[this.demoPhase] || PHASE_META.thinking;
    const demoTitles = {
      thinking: '深度思考构思中',
      reading: '翻阅检索代码资料',
      working: '飞速敲码施工中',
    };
    text = `${this.fastForm ? '⚡ ' : ''}${meta.icon} ${meta.label} · 预览`;
    cls = `busy phase-${this.demoPhase}`;
    this.card.dataset.phase = this.demoPhase;
    if (this.workBadgeEl) {
      this.workBadgeEl.hidden = false;
      this.workBadgeEl.dataset.phase = this.demoPhase;
      this.workIconEl.textContent = meta.icon;
      this.workTextEl.textContent = demoTitles[this.demoPhase] || meta.workLabel;
    }
  } else {
    delete this.card.dataset.phase;
    if (this.workBadgeEl) {
      this.workBadgeEl.hidden = true;
      delete this.workBadgeEl.dataset.phase;
    }
    if (st.unread) { text = '有新回复'; cls = 'unread'; }
    else if (this.state === 'sleep') text = '睡觉中';
    else if (st.roam) text = '散步中';
  }
  this.statusEl.textContent = text;
  this.statusEl.className = `pet-status ${cls}`.trim();
  if (this.workBadgeEl && !this.workBadgeEl.hidden) this.centerOnFloor(this.workBadgeEl);
  this.card.querySelector('[data-act="roam"]').classList.toggle('on', st.roam && !this.demoPhase);
  this.card.querySelector('[data-act="sleep"]').classList.toggle('on', this.state === 'sleep');
};

Pet.prototype.applySkin = function () {
  preloadSkin(this.id, S[this.id].skin);
  this.loadWalkFrames();
  const key = this.frameKey || 'idle';
  this.frameUrl = '';
  this.showFrame(key, true);
};
