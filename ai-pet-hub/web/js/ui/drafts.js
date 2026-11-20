'use strict';

// 草稿归属、附件接收顺序和容量在这里一起决定，回执与当前窗口可以属于不同会话。
// 每位的输入在触发时就定下值；程序回填立即落盘，键入才短暂防抖。
//
// 普通输入按助手共用；需要退回或正在等附件的草稿按原会话保存，未取得正式编号的新对话按工作空间找回。
// 几个窗口共用这份退回记录，读写前都重读最新值，只改本窗口动过的会话；同一会话另一窗口也新退回了文字或附件时按内容合并，两份都留，另一窗口退回的排前面；离开普通输入时暂存的文字只属于本窗口；
// 点📎后取消没有收到文件，不改草稿归属。
// 粘贴、拖入、选文件和编辑原图按操作顺序接收，等候中的发送遇到失败或超限就取消。
// 乱序回执中已收到的路径也随草稿落盘，重载后可找回。
// 新增最多 8 个，手动撤回放不下仍留在队列，自动退回保留所有已接收的附件。
// 停止或失败时先退原问，再按队列顺序退未送达的补充，用户正在输入的文字留在后面。
// 网页重载从原生回合取回原始草稿和队列，普通文件、截图清理标记和已撤回的位置都随原请求恢复。
const draftTimers = new Map();
function setDraft(id, value, delay = 0) {
  clearTimeout(draftTimers.get(id));
  draftTimers.delete(id);
  S[id].draft = value;
  if (id === active && els.input.value !== value) els.input.value = value;
  const save = () => {
    draftTimers.delete(id);
    // 异常/队列回填可能已经更新了草稿，旧键入不得覆盖它。
    if (S[id].draft === value) lsSet(`${id}_draft`, value);
  };
  if (delay) draftTimers.set(id, setTimeout(save, delay));
  else save();
  closeSuggest();
}

// 普通草稿按 AI 共用；只有明确没送出的请求才随原会话保存。没有 CLI 编号的新对话按工作空间找回。
function draftSession(view, workspace) {
  return view.startsWith('new:') ? 'workspace:' + workspace : 'session:' + view;
}

// 同一来源的几个窗口共用这份记录，各自内存里只是上次读写时的副本；整份写回会抹掉别的窗口刚退回的草稿。
// 读写前都和最新值三方合并：本窗口改过的会话和待收文件用自己的（同一会话别的窗口也新退回了就按内容合并），其余以最新值为准；归属和绑定只描述本窗口。
const returnedBase = {};
const storedReturned = id => lsJson(id + '_returnedDrafts', null) || {};
function mergeLatestReturned(id) {
  const book = S[id].returnedDrafts, base = returnedBase[id] || {}, latest = storedReturned(id);
  for (const field of ['parked','readyFiles']) {
    const mine = book[field] || {}, old = base[field] || {}, merged = {...latest[field]};
    for (const key of new Set([...Object.keys(mine),...Object.keys(old)])) {
      if (JSON.stringify(mine[key]) === JSON.stringify(old[key])) continue;
      // 两边都改了同一会话：别的窗口在本窗口读过之后新退回的段落和附件，排在本窗口这份前面，都保留。
      const added = field === 'parked' && merged[key] && JSON.stringify(merged[key]) !== JSON.stringify(old[key]) && addedSince(merged[key],old[key]);
      if (added && (added.text || added.paths.length)) merged[key] = mine[key] ? combineDrafts(mine[key],[added],'return').merged : added;
      else if (mine[key] === undefined) delete merged[key]; else merged[key] = mine[key];
    }
    // 暂存的普通草稿是本窗口离开普通输入时留下的，和归属一样只属于本窗口，取别的窗口的就会丢掉自己写的。
    if (field === 'parked') {
      delete merged[''];
      if (mine[''] !== undefined) merged[''] = mine[''];
    }
    if (field === 'parked' || Object.keys(merged).length) book[field] = merged;
    else delete book[field];
  }
}
function addedSince(latest, old) {
  if (!old) return latest;
  const left = (old.text || '').split('\n\n');
  const text = (latest.text || '').split('\n\n').filter(t => {
    const i = left.indexOf(t);
    if (i >= 0) left.splice(i,1);
    return i < 0 && t;
  }).join('\n\n');
  return {...latest,text,paths:(latest.paths || []).filter(p => !(old.paths || []).includes(p))};
}
function refreshReturnedDrafts(id) {
  mergeLatestReturned(id);
  returnedBase[id] = storedReturned(id);
}
ALL_AGENT_IDS.forEach(id => { returnedBase[id] = storedReturned(id); });

