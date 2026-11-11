'use strict';

// 一位桌宠：搭它的画面、换帧和各种循环（工作、睡觉、开心、挣扎）、切换状态。别的行为在 pet-*.js 里，挂在 Pet.prototype 上。

class Pet {
  constructor(id) {
    this.id = id;
    const card = document.getElementById('pet-card-tpl').content.firstElementChild.cloneNode(true);
    card.dataset.agent = id;
    card.querySelector('.pet-icon').innerHTML = ICONS[id];
    card.querySelector('.pet-label').textContent = AGENTS[id].name;
    this.card = card;
    this.floor = card.querySelector('.pet-floor');
    this.walker = card.querySelector('.pet-walker');
    this.body = card.querySelector('.pet-body');
    this.front = card.querySelector('.sprite.front');
    this.back = card.querySelector('.sprite.back');
    this.fastForm = false;   // 这一轮开着 fast：换成 fast 的样子（pet-reactions.js 的 syncFastForm）
    this.bubbleEl = card.querySelector('.pet-bubble');
    this.workBadgeEl = card.querySelector('.pet-work-badge');
    this.workIconEl = card.querySelector('.pwb-icon');
    this.workTextEl = card.querySelector('.pwb-text');
    this.statusEl = card.querySelector('.pet-status');
    this.front.alt = AGENTS[id].name;

    this.state = 'idle';
    this.frameKey = '';
    this.frameUrl = '';
    this.frameToken = 0;
    this.shownUrl = '';   // 真正显示在前层的帧（frameUrl 是最后要求的，可能还在解码）
    this.seqTimers = [];
    this.busyTimer = null;
    this.busyFrame = 0;
    this.demoPhase = null;
    this.walkFrame = 0;
    this.walkClock = 0;
    this.workFxTick = 0;
    this.cachedBounds = null;
    this.resetTimer = null;
    this.bubbleTimer = null;
    this.x = 0;
    this.y = 0;             // <0 表示被拎起来的高度
    this.vy = 0;
    this.dir = -1;          // -1 向左走（原图朝向），+1 向右走（镜像）
    this.walking = false;
    this.dragging = false;
    this.falling = false;
    this.pointer = null;
    this.justDragged = false;
    this.boutTicks = 0;
    this.boutLimit = 10;
    this.dockHover = false;
    this.lastInteraction = Date.now();

    card.addEventListener('click', e => {
      if (e.target.closest('.dock-btn, .card-gear')) return;
      setActive(id);
    });
    this.body.addEventListener('pointerdown', e => this.onPointerDown(e));
    this.body.addEventListener('pointermove', e => this.onPointerMove(e));
    this.body.addEventListener('pointerup', e => this.onPointerUp(e));
    this.body.addEventListener('pointercancel', e => this.onPointerUp(e));
    this.body.addEventListener('click', e => {
      e.stopPropagation();
      if (this.justDragged) { this.justDragged = false; return; }
      // 点她：和这一位开一个不绑定工作空间的新对话（已经停在这样的空白新对话上就不重开），照常摸头
      const st = S[id];
      if (active !== id || st.conversationId || st.workspace || viewBusy(id)) newChat(id, true, '');
      this.headpat();
    });
    card.querySelector('.pet-dock').addEventListener('mouseenter', () => { this.dockHover = true; });
    card.querySelector('.pet-dock').addEventListener('mouseleave', () => { this.dockHover = false; });
    card.querySelectorAll('.dock-btn').forEach(btn => btn.addEventListener('click', e => {
      e.stopPropagation();
      const act = btn.dataset.act;
      if (act === 'roam') this.toggleRoam();
      else if (act === 'sleep') this.toggleSleep();
    }));
    this.statusEl.addEventListener('click', e => {
      if (!isBusy(id)) {
        e.stopPropagation();
        this.cyclePose();
      }
    });
    const gear = card.querySelector('.card-gear');
    gear.innerHTML = UI.gear;
    gear.addEventListener('click', e => { e.stopPropagation(); openPetSettings(id, gear); });

    // 走路的 8 帧预先放好，走路时只切换显示，不再频繁换图片地址
    this.walkImgs = Array.from({ length: WALK_FRAMES }, () => {
      const img = document.createElement('img');
      img.className = 'sprite walk-frame';
      img.alt = '';
      this.body.appendChild(img);
      return img;
    });
    this.loadWalkFrames();
    new ResizeObserver(() => { this.cachedBounds = null; this.clampPosition(); }).observe(this.floor);

    preloadSkin(id, S[id].skin);
    this.setState('idle');
    this.rig = null;   // 骨骼等卡片放到界面上再建（ui/agents.js 的 layoutAgents → attachRig）
    setTimeout(() => setInterval(() => this.blink(), 3600), rand(2400));
  }

