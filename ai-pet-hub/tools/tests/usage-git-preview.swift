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
    // 假 CLI 要先起 python 再 exec 成 sh、再起子进程；机器很忙时这要好几秒。卡在「已启动、还没开始等」的位置等两份 PID 都写好，
    // 超时才落在进程树建好之后，被测的仍是「忽略 TERM 的根和子进程都被清理」。等不到就放行，由 verifyKilled 记失败。
    func waitForTree() {
        waitUntil { pids().count >= 2 }
    }
    func verifyKilled(_ label: String) {
        let ids = pids()
        check(ids.count == 2, "\(label)：记下根和子进程 PID")
        // terminateTree 3 秒后才补 SIGKILL，机器忙时还会晚；死了就往下走，期限只防卡死（不清理时 sleep 要 600 秒，比上限长）
        waitUntil(interval: 0.02) { !ids.contains { kill($0, 0) == 0 } }
        check(ids.allSatisfy { kill($0, 0) != 0 }, "\(label)：忽略 TERM 的根和子进程都被清理")
        ids.filter { kill($0, 0) == 0 }.forEach { kill($0, SIGKILL) }
        for suffix in [".pid", ".child"] { try? fm.removeItem(atPath: path + suffix) }
    }
    let doc = dir + "/broken.docx"
    try! Data("bad".utf8).write(to: URL(fileURLWithPath: doc))
    // 根进程忽略 TERM，要等 terminateTree 3 秒后补的 SIGKILL 才死：返回那一刻它还活着，才说明到期限就返回、没等进程退出。
    // 比的是「返回」和「被杀」谁先发生，负载对两边一样，不卡挂钟
    TestHooks.quickLookExecutable = path; TestHooks.quickLookTimeout = 0.5; TestHooks.quickLookStarted = waitForTree
    let result = makeDocumentPreview(doc)
    let rootAliveAtReturn = Int32(trimmed((try? String(contentsOfFile: path + ".pid", encoding: .utf8)) ?? "")).map { kill($0, 0) == 0 } ?? false
    check(result.file == nil && result.error.contains("超时"), "qlmanage：超时返回错误")
    check(rootAliveAtReturn, "qlmanage：到期限立即返回，不等进程退出")
    verifyKilled("qlmanage")
    TestHooks.quickLookExecutable = nil; TestHooks.quickLookTimeout = 60; TestHooks.quickLookStarted = nil
    // runTool 的期限在启动前就开始算，等进程树时多半已过期：放行后立即超时，结束的正是这棵还活着的进程树
    d.gitPath = path; d.hooks.toolTimeout = 0.5; d.hooks.toolStarted = waitForTree
    check(d.runGit(["status"], in: dir) == nil, "git：半截输出超时不能当成功")
    verifyKilled("git")
    d.hooks.cliExecutable = path
    check(d.readRollout(dir + "/bad.zst") == nil, "zstd：半截输出超时不能当成功")
    verifyKilled("zstd")
    d.hooks.toolStarted = nil
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
    d.hooks.jsSink = { fn,p in if fn == "onFilesListed" { found = p["files"] as? [String] ?? []; done.signal() } }
    d.listFiles(workspace:dir,query:"",reqId:1)
    check(waitSignal(done),"文件列表返回")
    check(Set(found) == Set(names),"git 不把中文/控制字符转义为不可用路径")
}

func testUsageNumbers() {
    let d = AppDelegate(), fm = FileManager.default
    let dir = NSTemporaryDirectory() + "aipethub-numbers-" + UUID().uuidString
    try! fm.createDirectory(atPath:dir,withIntermediateDirectories:true)
    defer { try? fm.removeItem(atPath:dir) }
    let cli = dir + "/cli.py"
    try! installFakeCLI(at: cli, behavior: "backend")
    try! fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:cli)
    d.hooks.cliExecutable = cli
    d.hooks.jsSink = { _,_ in }
    for mode in ["huge", "nan", "credits-huge", "credits-nan"] {
        try! mode.write(toFile:dir+"/mode",atomically:true,encoding:.utf8)
        let agent = mode.hasPrefix("credits") ? "gpt" : "gemini"
        d.loadUsage(agent:agent,force:true)
        // 完成就立刻往下走；期限只防卡死。机器很忙（并行测试、别的会话在编译）时 5 秒会偶发来不及
        RunLoop.current.run(until:Date().addingTimeInterval(0.02))
        let done = waitUntil(runLoop: true, interval: 0.02) { d.procLock.lock(); defer { d.procLock.unlock() }; return d.usageLoading.isEmpty }
        check(done,"\(mode)：异常用量数字不崩溃并完成查询")
        d.procLock.lock(); let items = d.usageCache[agent]?.items ?? []; d.procLock.unlock()
        check(!items.isEmpty && JSONSerialization.isValidJSONObject(items),"\(mode)：返回可序列化用量")
    }
}

