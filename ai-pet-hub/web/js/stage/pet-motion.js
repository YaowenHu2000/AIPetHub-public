'use strict';

// 桌宠的移动：朝向、活动范围、走路的帧、拖拽、落地、散步。

Pet.prototype.turn = function (dir) {
  this.dir = dir;
  this.body.classList.toggle('flip', dir > 0 && (this.state === 'walk' || this.state === 'idle'));
};

/** 只能在自己的卡片里活动：左右到地板边缘，往上最多拎到卡片顶部。 */
Pet.prototype.bounds = function () {
  if (this.cachedBounds) return this.cachedBounds;
  const spriteW = this.walker.offsetWidth;
  const spriteH = this.walker.offsetHeight;
  const b = {
    spriteW,
    maxX: Math.max(0, (this.floor.clientWidth - spriteW) / 2 - 4),
    maxLift: Math.max(0, this.floor.offsetTop + this.floor.clientHeight - 2 - spriteH),
  };
  if (spriteW > 0) this.cachedBounds = b;   // 尺寸缓存起来，卡片大小变化时（ResizeObserver）再重算
  return b;
};

/** 只改这一个元素的 transform（走 GPU 合成），不触发整张卡片重新计算样式。 */
Pet.prototype.applyPosition = function () {
  this.walker.style.transform = `translate3d(calc(-50% + ${this.x.toFixed(2)}px), ${this.y.toFixed(2)}px, 0)`;
  // 头顶的气泡和工作徽标跟着她走（在显示着的时候才量、才挪）
  if (this.bubbleEl.classList.contains('show')) this.centerOnFloor(this.bubbleEl);
  if (this.workBadgeEl && !this.workBadgeEl.hidden) this.centerOnFloor(this.workBadgeEl);
};

Pet.prototype.loadWalkFrames = function () {
  const skin = S[this.id].skin;
  this.walkImgs.forEach((img, i) => { img.src = `sprites/${this.id}/${skin}/walk_f${i}.${SPRITE_EXT}`; });
};

Pet.prototype.showWalkFrame = function (i) {
  if (this.shownWalkImg) this.shownWalkImg.classList.remove('on');
  this.shownWalkImg = this.walkImgs[i];
  this.shownWalkImg.classList.add('on');
};

/** 舞台变窄后把她拉回卡片内。 */
Pet.prototype.clampPosition = function () {
  const { maxX } = this.bounds();
  this.x = clamp(this.x, -maxX, maxX);
  this.applyPosition();
};

Pet.prototype.onPointerDown = function (e) {
  if (e.button !== 0) return;
  this.pointer = { id: e.pointerId, startX: e.clientX, startY: e.clientY, x0: this.x, y0: this.y };
  try { this.body.setPointerCapture(e.pointerId); } catch (_) { /* 拿不到捕获时照样能拖，只是鼠标移出卡片会停 */ }
};

Pet.prototype.onPointerMove = function (e) {
  const p = this.pointer;
  if (!p || e.pointerId !== p.id) return;
  const dx = e.clientX - p.startX;
  const dy = e.clientY - p.startY;
  if (!this.dragging) {
    if (Math.hypot(dx, dy) < 4) return;
    this.startDrag();
  }
  const { maxX, maxLift } = this.bounds();
  const nx = Math.max(-maxX, Math.min(maxX, p.x0 + dx));
  if (this.rig) this.rig.dragMove(nx - this.x);
  this.x = nx;
  this.y = Math.max(-maxLift, Math.min(0, p.y0 + dy));
  this.applyPosition();
};

Pet.prototype.onPointerUp = function (e) {
  const p = this.pointer;
  if (!p || e.pointerId !== p.id) return;
  this.pointer = null;
  if (this.body.hasPointerCapture(e.pointerId)) this.body.releasePointerCapture(e.pointerId);
  if (this.dragging) this.endDrag();
};

Pet.prototype.startDrag = function () {
  this.walkingToBed = false;
  this.dragging = true;
  this.falling = false;
  this.lastInteraction = Date.now();
  this.card.classList.add('dragging');
  this.setState('dragged');
  this.say(AGENTS[this.id].dragLine, 1800);
};

Pet.prototype.endDrag = function () {
  this.dragging = false;
  this.justDragged = true;
  setTimeout(() => { this.justDragged = false; }, 60);
  this.lastInteraction = Date.now();
  if (this.y < 0) {
    this.falling = true;
    this.vy = 0;
    ensureWalkLoop();
  } else {
    this.land();
  }
};

Pet.prototype.land = function () {
  this.moodEvent('dropped');
  this.falling = false;
  this.y = 0;
  this.vy = 0;
  this.applyPosition();
  this.card.classList.remove('dragging');
  this.setState(this.restingState());
};

/** 每帧：下落 + 散步，返回是否还需要下一帧。 */
Pet.prototype.step = function (dt) {
  let moving = false;
  if (this.falling) {
    this.vy += 2600 * dt;
    this.y += this.vy * dt;
    if (this.y >= 0) this.land();
    else moving = true;
    this.applyPosition();
  }
  if (this.state === 'walk' && this.walking && !this.dragging) {
    const { maxX, spriteW } = this.bounds();
    // 速度随立绘大小缩放（原桌宠约每秒 0.18 个身宽）；迈腿每 95ms 换一帧，和位移在同一帧里更新
    const prevX = this.x;
    this.x += this.dir * Math.max(18, spriteW * 0.18) * dt;
    if (this.walkingToBed && (prevX - 0) * (this.x - 0) <= 0) {   // 走过了中点：停在中间睡觉
      this.x = 0;
      this.walkingToBed = false;
      this.applyPosition();
      this.setState('sleep');
      return false;
    }
    if (this.x <= -maxX) { this.x = -maxX; this.turn(1); }
    else if (this.x >= maxX) { this.x = maxX; this.turn(-1); }
    this.walkClock += dt;
    if (this.walkClock >= WALK_FRAME_SEC) {
      this.walkClock %= WALK_FRAME_SEC;
      this.walkFrame = (this.walkFrame + 1) % WALK_FRAMES;
      this.showWalkFrame(this.walkFrame);
    }
    this.applyPosition();
    moving = true;
  }
  return moving;
};

Pet.prototype.toggleRoam = function () {
  const st = S[this.id];
  this.demoPhase = null;
  st.roam = !st.roam;
  lsSet(`${this.id}_roam`, st.roam ? '1' : '0');
  this.touch();
  this.boutTicks = 0;
  if (st.roam && !isBusy(this.id)) {
    this.walking = true;
    this.setState('walk');
    this.walking = true;
    ensureWalkLoop();
  } else if (this.state === 'walk' || BUSY_STATES.has(this.state)) {
    this.setState('idle');
  }
  this.renderStatus();
};
