// 后端自测：不开窗口，直接调用 AppDelegate 的历史读取 / 进程管理 / CLI 调用。
// 编译：tools/test.sh（编译并跑离线测试），或 swiftc -D HUB_SELFTEST Sources/**/*.swift tools/tests/*.swift -o build/selftest -framework Cocoa -framework WebKit -lsqlite3
// 用法：build/selftest offline         离线：解析、历史、进程、预热、用量、git 和预览
//      build/selftest deepseek <场景> <临时目录>  离线：假 HTTP/WebSocket 服务（通常由 tools/test-deepseek.py 驱动）
//      build/selftest preview-fixes   离线：浏览器、搜索、预览与改动归因
//      build/selftest preview-bridge  离线：无窗口 WebKit、双向桥、文档/图片/PDF、浏览器任务清理
//      python3 tools/test-suspend.py   离线：自建实例 App/CLI/双方 STOP/CONT（各 4.5 秒）
//      build/selftest git-race        并发查 git；用 -sanitize=thread 编译可验证首次初始化竞争
//      build/selftest list            三位的历史列表 + 打开第一条
//      build/selftest proc            子进程输出 / 停止 / 后台孙进程
//      build/selftest ask <agent> <权限> <提示词>   真实调用一次 CLI，可在工作空间和模型后指定续聊的会话 ID
//      build/selftest project <agent> <工作空间>     只读：统计这个工作空间里的全部会话
//      build/selftest docpreview <文档>…            Word / Excel / PPT 转预览网页（第二次应命中缓存）
//      build/selftest docbrowser <docx> <临时目录>  真的走内置浏览器：地址栏回报、改了刷新、坏文件、停止、后退
//      build/selftest weberror <空闲端口> <临时目录> 错误页：刷新重试不多占历史、服务器起来后恢复、后退
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
    case "history-activity":
        testHistoryActivity(); testAcpModelSelection()
        exit(failures == 0 ? 0 : 1)
    case "typing-resume":
        testTypingResume(); exit(failures == 0 ? 0 : 1)
    case "session-ownership":
        testSessionOwnership()
        exit(failures == 0 ? 0 : 1)
    case "conversation-search-disk":
        testConversationSearchDisk()
        exit(failures == 0 ? 0 : 1)
    case "history-read-efficiency":
        testHistoryReadEfficiency()
        exit(failures == 0 ? 0 : 1)
    case "codex-projection":
        testCodexProjectionFreshness()
        exit(failures == 0 ? 0 : 1)
    case "live-initialization":
        testLiveInitialization()
        exit(failures == 0 ? 0 : 1)
    case "codex-home":
        testCodexConfiguredHome()
        exit(failures == 0 ? 0 : 1)
    case "gemini-history-regressions":
        testGeminiHistoryRegressions()
        exit(failures == 0 ? 0 : 1)
    case "claude-capability":
        testClaudeCapabilityRefresh()
        exit(failures == 0 ? 0 : 1)
    case "codex-mixed-history":
        testCodexMixedHistory()
        exit(failures == 0 ? 0 : 1)
    case "steer-images":
        testCodexHistory()
        testSteerImages()
        exit(failures == 0 ? 0 : 1)
    case "conversation-search":
        testConversationSearch()
        exit(failures == 0 ? 0 : 1)
    case "search-benchmark":
        runConversationSearchBenchmark()
    case "suspend-case":
        runSuspendCase(args)
    case "preview-bridge":
        runPreviewBridgeTests()
    case "usage-numbers":
        runUsageNumberTests()
    case "git-race":
        runGitRaceTest()
    case "file-preview":
        runFilePreviewTests()
    case "more":
        runMoreTests()
    case "ask-state":
        runAskStateTests()
    case "cli-compatibility":
        runCLICompatibilityTests()
    case "boundaries":
        runBoundaryTests()
    case "live":   // 交互式回答：审批、拒绝、中途补充、停止（tools/tests/livetest.swift，要用真的 CLI）
        runLiveTests(args)
    case "codex-retry-logs":   // 只读验证上次现场留下的三条 429 日志
        verifyCodexRetryRealLogs()
    case "offline":
        runOfflineSuite()
    case "deepseek":
        runDeepSeekTests(Array(args.dropFirst()))
    case "preview-fixes":
        runPreviewFixSuite()
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
    var checks = 0, failures = 0
    func check(_ ok: Bool, _ name: String) { checks += 1; if !ok { failures += 1; print("✗ \(name)") } }
    func spin(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }
    func js(_ code: String) -> Any? {
        var done = false, value: Any?
        d.webView.evaluateJavaScript(code) { v, e in value = v; done = true; if let e = e { print("JS: \(e)") } }
        check(spin(5) { done }, "JS 返回")
        return value
    }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.userContentController.add(d, name: "hubBridge")
    d.webView = HubWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
    d.container = FlippedView(frame: d.webView.frame)
    d.container.addSubview(d.webView)
    d.webView.loadHTMLString("<html><body>test</body></html>", baseURL: nil)
    check(spin(5) { !d.webView.isLoading }, "页面加载")
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
    check(spin(5) { (js("received.length") as? Int ?? 0) >= 2 }, "850 条畸形消息后读文件与回调重入都成功")
    check((js("received.find(d=>d.reqId===11)?.content") as? String) == "hello 中文🙂", "readFile 返回中文正文")
    // 模拟旧后台请求跨过网页重载返回：前端文件请求编号重新从 1 起。
    d.webView.loadHTMLString("<script>window.received=[];window.onFileRead=d=>received.push(d)</script>", baseURL: nil)
    check(spin(5) { !d.webView.isLoading }, "重载完成")
    d.sendToJS("onFileRead", ["reqId": 1, "content": "old-page-result"])
    check(spin(3) { (js("received.length") as? Int ?? 0) == 1 }, "旧页面消息可进入新页面（需协议代次方案）")

    d.hooks.browserJobLifetime = 0.15
    let job = try! JSONSerialization.data(withJSONObject: ["tool":"unknown"])
    for _ in 0..<30 { _ = d.browserPortMessage(1, job) }
    check(spin(1) { d.browserJobs.isEmpty }, "MCP 调用者退出后无人领取的结果会清理")
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
    check(spin(5) { d.browserPDF != nil }, "本地 PDF 使用 PDFKit")
    d.placeBrowser(["visible":true,"x":0,"y":0,"w":400,"h":500])
    check(d.browserPDF?.frame == b.frame && d.browserPDF?.isHidden == false, "PDF 跟随面板尺寸")
    d.placeBrowser(["visible":false])
    check(d.browserPDF?.isHidden == true, "PDF 跟随隐藏")
    // 等待中的 browser_eval 在任务过期后返回，不能把结果重新塞回字典。
    b.loadHTMLString("<body>browser</body>", baseURL: nil)
    _ = spin(5) { !b.isLoading }; b.isHidden = false
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
    d.jsSink = { fn,p in
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
    let readyBy = Date().addingTimeInterval(8)
    while Date() < readyBy {
        lock.lock(); let ready = progress; lock.unlock()
        if ready { break }
        RunLoop.current.run(until:Date().addingTimeInterval(0.01))
    }
    guard let pid = d.runningPid(req.key) else { d.terminateAllChildren(); exit(3) }
    DispatchQueue.main.asyncAfter(deadline:.now()+1) { timerFired = true; d.loadUsage(agent:"gemini",force:true) }
    let info: [String:Any] = ["app":getpid(),"cli":pid]
    try! JSONSerialization.data(withJSONObject:info).write(to:URL(fileURLWithPath:dir+"/ready.json"),options:.atomic)
    let until = Date().addingTimeInterval(15)
    while Date() < until {
        lock.lock(); let done = response != nil && usage > 0; lock.unlock()
        if done && fm.fileExists(atPath:dir+"/resumed") { break }
        RunLoop.current.run(until:Date().addingTimeInterval(0.02))
    }
    // 缓存已过 4 秒，模拟别处运行状态在暂停期间改变。
    let new = d.claudeLiveElsewhere("elsewhere-fixture")
    let stale = d.warmGemini(req)!
    stale.warmKey = d.warmKey(req)
    stale.startedAt = Date(timeIntervalSinceNow:-601)
    d.keepWarm("gemini",stale); d.dropWarm(olderThan:600)
    let end = Date().addingTimeInterval(4)
    while stale.proc.isRunning && Date() < end { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
    d.procLock.lock(); let empty = d.warmProcs.isEmpty && d.asks.isEmpty && d.usageLoading.isEmpty; d.procLock.unlock()
    lock.lock()
    let result: [String:Any] = ["reply":response?["reply"] ?? "", "usage":usage,"timer":timerFired,"empty":empty,"warmReaped":!stale.proc.isRunning,"oldStatus":old?.status ?? "","newStatus":new?.status ?? ""]
    lock.unlock()
    try! JSONSerialization.data(withJSONObject:result,options:.prettyPrinted).write(to:URL(fileURLWithPath:dir+"/result.json"))
    d.terminateAllChildren()
    exit(0)
}