/// 查用量的 CLI 一启动就退出（没登录、版本不对）时，不能等满两轮 45 秒才说没查到，菜单那段时间一直是「正在查…」，也发不起新查询。
func testUsageEarlyExit() {
    print("· 查用量的 CLI 提前退出")
    let d = AppDelegate(), fm = FileManager.default
    let dir = NSTemporaryDirectory() + "aipethub-usage-exit-" + UUID().uuidString
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    let cli = dir + "/cli.py"
    try! installFakeCLI(at: cli, behavior: "backend")
    try! "offline".write(toFile: dir + "/mode", atomically: true, encoding: .utf8)
    d.hooks.cliExecutable = cli
    var replies: [String: [[String: Any]]] = [:]   // jsSink 在主线程调用，这里也只在主线程读
    d.hooks.jsSink = { fn, payload in
        guard fn == "onAgentUsage", let agent = payload["agent"] as? String else { return }
        replies[agent, default: []].append(payload)
    }
    func starts() -> [(pid: Int32, kind: String)] {
        ((try? String(contentsOfFile: cli + ".starts", encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t").map(String.init)
            guard cols.count == 2, let pid = Int32(cols[0]) else { return nil }
            return (pid, cols[1])
        }
    }
    let kinds = ["claude": "-p", "gpt": "app-server"]
    for round in 1...2 {
        let before = starts()
        let t0 = Date()
        for agent in ["claude", "gpt"] {
            d.loadUsage(agent: agent, force: true)
            d.procLock.lock(); let loading = d.usageLoading.contains(agent); d.procLock.unlock()
            check(loading, "LU \(agent) 第 \(round) 次：发起了新查询（上一次没有一直占着）")
        }
        var elapsed: [String: Double] = [:]
        let answered = waitUntil(runLoop: true) {
            for agent in ["claude", "gpt"] where elapsed[agent] == nil && (replies[agent]?.count ?? 0) >= round {
                elapsed[agent] = Date().timeIntervalSince(t0)
            }
            return elapsed.count == 2
        }
        check(answered, "LU 第 \(round) 次：两位都给出了查询结果（到上限没等到：\(elapsed)）")
        for agent in ["claude", "gpt"] {
            let reply = replies[agent]?.last
            check((reply?["error"] as? String)?.contains("没查到") == true && (reply?["items"] as? [Any])?.isEmpty == true,
                  "LU \(agent) 第 \(round) 次：返回没查到（实际 \(String(describing: reply))）")
            check((elapsed[agent] ?? 99) < 20, "LU \(agent) 第 \(round) 次：CLI 已退出就不再等满期限（实际 \(elapsed[agent].map { String(format: "%.1f 秒", $0) } ?? "没返回")）")
            let launched = starts().dropFirst(before.count).filter { $0.kind == kinds[agent] }.count
            check(launched >= 1 && launched <= 2, "LU \(agent) 第 \(round) 次：提前退出最多重试一次（实际起了 \(launched) 次）")
        }
        d.procLock.lock(); let idle = d.usageLoading.isEmpty; d.procLock.unlock()
        check(idle, "LU 第 \(round) 次：返回后不再标着正在查")
    }
    let leftover = starts().filter { kill($0.pid, 0) == 0 }
    check(leftover.isEmpty, "LU 起的假 CLI 都已退出（还在：\(leftover.map(\.pid))）")
    // 答完马上退出：被退出叫醒时，已经写出的答复仍要读完算数，不能当成没查到
    try! "usage-exit".write(toFile: dir + "/mode", atomically: true, encoding: .utf8)
    let t0 = Date(), count = replies["gpt"]?.count ?? 0
    d.loadUsage(agent: "gpt", force: true)
    check(waitUntil(runLoop: true) { (replies["gpt"]?.count ?? 0) > count }, "LU gpt 答完即退出：给出了查询结果")
    let reply = replies["gpt"]?.last
    check(reply?["error"] == nil && (reply?["items"] as? [[String: Any]])?.contains { $0["label"] as? String == "额外额度" } == true,
          "LU gpt 答完即退出：拿到退出前写出的用量（实际 \(String(describing: reply))）")
    check(Date().timeIntervalSince(t0) < 20, "LU gpt 答完即退出：不等满期限")   // 期限 45 秒（Usage.swift），取一半
}

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
    d.hooks.jsSink = { fn,p in if fn == "onFileRead" { reply = p; done.signal() } }
    d.readFileForPreview(path:fifo,base:dir,reqId:1)
    let returned = waitSignal(done)
    check(returned && reply["error"] != nil,"FIFO 返回错误，不等写入者出现")
    if !returned { return } // 修前孤立的读线程由自测进程退出回收
    let file = dir+"/normal.txt", link = dir+"/link.txt"
    try! "hello".write(toFile:file,atomically:true,encoding:.utf8)
    try! fm.createSymbolicLink(atPath:link,withDestinationPath:file)
    d.readFileForPreview(path:link,base:dir,reqId:2)
    check(waitSignal(done) && reply["content"] as? String == "hello","普通文件的符号链接照常预览")
    try! Data().write(to:URL(fileURLWithPath:file))
    d.readFileForPreview(path:file,base:dir,reqId:3)
    check(waitSignal(done) && reply["content"] as? String == "", "空文件照常返回空内容")
    // 带 BOM 的 UTF-16 文本每个 ASCII 字符都带一个零字节，不能因此判成二进制
    for (name, bom, encoding) in [("LE", [UInt8(0xFF), 0xFE], String.Encoding.utf16LittleEndian), ("BE", [0xFE, 0xFF], .utf16BigEndian)] {
        let path = dir + "/utf16-\(name).txt"
        try! (Data(bom) + "hello 世界".data(using: encoding)!).write(to: URL(fileURLWithPath: path))
        reply = [:]
        d.readFileForPreview(path: path, base: dir, reqId: 4)
        check(waitSignal(done) && reply["content"] as? String == "hello 世界",
              "MS 带 BOM 的 UTF-16 \(name) 文本照常预览（实际：\(reply["content"] ?? reply["error"] ?? "无回包")）")
    }
}

