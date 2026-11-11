'use strict';

// 图标、三位的配置（模型、思考强度、权限选项）。最先加载。

// ===== 官方图标 =====
const ICONS = {
  gemini: '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="url(#gemini-grad)" d="M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81"/></svg>',
  claude: '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="#D97757" d="M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z"/></svg>',
  gpt: '<svg viewBox="0 0 158.7128 157.296" aria-hidden="true"><path fill="currentColor" d="M60.8734,57.2556v-14.9432c0-1.2586.4722-2.2029,1.5728-2.8314l30.0443-17.3023c4.0899-2.3593,8.9662-3.4599,13.9988-3.4599,18.8759,0,30.8307,14.6289,30.8307,30.2006,0,1.1007,0,2.3593-.158,3.6178l-31.1446-18.2467c-1.8872-1.1006-3.7754-1.1006-5.6629,0l-39.4812,22.9651ZM131.0276,115.4561v-35.7074c0-2.2028-.9446-3.7756-2.8318-4.8763l-39.481-22.9651,12.8982-7.3934c1.1007-.6285,2.0453-.6285,3.1458,0l30.0441,17.3024c8.6523,5.0341,14.4708,15.7296,14.4708,26.1107,0,11.9539-7.0769,22.965-18.2461,27.527v.0021ZM51.593,83.9964l-12.8982-7.5497c-1.1007-.6285-1.5728-1.5728-1.5728-2.8314v-34.6048c0-16.8303,12.8982-29.5722,30.3585-29.5722,6.607,0,12.7403,2.2029,17.9324,6.1349l-30.987,17.9324c-1.8871,1.1007-2.8314,2.6735-2.8314,4.8764v45.6159l-.0014-.0015ZM79.3562,100.0403l-18.4829-10.3811v-22.0209l18.4829-10.3811,18.4812,10.3811v22.0209l-18.4812,10.3811ZM91.2319,147.8591c-6.607,0-12.7403-2.2031-17.9324-6.1344l30.9866-17.9333c1.8872-1.1005,2.8318-2.6728,2.8318-4.8759v-45.616l13.0564,7.5498c1.1005.6285,1.5723,1.5728,1.5723,2.8314v34.6051c0,16.8297-13.0564,29.5723-30.5147,29.5723v.001ZM53.9522,112.7822l-30.0443-17.3024c-8.652-5.0343-14.471-15.7296-14.471-26.1107,0-12.1119,7.2356-22.9652,18.403-27.5272v35.8634c0,2.2028.9443,3.7756,2.8314,4.8763l39.3248,22.8068-12.8982,7.3938c-1.1007.6287-2.045.6287-3.1456,0ZM52.2229,138.5791c-17.7745,0-30.8306-13.3713-30.8306-29.8871,0-1.2585.1578-2.5169.3143-3.7754l30.987,17.9323c1.8871,1.1005,3.7757,1.1005,5.6628,0l39.4811-22.807v14.9435c0,1.2585-.4721,2.2021-1.5728,2.8308l-30.0443,17.3025c-4.0898,2.359-8.9662,3.4605-13.9989,3.4605h.0014ZM91.2319,157.296c19.0327,0,34.9188-13.5272,38.5383-31.4594,17.6164-4.562,28.9425-21.0779,28.9425-37.908,0-11.0112-4.719-21.7066-13.2133-29.4143.7867-3.3035,1.2595-6.607,1.2595-9.909,0-22.4929-18.2471-39.3247-39.3251-39.3247-4.2461,0-8.3363.6285-12.4262,2.045-7.0792-6.9213-16.8318-11.3254-27.5271-11.3254-19.0331,0-34.9191,13.5268-38.5384,31.4591C11.3255,36.0212,0,52.5373,0,69.3675c0,11.0112,4.7184,21.7065,13.2125,29.4142-.7865,3.3035-1.2586,6.6067-1.2586,9.9092,0,22.4923,18.2466,39.3241,39.3248,39.3241,4.2462,0,8.3362-.6277,12.426-2.0441,7.0776,6.921,16.8302,11.3251,27.5271,11.3251Z"/></svg>',
  deepseek: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="#4D6BFE" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M3 13.2c0-3.5 3-6.2 7-6.2 3.6 0 6 2 7.2 4.6 1-.3 1.9-1.1 2.3-2.3.6 1.2 1.3 1.9 2.3 2.2-.9.5-1.5 1.5-1.6 2.6-.3 3-3.2 4.9-7.7 4.9H9.4C5.6 19 3 16.6 3 13.2z"/><path d="M7.6 12.4h.01"/><path d="M10.2 4.6c.2-1 .9-1.8 1.9-2M10.2 4.6c-.4-.9-1.2-1.5-2.2-1.6"/></svg>',
};

