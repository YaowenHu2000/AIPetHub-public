'use strict';

// 桌宠的作息：去睡觉、睡着时的小动作、每半秒一次的 tick（空闲太久就睡、偶尔眨眼和走动）。

/** 睡觉前先走回卡片中间：离中间很近就直接睡，否则转身走过去，到了再睡 */
Pet.prototype.goToSleep = function () {
  // 打哈欠 / 伸懒腰的过渡帧用到时才加载：还没好就等它好了再去睡（本地文件，很快）
  if (loadNap(this.id) === null) {
    const from = this.state;
    loadNap(this.id, () => { if (this.state === from && !this.dragging && !this.falling && !isBusy(this.id)) this.goToSleep(); });
    return;
  }
  if (Math.abs(this.x) < 6) { this.walkingToBed = false; this.setState('sleep'); return; }
  this.walkingToBed = true;
  this.turn(this.x > 0 ? -1 : 1);
  this.setState('walk');
  this.walking = true;
  ensureWalkLoop();
};

Pet.prototype.toggleSleep = function () {
  this.lastInteraction = Date.now();
  this.demoPhase = null;
  if (this.state === 'sleep') {
    this.setState(this.restingState());
  } else if (!isBusy(this.id)) {
    this.goToSleep();
  } else {
    this.say('正在忙活中，不能睡哦', 1800);
  }
};

/**
 * 睡着时的小动作（呼吸和慢慢的摇晃在 CSS 里一直放着）：
 * 每隔两三秒飘一个小 z；每隔十几秒随机点一下头或蹭一蹭。窗口不在前台时不做（看不见，省电）。
 */
Pet.prototype.sleepTick = function () {
  if (document.hidden) return;
  const now = Date.now();
  // 有 12 帧睡觉循环时，画里的 zZZ 自己在动，不再另外飘小 z
  if (now >= this.nextSleepZ && loadStateLoop(this.id, 'sleep') !== true) {
    this.nextSleepZ = now + 2200 + rand(1600);
    const [fx, fy] = SLEEP_Z_AT[this.id] || [0.84, 0.12];
    const rect = this.walker.getBoundingClientRect();
    const cardRect = this.card.getBoundingClientRect();
    const p = document.createElement('div');
    p.className = 'particle zzz';
    p.textContent = 'z';
    p.style.left = `${rect.left - cardRect.left + rect.width * fx}px`;
    p.style.top = `${rect.top - cardRect.top + rect.height * fy}px`;
    p.style.fontSize = `${10 + rand(5)}px`;
    p.style.setProperty('--dx', `${10 + rand(14)}px`);
    p.style.setProperty('--dy', `${-(22 + rand(14))}px`);
    this.card.appendChild(p);
    setTimeout(() => p.remove(), 2800);
  }
  if (now >= this.nextSleepMove) {
    this.nextSleepMove = now + 10000 + rand(10000);
    const cls = Math.random() < 0.6 ? 'sleep-nod' : 'sleep-nuzzle';
    this.body.classList.remove('sleep-nod', 'sleep-nuzzle');
    void this.body.offsetWidth;   // 同一个动作连着来两次也能重新放
    this.body.classList.add(cls);
  }
};

/** 每 500ms：自动入睡 + 散步节奏 + 干活时的轻量特效粒子。 */
Pet.prototype.tick = function () {
  if (this.dragging || this.falling) return;
  if (this.state === 'sleep') { this.sleepTick(); return; }
  if (this.fastForm && (this.fastTick = ((this.fastTick || 0) + 1) % 3) === 0) this.particles(['⚡'], 1);
  if (this.state === 'working' || this.state === 'reading') {
    this.workFxTick = (this.workFxTick + 1) % (this.state === 'working' ? 4 : 7);
    if (this.workFxTick === 0) {
      const syms = this.state === 'working' ? AGENTS[this.id].workParticles : AGENTS[this.id].readParticles;
      this.particles(syms, 1);
    }
  }
  if (this.demoPhase) return;
  const st = S[this.id];
  const idleSec = (Date.now() - this.lastInteraction) / 1000;
  // 当前选中的那位也会困：在输入框里打字算互动（boot.js），会把她叫醒
  if (st.autoSleep > 0 && idleSec >= st.autoSleep && !isBusy(this.id) &&
      (this.state === 'idle' || this.state === 'walk')) {
    this.goToSleep();
    this.say('困啦…眯一会儿 💤', 2600);
    return;
  }
  if (this.walkingToBed) return;   // 正在走回中间准备睡觉
  if (!st.roam || isBusy(this.id) || this.dockHover) {
    if (this.state === 'walk') this.setState(this.restingState());
    return;
  }
  if (this.state !== 'idle' && this.state !== 'walk') return;
  this.boutTicks += 1;
  if (this.boutTicks < this.boutLimit) return;
  this.boutTicks = 0;
  if (this.state === 'walk') {
    this.boutLimit = 5 + rand(5);
    this.setState('idle');
  } else {
    this.boutLimit = 8 + rand(7);
    if (Math.random() < 0.4) this.dir *= -1;
    this.setState('walk');
    this.walking = true;
    ensureWalkLoop();
  }
};
