// 后端自测：不开窗口，直接调用 AppDelegate 的历史读取 / 进程管理 / CLI 调用。
// 编译：tools/test.sh（编译并跑离线测试），或 swiftc -D HUB_SELFTEST Sources/**/*.swift tools/tests/*.swift -o build/selftest -framework Cocoa -framework WebKit -lsqlite3
// 子命令清单只写在这里（docs/ARCHITECTURE.md 指过来）。
// 离线、自动跑（tools/test.sh 会调）：
//      build/selftest offline         解析、历史、进程、预热、用量、git 和预览；只跑某几组用 tools/test.sh --only 词1,词2（按组名匹配），不再为单组设子命令
//      build/selftest deepseek <场景> <临时目录>  假 HTTP/WebSocket 服务（通常由 tools/test-deepseek.py 驱动）
//      build/selftest preview-fixes [git] [browser] [docs]  改动归因、浏览器和搜索、文档转换（不写段名就按顺序全跑）
//      build/selftest preview-bridge  无窗口 WebKit、双向桥、文档/图片/PDF、浏览器任务清理
//      python3 tools/test-suspend.py   自建实例 App/CLI/双方 STOP/CONT（各 4.5 秒）
// 只给别的测试当帮手、不直接用：hold-session-file <文件>（gemini-history-regressions 用它扮外部持库进程）、
//      suspend-case …（test-suspend.py 起的被测实例）。
// 手动、不判对错或要真实 CLI 和会话（排查问题时用，大多在 selftest-commands.swift）：
//      build/selftest git-race        并发查 git；用 -sanitize=thread 编译可验证首次初始化竞争
//      build/selftest search-benchmark [词] [临时目录]  四位正文搜索跑两遍的耗时，手动看性能用、不判对错；给临时目录则测磁盘缓存复用
//      build/selftest list [条数] [agent]            四位的历史列表 + 打开第一条；给条数时多列几条并带会话 ID（清理测试会话时用）
//      build/selftest load <agent> <会话ID> [关键字]  打开一个会话并打印消息，给关键字时统计含它的用户消息
//      build/selftest dump <输出.json> [每位条数]     导出最近会话的消息，给网页渲染测试用
//      build/selftest project <agent> <工作空间>     只读：统计这个工作空间里的全部会话
//      build/selftest delete <agent> <会话ID>         删一个会话
//      build/selftest deletemany <agent> <会话ID>…    批量删
//      build/selftest deleteproject <agent> <工作空间> 和界面「删除项目」同一条路：删这个工作空间的全部会话（测试后清理）
//      build/selftest proc            子进程输出 / 停止 / 后台孙进程
//      build/selftest ask <agent> <权限> <提示词> [工作空间] [模型] [会话ID]  真实调用一次 CLI，给会话 ID 就续聊
//      build/selftest e2e <agent> <目录>              最高权限建文件 → 同一会话追问 → 中途停止
//      build/selftest live <agent> <空目录> [模型] [第几项]  交互式：来问→允许 / 拒绝、中途补充、停止、接着问、提问卡（livetest.swift）
//      build/selftest orphan <agent> <目录> <秒数>    命令运行中停止，检查没有残留进程
//      build/selftest parallel <agent> <目录>         同一位同时两个会话，单独停一个不影响另一个
//      build/selftest models <agent> <目录>           模型菜单里的每个模型发一句（只读模式），看 CLI 认不认
//      build/selftest docpreview <文档>…            Word / Excel / PPT 转预览网页（第二次应命中缓存）
//      build/selftest docbrowser <docx> <临时目录>  真的走内置浏览器：地址栏回报、改了刷新、坏文件、停止、后退
//      build/selftest weberror <空闲端口> <临时目录> 错误页：刷新重试不多占历史、服务器起来后恢复、后退
// agent 是 claude、gpt（Codex）、gemini、deepseek；有的子命令只认前三位，以各自的用法提示为准。
import Cocoa
import WebKit
import PDFKit