  /**
   * 有骨骼模型（web/rig/<id>/）就换成骨骼动画；没有或加载失败就继续用逐帧。
   * 卡片从界面上拿掉时（移除这一位）骨骼会把自己收掉——画布不在页面上它就停；加回来时要重新建一个（ui/agents.js 的 layoutAgents）。
   */
  attachRig() {
    if (this.rig || this.rigLoading || !window.PetRig) return;
    this.rigLoading = true;
    window.PetRig.create(this.id, this.body).then(c => {
      this.rigLoading = false;
      if (!c) return;
      if (!this.card.isConnected) { c.dispose(); return; }   // 加载的这一会儿里又被移除了
      this.rig = c;
      if (this.usesRig()) this.stopBusyLoop();   // 思考、施工还是逐帧：正在放的循环不停
      this.syncRig();
    });
  }

  /** 这一位从界面上拿掉了：收掉骨骼（不收的话 this.rig 还指着一个已经停了的，拖她时逐帧被藏起来、画布又没了，人就不见了）。 */
  detachRig() {
    if (!this.rig) return;
    this.rig.dispose();
    this.rig = null;
    this.body.classList.remove('rigged', 'rig-off');
  }

  frameSrc(key) { return `sprites/${this.id}/${S[this.id].skin}/${key}.${SPRITE_EXT}`; }

  showFrame(key, instant = false, fadeMs = 110) {
    const url = this.frameSrc(key);
    this.frameKey = key;
    if (this.frameUrl === url) return;
    this.frameUrl = url;
    const token = ++this.frameToken;   // 解码期间又换了别的帧：这次作废
    const swap = ok => {
      if (token !== this.frameToken) return;
      if (!ok) { this.frameUrl = this.shownUrl; return; }   // 图坏了：留在当前帧
      const first = !this.shownUrl;   // 还没真正显示过任何帧：没有旧帧可以叠化
      this.shownUrl = url;
      if (instant || first) {
        this.front.style.transition = 'none';
        this.back.style.transition = 'none';
        this.front.src = url;
        this.front.style.opacity = '1';
        this.back.style.opacity = '0';
        return;
      }
      // 叠化时不让角色变透明：以前新帧淡入、旧帧同时淡出，中间两张都只有一半不透明，整个人发虚、一明一暗。
      // 现在旧帧保持完全不透明，新帧在上面淡入；新帧到位后，旧帧只剩新帧没盖住的边角，再很快淡出。
      const outMs = Math.round(fadeMs * 0.6);
      this.back.style.transition = 'none';
      this.back.src = this.front.src;
      this.back.style.opacity = '1';
      this.front.style.transition = 'none';
      this.front.style.opacity = '0';
      this.front.src = url;
      void this.front.offsetWidth;
      requestAnimationFrame(() => {
        if (token !== this.frameToken) return;
        this.front.style.transition = `opacity ${fadeMs}ms ease-out`;
        this.front.style.opacity = '1';
        this.back.style.transition = `opacity ${outMs}ms ease ${fadeMs}ms`;
        this.back.style.opacity = '0';
      });
    };
    if (decodedFrames.has(url)) swap(true); else decodeFrame(url).then(swap);
  }

  clearSeq() {
    this.seqTimers.forEach(clearTimeout);
    this.seqTimers = [];
  }

  stopBusyLoop() {
    clearInterval(this.busyTimer);
    this.busyTimer = null;
  }

