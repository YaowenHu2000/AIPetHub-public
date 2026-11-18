// 用量边界、git 与预览资源回收；build/selftest offline。
import Foundation
import Cocoa
import SQLite3

func testPreviewTimeoutAndQuit() {
    print("· 预览转换、git、zstd 的挂死与退出确认")
    let fm = FileManager.default, d = AppDelegate()
    let dir = NSTemporaryDirectory() + "aipethub-boundaries-" + UUID().uuidString
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir); try? fm.removeItem(at: docPreviewRoot) }
    let path = dir + "/hung"
    // 根和子进程都忽略 TERM；写出 PID 后只对这两个自建进程发信号。
    try! installFakeCLI(at: path, behavior: "hung-tree")
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    func pids() -> [Int32] { [".pid", ".child"].compactMap { Int32(trimmed((try? String(contentsOfFile: path + $0, encoding: .utf8)) ?? "")) } }
    func verifyKilled(_ label: String) {
        let ids = pids()
        check(ids.count == 2, "\(label)：记下根和子进程 PID")
        let end = Date().addingTimeInterval(4)
        while Date() < end, ids.contains(where: { kill($0, 0) == 0 }) { Thread.sleep(forTimeInterval: 0.02) }
        check(ids.allSatisfy { kill($0, 0) != 0 }, "\(label)：忽略 TERM 的根和子进程都被清理")
        ids.filter { kill($0, 0) == 0 }.forEach { kill($0, SIGKILL) }
        for suffix in [".pid", ".child"] { try? fm.removeItem(atPath: path + suffix) }
    }
    let doc = dir + "/broken.docx"
    try! Data("bad".utf8).write(to: URL(fileURLWithPath: doc))
    // 期限要留够假 CLI（python）启动并写下 PID 的时间：并行跑测试时机器很忙，0.2 秒、1 秒都会偶发来不及
    TestHooks.quickLookExecutable = path; TestHooks.quickLookTimeout = 3
    let began = Date(), result = makeDocumentPreview(doc)
    check(result.file == nil && result.error.contains("超时"), "qlmanage：超时返回错误")
    check(Date().timeIntervalSince(began) < 4, "qlmanage：到期限立即返回")
    verifyKilled("qlmanage")
    TestHooks.quickLookExecutable = nil; TestHooks.quickLookTimeout = 60
    d.gitPath = path; d.hooks.toolTimeout = 1.5
    check(d.runGit(["status"], in: dir) == nil, "git：半截输出超时不能当成功")
    verifyKilled("git")
    d.hooks.cliExecutable = path
    check(d.readRollout(dir + "/bad.zst") == nil, "zstd：半截输出超时不能当成功")
    verifyKilled("zstd")
    let staleReq = AskRequest(agent: "gemini", reqId: 32, prompt: "", model: "", effort: "", permissionMode: "", workspace: "", conversationId: "")
    let stale = CLIProcess(input: LiveInput())
    try! stale.start(executable:"/bin/cat", arguments:[], cwd:dir, environment:ProcessInfo.processInfo.environment)
    stale.warmKey = d.warmKey(staleReq); stale.startedAt = Date(timeIntervalSinceNow:-601)
    d.keepWarm("gemini",stale)
    check(d.takeWarm(staleReq) == nil, "唤醒后回收 timer 尚未触发，也不接手已过期预热")
    if stale.proc.isRunning { terminateTree(stale.proc.processIdentifier) }
    _ = stale.waitForExit(); stale.input?.abandon()
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    d.hooks.terminationReply = .alertSecondButtonReturn
    d.procLock.lock(); d.asks["claude#prepare"] = AskState(); d.procLock.unlock()
    check(d.applicationShouldTerminate(app) == .terminateCancel, "尚在准备的回答：取消退出")
    d.procLock.lock(); d.asks["claude#prepare"] = nil; d.procLock.unlock()
    let req = AskRequest(agent: "deepseek", reqId: 1, prompt: "", model: "", effort: "", permissionMode: "", workspace: "", conversationId: "")
    let live = DeepSeekLiveTurn(app: d, req: req)
    d.procLock.lock(); d.asks[req.key] = AskState(); d.procLock.unlock()
    d.registerLive(req.key, live)
    check(d.applicationShouldTerminate(app) == .terminateCancel, "DeepSeek 共用服务：取消退出")
    check(d.liveTurn(agent: req.agent, reqId: req.reqId) === live && !live.stopping, "取消退出不停止回答")
    d.hooks.terminationReply = .alertFirstButtonReturn
    check(d.applicationShouldTerminate(app) == .terminateNow, "DeepSeek 共用服务：确认退出")
    d.unregisterLive(req.key)
    d.procLock.lock(); d.asks[req.key] = nil; d.procLock.unlock()
    live.input.abandon()
    check(d.applicationShouldTerminate(app) == .terminateNow, "空闲时直接退出")
}

func runBoundaryTests() -> Never { testPreviewTimeoutAndQuit(); print("Boundary failures=\(failures) checks=\(checks)"); exit(failures == 0 ? 0 : 1) }

