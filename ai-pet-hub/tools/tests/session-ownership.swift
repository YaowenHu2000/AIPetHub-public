// 用隔离的历史库和 CLI 进程验证归档、续接和模型菜单之间的边界。
import Cocoa
import SQLite3

func testSessionOwnership() {
    let d = AppDelegate(), fm = FileManager.default
    let root = NSTemporaryDirectory() + "aipethub-ownership-" + UUID().uuidString
    let cli = root + "/cli", db = root + "/state_5.sqlite"
    try! fm.createDirectory(atPath: root + "/sessions", withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }
    try! installFakeCLI(at: cli, behavior: "backend")
    d.hooks.cliExecutable = cli
    d.hooks.codexEnvironment = ["CODEX_HOME": root]
    var handle: OpaquePointer?
    sqlite3_open(db, &handle)
    sqlite3_exec(handle, "CREATE TABLE threads(id TEXT PRIMARY KEY, archived INTEGER, archived_at INTEGER, rollout_path TEXT)", nil, nil, nil)
    for cid in ["indexed", "refused", "legacy"] {
        let path = root + "/sessions/rollout-test-" + cid + ".jsonl"
        try! Data().write(to: URL(fileURLWithPath: path))
        if cid != "legacy" {
            sqlite3_exec(handle, "INSERT INTO threads VALUES ('\(cid)',0,NULL,'\(path)')", nil, nil, nil)
        }
    }
    sqlite3_close(handle)
    var deleted: [String] = [], failed: [String] = []
    d.jsSink = { fn, data in
        if fn == "onConversationsDeleted" {
            deleted = data["deleted"] as? [String] ?? []; failed = data["failed"] as? [String] ?? []
        }
    }
    d.deleteConversations(agent: "gpt", ids: ["indexed", "refused", "legacy"])
    d.codexQueue.sync {}; d.codexQueue.sync {}
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    let log = (try? String(contentsOfFile: cli + ".archives", encoding: .utf8)) ?? ""
    let calls = log.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
    eq(calls.compactMap(\.last).sorted(), ["indexed", "refused"], "只有已索引会话交给 thread/archive")
    eq(Set(calls.compactMap(\.first)).count, 1, "批量归档只启动一个 app-server")
    eq(deleted, ["indexed", "legacy"], "归档以 CLI 的答复为准，旧 rollout 仍能移动")
    eq(failed, ["refused"], "CLI 拒绝归档时返回失败")
    check(fm.fileExists(atPath: root + "/sessions/rollout-test-refused.jsonl"), "CLI 拒绝后原文件还在")
    check(fm.fileExists(atPath: root + "/archived_sessions/rollout-test-legacy.jsonl"), "无索引的旧记录已归档")

    d.hooks.cliExecutable = root + "/no-such-cli"
    check(!d.deleteOne(agent: "gpt", cid: "refused"), "没有 Codex 时已索引会话返回失败")
    check(fm.fileExists(atPath: root + "/sessions/rollout-test-refused.jsonl"), "缺 CLI 不移动有索引的文件")
    d.hooks.cliExecutable = cli
    let late = root + "/sessions/rollout-test-late-indexed.jsonl"
    try! Data().write(to: URL(fileURLWithPath: late))
    d.hooks.codexLegacyArchiveLocated = {
        _ = d.withSQLite(db, readOnly: false) {
            sqlite3_exec($0, "INSERT INTO threads VALUES ('late-indexed',0,NULL,'\(late)')", nil, nil, nil)
        }
    }
    check(d.deleteOne(agent: "gpt", cid: "late-indexed"), "扫描期间刚被收录的线程能正常归档")
    let lateCalls = (try? String(contentsOfFile: cli + ".archives", encoding: .utf8)) ?? ""
    check(lateCalls.contains("\tlate-indexed\n"), "扫描后补上的索引也必须走原生归档")
    d.hooks.codexLegacyArchiveLocated = nil
    for agent in ["gpt", "gemini"] {
        let req = AskRequest(agent: agent, reqId: 83, prompt: "OK", model: "model", effort: "low",
                             permissionMode: "default", workspace: root, conversationId: "existing")
        guard let warm = (agent == "gpt" ? d.warmCodex(req) : d.warmGemini(req)) else {
            check(false, "\(agent) 预热能启动"); continue
        }
        // EOF 让假 CLI 发完 initialize 的答复并退出，读完输出再检查预热停在哪一阶段。
        warm.input?.close(); _ = warm.waitForExit()
        eq(warm.stage, 1, "\(agent) 预热已有会话只完成 initialize")
    }

    // 自测程序以 agy 的名字持有库；等它确认打开成功才发送。
    let holder = Process(), ready = Pipe(), release = Pipe(), other = root + "/agy"
    try! fm.copyItem(atPath: CommandLine.arguments[0], toPath: other)
    d.hooks.geminiCliDir = root
    try! fm.createDirectory(atPath: root + "/conversations", withIntermediateDirectories: true)
    let session = root + "/conversations/existing.db"
    try! Data("ready\n".utf8).write(to: URL(fileURLWithPath: session))
    holder.executableURL = URL(fileURLWithPath: other); holder.arguments = ["hold-session-file", session]
    holder.standardOutput = ready; holder.standardInput = release
    try! holder.run()
    eq(ready.fileHandleForReading.availableData, Data("ready".utf8), "持有者已打开库文件")
    var req = AskRequest(agent: "gemini", reqId: 84, prompt: "OK", model: "model", effort: "low",
                         permissionMode: "default", workspace: root, conversationId: "existing")
    req.browserTools = false
    // 同一时刻让上一轮 App 启动的 agy 也持库。两边分别放行，确定地覆盖收尾窗口。
    let previous = Process(), ownReady = Pipe(), ownRelease = Pipe()
    previous.executableURL = holder.executableURL; previous.arguments = holder.arguments
    previous.standardOutput = ownReady; previous.standardInput = ownRelease
    try! ChildProcesses.shared.start(previous)
    eq(ownReady.fileHandleForReading.availableData, Data("ready".utf8), "上一轮子进程仍持有会话文件")
    let busy = withTestAsk(d, req.key) { d.runGemini(req) }
    check(busy.reply.contains("其他客户端"), "另一 agy 持库时拦住发送")
    try! "unsupported".write(toFile: root + "/mode", atomically: true, encoding: .utf8)
    let fallback = withTestAsk(d, req.key) { d.runGemini(req) }
    check(fallback.reply.contains("其他客户端"), "旧 agy 的单次提问回退也不写被占用的会话")
    try! fm.removeItem(atPath: root + "/mode")
    release.fileHandleForWriting.closeFile(); holder.waitUntilExit()
    let free = withTestAsk(d, req.key) { d.runGemini(req) }
    eq(free.reply, "fixture-ok", "外部持有者已退，上一轮自己的 agy 尚未退出也能续聊")

    ownRelease.fileHandleForWriting.closeFile(); previous.waitUntilExit()

    var models: [String] = []
    d.jsSink = { fn, data in
        if fn == "onAgentModels" { models = (data["models"] as? [[String: Any]] ?? []).compactMap { $0["v"] as? String } }
    }
    d.loadUsage(agent: "gpt", force: true)
    let end = Date().addingTimeInterval(4)
    repeat {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        d.procLock.lock(); let busy = d.usageLoading.contains("gpt"); d.procLock.unlock()
        if !busy { break }
    } while Date() < end
    eq(models, ["new-codex-model"], "未预热时模型菜单从 app-server 读取 model/list")
}