func runSelfTest() {
    let args = Array(CommandLine.arguments.dropFirst())
    let d = AppDelegate()
    switch args.first ?? "list" {
    case "hold-session-file":
        guard args.count == 2, let file = FileHandle(forReadingAtPath: args[1]) else { exit(1) }
        withExtendedLifetime(file) {
            FileHandle.standardOutput.write(Data("ready".utf8))
            _ = FileHandle.standardInput.availableData
        }
    case "search-benchmark":
        runConversationSearchBenchmark()
    case "suspend-case":
        runSuspendCase(args)
    case "preview-bridge":
        runPreviewBridgeTests()
    case "git-race":
        runGitRaceTest()
    case "live":   // 交互式回答：审批、拒绝、中途补充、停止（tools/tests/livetest.swift，要用真的 CLI）
        runLiveTests(args)
    case "offline":
        runOfflineSuite()
    case "deepseek":
        runDeepSeekTests(Array(args.dropFirst()))
    case "preview-fixes":
        runPreviewFixSuite(Array(args.dropFirst()))
    default:
        runMaintenanceCommand(args, d)
    }
}

// 不开窗口的 WebKit/预览测试，网站数据及预览缓存都隔离；不读取真实 CLI 会话。
private func runPreviewBridgeTests() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let d = AppDelegate(), fm = FileManager.default
    let dir = NSTemporaryDirectory() + "aipethub-preview-" + UUID().uuidString
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    func js(_ code: String) -> Any? {
        var done = false, value: Any?
        d.webView.evaluateJavaScript(code) { v, e in value = v; done = true; if let e = e { print("JS: \(e)") } }
        check(waitUntil(runLoop: true) { done }, "JS 返回")
        return value
    }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.userContentController.add(d, name: "hubBridge")
    d.webView = HubWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
    d.container = FlippedView(frame: d.webView.frame)
    d.container.addSubview(d.webView)
    d.webView.loadHTMLString("<html><body>test</body></html>", baseURL: nil)
    check(waitUntil(runLoop: true) { !d.webView.isLoading }, "页面加载")
    d.sendToJS("onFileRead", ["reqId": 1, "content": "before-ready"])
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    _ = js("window.received=[]; window.onFileRead=d=>{received.push(d);if(d.reqId===11)webkit.messageHandlers.hubBridge.postMessage({action:'checkFiles',reqId:12,items:[]});}; window.onFilesChecked=d=>received.push(d); null;")
    check((js("received.length") as? Int) == 0, "未 ready 的消息当前会丢弃（记录现状）")
    let text = dir + "/中文#1.txt"
    try! "hello 中文🙂".write(toFile: text, atomically: true, encoding: .utf8)
    let encoded = String(data: try! JSONSerialization.data(withJSONObject: ["path": text]), encoding: .utf8)!
    _ = js("""
    const bad=[null,[],true,42,'text',{}, {action:[]}, {action:'unknown'},
      {action:'readFile',path:42,reqId:1},{action:'readFile',path:'x',reqId:'wrong'},
      {action:'checkFiles',reqId:1,items:1},{action:'askAgent',agent:'invalid',reqId:1,prompt:'x'},
      {action:'askAgent',agent:'gemini',reqId:[],prompt:'x'},
      {action:'steerAgent',agent:'gemini',reqId:1,text:null},
      {action:'answerAgentRequest',agent:'gemini',requestId:[]},
      {action:'chatImage',reqId:'wrong'}, {action:'loadConversation',agent:'gpt',conversationId:[]}];
    for(let i=0;i<50;i++)for(const v of bad)webkit.messageHandlers.hubBridge.postMessage(v);
    webkit.messageHandlers.hubBridge.postMessage({action:'readFile',...\(encoded),reqId:11}); null;
    """)
    check(waitUntil(runLoop: true) { (js("received.length") as? Int ?? 0) >= 2 }, "850 条畸形消息后读文件与回调重入都成功")
    check((js("received.find(d=>d.reqId===11)?.content") as? String) == "hello 中文🙂", "readFile 返回中文正文")
    _ = js("""
    window.badImages=[]; window.onAgentResponse=d=>badImages.push(d); window.onAgentSteer=d=>badImages.push(d);
    for (const agent of ['claude','gpt','gemini','deepseek']) for (const action of ['askAgent','steerAgent']) {
      webkit.messageHandlers.hubBridge.postMessage({action,agent,reqId:51,prompt:'看图',text:'补图',steerId:'s',images:['\(dir)/已移走.png'],workspace:'\(dir)/gone'});
    } null;
    """)
    check(waitUntil(runLoop: true) { js("badImages.length") as? Int == 8 }, "B2-13 四位的发送与补充都有回执")
    let results = js("badImages") as? [[String:Any]] ?? []
    check(results.allSatisfy { ($0["restoreDraft"] as? Bool == true) && (str($0,"reply") + str($0,"reason")).contains("已移走.png") }, "B2-13 缺少附件时退回并指明文件，实际 \(results.map { str($0,"state") + str($0,"reply") })")
    // 卡在回答收尾前，旧页面收过的已撤卡片不能随着还在等的卡片一起补发。
    let gate = DispatchSemaphore(value: 0)
    let cli = dir + "/b3-cli"
    try! installFakeCLI(at: cli, behavior: "backend")
    d.hooks.cliExecutable = cli
    d.hooks.askFinishing = { _ in gate.wait() }
    d.window = HubWindow(contentRect: d.webView.frame, styleMask: [], backing: .buffered, defer: true)
    _ = js("window.replays=[];window.onRestoreActiveTurn=d=>replays.push(d);webkit.messageHandlers.hubBridge.postMessage({action:'askAgent',agent:'claude',reqId:8713,prompt:'fixture',draft:{text:' 原问 ',paths:['/原.zip']},workspace:'" + dir + "'});null")
    check(waitUntil(runLoop: true) { d.procLock.lock(); defer { d.procLock.unlock() }; return d.asks["claude#8713"] != nil }, "重载夹具已收到提问")
    for rid in ["closed", "waiting"] {
        d.sendToJS("onAgentRequest", ["agent":"claude", "reqId":8713, "kind":"question", "requestId":rid])
    }
    d.sendToJS("onAgentRequestClosed", ["agent":"claude", "reqId":8713, "requestId":"closed"])
    // 卡片的记账在主队列上异步做：记完（只剩还在等的那张）再让页面报 pageReady，慢机器上不会抢在记账前面
    func pageCards() -> String { (d.pageTurns["claude#8713"]?.cards ?? []).map { str($0, "requestId") }.joined(separator: ",") }
    check(waitUntil(runLoop: true) { pageCards() == "waiting" }, "B3-13 原生已记下仍在等的卡，实际 \(d.pageTurns["claude#8713"] == nil ? "这一轮已不在" : pageCards())")
    _ = js("for(const body of [{action:'pageReady'},{action:'checkFiles',reqId:8714,items:[]}]) webkit.messageHandlers.hubBridge.postMessage(body);null")
    check(waitUntil(runLoop: true) { js("received.some(d=>d.reqId===8714)") as? Bool == true }, "pageReady 之后的桥消息已投递")
    let restored = js("replays.flatMap(r=>r.cards.map(c=>c.requestId))") as? [String] ?? []
    check(restored == ["waiting"], "B3-13 pageReady 恢复活动回答且只补发仍在等的卡，实际 \(restored)")
    _ = js("""
    for(const body of [{action:'steerAgent',agent:'claude',reqId:8713,steerId:'pending',text:'补充',draft:{text:'原文',paths:['/test.zip']}},
                       {action:'pageReady'}]) webkit.messageHandlers.hubBridge.postMessage(body);null
    """)
    check(waitUntil(runLoop: true) { js("replays.length") as? Int == 2 }, "排队后页面重新握手")
    let recovered = js("replays.at(-1).queue?.map(q=>q.draft.text)") as? [String] ?? []
    check(recovered == ["原文"], "未送达的补充随原回合恢复，实际 \(recovered)")
    eq(js("replays.at(-1).draft.paths[0]") as? String, "/原.zip", "网页重载保留首问的原始附件")
    _ = js("""
    for(const body of [{action:'queueOrder',agent:'claude',reqId:8713,ids:['pending'],
                        returnedQueue:{ids:['withdrawn','pending'],parts:{withdrawn:{text:'先撤回',paths:[]}}}},
                       {action:'pageReady'}]) webkit.messageHandlers.hubBridge.postMessage(body);null
    """)
    check(waitUntil(runLoop: true) { js("replays.at(-1).returnedQueue?.parts.withdrawn.text") as? String == "先撤回" },
          "网页重载保留已撤回补充在队列中的位置")
    gate.signal()
    _ = waitUntil(runLoop: true) { d.procLock.lock(); defer { d.procLock.unlock() }; return d.asks.isEmpty }
    d.hooks.cliExecutable = nil; d.hooks.askFinishing = nil
    // 模拟旧后台请求跨过网页重载返回：前端文件请求编号重新从 1 起。
    d.webView.loadHTMLString("<script>window.received=[];window.onFileRead=d=>received.push(d)</script>", baseURL: nil)
    check(waitUntil(runLoop: true) { !d.webView.isLoading }, "重载完成")
    d.sendToJS("onFileRead", ["reqId": 1, "content": "old-page-result"])
    check(waitUntil(runLoop: true) { (js("received.length") as? Int ?? 0) == 1 }, "旧页面消息可进入新页面（需协议代次方案）")

    d.hooks.browserJobLifetime = 0.15
    let job = try! JSONSerialization.data(withJSONObject: ["tool":"unknown"])
    for _ in 0..<30 { _ = d.browserPortMessage(1, job) }
    check(waitUntil(runLoop: true) { d.browserJobs.isEmpty }, "MCP 调用者退出后无人领取的结果会清理")
    let id = d.browserPortMessage(1, job)
    check(!d.browserPortMessage(2, id).isEmpty && d.browserPortMessage(2, id).isEmpty, "MCP 结果只领取一次")

    // 真实文件系统路径、图片、PDF 与缓存；转换器用假 qlmanage，缓存仅在临时目录。
    check(d.resolvePath("中文#1.txt", base: dir) == text, "文件名 # 按字面优先")
    check(d.resolvePath("中文#1.txt:12", base: dir) == text, "带行号路径")
    check(d.resolvePath(URL(fileURLWithPath: text).absoluteString, base: "") == text, "file URL 解码")
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    check(chatImageData(png, maxPixels: 640) != nil, "图片缩略图")
    check(chatImageData(Data("broken".utf8), maxPixels: 640) == nil, "坏图片返回 nil")
    let converter = dir + "/qlmanage"
    try! installFakeCLI(at: converter, behavior: "preview-document")
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: converter)
    TestHooks.quickLookExecutable = converter
    let doc = dir + "/file.docx"
    try! "fixture".write(toFile: doc, atomically: true, encoding: .utf8)
    let first = makeDocumentPreview(doc), hit = makeDocumentPreview(doc)
    check(first.file != nil && first.file == hit.file, "文档缓存命中")
    check(documentPreviewOrigin(first.file) == doc, "预览反查原文件")
    let html = first.file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    check(html.contains("Content-Security-Policy") && html.contains("function fit"), "转换结果注入样式和缩放")
    try! "fixture changed".write(toFile: doc, atomically: true, encoding: .utf8)
    check(makeDocumentPreview(doc).file != first.file, "文件修改后缓存失效")
    for i in 0..<15 {
        let p = dir + "/\(i).docx"
        try! "fixture".write(toFile: p, atomically: true, encoding: .utf8)
        check(makeDocumentPreview(p).file != nil, "缓存样本 \(i)")
    }
    check(((try? fm.contentsOfDirectory(atPath: docPreviewRoot.path)) ?? []).count == 12, "预览缓存最多 12 份")
    let stale = docPreviewRoot.appendingPathComponent(".tmp-stale")
    try! fm.createDirectory(at: stale, withIntermediateDirectories: true)
    try! fm.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-700)], ofItemAtPath:stale.path)
    pruneDocumentPreviews()
    check(!fm.fileExists(atPath: stale.path), "遗留转换临时目录清理")
    let rtf = dir + "/doc.rtf"
    try! #"{\rtf1\ansi hello}"#.write(toFile: rtf, atomically: true, encoding: .utf8)
    check(makeDocumentPreview(rtf).file != nil, "系统 RTF 转换")
    let page = PDFPage(image: NSImage(size: NSSize(width: 200, height: 300), flipped: false) { r in NSColor.white.setFill(); r.fill(); return true })!
    let pdf = PDFDocument(); pdf.insert(page, at: 0)
    let pdfPath = dir + "/file.pdf"; check(pdf.write(toFile: pdfPath), "生成测试 PDF")
    let b = d.browserView()
    b.loadFileURL(URL(fileURLWithPath: pdfPath), allowingReadAccessTo: URL(fileURLWithPath: dir))
    check(waitUntil(runLoop: true) { d.browserPDF != nil }, "本地 PDF 使用 PDFKit")
    d.placeBrowser(["visible":true,"x":0,"y":0,"w":400,"h":500])
    check(d.browserPDF?.frame == b.frame && d.browserPDF?.isHidden == false, "PDF 跟随面板尺寸")
    d.placeBrowser(["visible":false])
    check(d.browserPDF?.isHidden == true, "PDF 跟随隐藏")
    // 等待中的 browser_eval 在任务过期后返回，不能把结果重新塞回字典。
    b.loadHTMLString("<body>browser</body>", baseURL: nil)
    _ = waitUntil(runLoop: true) { !b.isLoading }; b.isHidden = false
    let late = try! JSONSerialization.data(withJSONObject: ["tool":"browser_eval","args":["script":"await new Promise(r=>setTimeout(r,400)); return 1;"]])
    _ = d.browserPortMessage(1, late)
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    check(d.browserJobs.isEmpty, "过期任务的迟到回调不能复活结果")
    d.terminateAllChildren()
    try? fm.removeItem(atPath: dir); try? fm.removeItem(at: docPreviewRoot)
    print("Preview/bridge checks=\(checks) failures=\(failures)")
    exit(failures == 0 ? 0 : 1)
}

