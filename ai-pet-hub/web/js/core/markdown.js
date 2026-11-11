'use strict';

// ===== Markdown 渲染：聊天回答和文件预览共用 =====
// 支持标题、段落、列表（嵌套 / 任务 / 起始编号，列表项里可以有代码块等）、引用（含 [!NOTE] 提示块）、
// 表格（对齐、单元格内 <br>）、分隔线、代码块（highlight.js）、公式（$…$、$$…$$、\(…\)、\[…\]、```math，
// 用 KaTeX 排版，化学式 \ce{}）、行内代码、粗体 / 斜体 / 删除线、链接、图片。
// 原始 HTML 一律转义（只认 <br>）；链接不直接跳转，交给原生层用浏览器打开。
// 依赖 chat/messages.js 里的 escapeHtml / looksLikeFile / fileChip、core/config.js 里的 UI、preview/highlight.js 里的 highlightBlock（都在渲染时才用到）。

const MATH_CACHE = new Map();

/** 用 KaTeX 排版公式；公式写错时 KaTeX 会用红字标出，KaTeX 没加载时原样显示。 */
function renderMath(tex, display) {
  const key = (display ? 'D:' : 'I:') + tex;
  if (MATH_CACHE.has(key)) return MATH_CACHE.get(key);
  let html = '';
  if (window.katex) {
    try {
      html = katex.renderToString(tex, { displayMode: display, throwOnError: false, strict: 'ignore' });
    } catch (_) { html = ''; }
  }
  if (!html) html = `<code class="math-raw">${escapeHtml(display ? `$$${tex}$$` : `$${tex}$`)}</code>`;
  if (MATH_CACHE.size > 1000) MATH_CACHE.clear();
  MATH_CACHE.set(key, html);
  return html;
}

/** s[i] 是 $：找行内公式的结尾。$ 后不能是空白，结尾的 $ 前不能是空白、后面不能紧跟数字（不把「$5 和 $10」当公式）。 */
function inlineMathEnd(s, i) {
  if (s[i + 1] === undefined || /\s/.test(s[i + 1])) return -1;
  for (let j = i + 1; j < s.length; j++) {
    const c = s[j];
    if (c === '\\') { j++; continue; }
    if (c === '\n') return -1;
    if (c === '$') return !/\s/.test(s[j - 1]) && !/\d/.test(s[j + 1] || '') ? j : -1;
  }
  return -1;
}

/** 把行内的公式换成占位：\(…\)、\[…\]、$$…$$、$…$。 */
function protectMath(s, keep) {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === '\\' && (s[i + 1] === '(' || s[i + 1] === '[')) {
      const display = s[i + 1] === '[';
      const end = s.indexOf(display ? '\\]' : '\\)', i + 2);
      const tex = end > i + 2 ? s.slice(i + 2, end) : '';
      // \[…\] 也可能只是转义的方括号（如「\[1\]」），里面像公式才当公式
      if (tex && (!display || /[\\^_={}]/.test(tex))) { out += keep(renderMath(tex, display)); i = end + 1; continue; }
    }
    if (c === '\\' && s[i + 1] === '$') { out += '\\$'; i++; continue; }   // 交给后面的转义处理
    if (c === '$') {
      if (s[i + 1] === '$') {
        const end = s.indexOf('$$', i + 2);
        if (end > i + 2) { out += keep(renderMath(s.slice(i + 2, end), true)); i = end + 1; continue; }
        out += '$$';
        i++;
        continue;
      }
      const end = inlineMathEnd(s, i);
      if (end > 0) { out += keep(renderMath(s.slice(i + 1, end), false)); i = end; continue; }
    }
    out += c;
  }
  return out;
}

function mdLink(label, target, opts) {
  if (/^https?:/i.test(target)) return `<a class="ext-link" data-url="${target}">${label}</a>`;
  if (/^(file:|\/|~\/|\.{1,2}\/)/.test(target) || looksLikeFile(target)) return fileChip(target, label, 'link');
  return label;   // 页内锚点、mailto: 等只显示文字
}