// 先放入答完后的握手进程，再模拟同一会话开始打字；用协议阶段确认 resume 已经答复。
func testTypingResume() {
    let d = AppDelegate(), fm = FileManager.default
    let root = NSTemporaryDirectory() + "aipethub-typing-" + UUID().uuidString
    try! fm.createDirectory(atPath: root + "/sessions", withIntermediateDirectories: true)
    try! fm.createDirectory(atPath: root + "/conversations", withIntermediateDirectories: true)
    defer { d.dropWarm(); try? fm.removeItem(atPath: root) }
    let previous = ProcessInfo.processInfo.environment["AIPETHUB_PREWARM"]
    setenv("AIPETHUB_PREWARM", "1", 1)
    defer { if let previous = previous { setenv("AIPETHUB_PREWARM", previous, 1) } else { unsetenv("AIPETHUB_PREWARM") } }
    d.hooks.codexEnvironment = ["CODEX_HOME":root]; d.hooks.geminiCliDir = root
    let commands = DispatchSemaphore(value: 0)
    d.jsSink = { fn, data in
        if fn == "onAgentCommands", (data["commands"] as? [[String:String]])?.first?["name"] == "compact" { commands.signal() }
    }
    let cli = root + "/cli"
    try! installFakeCLI(at: cli, behavior: "initialization")
    try! "ok".write(toFile: cli + ".mode", atomically: true, encoding: .utf8)
    d.hooks.cliExecutable = cli
    for (agent,cid) in [("gpt","thread"),("gemini","session")] {
        let req = AskRequest(agent: agent, reqId: 81, prompt: "test", model: "model", effort: "low",
                             permissionMode: "default", workspace: root, conversationId: cid, browserTools: false)
        let file = agent == "gpt" ? root + "/sessions/rollout-fixture-thread.jsonl" : d.geminiConversationDb(cid)
        try! Data().write(to: URL(fileURLWithPath:file))
        let process = (agent == "gpt" ? d.warmCodex(req) : d.warmGemini(req))!
        process.warmKey = d.warmKey(req); d.keepWarm(agent, process)
        d.prewarm(req)
        let deadline = Date().addingTimeInterval(2)
        while process.withWarmLock({ process.stage < 3 }) && Date() < deadline { Thread.sleep(forTimeInterval:0.01) }
        eq(process.withWarmLock { process.stage }, 3, "\(agent) 打字复用答完后的进程，并提前接上旧会话")
        if agent == "gemini" {
            check(commands.wait(timeout: .now() + 1) == .success, "打字预热收到的斜杠命令在发送前就发布")
        }
        try! Data("change".utf8).write(to: URL(fileURLWithPath: agent == "gemini" ? file + "-wal" : file))
        let taken = d.takeWarm(req)
        check(taken == nil, "\(agent) 接上后头 8 秒改动也丢弃，不复用旧快照")
        if let taken = taken { taken.input?.close() }
        _ = process.waitForExit()
    }
    // 进入真正的打字续接回调，等它在预热锁内查完状态后再检查 ACP 阶段。
    d.hooks.geminiCliDir = root + "/antigravity-cli"
    let desk = AskRequest(agent: "gemini", reqId: 85, prompt: "test", model: "model", effort: "low",
                          permissionMode: "default", workspace: root, conversationId: "desktop:session", browserTools: false)
    let desktopDB = URL(fileURLWithPath: d.geminiConversationDb(desk.conversationId))
    try! fm.createDirectory(at: desktopDB.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data().write(to: desktopDB)
    for running: Bool? in [true, nil, false] {
        let queried = DispatchSemaphore(value: 0)
        d.hooks.geminiDesktopRunning = { queried.signal(); return running }
        let process = d.warmGemini(desk)!
        process.warmKey = d.warmKey(desk); d.keepWarm("gemini", process); d.prewarm(desk)
        check(queried.wait(timeout: .now() + 2) == .success, "打字续接前查询桌面进程状态")
        if running == false {
            check(commands.wait(timeout: .now() + 2) == .success, "桌面退出后打字预热照常接入")
        } else {
            eq(process.withWarmLock { process.stage }, 1, "桌面仍可能在运行时预热只完成握手")
            d.hooks.geminiDesktopRunning = { false }
            d.prewarm(desk)
            check(commands.wait(timeout: .now() + 2) == .success, "退出桌面后继续打字，同一预热进程可以续接")
        }
        d.dropWarm(); _ = process.waitForExit()
    }
    d.hooks.geminiCliDir = root
    let req = AskRequest(agent: "gemini", reqId: 82, prompt: "test", model: "model", effort: "low",
                         permissionMode: "default", workspace: root, conversationId: "session", browserTools: false)
    // 第一个 agy 已成功预热；此时外部客户端才打开同一个库。文件内容完全不动，只有发送前的持库检查能拦住。
    let warm = d.warmGemini(req)!
    warm.warmKey = d.warmKey(req); d.keepWarm("gemini", warm); d.prewarm(req)
    check(commands.wait(timeout: .now() + 3) == .success, "第二次打字预热已接入会话")
    let holder = Process(), ready = Pipe(), release = Pipe(), other = root + "/agy"
    try! fm.copyItem(atPath: CommandLine.arguments[0], toPath: other)
    holder.executableURL = URL(fileURLWithPath: other)
    holder.arguments = ["hold-session-file", d.geminiConversationDb("session")]
    holder.standardOutput = ready; holder.standardInput = release
    try! holder.run()
    eq(ready.fileHandleForReading.availableData, Data("ready".utf8), "预热后外部 agy 已打开同一库")
    let watchdog = DispatchWorkItem { d.cancel(agent: req.agent, reqId: req.reqId) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: watchdog)
    let blocked = withTestAsk(d, req.key) { d.runGemini(req) }
    watchdog.cancel()
    release.fileHandleForWriting.closeFile(); holder.waitUntilExit()
    check(blocked.reply.contains("其他客户端"), "接手已预热的会话也拦住新出现的 agy")
    let log = try! String(contentsOfFile: cli + ".log", encoding: .utf8)
    check(!log.contains("session/prompt"), "外部持库时没有提交提问")

    d.hooks.warmTypingIdle = 1
    let idle = d.warmGemini(req)!
    idle.warmKey = d.warmKey(req); d.keepWarm("gemini", idle); d.prewarm(req)
    check(commands.wait(timeout: .now() + 3) == .success, "停止打字前已接上会话")
    let expired = idle.waitForExit(until: .now() + 4) { terminateTree(idle.proc.processIdentifier) }
    check(!expired.timedOut && d.takeWarm(req) == nil, "打字闲置后预热进程自行退出并从缓存移除")

}