function saveReturnedDrafts(id) {
  mergeLatestReturned(id);
  const book = S[id].returnedDrafts;
  lsSet(id + '_returnedDrafts', book.owner || Object.keys(book.parked).length || Object.keys(book.readyFiles || {}).length ? JSON.stringify(book) : '');
  returnedBase[id] = storedReturned(id);
}

function draftAttachments(st) {
  const list = st.attach || [], edited = list.filter(a => a.edited).map(a => a.path);
  const shown = list.filter(a => a.shown);
  return {text:st.draft, paths:list.map(a => a.path), pasted:list.filter(a => a.pasted).map(a => a.path),
    ...(edited.length ? {edited} : {}), ...(shown.length ? {shown:Object.fromEntries(shown.map(a => [a.path,a.shown]))} : {})};
}

const attachmentLimit = 8;
const currentDraftKey = id => draftSession(viewKey(id), S[id].workspace || '');
const originView = origin => origin.run?.view || origin.view;
const originDraftKey = origin => draftSession(originView(origin), origin.workspace || '');
// 同一工作空间可以找回无编号的草稿，自动发送则还必须停留在最初的临时会话。
const inDraftView = (id, origin) => originView(origin) === viewKey(id) && originDraftKey(origin) === currentDraftKey(id);
function unsentDraft(item) {
  if (!item.imageRefs?.length || !item.restoredPaths) return item.draft || {text:item.text,paths:item.images || []};
  const paths = [...(item.images || [])];
  item.imageRefs.forEach((ref,i) => paths.splice(ref.index ?? paths.length,0,item.restoredPaths[i]));
  return {...item.draft,text:item.draft?.text ?? item.text,paths:paths.filter(Boolean)};
}

function claimDraft(id) {
  const book = S[id].returnedDrafts, key = currentDraftKey(id);
  if (draftTimers.has(id)) setDraft(id,S[id].draft);
  const reqId = runsOf(id,viewKey(id))[0]?.reqId;
  if (book.owner === key && book.bindings?.[key] === reqId) return;
  book.owner = key;
  if (reqId != null) (book.bindings ||= {})[key] = reqId;
  else if (book.bindings) delete book.bindings[key];
  saveReturnedDrafts(id);
}

function sentDraft(id) {
  const book = S[id].returnedDrafts;
  if (!book.owner) return;
  if (book.bindings) delete book.bindings[book.owner];
  // 整份退稿已取走，后来新写的普通草稿恢复共用。有另一份普通草稿暂存时，仍在切走时还给它。
  if (!book.parked['']) book.owner = '';
  saveReturnedDrafts(id);
}

// 回执可能在别的会话显示期间到达。先选定一份草稿，容量、去重和顺序就不再依赖当前页面。
function draftTarget(id, origin) {
  refreshReturnedDrafts(id);
  const st = S[id], current = currentDraftKey(id);
  const key = origin ? originDraftKey(origin) : current;
  const here = key === current;
  const prior = (here ? draftAttachments(st) : st.returnedDrafts.parked[key]) || {text:'',paths:[]};
  return {id,origin,key,here,prior};
}