private func runSuspendCase(_ args: [String]) -> Never {
    guard args.count == 2 else { exit(2) }
    let dir = args[1], d = AppDelegate(), fm = FileManager.default
    let cli = dir + "/cli.py"
    try! installFakeCLI(at: cli, behavior: "backend")
    try! fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:cli)
    try! "slow".write(toFile:dir+"/mode",atomically:true,encoding:.utf8)
    d.hooks.cliExecutable = cli
    let lock = NSLock()
    var response: [String:Any]?, usage = 0, progress = false, timerFired = false
    d.hooks.jsSink = { fn,p in
        lock.lock(); defer { lock.unlock() }
        if fn == "onAgentResponse" { response = p }
        if fn == "onAgentUsage" { usage += 1 }
        if fn == "onAgentStep" { progress = true }
    }
    var req = AskRequest(agent:"gemini",reqId:700,prompt:"fixture",model:"fixture",effort:"low",permissionMode:"bypassPermissions",workspace:dir,conversationId:"")
    req.browserTools = false
    let old = d.claudeLiveElsewhere("elsewhere-fixture")
    let warm = d.warmGemini(req)!
    warm.warmKey = d.warmKey(req); d.keepWarm("gemini",warm)
    d.ask(req)
    waitUntil(runLoop: true) { lock.lock(); defer { lock.unlock() }; return progress }
    guard let pid = d.runningPid(req.key) else { d.terminateAllChildren(); exit(3) }
    DispatchQueue.main.asyncAfter(deadline:.now()+1) { timerFired = true; d.loadUsage(agent:"gemini",force:true) }
    let info: [String:Any] = ["app":getpid(),"cli":pid]
    try! JSONSerialization.data(withJSONObject:info).write(to:URL(fileURLWithPath:dir+"/ready.json"),options:.atomic)
    waitUntil(runLoop: true, interval: 0.02) {
        lock.lock(); let done = response != nil && usage > 0; lock.unlock()
        return done && fm.fileExists(atPath:dir+"/resumed")
    }
    // 缓存已过 4 秒，模拟别处运行状态在暂停期间改变。
    let new = d.claudeLiveElsewhere("elsewhere-fixture")
    let stale = d.warmGemini(req)!
    stale.warmKey = d.warmKey(req)
    stale.startedAt = Date(timeIntervalSinceNow:-601)
    d.keepWarm("gemini",stale); d.dropWarm(olderThan:600)
    waitUntil(runLoop: true, interval: 0.02) { !stale.proc.isRunning }
    d.procLock.lock(); let empty = d.warmProcs.isEmpty && d.asks.isEmpty && d.usageLoading.isEmpty; d.procLock.unlock()
    lock.lock()
    let result: [String:Any] = ["reply":response?["reply"] ?? "", "usage":usage,"timer":timerFired,"empty":empty,"warmReaped":!stale.proc.isRunning,"oldStatus":old?.status ?? "","newStatus":new?.status ?? ""]
    lock.unlock()
    try! JSONSerialization.data(withJSONObject:result,options:.prettyPrinted).write(to:URL(fileURLWithPath:dir+"/result.json"))
    d.terminateAllChildren()
    exit(0)
}
