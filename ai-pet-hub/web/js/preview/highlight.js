'use strict';

// 代码着色：自带的轻量着色（HL），有 highlight.js 时用它；按行切开，方便逐行标改动。

// ---------- 代码着色（轻量，按行带状态处理跨行注释 / 字符串） ----------
const HL = (() => {
  const words = s => new Set(s.split(/\s+/).filter(Boolean));
  const JS_KW = 'break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new return super switch this throw try typeof var void while with yield async await of static get set null undefined true false from as';
  const LANGS = {
    js: { kw: words(JS_KW), lc: '//', bc: ['/*', '*/'], q: '"\'`', types: true },
    ts: { kw: words(JS_KW + ' interface type enum implements private public protected readonly declare namespace abstract keyof infer is satisfies'), lc: '//', bc: ['/*', '*/'], q: '"\'`', types: true },
    swift: { kw: words('func let var if else guard return import class struct enum protocol extension switch case default for in while repeat break continue defer do try catch throw throws rethrows init deinit self Self super nil true false static private fileprivate public internal open final override mutating lazy weak unowned inout async await some any where typealias associatedtype is as subscript convenience required @objc @escaping @discardableResult'), lc: '//', bc: ['/*', '*/'], q: '"', tq: ['"""'], types: true },
    py: { kw: words('def class return if elif else for while in not and or is import from as with try except finally raise pass break continue lambda yield global nonlocal assert del None True False async await self cls match case'), lc: '#', q: '"\'', tq: ['"""', "'''"], types: true },
    sh: { kw: words('if then else elif fi for in do done while until case esac function return local export set unset echo exit source alias cd test read shift trap eval exec'), lc: '#', q: '"\'', vars: true },
    go: { kw: words('break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var nil true false'), lc: '//', bc: ['/*', '*/'], q: '"\'`', types: true },
    rust: { kw: words('as async await break const continue crate else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while dyn'), lc: '//', bc: ['/*', '*/'], q: '"', types: true },
    c: { kw: words('if else for while do switch case default break continue return goto sizeof struct union enum typedef static const extern void int char float double long short unsigned signed bool true false NULL nullptr class public private protected virtual template typename namespace using new delete this @interface @implementation @end @property'), lc: '//', bc: ['/*', '*/'], q: '"\'', types: true },
    java: { kw: words('abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for if implements import instanceof int interface long native new package private protected public return short static super switch synchronized this throw throws transient try void volatile while true false null fun val var when object data sealed override'), lc: '//', bc: ['/*', '*/'], q: '"\'', types: true },
    sql: { kw: words('select from where and or not insert into values update set delete create table index view drop alter add join left right inner outer on as group by order having limit offset distinct union all null is in like between case when then else end primary key foreign references default integer text real blob'), lc: '--', bc: ['/*', '*/'], q: '"\'', ci: true },
  };
  const EXT = {
    js: 'js', mjs: 'js', cjs: 'js', jsx: 'js', php: 'js', ts: 'ts', tsx: 'ts', swift: 'swift', py: 'py', rb: 'py', lua: 'py', r: 'py', jl: 'py',
    sh: 'sh', zsh: 'sh', bash: 'sh', env: 'sh', go: 'go', rs: 'rust', c: 'c', h: 'c', cc: 'c', cpp: 'c', hpp: 'c', m: 'c', mm: 'c',
    java: 'java', kt: 'java', dart: 'java', sql: 'sql', json: 'json', jsonl: 'json', ipynb: 'json', css: 'css', scss: 'css', less: 'css',
    html: 'html', htm: 'html', xml: 'html', plist: 'html', svg: 'html', vue: 'html', svelte: 'html', yml: 'yaml', yaml: 'yaml',
    toml: 'toml', ini: 'toml', conf: 'toml', lock: 'toml', md: 'md', markdown: 'md',
  };
  const ALIAS = { javascript: 'js', typescript: 'ts', python: 'py', shell: 'sh', bash: 'sh', zsh: 'sh', console: 'sh', golang: 'go', 'c++': 'c', cpp: 'c', objc: 'c', kotlin: 'java', yml: 'yaml', markdown: 'md', xml: 'html', jsonc: 'json' };

  const span = (cls, text) => `<span class="tk-${cls}">${escapeHtml(text)}</span>`;

  function codeLine(src, L, state) {
    let out = '';
    let i = 0;
    const n = src.length;
    if (state.until) {   // 接着上一行没结束的块注释 / 多行字符串
      const end = src.indexOf(state.until, 0);
      if (end < 0) return span(state.cls, src);
      out += span(state.cls, src.slice(0, end + state.until.length));
      i = end + state.until.length;
      state.until = null;
    }
    while (i < n) {
      const c = src[i];
      if (L.lc && src.startsWith(L.lc, i) && !(L.lc === '#' && src[i - 1] === '$')) { out += span('com', src.slice(i)); break; }
      if (L.bc && src.startsWith(L.bc[0], i)) {
        const end = src.indexOf(L.bc[1], i + L.bc[0].length);
        if (end < 0) { out += span('com', src.slice(i)); state.until = L.bc[1]; state.cls = 'com'; break; }
        out += span('com', src.slice(i, end + L.bc[1].length));
        i = end + L.bc[1].length;
        continue;
      }
      const tq = L.tq && L.tq.find(t => src.startsWith(t, i));
      if (tq) {
        const end = src.indexOf(tq, i + 3);
        if (end < 0) { out += span('str', src.slice(i)); state.until = tq; state.cls = 'str'; break; }
        out += span('str', src.slice(i, end + 3));
        i = end + 3;
        continue;
      }
      if (L.q.includes(c)) {
        let j = i + 1;
        while (j < n && src[j] !== c) { if (src[j] === '\\') j++; j++; }
        if (j >= n && c === '`') { out += span('str', src.slice(i)); state.until = '`'; state.cls = 'str'; break; }
        out += span('str', src.slice(i, j + 1));
        i = j + 1;
        continue;
      }
      if (L.vars && c === '$') {
        const m = src.slice(i).match(/^\$(\{[^}]*\}|[A-Za-z_]\w*|[0-9@#?*!$-])/);
        if (m) { out += span('var', m[0]); i += m[0].length; continue; }
      }
      if (/[0-9]/.test(c) && !/[\w$.]/.test(src[i - 1] || '')) {
        const m = src.slice(i).match(/^(0x[0-9a-fA-F_]+|\d[\d_]*(\.\d+)?([eE][+-]?\d+)?)/);
        out += span('num', m[0]);
        i += m[0].length;
        continue;
      }
      if (/[A-Za-z_@$]/.test(c)) {
        const m = src.slice(i).match(/^[@$]?[A-Za-z_][\w$]*/);
        const w = m ? m[0] : c;
        const key = L.ci ? w.toLowerCase() : w;
        let cls = '';
        if (L.kw.has(key)) cls = 'kw';
        else if (src[i + w.length] === '(') cls = 'fn';
        else if (L.types && /^[A-Z][A-Za-z0-9]*$/.test(w) && w.length > 1) cls = 'type';
        out += cls ? span(cls, w) : escapeHtml(w);
        i += w.length;
        continue;
      }
      out += escapeHtml(c);
      i++;
    }
    return out;
  }

  function jsonLine(src) {
    return escapeHtml(src)
      .replace(/(&quot;(?:[^&\\]|\\.|&(?!quot;))*?&quot;)(\s*:)?/g, (m, str, colon) => (colon ? `<span class="tk-key">${str}</span>${colon}` : `<span class="tk-str">${str}</span>`))
      .replace(/\b(true|false|null)\b/g, '<span class="tk-kw">$1</span>')
      .replace(/(^|[\s,:[])(-?\d+(\.\d+)?([eE][+-]?\d+)?)(?=[\s,\]}]|$)/g, '$1<span class="tk-num">$2</span>');
  }

  function cssLine(src, state) {
    if (state.until) {
      const end = src.indexOf('*/');
      if (end < 0) return span('com', src);
      state.until = null;
      return span('com', src.slice(0, end + 2)) + cssLine(src.slice(end + 2), state);
    }
    const start = src.indexOf('/*');
    if (start >= 0) {
      const end = src.indexOf('*/', start + 2);
      if (end < 0) { state.until = '*/'; return cssLine(src.slice(0, start), {}) + span('com', src.slice(start)); }
      return cssLine(src.slice(0, start), {}) + span('com', src.slice(start, end + 2)) + cssLine(src.slice(end + 2), state);
    }
    const esc = escapeHtml(src);
    if (/\{\s*$/.test(src) || (/^[^:]*\{/.test(src) && !/:\s*[^;{]+;/.test(src.split('{')[0]))) {
      return esc.replace(/^(\s*)([^{]+)/, (m, sp, sel) => `${sp}<span class="tk-type">${sel}</span>`);
    }
    return esc
      .replace(/([\w-]+)(\s*:)(?!\/)/g, '<span class="tk-key">$1</span>$2')
      .replace(/(#[0-9a-fA-F]{3,8})\b/g, '<span class="tk-num">$1</span>')
      .replace(/(^|[\s(,])(-?\d*\.?\d+)(px|em|rem|%|vh|vw|s|ms|deg|fr|cqh|cqw)?/g, '$1<span class="tk-num">$2$3</span>')
      .replace(/(&quot;[^&]*&quot;|'[^']*')/g, '<span class="tk-str">$1</span>');
  }

  function htmlLine(src, state) {
    let out = '';
    let rest = src;
    if (state.until) {
      const end = rest.indexOf('-->');
      if (end < 0) return span('com', rest);
      out += span('com', rest.slice(0, end + 3));
      rest = rest.slice(end + 3);
      state.until = null;
    }
    const re = /<!--[\s\S]*?(-->|$)|<\/?[\w:.-]+(?:\s+[\w:@.-]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?)*\s*\/?>?/g;
    let last = 0;
    let m;
    while ((m = re.exec(rest)) !== null) {
      out += escapeHtml(rest.slice(last, m.index));
      const tok = m[0];
      if (tok.startsWith('<!--')) {
        out += span('com', tok);
        if (!tok.endsWith('-->')) state.until = '-->';
      } else {
        out += escapeHtml(tok)
          .replace(/^(&lt;\/?)([\w:.-]+)/, '$1<span class="tk-tag">$2</span>')
          .replace(/(\s)([\w:@.-]+)(=)/g, '$1<span class="tk-attr">$2</span>$3')
          .replace(/(&quot;[^&]*?&quot;|'[^']*')/g, '<span class="tk-str">$1</span>');
      }
      last = m.index + tok.length;
      if (tok.length === 0) re.lastIndex++;
    }
    return out + escapeHtml(rest.slice(last));
  }

  function yamlLine(src, isToml) {
    const hash = src.search(/(^|\s)#/);
    const code = hash >= 0 ? src.slice(0, hash) : src;
    const comment = hash >= 0 ? src.slice(hash) : '';
    let html = escapeHtml(code);
    if (isToml && /^\s*\[.*\]\s*$/.test(code)) html = `<span class="tk-type">${html}</span>`;
    else {
      html = html
        .replace(isToml ? /^(\s*)([\w.\-"]+)(\s*=)/ : /^(\s*-?\s*)([\w.\-"' ]+?)(\s*:)(?=\s|$)/, '$1<span class="tk-key">$2</span>$3')
        .replace(/(&quot;[^&]*?&quot;|'[^']*')/g, '<span class="tk-str">$1</span>')
        .replace(/\b(true|false|null|yes|no)\b/g, '<span class="tk-kw">$1</span>')
        .replace(/(=\s*|:\s+)(-?\d+(\.\d+)?)\b/g, '$1<span class="tk-num">$2</span>');
    }
    return html + (comment ? span('com', comment) : '');
  }

  function mdLine(src, state) {
    if (/^\s*(```|~~~)/.test(src)) { state.fence = !state.fence; return span('com', src); }
    if (state.fence) return span('str', src);
    const esc = escapeHtml(src);
    if (/^#{1,6}\s/.test(src)) return `<span class="tk-kw">${esc}</span>`;
    return esc
      .replace(/^(\s*)([-*+]|\d+[.)])(\s)/, '$1<span class="tk-tag">$2</span>$3')
      .replace(/(`[^`]+`)/g, '<span class="tk-str">$1</span>')
      .replace(/(\*\*[^*]+\*\*)/g, '<span class="tk-type">$1</span>')
      .replace(/(\[[^\]]*\]\([^)]*\))/g, '<span class="tk-fn">$1</span>');
  }

  /** 返回每一行的着色 HTML。 */
  function lines(list, lang) {
    const state = {};
    const L = LANGS[lang];
    return list.map(src => {
      if (L) return codeLine(src, L, state);
      switch (lang) {
        case 'json': return jsonLine(src);
        case 'css': return cssLine(src, state);
        case 'html': return htmlLine(src, state);
        case 'yaml': return yamlLine(src, false);
        case 'toml': return yamlLine(src, true);
        case 'md': return mdLine(src, state);
        default: return escapeHtml(src);
      }
    });
  }

  const langOf = path => EXT[(path.split('.').pop() || '').toLowerCase()] || '';
  const langName = name => {
    const k = (name || '').toLowerCase();
    return ALIAS[k] || (LANGS[k] || ['json', 'css', 'html', 'yaml', 'toml', 'md'].includes(k) ? k : (EXT[k] || ''));
  };
  return { lines, langOf, langName };
})();

// ---------- highlight.js（vendor/highlight.min.js）：有就用它，没有就退回上面的轻量着色 ----------
const HLJS_EXT = {
  js: 'javascript', mjs: 'javascript', cjs: 'javascript', jsx: 'javascript', ts: 'typescript', tsx: 'typescript',
  swift: 'swift', py: 'python', rb: 'ruby', lua: 'lua', r: 'r', pl: 'perl', php: 'php',
  sh: 'bash', zsh: 'bash', bash: 'bash', env: 'bash', go: 'go', rs: 'rust', c: 'c', h: 'c', cc: 'cpp', cpp: 'cpp', hpp: 'cpp',
  m: 'objectivec', mm: 'objectivec', java: 'java', kt: 'kotlin', cs: 'csharp', sql: 'sql',
  json: 'json', jsonl: 'json', ipynb: 'json', css: 'css', scss: 'scss', less: 'less',
  html: 'xml', htm: 'xml', xml: 'xml', plist: 'xml', svg: 'xml', vue: 'xml', svelte: 'xml',
  yml: 'yaml', yaml: 'yaml', toml: 'ini', ini: 'ini', conf: 'ini', lock: 'ini', md: 'markdown', markdown: 'markdown',
  diff: 'diff', patch: 'diff', mk: 'makefile', graphql: 'graphql', gql: 'graphql',
};

function hljsLanguage(name) {
  if (!window.hljs || !name) return '';
  const key = String(name).toLowerCase();
  if (hljs.getLanguage(key)) return key;
  const mapped = HLJS_EXT[key];
  return mapped && hljs.getLanguage(mapped) ? mapped : '';
}

/** highlight.js 的结果可能有跨行的 span，拆成逐行时要在行尾闭合、下一行重新打开。 */
function splitHighlighted(html) {
  const out = [];
  const open = [];
  let cur = '';
  const re = /<span[^>]*>|<\/span>|\n|[^<\n]+|</g;
  let m;
  while ((m = re.exec(html)) !== null) {
    const t = m[0];
    if (t === '\n') {
      out.push(cur + '</span>'.repeat(open.length));
      cur = open.join('');
    } else if (t.startsWith('<span')) {
      open.push(t);
      cur += t;
    } else if (t === '</span>') {
      open.pop();
      cur += t;
    } else {
      cur += t;
    }
  }
  out.push(cur + '</span>'.repeat(open.length));
  return out;
}

/** 文件的若干行 → 每行的着色 HTML。 */
function highlightFileLines(lines, path) {
  const lang = hljsLanguage(path.toLowerCase().endsWith('makefile') ? 'makefile' : (path.split('.').pop() || ''));
  if (lang) {
    try {
      const parts = splitHighlighted(hljs.highlight(lines.join('\n'), { language: lang, ignoreIllegals: true }).value);
      if (parts.length === lines.length) return parts;
    } catch (_) { /* 退回轻量着色 */ }
  }
  return HL.lines(lines, HL.langOf(path));
}

/** 代码块（Markdown 围栏、聊天回答）→ 着色 HTML。 */
function highlightBlock(code, langName) {
  const lang = hljsLanguage(langName);
  if (lang) {
    try { return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value; } catch (_) { /* 退回 */ }
  }
  const own = HL.langName(langName);
  return own ? HL.lines(code.split('\n'), own).join('\n') : escapeHtml(code);
}