// 已接收的队列必须全部找回；主动撤回可以稍后再试；新附的文件只接收到上限。
function combineDrafts(prior, parts, mode) {
  const incoming = [...new Set(parts.flatMap(d => d.paths || []))];
  const paths = new Set(prior.paths);
  for (const path of incoming) {
    if (mode !== 'add' || paths.size < attachmentLimit) paths.add(path);
  }
  if (mode === 'withdraw' && incoming.length && paths.size > attachmentLimit) return null;
  const kept = incoming.filter(p => paths.has(p));
  const ordered = mode === 'add' ? [prior,...parts] : [...parts,prior];
  const edited = new Set(prior.edited || []);
  for (const part of parts) {
    for (const path of part.edited || []) if (!prior.paths.includes(path)) edited.add(path);
  }
  const pasted = new Set(ordered.flatMap(d => d.pasted || []));
  const mergedPaths = mode === 'add' ? [...paths] : [...new Set([...incoming,...prior.paths])];
  const merged = {text:ordered.map(d => d.text).filter(Boolean).join('\n\n'),paths:mergedPaths,
    pasted:mergedPaths.filter(p => pasted.has(p))};
  if (edited.size) merged.edited = mergedPaths.filter(p => edited.has(p));
  const shown = Object.assign({},...ordered.map(d => d.shown || {}));
  if (mergedPaths.some(p => shown[p])) merged.shown = Object.fromEntries(mergedPaths.filter(p => shown[p]).map(p => [p,shown[p]]));
  return {merged,kept};
}
function mergeDraft({id,origin,key,here,prior}, parts, mode = 'return', thumb = '') {
  const book = S[id].returnedDrafts, combined = combineDrafts(prior,parts,mode);
  if (!combined) return null;
  const {merged,kept} = combined;
  const run = origin?.run || origin;
  if (run?.reqId != null && S[id].runs.has(run.reqId)) (book.bindings ||= {})[key] = run.reqId;
  if (here) {
    if (origin) book.owner = key;
    displayReturnedDraft(id,merged,thumb ? new Map(kept.map(p => [p,thumb])) : null,mode !== 'add');
  } else book.parked[key] = merged;
  if (origin) saveReturnedDrafts(id);
  return kept;
}

// 用户仍可直接改草稿。只有上次退回的前缀原样留着，才把分批到达的几条按队列位置重排。
function afterReturnedPrefix(prior, prefix) {
  const text = prefix.map(d => d.text).filter(Boolean).join('\n\n');
  const paths = [...new Set(prefix.flatMap(d => d.paths || []))];
  if (text && prior.text !== text && !prior.text.startsWith(text+'\n\n')) return null;
  if (!paths.every((path,i) => prior.paths[i] === path)) return null;
  return {...prior,text:text ? prior.text.slice(text.length+2) : prior.text,paths:prior.paths.slice(paths.length)};
}

function returnQueuedDrafts(id, run, items, original = null, mode = 'return') {
  const target = draftTarget(id,run);
  let drafts = items.map(unsentDraft);
  let next;
  if (run.returnedQueue || mode !== 'return') {
    const previous = run.returnedQueue || {ids:[],parts:{}};
    const ids = [...new Set([...previous.ids,...(run.queue || []).map(q => q.sid),...items.map(q => q.sid)])];
    const remainder = afterReturnedPrefix(target.prior,ids.map(sid => previous.parts[sid]).filter(Boolean));
    const parts = remainder ? {...previous.parts} : {};
    items.forEach((q,i) => { parts[q.sid] = drafts[i]; });
    next = {ids,parts};
    if (remainder) target.prior = remainder;
    drafts = ids.map(sid => parts[sid]).filter(Boolean);
  }
  if (original) drafts.unshift(original);
  const kept = mergeDraft(target,drafts,mode);
  if (kept && next) run.returnedQueue = next;
  return kept;
}