  /**
   * 思考 / 查阅 / 施工的循环，按顺序选能用的一套帧：① 12 帧（<动作>_g00…g11）→ ② 原图 4 帧。
   * 一圈的时长都一样（4 × frameMs），帧越多每帧越短。12 帧那套用到时才加载，加载中先停在它的第一帧；缺图才加载、才放原来的 4 帧。
   * busyFrame 记的是一圈里的位置（0–1），换套时接着当前位置放，不会跳回开头。
   */
  /** 进入思考 / 查阅 / 施工时先显示的那一帧：和接下来要放的那套是同一套，换进循环时不会跳一下。 */
  /** 这时候按顺序试哪几套帧：fast 的样子先试 fast 那一套（没画的话还是平时那套）。 */
  loopSets() {
    return this.fastForm ? [FAST_SET, ...LOOP_SETS] : LOOP_SETS;
  }

  loopFirstFrame(phase) {
    for (const set of this.loopSets()) {
      // 还在加载的也算：第一帧先按需解码显示出来，整套好了循环接着放（缺图才退回原来的 4 帧）
      if (loadFrameSet(this.id, phase + set.name, set.keys(phase)) !== false) return set.keys(phase)[0];
    }
    return `${phase}_f0`;
  }

  startBusyLoop(phase, delayMs = 0) {
    if (this.usesRig(phase)) return;
    this.stopBusyLoop();
    const meta = PHASE_META[phase] || PHASE_META.thinking;
    const begin = () => {
      if (this.state !== phase) return;
      const restart = () => { if (this.state === phase) this.startBusyLoop(phase); };
      let keys = null, loading = false, fastArt = false;
      for (const set of this.loopSets()) {
        const ready = loadFrameSet(this.id, phase + set.name, set.keys(phase));
        if (ready === true) { keys = set.keys(phase); fastArt = set === FAST_SET; break; }
        if (ready === null) { loading = true; loadFrameSet(this.id, phase + set.name, set.keys(phase), restart); }
      }
      // 12 帧那套还在加载（本地文件，一眨眼的事）：先停在第一帧，好了再开始放；原来的 4 帧只在缺图时才加载、才用
      if (!keys && loading) return;
      if (!keys) keys = [0, 1, 2, 3].map(i => `${phase}_f${i}`);
      const n = keys.length;
      this.card.classList.toggle('fast-art', fastArt);   // 放的是专门画的 fast 帧（stage.css：这时不再整个人前倾）
      let i = Math.round((this.busyFrame || 0) * n) % n;
      this.stopBusyLoop();   // 同一时间只留一个循环（延时开始的和立即开始的不会叠成两个）
      const id = setInterval(() => {
        if (this.state !== phase || this.busyTimer !== id) { clearInterval(id); if (this.busyTimer === id) this.busyTimer = null; return; }
        i = (i + 1) % n;
        this.busyFrame = i / n;
        this.showFrame(keys[i], true);
      }, (meta.frameMs * 4) / n / (this.fastForm ? FAST_FORM_SPEED : 1));
      this.busyTimer = id;
    };
    if (delayMs > 0) this.seqTimers.push(setTimeout(begin, delayMs));
    else begin();
  }

  /** 睡觉 / 开心的 12 帧循环：这套图用到时才加载，好了才开始放（之前停在原来那一张）；离开这个状态就停。 */
  startStateLoop(state, delayMs = 0) {
    const begin = () => {
      if (this.state !== state) return;
      const ready = loadStateLoop(this.id, state);
      if (ready === null) loadStateLoop(this.id, state, ok => { if (ok && this.state === state && !this.busyTimer) this.startStateLoop(state); });
      if (ready !== true) return;
      const keys = stateLoopKeys(state);
      const { ms, fade } = STATE_LOOP[state];
      this.stopBusyLoop();
      let i = 0;
      this.showFrame(keys[0], !fade, fade || 110);
      const id = setInterval(() => {
        if (this.state !== state || this.busyTimer !== id) { clearInterval(id); if (this.busyTimer === id) this.busyTimer = null; return; }
        if (document.hidden) return;   // 窗口不在前台：停在当前帧
        i = (i + 1) % keys.length;
        this.showFrame(keys[i], !fade, fade || 110);
      }, ms);
      this.busyTimer = id;
    };
    if (delayMs > 0) this.seqTimers.push(setTimeout(begin, delayMs));
    else begin();
  }