function mdImage(alt, src, opts) {
  if (/^data:image\//i.test(src)) return `<img class="md-img" src="${src}" alt="${alt}">`;
  if (/^https?:/i.test(src)) {
    // 聊天里不自动加载网络图片（不让回答内容触发联网），给一个链接；文件预览里正常显示
    return opts.remoteImages ? `<img class="md-img" src="${src}" alt="${alt}">` : `<a class="ext-link" data-url="${src}">［图片：${alt || src}］</a>`;
  }
  return `<img class="md-img" data-local="${src}" alt="${alt}">`;   // 本地图片由 loadLocalImages 读进来
}

/** 行内 Markdown。opts.chips：行内代码里的文件路径变成文件标签（聊天用）。 */
function mdInline(text, opts = {}) {
  const slots = [];
  const keep = html => `\u0000${slots.push(html) - 1}\u0000`;
  let s = String(text).replace(/\u0000/g, '');
  // 1. 行内代码先占位，里面的 * $ \ 都不再处理
  s = s.replace(/(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)/g, (m, ticks, code) => {
    const c = /^ .+ $/.test(code) ? code.slice(1, -1) : code;
    return keep(opts.chips && looksLikeFile(c) ? fileChip(escapeHtml(c), '', 'code') : `<code>${escapeHtml(c)}</code>`);
  });
  // 2. 公式
  s = protectMath(s, keep);
  // 3. 反斜杠转义：\* \_ \| \$ 等按原字符显示
  s = s.replace(/\\([\\`*_{}[\]()#+\-.!|~$<>])/g, (m, ch) => keep(escapeHtml(ch)));
  // 4. 图片、链接（在转义之前处理，文字和地址各自转义）
  s = s.replace(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g, (m, alt, src) => keep(mdImage(escapeHtml(alt), escapeHtml(src), opts)))
    .replace(/\[([^\]\n]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g, (m, label, target) => keep(mdLink(emphasize(escapeHtml(label)), escapeHtml(target), opts)));
  // 5. 裸网址：只认网址里合法的 ASCII 字符，遇到中文、全角标点、* 就结束（中文里网址后面常常不空格）
  s = s.replace(/(^|[^\w/@.-])(https?:\/\/[A-Za-z0-9\-._~:/?#@!$&'+,;=%]+)/g, (m, pre, url) => {
    const tail = url.match(/[.,;:!?']+$/);
    const clean = tail ? url.slice(0, -tail[0].length) : url;
    const safe = escapeHtml(clean);
    return pre + keep(`<a class="ext-link" data-url="${safe}">${safe}</a>`) + (tail ? tail[0] : '');
  });
  // 6. 其余文字转义；<br> 是表格里常见的换行写法，单独放行
  s = escapeHtml(s).replace(/&lt;br\s*\/?&gt;/gi, '<br/>');
  // 7. 强调：代码、公式、链接都已占位，可以被包在粗体里
  s = emphasize(s);
  // 8. 还原占位（链接文字里还可能套着代码占位）
  for (let k = 0; k < 5 && s.includes('\u0000'); k++) s = s.replace(/\u0000(\d+)\u0000/g, (m, n) => slots[Number(n)] ?? '');
  return s;
}

/** 粗体 / 斜体 / 删除线（输入已转义）。 */
function emphasize(s) {
  return s.replace(/\*\*\*(?=\S)(.+?)\*\*\*/g, '<strong><em>$1</em></strong>')
    .replace(/\*\*(?=\S)(.+?)\*\*/g, (m, t) => (/\s$/.test(t) ? m : `<strong>${t}</strong>`))
    .replace(/(^|\W)__(?=\S)(.+?)__(?!\w)/g, (m, pre, t) => (/\s$/.test(t) ? m : `${pre}<strong>${t}</strong>`))
    .replace(/(^|[^*\w])\*(?=[^\s*])(.+?)\*(?![*\w])/g, (m, pre, t) => (/\s$/.test(t) ? m : `${pre}<em>${t}</em>`))
    .replace(/(^|\W)_(?=[^\s_])(.+?)_(?!\w)/g, (m, pre, t) => (/\s$/.test(t) ? m : `${pre}<em>${t}</em>`))
    .replace(/~~(?=\S)(.+?)~~/g, '<del>$1</del>');
}

// ---------- 块级 ----------
const LIST_RE = /^(\s*)([-*+]|\d{1,9}[.)])(\s+|$)(.*)$/;
const HR_RE = /^\s{0,3}([-*_])(\s*\1){2,}\s*$/;
const FENCE_RE = /^(\s*)(`{3,}|~{3,})\s*([^`\s]*)/;
const isBlank = s => !s.trim();
const indentOf = s => s.match(/^[ \t]*/)[0].replace(/\t/g, '    ').length;

function dedent(s, n) {
  let k = 0;
  let w = 0;
  while (k < s.length && w < n && (s[k] === ' ' || s[k] === '\t')) { w += s[k] === '\t' ? 4 : 1; k++; }
  return s.slice(k);
}

function isTableSep(s) {
  const t = (s || '').trim();
  return t.includes('-') && t.includes('|') && /^\|?(\s*:?-+:?\s*\|)*\s*:?-+:?\s*\|?$/.test(t);
}

function isBlockStart(line, next) {
  return FENCE_RE.test(line) || /^\s{0,3}#{1,6}\s/.test(line) || /^\s*>/.test(line) || HR_RE.test(line)
    || /^\s*(\$\$|\\\[)/.test(line) || LIST_RE.test(line) || (line.includes('|') && isTableSep(next));
}

/** 表格的一行拆成单元格：\| 是普通字符，行内代码和公式里的 | 不拆。 */
function splitRow(line) {
  let t = line.trim();
  if (t.startsWith('|')) t = t.slice(1);
  if (t.endsWith('|') && !t.endsWith('\\|')) t = t.slice(0, -1);
  const cells = [];
  let cur = '';
  for (let k = 0; k < t.length; k++) {
    const c = t[k];
    if (c === '\\' && t[k + 1] === '|') { cur += '\\|'; k++; continue; }
    if (c === '`') {
      const end = t.indexOf('`', k + 1);
      if (end > k) { cur += t.slice(k, end + 1); k = end; continue; }
    }
    if (c === '$' && t[k + 1] !== '$') {
      const end = inlineMathEnd(t, k);
      if (end > 0) { cur += t.slice(k, end + 1); k = end; continue; }
    }
    if (c === '|') { cells.push(cur.trim()); cur = ''; continue; }
    cur += c;
  }
  cells.push(cur.trim());
  return cells;
}

/** 从 start 行开始的一个列表（同一缩进、同一种编号）；列表项的内容递归渲染。 */
function renderList(lines, start, opts) {
  const first = lines[start].match(LIST_RE);
  const baseIndent = indentOf(first[1]);
  const ordered = /\d/.test(first[2]);
  const items = [];
  let i = start;
  while (i < lines.length) {
    const m = lines[i].match(LIST_RE);
    if (!m || indentOf(m[1]) !== baseIndent || /\d/.test(m[2]) !== ordered) break;
    const contentIndent = baseIndent + m[2].length + Math.min(4, Math.max(1, m[3].length));
    const body = [m[4]];
    i++;
    while (i < lines.length) {
      const l = lines[i];
      if (isBlank(l)) {
        // 空行之后还有缩进到内容位置的行，仍属于这一项
        let k = i + 1;
        while (k < lines.length && isBlank(lines[k])) k++;
        if (k < lines.length && indentOf(lines[k]) >= contentIndent) { for (; i < k; i++) body.push(''); continue; }
        break;
      }
      const ind = indentOf(l);
      if (ind >= contentIndent) { body.push(dedent(l, contentIndent)); i++; continue; }
      const sub = LIST_RE.test(l);
      if (sub && ind > baseIndent) { body.push(dedent(l, ind)); i++; continue; }   // 缩进不够的子列表
      if (!sub && !isBlockStart(l, lines[i + 1]) && !isBlank(body[body.length - 1])) { body.push(l.trim()); i++; continue; }   // 懒续行
      break;
    }
    items.push(body);
    let k = i;
    while (k < lines.length && isBlank(lines[k])) k++;
    if (k === i) continue;   // 没有空行：外层循环会检查下一行是不是同级的项
    // 列表项之间隔着空行：后面紧接着同级的项就还是这个列表
    const n = k < lines.length && lines[k].match(LIST_RE);
    if (n && indentOf(n[1]) === baseIndent && /\d/.test(n[2]) === ordered) { i = k; continue; }
    break;
  }
  const tag = ordered ? 'ol' : 'ul';
  const startNum = ordered ? parseInt(first[2], 10) : 1;
  const html = `<${tag}${startNum !== 1 ? ` start="${startNum}"` : ''}>` + items.map(body => {
    const task = body[0].match(/^\[([ xX])\]\s+(.*)$/);
    const lines2 = task ? [task[2], ...body.slice(1)] : body;
    // 只有几行文字（最常见）就直接行内渲染，列表更紧凑；有子列表、代码块等再按块渲染
    const simple = !lines2.slice(1).some((l, k) => isBlank(l) || isBlockStart(l, lines2[k + 2]));
    const inner = simple ? lines2.map(l => mdInline(l.trim(), opts)).join('<br/>') : renderBlocks(lines2, opts, null);
    if (!task) return `<li>${inner}</li>`;
    const done = task[1] !== ' ';
    return `<li class="task"><span class="task-box${done ? ' done' : ''}">${done ? '✓' : ''}</span>${inner}</li>`;
  }).join('') + `</${tag}>`;
  return { html, end: i };
}

const ALERTS = { note: '说明', tip: '提示', important: '重要', warning: '注意', caution: '警告' };

/** marks：文件预览的改动标注（改动过的块绿条、删掉的内容红色删除线），按源码行号对应。 */
function renderBlocks(lines, opts, marks) {
  const added = marks ? marks.addedLines : new Set();
  const ghosts = marks ? marks.ghosts : new Map();
  const out = [];
  const wrap = (html, a, b) => {
    if (!marks) return html;
    let chg = false;
    const gone = [];
    for (let k = a; k <= b; k++) {
      if (added.has(k)) chg = true;
      if (ghosts.has(k)) gone.push(...ghosts.get(k));
    }
    const del = gone.length ? `<div class="md-del">${gone.map(g => mdInline(g, opts)).join('<br/>')}</div>` : '';
    return `${del}<div class="md-blk${chg ? ' md-chg' : ''}">${html}</div>`;
  };

  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (isBlank(line)) { i++; continue; }

    // 代码块；```math 当成公式
    let m = line.match(FENCE_RE);
    if (m) {
      const close = new RegExp(`^\\s*${m[2][0] === '`' ? '`' : '~'}{${m[2].length},}\\s*$`);
      const body = [];
      let j = i + 1;
      while (j < lines.length && !close.test(lines[j])) { body.push(dedent(lines[j], m[1].length)); j++; }
      const code = body.join('\n');
      const lang = m[3].toLowerCase();
      const html = lang === 'math'
        ? `<div class="math-block">${renderMath(code.trim(), true)}</div>`
        : `<div class="code-block"><button class="code-copy" title="拷贝代码">${UI.copy}</button>`
          + `<pre class="md-code"><code>${typeof highlightBlock === 'function' ? highlightBlock(code, lang) : escapeHtml(code)}</code></pre></div>`;
      out.push(wrap(html, i, Math.min(j, lines.length - 1)));
      i = j + 1;
      continue;
    }

    // 独立成段的公式：$$ … $$ / \[ … \]（可以跨行）；没闭合（例如回答还在输出）就先当普通段落
    m = line.match(/^\s*(\$\$|\\\[)(.*)$/);
    if (m) {
      const closeTok = m[1] === '$$' ? '$$' : '\\]';
      const parts = [];
      let rest = m[2];
      let j = i;
      let closed = false;
      for (;;) {
        const k = rest.indexOf(closeTok);
        if (k >= 0) { parts.push(rest.slice(0, k)); closed = !rest.slice(k + 2).trim(); break; }
        parts.push(rest);
        if (++j >= lines.length) break;
        rest = lines[j];
      }
      const tex = parts.join('\n').trim();
      if (closed && tex) {
        out.push(wrap(`<div class="math-block">${renderMath(tex, true)}</div>`, i, j));
        i = j + 1;
        continue;
      }
    }

    m = line.match(/^\s{0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$/);
    if (m) {
      const n = m[1].length;
      out.push(wrap(`<h${n}>${mdInline(m[2], opts)}</h${n}>`, i, i));
      i++;
      continue;
    }

    if (HR_RE.test(line)) { out.push(wrap('<hr/>', i, i)); i++; continue; }

    if (line.includes('|') && isTableSep(lines[i + 1])) {
      const head = splitRow(line);
      const aligns = splitRow(lines[i + 1]).map(c => (/^:-+:$/.test(c) ? 'center' : /^-+:$/.test(c) ? 'right' : /^:-+$/.test(c) ? 'left' : ''));
      let j = i + 2;
      const rows = [];
      while (j < lines.length && lines[j].includes('|') && !isBlank(lines[j])) { rows.push(splitRow(lines[j])); j++; }
      const cell = (tag, text, k) => `<${tag}${aligns[k] ? ` style="text-align:${aligns[k]}"` : ''}>${mdInline(text, opts)}</${tag}>`;
      const html = '<div class="table-wrap"><table><thead><tr>' + head.map((c, k) => cell('th', c, k)).join('') + '</tr></thead><tbody>'
        + rows.map(r => '<tr>' + head.map((_, k) => cell('td', r[k] || '', k)).join('') + '</tr>').join('')
        + '</tbody></table></div>';
      out.push(wrap(html, i, j - 1));
      i = j;
      continue;
    }

    if (/^\s*>/.test(line)) {
      let j = i;
      const body = [];
      while (j < lines.length && /^\s*>/.test(lines[j])) { body.push(lines[j].replace(/^\s*>\s?/, '')); j++; }
      const alert = (body[0] || '').match(/^\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$/i);
      const html = alert
        ? `<div class="md-alert md-alert-${alert[1].toLowerCase()}"><div class="md-alert-title">${ALERTS[alert[1].toLowerCase()]}</div>${renderBlocks(body.slice(1), opts, null)}</div>`
        : `<blockquote>${renderBlocks(body, opts, null)}</blockquote>`;
      out.push(wrap(html, i, j - 1));
      i = j;
      continue;
    }

    if (LIST_RE.test(line)) {
      const { html, end } = renderList(lines, i, opts);
      out.push(wrap(html, i, end - 1));
      i = end;
      continue;
    }

    // 段落：行与行之间保留换行
    let j = i;
    const para = [];
    while (j < lines.length && !isBlank(lines[j]) && (j === i || !isBlockStart(lines[j], lines[j + 1]))) { para.push(lines[j].trim()); j++; }
    out.push(wrap(`<p>${para.map(p => mdInline(p, opts)).join('<br/>')}</p>`, i, j - 1));
    i = j;
  }
  if (ghosts.has(lines.length)) out.push(`<div class="md-del">${ghosts.get(lines.length).map(g => mdInline(g, opts)).join('<br/>')}</div>`);
  return out.join('');
}

/**
 * Markdown → HTML。
 * opts.chips：行内代码里的文件路径变成文件标签（聊天）；opts.remoteImages：显示网络图片（文件预览）；
 * opts.marks：文件预览的改动标注。
 */
/**
 * 回答还在生成时用：找出 text 里「前面这一截已经定下来」的位置（字符偏移，0 = 没有）。
 * 这一截和后面那一截分开渲染、拼起来，和整段一起渲染的结果一样，所以流式显示时前面渲染过的不用每次重来。
 * 只在这样的地方切：前面是空行（不在没闭合的代码块、公式块里），后面那一行顶格、不是列表项 / 引用 / 表格行
 * ——列表隔着空行还能接着列，缩进的行可能是上一项的内容，这些地方不切。
 */
function streamSplit(text) {
  let split = 0, pos = 0, fence = null, math = null, blankBefore = false;
  for (const line of text.split('\n')) {
    const start = pos;
    pos += line.length + 1;
    if (fence) { if (fence.test(line)) fence = null; blankBefore = false; continue; }
    if (math) { if (line.includes(math)) math = null; blankBefore = false; continue; }
    if (isBlank(line)) { blankBefore = true; continue; }
    if (blankBefore && !/^[ \t>|]/.test(line) && !LIST_RE.test(line)) split = start;
    blankBefore = false;
    let m = line.match(FENCE_RE);
    if (m) { fence = new RegExp(`^\\s*${m[2][0] === '`' ? '`' : '~'}{${m[2].length},}\\s*$`); continue; }
    m = line.match(/^\s*(\$\$|\\\[)(.*)$/);
    if (m) {
      const closeTok = m[1] === '$$' ? '$$' : '\\]';
      if (!m[2].includes(closeTok)) math = closeTok;
    }
  }
  return split;
}

function renderMarkdown(src, opts = {}) {
  const lines = String(src || '').replace(/\r\n?/g, '\n').split('\n');
  return renderBlocks(lines, opts, opts.marks || null);
}