// ===== 界面小图标（线条） =====
const lineIcon = (body, cls = '') =>
  `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"${cls ? ` class="${cls}"` : ''}>${body}</svg>`;
const UI = {
  folder: lineIcon('<path d="M3 7.5A2.5 2.5 0 0 1 5.5 5H9l2 2.2h7.5A2.5 2.5 0 0 1 21 9.7v7.8a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5z"/>'),
  folderOpen: lineIcon('<path d="M3 17.5V7.5A2.5 2.5 0 0 1 5.5 5H9l2 2.2h6.5A2.5 2.5 0 0 1 20 9.7V11"/><path d="M3.6 18.4l2.3-6.1A2 2 0 0 1 7.8 11h12.4a1 1 0 0 1 .94 1.35l-2.2 6.1A2.4 2.4 0 0 1 16.7 20H5a1.5 1.5 0 0 1-1.4-1.6z"/>'),
  folderPlus: lineIcon('<path d="M3 7.5A2.5 2.5 0 0 1 5.5 5H9l2 2.2h7.5A2.5 2.5 0 0 1 21 9.7v7.8a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5z"/><path d="M12 10.3v6.4M8.8 13.5h6.4"/>'),
  more: '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="5.5" r="1.7"/><circle cx="12" cy="12" r="1.7"/><circle cx="12" cy="18.5" r="1.7"/></svg>',
  info: lineIcon('<circle cx="12" cy="12" r="8.5"/><path d="M12 11v5.5M12 7.8h.01"/>'),
  caret: lineIcon('<path d="M6 15l6-6 6 6"/>', 'caret'),
  shield: lineIcon('<path d="M12 3l7 3v5.5c0 4.6-3 8.1-7 9.5-4-1.4-7-4.9-7-9.5V6z"/>'),
  check: lineIcon('<path d="M5 12.5l4.5 4.5L19 7.5"/>'),
  copy: lineIcon('<rect x="8.5" y="8.5" width="11.5" height="11.5" rx="2.5"/><path d="M15.5 8.5V6.5a2.5 2.5 0 0 0-2.5-2.5H6.5A2.5 2.5 0 0 0 4 6.5V13a2.5 2.5 0 0 0 2.5 2.5h2"/>'),
  plus: lineIcon('<path d="M12 5v14M5 12h14"/>'),
  refresh: lineIcon('<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 5v6h-6"/>'),
  trash: lineIcon('<path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3"/>'),
  send: lineIcon('<path d="M12 19V5M5.5 11.5L12 5l6.5 6.5"/>'),
  stop: '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="7" y="7" width="10" height="10" rx="2"/></svg>',
  sidebar: lineIcon('<rect x="3" y="4.5" width="18" height="15" rx="2.5"/><path d="M9 4.5v15"/>'),
  file: lineIcon('<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>'),
  filePlus: lineIcon('<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5M12 11v6M9 14h6"/>'),
  pencil: lineIcon('<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="M13.5 6.5l4 4"/>'),
  terminal: lineIcon('<rect x="3" y="4.5" width="18" height="15" rx="2.5"/><path d="M7 10l3 2.5L7 15M12.5 15H17"/>'),
  search: lineIcon('<circle cx="11" cy="11" r="6.5"/><path d="M20 20l-4.2-4.2"/>'),
  globe: lineIcon('<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.5 2.6 2.5 14.4 0 17M12 3.5c-2.5 2.6-2.5 14.4 0 17"/>'),
  listIcon: lineIcon('<path d="M9 6h11M9 12h11M9 18h11M4.5 6h.01M4.5 12h.01M4.5 18h.01"/>'),
  agent: lineIcon('<circle cx="12" cy="8" r="3.5"/><path d="M5 20a7 7 0 0 1 14 0"/>'),
  tool: lineIcon('<path d="M14.5 5.5a4 4 0 0 0 4.9 4.9l-9 9a2.1 2.1 0 0 1-3-3l9-9a4 4 0 0 1-1.9-1.9z"/>'),
  alert: lineIcon('<path d="M12 4l9 16H3z"/><path d="M12 10v4M12 17h.01"/>'),
  think: lineIcon('<path d="M12 3l1.8 4.7L18.5 9l-4.7 1.8L12 15.5l-1.8-4.7L5.5 9l4.7-1.3z"/><path d="M18.5 15l.8 2 2 .8-2 .8-.8 2-.8-2-2-.8 2-.8z"/>'),
  chevron: lineIcon('<path d="M9 6l6 6-6 6"/>', 'chev'),
  reveal: lineIcon('<path d="M3 7.5A2.5 2.5 0 0 1 5.5 5H9l2 2.2h7.5A2.5 2.5 0 0 1 21 9.7v7.8a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5z"/><path d="M12 11v5M9.5 13.5L12 16l2.5-2.5"/>'),
  external: lineIcon('<path d="M14 4h6v6M20 4l-9 9M18 14v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4"/>'),
  close: lineIcon('<path d="M6 6l12 12M18 6L6 18"/>'),
  expand: lineIcon('<path d="M14 4h6v6M10 20H4v-6M20 4l-7 7M4 20l7-7"/>'),
  spinner: '<svg viewBox="0 0 24 24" class="spin" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M12 3a9 9 0 1 1-9 9" opacity=".9"/></svg>',
  arrowUp: lineIcon('<path d="M12 19V6M6.5 11.5L12 6l5.5 5.5"/>'),
  bolt: lineIcon('<path d="M13 3L5 14h6l-1 7 8-11h-6z"/>'),
  reset: lineIcon('<path d="M4 12a8 8 0 1 0 2.6-5.9"/><path d="M4 4v4.5h4.5"/>'),
  back: lineIcon('<path d="M15 6l-6 6 6 6"/>'),
  gear: lineIcon('<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33 1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82 1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>'),
};