  /** 被拖着：有挣扎帧就一直循环（加载中先停在 dragged，好了再开始），没有就停在 dragged 这一张。 */
  startStruggleLoop() {
    if (this.usesRig('dragged')) return;
    this.stopBusyLoop();
    const again = ok => { if (ok && this.state === 'dragged') this.startStruggleLoop(); };
    const r12 = loadStruggle12(this.id);
    if (r12 === null) loadStruggle12(this.id, again);   // 12 帧那套好了再换过去
    const r2 = r12 ? true : loadStruggle(this.id);
    if (!r12 && r2 === null) { loadStruggle(this.id, ok => { if (!this.busyTimer) again(ok); }); return; }
    if (!r12 && !r2) return;
    const { keys, ms } = r12 ? struggleOrder(this.id) : { keys: STRUGGLE_KEYS, ms: STRUGGLE_MS * 2 };
    let i = 0;
    this.showFrame(keys[0], true);
    this.busyTimer = setInterval(() => {
      if (this.state !== 'dragged') { this.stopBusyLoop(); return; }
      i = (i + 1) % keys.length;
      this.showFrame(keys[i], true);
    }, ms);
  }

  play(frames) {
    this.clearSeq();
    let elapsed = 0;
    frames.forEach(([key, delay, instant, fadeMs]) => {
      this.seqTimers.push(setTimeout(() => this.showFrame(key, !!instant, fadeMs || 110), elapsed));
      elapsed += delay;
    });
    this.seqUntil = Date.now() + elapsed;
  }

  restingState() {
    const info = busyInfo(this.id);
    if (info) return info.phase;
    return this.demoPhase || 'idle';
  }