function displayReturnedDraft(id, draft, thumbnails = null, updateText = true) {
  const st = S[id], old = new Map((st.attach || []).map(a => [a.path,a.thumb]));
  if (updateText) setDraft(id,draft?.text || '');
  st.attach = (draft?.paths || []).map(path => ({path, pasted:draft.pasted?.includes(path), edited:draft.edited?.includes(path),
    ...(draft.shown?.[path] ? {shown:draft.shown[path]} : {}), thumb:thumbnails?.get(path) || old.get(path) || ''}));
  saveAttachments(id);
  if (id === active) { renderAttachments(); if (updateText) autosize(); }
}

function syncReturnedDraft(id) {
  refreshReturnedDrafts(id);
  const st = S[id], book = st.returnedDrafts, key = currentDraftKey(id);
  if (key === book.owner || (!book.owner && !book.parked[key])) return;
  const target = book.parked[key] ? key : '';
  const draft = book.parked[target];
  const current = draftAttachments(st);
  // 占着这个会话期间，别的窗口可能把失败的提问退回到这里；它排在本窗口的输入前面，和同一窗口收到退回时一样。
  const returned = book.parked[book.owner];
  if (current.text || current.paths.length) book.parked[book.owner] = returned ? combineDrafts(current,[returned],'return').merged : current;
  delete book.parked[target];
  book.owner = target;
  displayReturnedDraft(id, draft);
  saveReturnedDrafts(id);
}

// 附件路径跟草稿一样存在本地：不发送就重开 App，话和附件都还在。
// 粘贴截图的缩略图是整张图的 data URL，太大不存，重开后那张显示成文件图标。
function saveAttachments(id) {
  const paths = (S[id].attach || []).map(a => a.pasted || a.edited || a.shown
    ? {path:a.path, pasted:!!a.pasted, edited:!!a.edited, ...(a.shown ? {shown:a.shown} : {})} : a.path);
  lsSet(`${id}_attach`, paths.length ? JSON.stringify(paths) : '');
}
function loadAttachments(id) {
  const paths = lsJson(`${id}_attach`, []);
  S[id].attach = Array.isArray(paths) ? paths.flatMap(p => typeof p === 'string' && p ? [{path:p, thumb:''}] :
    ((p?.pasted || p?.edited || p?.shown) && typeof p.path === 'string'
      ? [{path:p.path, pasted:!!p.pasted, edited:!!p.edited, ...(typeof p.shown === 'string' ? {shown:p.shown} : {}), thumb:''}] : [])) : [];
}
ALL_AGENT_IDS.forEach(loadAttachments);

const pendingPastes = new Map();
function beginAttachment(id, options = {}) {
  const view = viewKey(id), key = nextRequestId();
  const p = {key,id,view,workspace:S[id].workspace,run:runsOf(id,view)[0],...options};
  pendingPastes.set(key,p);
  // 系统选框打开期间窗口切不走；取消时什么都没收到，不能因此改普通草稿的归属。选到文件时 mergeDraft 会认领。
  if (!options.picker) claimDraft(id);
  return p;
}

function pastesInView(id) {
  return [...pendingPastes.values()].filter(p => p.id === id && inDraftView(id,p));
}

function cancelPendingEdit(id) {
  const group = pastesInView(id);
  if (!group.some(p => p.edited)) return;
  for (const p of group) {
    delete p.sendText;
    if (p.edited) {
      pendingPastes.delete(p.key);
      if (S[id].returnedDrafts.readyFiles?.[p.key]) {
        delete S[id].returnedDrafts.readyFiles[p.key];
        saveReturnedDrafts(id);
      }
    }
  }
  const next = pastesInView(id)[0];
  if (next?.result) finishPaste(next,next.result);
}

// 编辑带回的是发送时的副本、显示原路径。再拖入或选中同一原文件时先按发送的规则冻结：内容没变得到同一副本、按路径去重，变了就是另一份。
function needsFreeze(id, paths, origin = null) {
  const shown = Object.values(draftTarget(id,origin).prior.shown || {});
  return hasBridge() && paths.some(p => shown.includes(p));
}
function freezeFiles(paste, paths) {
  paste.frozen = true;
  paste.shown = paths;
  postNative('editChatImages',{reqId:paste.key,paths,refs:[],freeze:true});
}