// ===== 三位 AI 娘的配置：功能区完全一致，只是选项内容不同 =====
// 思考强度：名字用英文（和 Codex 桌面版一样首字母大写），后面是悬停时的说明
const EFFORTS = {
  off: ['Off', '不思考，直接回答'],
  low: ['Low', '最快，适合简单问题'],
  medium: ['Medium', '速度和深度均衡'],
  high: ['High', '深度推理'],
  xhigh: ['XHigh', '更慢、更仔细'],
  max: ['Max', '很慢、非常仔细'],
  ultra: ['Ultra', '最慢、最彻底（Codex 的最高档，部分模型才有）'],
  ultracode: ['Ultracode', 'Claude Code 的最高档：xhigh 再加多智能体编排，最彻底也最费用量'],
};
const effortOptions = (...keys) => keys.map(v => ({ v, name: EFFORTS[v][0], desc: EFFORTS[v][1] }));
const SLEEP_OPTIONS = [
  { v: '20', name: '20 秒' }, { v: '45', name: '45 秒', desc: '推荐' }, { v: '120', name: '2 分钟' },
  { v: '300', name: '5 分钟' }, { v: '0', name: '从不自动睡觉' },
];

const AGENTS = {
  gemini: {
    name: '极其猫', brand: 'Gemini', cli: 'agy', cliTitle: '本机 Antigravity CLI（agy）',
    install: { how: '安装 Antigravity，然后在终端运行 agy 按提示登录', url: 'https://antigravity.google/' },
    // tip：悬停说明；fast：有没有 fast 档；efforts：这个模型支持的思考强度（不写 = 全部）
    models: [
      { v: 'gemini-4-argon', name: 'Gemini 4 Argon' },
      { v: 'gemini-3.8-flash', name: 'Gemini 3.8 Flash' },
      { v: 'claude-opus-5-5', name: 'Claude Opus 5.5', tip: '通过 agy 调用' },
      { v: 'claude-sonnet-5-5', name: 'Claude Sonnet 5.5', tip: '通过 agy 调用' },
      { v: 'gpt-oss-120b', name: 'GPT-OSS 120B', tip: '开源模型，思考强度固定为中等', efforts: ['medium'] },
    ],
    model: 'gemini-4-argon',
    efforts: effortOptions('low', 'medium', 'high'),
    effort: 'medium',
    perms: [
      { v: 'bypassPermissions', name: '最高权限', desc: '自动批准所有读写和命令' },
      { v: 'accept-edits', name: '自动改文件', desc: '自动批准文件修改，跑命令前会问你' },
      { v: 'default', name: '默认', desc: '跑命令、改文件前会问你' },
      { v: 'plan', name: '只读规划', desc: '先做计划，动手前会问你' },
    ],
    perm: 'bypassPermissions',
    safePerm: 'default',
    skins: [{ v: 'default', name: 'Q版二头身' }],
    skin: 'default',
    clickLines: ['喵呜～✨', '呼噜噜 💜', '嘿嘿，痒痒的 🐾', '在陪你写代码哟 ✦', '摸摸头 +1 💖'],
    particles: ['✦', '✨', '💜', '⭐', '💖'],
    readParticles: ['📖', '🔍', '✦'],
    workParticles: ['</>', '✦', '⚡', '{}', '✨'],
    thinkLine: '思考中…✦',
    doneLine: '喵呜～✨',
    dragLine: '哇啊 > <',
  },
  claude: {
    name: '克劳蒂娜', brand: 'Claude', cli: 'Claude Code', cliTitle: '本机 Claude Code CLI（claude）',
    install: { cmd: 'npm install -g @anthropic-ai/claude-code', how: '装好后在终端运行 claude 登录', url: 'https://docs.anthropic.com/claude-code' },
    models: [
      // 用 Claude Code 自己的模型别名（opus / fable / sonnet / haiku）：它升级后别名指向新版本，这里不用改
      { v: 'opus', name: 'Opus 5.5', fast: true },
      { v: 'fable', name: 'Fable 5.2', fast: true },
      { v: 'sonnet', name: 'Sonnet 5.5' },
      { v: 'haiku', name: 'Haiku 5.5' },
    ],
    model: 'opus',
    efforts: effortOptions('low', 'medium', 'high', 'xhigh', 'max', 'ultracode'),
    effort: 'high',
    perms: [
      { v: 'bypassPermissions', name: '最高权限', desc: '自动批准所有读写和命令' },
      { v: 'acceptEdits', name: '自动改文件', desc: '改文件不问，跑命令前先问你' },
      { v: 'auto', name: '自动判断', desc: '由 Claude Code 判断操作是否安全' },
      { v: 'plan', name: '先做计划', desc: '只读着做计划，你批准后再动手' },
    ],
    perm: 'bypassPermissions',
    safePerm: 'acceptEdits',
    skins: [{ v: 'v2', name: 'Q版二头身' }],
    skin: 'v2',
    clickLines: ['在呢 ✨', '随时待命 📖', '摸摸头 +1 ✨', '有什么需要帮忙的？'],
    particles: ['✦', '✨', '📖', '⭐', '🧡'],
    readParticles: ['📖', '🔍', '📜'],
    workParticles: ['</>', '🪶', '✦', '{}', '✨'],
    thinkLine: '思考中…',
    doneLine: '处理完了 ✨',
    dragLine: '……放手。',
  },
  gpt: {
    name: '吉佩缇', brand: 'Codex', cli: 'Codex', cliTitle: '本机 Codex CLI（codex）',
    install: { cmd: 'npm install -g @openai/codex', how: '装好后在终端运行 codex 登录', url: 'https://github.com/openai/codex' },
    models: [
      // 和 codex 的 model/list 一致（CLI 报上来新的会自动换掉这份）；Luna 没有 ultra；都有 Fast 档
      { v: 'gpt-6.1-sol', name: 'GPT-6.1-Sol', fast: true },
      { v: 'gpt-6-astra', name: 'GPT-6-Astra', fast: true },
      { v: 'gpt-6.1-terra', name: 'GPT-6.1 Terra', fast: true },
      { v: 'gpt-6-sol', name: 'GPT-6-Sol', fast: true },
      { v: 'gpt-6-luna', name: 'GPT-6-Luna', fast: true, efforts: ['low', 'medium', 'high', 'xhigh', 'max'] },
      { v: 'gpt-5.6-sol', name: 'GPT-5.6-Sol', fast: true },
      { v: 'gpt-5.6-terra', name: 'GPT-5.6-Terra', fast: true },
      { v: 'gpt-5.6-luna', name: 'GPT-5.6-Luna', fast: true, efforts: ['low', 'medium', 'high', 'xhigh', 'max'] },
    ],
    model: 'gpt-6-astra',
    efforts: effortOptions('low', 'medium', 'high', 'xhigh', 'max', 'ultra'),
    effort: 'high',
    perms: [
      { v: 'danger-full-access', name: '最高权限', desc: '不加沙盒，可读写任何文件、联网' },
      { v: 'workspace-write', name: '仅工作空间可写', desc: '只能修改工作空间里的文件' },
      { v: 'read-only', name: '只读', desc: '不修改任何文件' },
    ],
    perm: 'danger-full-access',
    safePerm: 'workspace-write',
    skins: [{ v: 'v2', name: 'Q版二头身' }],
    skin: 'v2',
    clickLines: ['在呢 ✨', '随时待命 ☁️', '摸摸头 +1 💎', '有什么需要帮忙的？'],
    particles: ['✨', '☁️', '💎', '💜'],
    readParticles: ['🔍', '☁️', '📊'],
    workParticles: ['</>', '⚡', '💎', '{}', '✨'],
    thinkLine: '思考中…✨',
    doneLine: '完成啦 ✨',
    dragLine: '哇啊 > <',
  },
  deepseek: {
    // 走 dsh（DeepSeek Harness）的本机服务；模型和每个模型的思考强度由它报上来（Agents/DeepSeekRun.swift 的 noteDshModels）
    name: '大肥鱼', brand: 'DeepSeek', cli: 'dsh', cliTitle: '本机 DeepSeek Harness（dsh）',
    install: { cmd: 'npm install -g @deepseek-ai/dsh', how: '装好后按 dsh 的说明配置 DeepSeek 的 API 密钥', url: 'https://github.com/deepseek-ai/deepseek-harness' },
    models: [
      // keep：dsh 报上来的模型目录只有用户在它的配置里列出的那几个，Flash 不在目录里也能选，所以一直留着
      { v: 'deepseek-v4-flash', name: 'DeepSeek-V4-Flash', efforts: ['off', 'low', 'high', 'max'], keep: true },
      { v: 'deepseek-v4-pro', name: 'DeepSeek-V4-Pro', efforts: ['off', 'low', 'high', 'max'] },
    ],
    model: 'deepseek-v4-flash',
    efforts: effortOptions('off', 'low', 'high', 'max'),
    effort: 'high',
    perms: [
      { v: 'danger-full-access', name: '最高权限', desc: '不加沙盒，不来问，可读写任何文件' },
      { v: 'workspace-write', name: '仅工作空间可写', desc: '只能改工作空间里的文件，出了这个范围会来问你' },
      { v: 'read-only', name: '只读', desc: '不修改任何文件，要改会来问你' },
    ],
    perm: 'danger-full-access',
    safePerm: 'workspace-write',
    skins: [{ v: 'v2', name: 'Q版二头身' }],
    skin: 'v2',
    clickLines: ['在呢～🐳', '饭好了叫我 🍚', '才、才不胖！', '摸摸头 +1 💙', '摸鱼中…被发现了'],
    particles: ['💧', '🫧', '🐳', '💙', '✨'],
    readParticles: ['📖', '🫧', '🔍'],
    workParticles: ['</>', '💧', '🫧', '{}', '✨'],
    thinkLine: '深度思考中…🫧',
    doneLine: '做完啦，开饭 🍚',
    dragLine: '呜哇，放我下来！',
  },
};
// 支持的全部 AI，和界面上启用着的那几位。启用哪几位记在本地，可以随时增删（ui/agents.js）；
// AGENT_IDS 是同一个数组，增删时原地改，所以到处的 AGENT_IDS.forEach 自动跟着变。状态（S）、桌宠这些对「全部」都建好，没启用的只是不放到界面上。
const ALL_AGENT_IDS = Object.keys(AGENTS);
const AGENT_IDS = (() => {
  let saved = null;
  try { saved = JSON.parse(localStorage.getItem('aihub_enabled_agents')); } catch (_) { /* 忽略 */ }
  const list = Array.isArray(saved) ? ALL_AGENT_IDS.filter(id => saved.includes(id)) : [];
  return list.length ? list : ['gemini', 'claude', 'gpt'].filter(id => ALL_AGENT_IDS.includes(id));
})();
// 写死的模型列表只是 CLI 还没报上来之前的样子；CLI 一报（预热、第一次回答时），菜单就换成它的（见 ui/menus.js 的 onAgentModels）
const BUILTIN_MODELS = Object.fromEntries(ALL_AGENT_IDS.map(id => [id, AGENTS[id].models]));
// 以前写死的条目 → CLI 里对应的名字（选着旧条目的会自动换过去）
const MODEL_ALIASES = { 'claude-opus-5-5': 'opus', 'claude-opus-5-5[1m]': 'opus', 'claude-fable-5-1[1m]': 'fable', 'claude-fable-5[1m]': 'fable', 'claude-sonnet-5-5': 'sonnet', 'gpt-oss-120b': 'gpt-oss-120b-medium' };
/** 启动时就解码好的帧：待机、眨眼、蹲下、睡觉、开心这几张随时会用到。其余的（思考 / 查阅 / 施工 / 拖拽 / 睡觉 / 开心的循环帧）用到时才加载 */
const FRAME_KEYS = ['idle', 'idle_blink_half', 'idle_blink_closed', 'crouch', 'sleep', 'happy'];
const BUSY_STATES = new Set(['thinking', 'reading', 'working']);
/** 有骨骼模型时，这些状态仍然用逐帧 / 原来的素材 */
const RIG_OFF_STATES = new Set(['thinking', 'reading', 'working', 'sleep', 'walk', 'happy']);
/** 走路：AI 逐帧的 8 帧（walk_f0…f7），每帧时长 */
const WALK_FRAMES = 8, WALK_FRAME_SEC = 0.095;
const READING_KINDS = new Set(['read', 'list', 'search', 'web']);
const WORKING_KINDS = new Set(['edit', 'write', 'delete', 'command', 'tool', 'agent', 'todo', 'text']);
const KIND_ICONS = {
  think: '💭', read: '📖', list: '📂', search: '🔍', web: '🌐',
  edit: '✏️', write: '📝', delete: '🗑️', command: '⚡', text: '✍️',
  todo: '📋', agent: '🤖', tool: '🛠️', error: '⚠️', denied: '🚫',
};
const PHASE_META = {
  // frameMs：原图 4 帧时每帧的时长；有中间帧时一圈 8 帧、每帧一半。换得太快，AI 画的每帧细节不完全一样，会像果冻在抖
  thinking: { label: '思考中', icon: '🧠', workLabel: '正在思考', frameMs: 540, fadeMs: 240 },
  reading:  { label: '查阅中', icon: '📖', workLabel: '正在查阅', frameMs: 360, fadeMs: 160 },
  working:  { label: '施工中', icon: '🛠️', workLabel: '正在施工', frameMs: 300, fadeMs: 95 },
};