  setState(state, durationMs = 0) {
    if (state !== 'walk' && state !== 'sleep') this.walkingToBed = false;
    clearTimeout(this.resetTimer);
    this.resetTimer = null;
    const prev = this.state;
    this.state = state;
    this.clearSeq();
    this.stopBusyLoop();
    if (state !== 'walk') this.walking = false;
    const isBusyPhase = BUSY_STATES.has(state);
    const wasBusyPhase = BUSY_STATES.has(prev);
    // 思考 / 查阅 / 施工之间切换不再弹一下：这几个动作里角色整体不动，只有手和道具在动
    this.body.className = `pet-body anim-${state}` + (this.dir > 0 && (state === 'walk' || state === 'idle') ? ' flip' : '')
      + (state === 'walk' ? ' walking' : '');

    const targetFrame = state === 'walk' ? 'walk_f0' : (isBusyPhase ? this.loopFirstFrame(state) : state);
    const nap = loadNap(this.id) === true;   // 有打哈欠 / 伸懒腰的过渡帧
    this.rigHoldUntil = 0;

    if (state === 'sleep' && prev !== 'sleep') {
      // 入睡：打个哈欠（张嘴 → 张到最大 → 合上），蹲下，睡着
      this.play(nap
        ? [['idle_blink_half', 95, true], ['yawn_0', 240], ['yawn_1', 620], ['yawn_0', 230], ['crouch', 170], ['sleep', 0]]
        : [['idle_blink_half', 95, true], ['crouch', 160], ['sleep', 0]]);
      const now = Date.now();
      this.startStateLoop('sleep', this.seqUntil - now + 500);
      this.nextSleepZ = now + 1600;
      this.nextSleepMove = now + 7000 + rand(6000);
    } else if (state === 'idle' && prev === 'sleep' && nap) {
      // 自己醒来回到待机：揉揉眼睛、伸个懒腰再站好。这一段是逐帧画的，放完之前骨骼画布先不出来、也不镜像
      this.play([['crouch', 150], ['wake_0', 430], ['wake_1', 560], ['idle_blink_half', 95], ['idle', 0]]);
      const ms = this.seqUntil - Date.now();
      this.rigHoldUntil = this.seqUntil;
      this.body.classList.remove('flip');
      this.seqTimers.push(setTimeout(() => {
        this.rigHoldUntil = 0;
        this.body.classList.toggle('flip', this.dir > 0);
        this.syncRig();
      }, ms + 20));
    } else if (state !== 'sleep' && prev === 'sleep') {
      // 被叫起来干活、被拎起来：不磨蹭，直接起身
      this.play([['crouch', 150], ['idle_blink_half', 95], [targetFrame, 0]]);
      if (state === 'happy') this.startStateLoop('happy', 260);
      if (isBusyPhase) { this.busyFrame = 0; this.startBusyLoop(state, 260); }
      // 睡着时被拎起来：醒过来以后再开始挣扎
      if (state === 'dragged') this.seqTimers.push(setTimeout(() => { if (this.state === 'dragged') this.startStruggleLoop(); }, 260));
    } else if (prev === 'dragged' && state !== 'dragged') {
      this.play([['crouch', 130, true], [targetFrame, 0]]);
      if (isBusyPhase) { this.busyFrame = 0; this.startBusyLoop(state, 150); }
    } else if (state === 'happy') {
      this.play([['idle_blink_half', 70, true], ['happy', 0]]);
      this.startStateLoop('happy', 80);
    } else if (state === 'walk') {
      this.walkFrame = 0;
      this.walkClock = 0;
      this.showWalkFrame(0);
    } else if (isBusyPhase) {
      this.busyFrame = 0;
      if (prev === 'idle') {
        // 从空闲切入思考/查阅/施工：先眨眼过渡帧再柔滑切入补帧序列
        this.play([['idle_blink_half', 75, true], [targetFrame, 0, false, 140]]);
        this.startBusyLoop(state, 120);
      } else {
        // 思考 ↔ 查阅 ↔ 施工 之间切换：柔和补帧叠化 + 4 帧丝滑循环
        this.showFrame(targetFrame, false, 155);
        this.startBusyLoop(state, 90);
      }
    } else if (state === 'dragged') {
      // 一拎起来就进挣扎循环；12 帧那套还没加载好时先停在原来那张 dragged
      if (loadStruggle12(this.id) !== true) this.showFrame('dragged', true);
      this.startStruggleLoop();
    } else if (wasBusyPhase && state === 'idle') {
      // 从忙碌回归空闲：眨眼过渡帧平滑收尾
      this.play([['idle_blink_half', 75, true], ['idle', 0, false, 130]]);
    } else {
      this.showFrame(state);
    }

    if (durationMs > 0) this.resetTimer = setTimeout(() => this.setState(this.restingState()), durationMs);
    this.syncRig();
    this.renderStatus();
  }

  /**
   * 哪些状态用骨骼：待机、查阅、拖拽、走路、开心用骨骼动画；
   * 思考、施工用 AI 逐帧（这两个逐帧版更好看）；睡觉播原来的睡觉素材（比如极其猫抱着尾巴睡）。
   */
  usesRig(state = this.state) { return !!this.rig && !RIG_OFF_STATES.has(state); }

  syncRig() {
    if (!this.rig) return;
    this.rig.setState(this.state);
    this.body.classList.add('rigged');   // setState 会整个重写 className，这里补回来
    this.body.classList.toggle('rig-off', !this.usesRig() || Date.now() < (this.rigHoldUntil || 0));
  }

  blink() {
    if (this.usesRig('idle')) return;   // 骨骼版自己眨眼
    if (this.state !== 'idle' || Date.now() < (this.seqUntil || 0)) return;
    this.play([['idle_blink_half', 65, true], ['idle_blink_closed', 95, true], ['idle_blink_half', 65, true], ['idle', 0, true]]);
  }

  /** 给骨骼版的心情推一把（见 web/rig/src/mood.js）：表情跟着心情慢慢变，不是直接换 */
  moodEvent(name) { if (this.rig) this.rig.event(name); }
}
