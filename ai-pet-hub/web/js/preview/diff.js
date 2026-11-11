'use strict';

// 把一段 diff 对到完整文件上：哪些行是新增的、哪里删掉了什么。

// ---------- 改动：把 diff 逐段定位回当前文件，得到每一行的着色 ----------
function parseHunks(diff) {
  const hunks = [];
  let cur = null;
  for (const raw of (diff || '').split('\n')) {
    const line = raw.replace(/\r$/, '');
    if (line.startsWith('@@')) {
      const m = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)/);
      cur = { newStart: m ? Number(m[1]) : null, lines: [] };
      hunks.push(cur);
      continue;
    }
    if (line.startsWith('+++') || line.startsWith('---') || line.startsWith('\\')) continue;
    if (!cur) { cur = { newStart: null, lines: [] }; hunks.push(cur); }
    const t = line[0];
    if (t === '+' || t === '-' || t === ' ') cur.lines.push({ t, s: line.slice(1) });
    else if (line === '' && cur.newStart !== null) cur.lines.push({ t: ' ', s: '' });
  }
  return hunks.filter(h => h.lines.length);
}

/** 在文件里找这一段改动的新内容；替换可能只占一行的一部分，所以首尾行用包含匹配。 */
function locateHunk(lines, hunk) {
  const newSide = hunk.lines.filter(l => l.t !== '-').map(l => l.s);
  if (!newSide.length) return -1;
  const fits = k => {
    if (k < 0 || k + newSide.length > lines.length) return false;
    if (newSide.length === 1) return lines[k].includes(newSide[0]);
    for (let j = 0; j < newSide.length; j++) {
      const a = lines[k + j];
      const b = newSide[j];
      if (j === 0 ? !a.endsWith(b) : (j === newSide.length - 1 ? !a.startsWith(b) : a !== b)) return false;
    }
    return true;
  };
  if (hunk.newStart !== null) {
    const guess = hunk.newStart - 1;
    for (let d = 0; d <= 80; d++) {
      if (fits(guess + d)) return guess + d;
      if (d && fits(guess - d)) return guess - d;
    }
  }
  if (newSide.length === 1 && !newSide[0].trim()) return -1;
  for (let k = 0; k < lines.length; k++) if (fits(k)) return k;
  return -1;
}

/** 返回 { rows: [{type: ctx|add|del, text, no}], unplaced: [hunk], added, removed } */
function annotateFile(content, diff) {
  const lines = content.split('\n').map(l => l.replace(/\r$/, ''));
  const added = new Set();
  const ghosts = new Map();
  const unplaced = [];
  for (const hunk of parseHunks(diff)) {
    const pos = locateHunk(lines, hunk);
    if (pos < 0) { unplaced.push(hunk); continue; }
    let idx = pos;
    for (const l of hunk.lines) {
      if (l.t === '-') {
        if (!ghosts.has(idx)) ghosts.set(idx, []);
        ghosts.get(idx).push(l.s);
      } else {
        if (l.t === '+') added.add(idx);
        idx++;
      }
    }
  }
  const rows = [];
  let removed = 0;
  lines.forEach((text, i) => {
    (ghosts.get(i) || []).forEach(g => { rows.push({ type: 'del', text: g, no: null }); removed++; });
    rows.push({ type: added.has(i) ? 'add' : 'ctx', text, no: i + 1 });
  });
  (ghosts.get(lines.length) || []).forEach(g => { rows.push({ type: 'del', text: g, no: null }); removed++; });
  return { rows, unplaced, added: added.size, removed, addedLines: added, ghosts };
}

// Markdown 渲染在 markdown.js（和聊天回答共用），这里传入改动标注
