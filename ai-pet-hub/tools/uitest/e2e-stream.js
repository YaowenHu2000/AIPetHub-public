// 观察用户真正看见的正文，也把实时节点换成定稿的那一次算进去。
const {check,note,skip,until,finish} = makeSuite('stream');
const chat = chatHarness(AGENT,{check,note,until});
const loaded = window.onConversationLoaded;
// 夹具只模拟协议、不写历史；空库的 missing 回执不代表用户删了正在测的这一轮。
window.onConversationLoaded = data => { if (!['fixture-session','fixture-stream','fixture-external','probe'].includes(data.conversationId)) loaded(data); };
setActive(AGENT); newChat(AGENT,true,REPO);
Object.assign(S[AGENT],{model:MODEL, effort:'low', perm:FULL_PERM});
const expected = '甲乙丙丁戊己庚辛'.repeat(32), increments = [];
let previous = 0;
const observe = () => {
  const text = chat.lastTurn()?.querySelector('.answer')?.textContent || '';
  if (text.length !== previous) increments.push(text.length - previous);
  previous = text.length;
};
const observer = new MutationObserver(observe);
observer.observe(chat.box,{subtree:true,childList:true,characterData:true});
try {
  const req = await chat.start('写几个字');
  const result = await until(()=>chat.response(req),'夹具定稿');
  check('夹具完整答复',result.reply === expected,result.reply);
  if (result.reply === expected) await until(()=>previous === expected.length,'正文显示完整');
  const count = chat.events.filter(e=>e.name === 'onAgentStep' && e.data.step.kind === 'text').length;
  check(AGENT + ' 流式全程没有一帧跳出一整段',count > 3 && increments.length > 3 && increments.every(n=>n>0 && n<=24),{count,increments});
  const cid = 'fixture-external', state = S[AGENT];
  newChat(AGENT,true,REPO); state.conversationId = cid; state.ownAt = 0; state.ownTurnUnsynced = false;
  const snapshot = (length,sync,running = true) => {
    const reqId = nextRequestId(); (state.historyReads ??= new Map()).set(reqId,sync ? 'sync' : 'open');
    loaded({agent:AGENT,conversationId:cid,reqId,lastTurn:{running,updatedAt:Date.now()/1000},messages:[
      {role:'user',text:'外部夹具'}, {role:'bot',steps:[{kind:'command',title:'读取',status:'ok'}],text:expected.slice(0,length)}]});
  };
  snapshot(8,false); observe(); increments.length = 0;
  snapshot(120,true);
  await until(()=>previous > 8,'外部新字开始显示');
  snapshot(256,true,false);
  await until(()=>previous === 256,'外部正文完整');
  // 同步补上的正文由 continueAnswer 逐字放出，它在页面不可见时有意直接显示整段（没人看，不白耗动画）；
  // 屏幕锁定或窗口被遮住时测试窗口也算不可见，这时判不了逐帧，单独记跳过，不算失败
  const framed = (name, ok) => document.hidden ? skip(name, '测试窗口不可见（屏幕锁定或被遮住），App 有意不播逐字动画', increments) : check(name, ok, increments);
  framed(AGENT + ' 外部会话同步也从已显示的位置继续',increments.length > 2 && increments.every(n=>n>0 && n<=24));
  snapshot(0,false); observe(); increments.length = 0;
  snapshot(120,true);
  await until(()=>previous === 120,'工作步骤后的首段正文完整');
  framed(AGENT + ' 工作步骤后的第一段也逐帧显示',increments.length > 1 && increments.every(n=>n>0 && n<=24));
  snapshot(256,false);
  check('整页重开直接显示完整历史',chat.lastTurn()?.querySelector('.answer')?.textContent === expected);
} finally { observer.disconnect(); chat.restore(); window.onConversationLoaded = loaded; }
return finish();