// 文件已经到达也可能排在尚未保存的截图之后。按用户操作顺序接收才能让最后一个名额给先放进来的附件。
function receiveFiles(id, paths, options = {}) {
  if (!options.edited && needsFreeze(id,paths)) freezeFiles(beginAttachment(id,{...options,file:true}),paths);
  else if (options.edited || pastesInView(id).length) {
    finishPaste(beginAttachment(id,{...options,file:true}),{paths});
  } else addAttachments(id,paths,!!options.pasted);
}

function finishPaste(paste, result) {
  paste.result = result;
  const key = originDraftKey(paste);
  const view = originView(paste);
  const group = [...pendingPastes.values()].filter(p => p.id === paste.id && originView(p) === view && originDraftKey(p) === key);
  const book = S[paste.id].returnedDrafts;
  // 等前一张时，后到的拖入文件或已经保存好的第二张图已经属于用户。重开也要能取回已收到的路径。
  if (group[0] !== paste && !group[0]?.result && result.paths?.length) {
    (book.readyFiles ||= {})[paste.key] = {key:paste.key,view,workspace:paste.workspace,
      pasted:!paste.edited && (!paste.file || !!paste.pasted),edited:!!paste.edited,paths:result.paths,...(paste.shown ? {shown:paste.shown} : {})};
    saveReturnedDrafts(paste.id);
    return;
  }
  let intent;
  for (const p of group) {
    if (!p.result) {
      if (intent !== undefined) p.sendText ??= intent;
      return;
    }
    pendingPastes.delete(p.key);
    if (book.readyFiles) delete book.readyFiles[p.key];
    if (p.sendText !== undefined) intent = p.sendText;
    const paths = p.result.paths || [];
    if (p.result.error) pets[p.id].say((p.edited ? '图片恢复失败：' : '截图保存失败：') + p.result.error,5000);
    const kept = paths.length && !p.result.error
      ? addAttachments(p.id,paths,!p.edited && (!p.file || !!p.pasted),p) : [];
    if (!paths.length || kept.length !== new Set(paths).size) {
      intent = undefined;
      for (const item of group) delete item.sendText;
    }
  }
  if (intent !== undefined && paste.id === active && inDraftView(active,paste) && intent === els.input.value) send();
}

function recoverReadyFiles(id) {
  const book = S[id].returnedDrafts;
  const files = Object.values(book.readyFiles || {}).sort((a,b) => a.key-b.key);
  for (const file of files) {
    delete book.readyFiles[file.key];
    addAttachments(id,file.paths,file.pasted,file);
  }
}

function finishDraftBinding(id, run) {
  const book = S[id].returnedDrafts;
  if (!book.bindings || run.reqId == null) return;
  const key = originDraftKey(run);
  if (book.bindings[key] !== run.reqId) return;
  delete book.bindings[key];
  saveReturnedDrafts(id);
}

function bindRunDraft(id, run, oldView) {
  const oldKey = draftSession(oldView,run.workspace || ''), key = originDraftKey(run);
  // 回执可能先于正式编号。连已经回填的草稿一起迁移，否则切走期间文字会留在临时项目下。
  const book = S[id].returnedDrafts;
  let moved = book.bindings?.[oldKey] === run.reqId && run.reqId != null;
  for (const p of pendingPastes.values()) {
    if (p.id === id && !p.run && p.view === oldView && originDraftKey(p) === oldKey) {
      p.run = run;
      moved = true;
    }
    const ready = book.readyFiles?.[p.key];
    if (p.run === run && ready) ready.view = run.view;
  }
  if (moved) {
    if (book.bindings) delete book.bindings[oldKey];
    if (book.owner === oldKey) book.owner = key;
    const parked = book.parked[oldKey];
    if (parked) {
      delete book.parked[oldKey];
      syncReturnedDraft(id);
      mergeDraft(draftTarget(id,run),[parked]);
    } else saveReturnedDrafts(id);
  }
  syncReturnedDraft(id);
}