func testGitFileNames() {
    print("· git 文件列表保留非 ASCII 和换行文件名")
    let d = AppDelegate(), fm = FileManager.default
    let dir = NSTemporaryDirectory() + "aipethub-files-" + UUID().uuidString
    try! fm.createDirectory(atPath:dir,withIntermediateDirectories:true)
    defer { try? fm.removeItem(atPath:dir) }
    check(d.runGit(["init","-q"],in:dir) != nil,"创建临时仓库（不 add/commit）")
    let names = ["中文.txt","space name.txt","tab\tname.txt","line\nbreak.txt"]
    for name in names { try! Data("x".utf8).write(to:URL(fileURLWithPath:dir+"/"+name)) }
    let done = DispatchSemaphore(value:0); var found:[String] = []
    d.jsSink = { fn,p in if fn == "onFilesListed" { found = p["files"] as? [String] ?? []; done.signal() } }
    d.listFiles(workspace:dir,query:"",reqId:1)
    check(done.wait(timeout:.now()+5) == .success,"文件列表返回")
    check(Set(found) == Set(names),"git 不把中文/控制字符转义为不可用路径")
}

func runMoreTests() -> Never { testDshStreamOrders(); testGitFileNames(); print("More failures=\(failures) checks=\(checks)"); exit(failures == 0 ? 0 : 1) }

func testUsageNumbers() {
    let d = AppDelegate(), fm = FileManager.default
    let dir = NSTemporaryDirectory() + "aipethub-numbers-" + UUID().uuidString
    try! fm.createDirectory(atPath:dir,withIntermediateDirectories:true)
    defer { try? fm.removeItem(atPath:dir) }
    let cli = dir + "/cli.py"
    try! installFakeCLI(at: cli, behavior: "backend")
    try! fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:cli)
    d.hooks.cliExecutable = cli
    d.jsSink = { _,_ in }
    for mode in ["huge", "nan", "credits-huge", "credits-nan"] {
        try! mode.write(toFile:dir+"/mode",atomically:true,encoding:.utf8)
        let agent = mode.hasPrefix("credits") ? "gpt" : "gemini"
        d.loadUsage(agent:agent,force:true)
        // 完成就立刻往下走；期限只防卡死。机器很忙（并行测试、别的会话在编译）时 5 秒会偶发来不及
        let end = Date().addingTimeInterval(20)
        var done = false
        while Date() < end {
            RunLoop.current.run(until:Date().addingTimeInterval(0.02))
            d.procLock.lock(); done = d.usageLoading.isEmpty; d.procLock.unlock()
            if done { break }
        }
        check(done,"\(mode)：异常用量数字不崩溃并完成查询")
        d.procLock.lock(); let items = d.usageCache[agent]?.items ?? []; d.procLock.unlock()
        check(!items.isEmpty && JSONSerialization.isValidJSONObject(items),"\(mode)：返回可序列化用量")
    }
}

func runUsageNumberTests() -> Never { testUsageNumbers(); print("Numbers failures=\(failures) checks=\(checks)"); exit(failures == 0 ? 0 : 1) }

func runGitRaceTest() -> Never {
    let d = AppDelegate()
    DispatchQueue.concurrentPerform(iterations:32) { _ in _ = d.runGit(["--version"],in:NSTemporaryDirectory()) }
    print("Concurrent git lookup complete")
    exit(0)
}

func testPreviewSpecialFile() {
    print("· 文件预览：FIFO 不应阻塞读取线程，符号链接仍能打开")
    let d = AppDelegate(), fm = FileManager.default
    let dir = NSTemporaryDirectory()+"aipethub-fifo-"+UUID().uuidString
    try! fm.createDirectory(atPath:dir,withIntermediateDirectories:true)
    defer { try? fm.removeItem(atPath:dir) }
    let fifo = dir+"/pipe.txt"
    check(mkfifo(fifo,0o600) == 0,"创建测试 FIFO")
    let done = DispatchSemaphore(value:0)
    var reply:[String:Any] = [:]
    d.jsSink = { fn,p in if fn == "onFileRead" { reply = p; done.signal() } }
    d.readFileForPreview(path:fifo,base:dir,reqId:1)
    let returned = done.wait(timeout:.now()+1) == .success
    check(returned && reply["error"] != nil,"FIFO 返回错误，不等写入者出现")
    if !returned { return } // 修前孤立的读线程由自测进程退出回收
    let file = dir+"/normal.txt", link = dir+"/link.txt"
    try! "hello".write(toFile:file,atomically:true,encoding:.utf8)
    try! fm.createSymbolicLink(atPath:link,withDestinationPath:file)
    d.readFileForPreview(path:link,base:dir,reqId:2)
    check(done.wait(timeout:.now()+1) == .success && reply["content"] as? String == "hello","普通文件的符号链接照常预览")
    try! Data().write(to:URL(fileURLWithPath:file))
    d.readFileForPreview(path:file,base:dir,reqId:3)
    check(done.wait(timeout:.now()+1) == .success && reply["content"] as? String == "", "空文件照常返回空内容")
}

func runFilePreviewTests() -> Never { testPreviewSpecialFile(); print("Files failures=\(failures) checks=\(checks)"); exit(failures == 0 ? 0 : 1) }

