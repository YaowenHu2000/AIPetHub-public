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
    // 输入框刚查过空清单；发送时外部进程已经接手同一会话。
    d.claudeLiveCache = (Date(), [])
    var forked = false
    d.hooks.liveTurnCreated = { forked = $0.req.fork }
    let ask = AskRequest(agent:"claude",reqId:39,prompt:"好",model:"haiku",effort:"low",permissionMode:"default",workspace:root,conversationId:"elsewhere-fixture",browserTools:false)
    try! "claude-unsupported".write(toFile:root+"/mode",atomically:true,encoding:.utf8)
    d.hooks.jsSink = { _, _ in }
    _ = withTestAsk(d, ask.key) { d.runClaude(ask) }
    eq(forked, true, "B2-11 发送重新查占用并分叉")
    let badList = root + "/agents.json"
    try! "查询服务暂不可用".write(toFile: badList, atomically: true, encoding: .utf8)
    forked = false
    _ = withTestAsk(d, ask.key) { d.runClaude(ask) }
    eq(forked, true, "占用现查失败仍为刚确认的写者分叉")
    d.claudeLiveCache = nil
    let unknown = withTestAsk(d, ask.key) { d.runClaude(ask) }
    check(unknown.reply.contains("无法确认"), "没有可用清单时保留提问供重试，实际 \(unknown.reply)")
    // 这句没交给 CLI：原话和附件退回原会话草稿，切走再回来、重开都还在
    check(unknown.restoreDraft, "没有可用清单时原话退回原会话草稿")
    try! fm.removeItem(atPath: badList)
    try! fm.removeItem(atPath: root + "/mode")
    d.hooks.liveTurnCreated = nil
    let parent = Process(), nestedReady = Pipe(), nestedInput = Pipe()
    parent.executableURL = URL(fileURLWithPath: "/bin/sh")
    parent.arguments = ["-c", "/bin/sh -c 'echo $$; read release'; :"]
    parent.standardInput = nestedInput; parent.standardOutput = nestedReady
    try! ChildProcesses.shared.start(parent)
    let child = Int32(trimmed(String(decoding: nestedReady.fileHandleForReading.availableData, as: UTF8.self)))!
    let agentsFile = root + "/agents.json"
    let agents = [["sessionId": "direct", "pid": parent.processIdentifier, "status": "busy"],
                  ["sessionId": "delegated", "pid": child, "status": "busy"]] as [[String: Any]]
    try! JSONSerialization.data(withJSONObject: agents).write(to: URL(fileURLWithPath: agentsFile))
    d.asks["claude#test"] = AskState(proc: parent)
    eq(d.claudeLiveElsewhere("delegated", fresh: true)?.status, "busy", "派出的子任务仍是独立会话写者")
    check(d.claudeLiveElsewhere("direct") == nil, "直接管理的 CLI 不触发分叉")
    nestedInput.fileHandleForWriting.closeFile(); parent.waitUntilExit()
    d.asks["claude#test"] = nil
    try! fm.removeItem(atPath: agentsFile)
    for batch in [false,true] {
        let file = root + "/occupied.jsonl", cid = "elsewhere-fixture"
        try! Data("fixture".utf8).write(to:URL(fileURLWithPath:file))
        d.claudeCache[cid] = (0, nil, file); d.claudeLiveCache = (Date(), [])
        var reason = ""
        d.hooks.jsSink = { fn, data in if fn.hasPrefix("onConversation") && fn.contains("Deleted") { reason = str(data,"reason") } }
        if batch { d.deleteConversations(agent:"claude",ids:[cid]) } else { d.deleteConversation(agent:"claude",cid:cid) }
        d.claudeQueue.sync {}; d.claudeQueue.sync {}
        check(fm.fileExists(atPath:file) && !reason.isEmpty, "B2-12 Claude 占用时拒绝删除 batch=\(batch)，文件存在=\(fm.fileExists(atPath:file))，原因=\(reason)")
    }
    // 同一编号在不同项目目录有副本时，列表、聊天页和搜索都只给用户一个入口。
    let previousConfig = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
    setenv("CLAUDE_CONFIG_DIR",root,1)
    do {
        defer { if let previousConfig { setenv("CLAUDE_CONFIG_DIR",previousConfig,1) } else { unsetenv("CLAUDE_CONFIG_DIR") } }
        let cid = UUID().uuidString
        for project in ["original","copy"] {
            let dir = root + "/projects/" + project
            try! fm.createDirectory(atPath:dir,withIntermediateDirectories:true)
            try! Data(#"{"type":"user","message":{"content":"副本"}}"#.utf8).write(to:URL(fileURLWithPath:dir+"/"+cid+".jsonl"))
        }
        let ok = d.deleteOne(agent:"claude",cid:cid)
        let remaining = d.claudeSessionFiles().filter { $0.cid == cid }
        check(ok && remaining.isEmpty, "Claude 同一会话删除后另一实例无旧副本可打开，成功=\(ok) 剩余=\(remaining.count)")
    }
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
    var deleted: [String] = [], failed: [String] = [], reason = ""
    d.hooks.jsSink = { fn, data in
        if fn == "onConversationsDeleted" {
            reason = str(data, "reason")
            deleted = data["deleted"] as? [String] ?? []; failed = data["failed"] as? [String] ?? []
        }
    }
    let observer = AppDelegate(), channel = Notification.Name("AIPetHub.fixture." + UUID().uuidString)
    var peerRefresh = [String]()
    observer.hooks.jsSink = { fn, data in if fn == "onHistoryChangedElsewhere" { peerRefresh.append(str(data,"agent")) } }
    observer.observeHistoryChanges(named:channel); d.observeHistoryChanges(named:channel)
    defer {
        DistributedNotificationCenter.default().removeObserver(observer)
        DistributedNotificationCenter.default().removeObserver(d)
    }
    d.deleteConversations(agent: "gpt", ids: ["indexed", "refused", "legacy"])
    d.codexQueue.sync {}; d.codexQueue.sync {}
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    waitUntil(runLoop: true) { !peerRefresh.isEmpty }
    eq(peerRefresh,["gpt"],"项目部分成功也只通知另一实例刷新这一位")
    // 右键移进移出「任务会话」只记在本实例的网页存储里，各实例之间不实时同步：要把结果告诉另一实例，它删项目时才按最新分组筛
    var groupChanges = [String](), ownEcho = [String]()
    observer.hooks.jsSink = { fn, data in
        if fn == "onTaskGroupChangedElsewhere" { groupChanges.append(str(data,"agent") + ":" + str(data,"conversationId") + ":" + str(data,"task")) }
        if fn == "onHistoryChangedElsewhere" { peerRefresh.append(str(data,"agent")) }
    }
    d.hooks.jsSink = { fn, _ in if fn.hasSuffix("Elsewhere") { ownEcho.append(fn) } }
    d.notifyTaskGroupChanged(agent: "claude", cid: "moved-in", task: true)
    d.notifyTaskGroupChanged(agent: "deepseek", cid: "moved-out", task: false)
    d.notifyTaskGroupChanged(agent: "gemini", cid: "back-to-auto", task: nil)
    waitUntil(runLoop: true) { groupChanges.count >= 3 }
    eq(groupChanges, ["claude:moved-in:task", "deepseek:moved-out:project", "gemini:back-to-auto:auto"], "手动分组的变化按原样交给另一实例")
    eq(peerRefresh, ["gpt"], "分组变化不让另一实例重读历史")
    eq(ownEcho, [], "发出分组变化的实例不处理自己的通知")
    let log = (try? String(contentsOfFile: cli + ".archives", encoding: .utf8)) ?? ""
    let calls = log.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
    eq(calls.compactMap(\.last).sorted(), ["indexed", "refused"], "只有已索引会话交给 thread/archive")
    eq(Set(calls.compactMap(\.first)).count, 1, "批量归档只启动一个 app-server")
    eq(deleted, ["indexed", "legacy"], "归档以 CLI 的答复为准，旧 rollout 仍能移动")
    eq(reason, "refused", "归档显示 CLI 拒绝原因")
    eq(failed, ["refused"], "CLI 拒绝归档时返回失败")
    check(fm.fileExists(atPath: root + "/sessions/rollout-test-refused.jsonl"), "CLI 拒绝后原文件还在")
    check(fm.fileExists(atPath: root + "/archived_sessions/rollout-test-legacy.jsonl"), "无索引的旧记录已归档")

    let collision = "old-collision", name = "rollout-fixture-" + collision + ".jsonl"
    for suffix in ["",".zst"] { fm.createFile(atPath:root + "/sessions/" + name + suffix,contents:Data()) }
    let archiveCopy = root + "/archived_sessions/" + name + ".zst"
    fm.createFile(atPath:archiveCopy,contents:Data())
    for blocked in [true,false] {
        if !blocked { try! fm.removeItem(atPath:archiveCopy) }
        let accepted = d.archiveCodex([collision]) { _ in }.contains(collision)
        eq(accepted,!blocked,"旧 rollout 两份文件都移走才回报成功，目标冲突=\(blocked)")
    }

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
    let warmClaude = d.warmClaude(ask)
    check(warmClaude == nil, "Claude 打字或答完不会提前接管已有会话，实际启动=\(warmClaude != nil)")
    warmClaude?.input?.close()
    if let warmClaude = warmClaude { _ = warmClaude.waitForExit() }
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

    let desktopBin = root + "/Applications/Antigravity.app/Contents/MacOS"
    try! fm.createDirectory(atPath:desktopBin, withIntermediateDirectories:true)
    let desktop = Process(), readyDesk = Pipe(), closeDesk = Pipe()
    let executable = desktopBin + "/Antigravity"
    try! fm.copyItem(atPath:CommandLine.arguments[0], toPath:executable)
    desktop.executableURL = URL(fileURLWithPath:executable)
    desktop.arguments = ["hold-session-file", db]
    desktop.standardOutput = readyDesk; desktop.standardInput = closeDesk
    try! desktop.run()
    eq(readyDesk.fileHandleForReading.availableData, Data("ready".utf8), "桌面夹具已启动")
    eq(d.geminiDesktopReadOnly("desktop:existing"), true, "自定义安装位置的反重力仍保护桌面会话")
    closeDesk.fileHandleForWriting.closeFile(); desktop.waitUntilExit()

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
    d.hooks.jsSink = { fn, data in
        if fn == "onAgentModels" { models = (data["models"] as? [[String: Any]] ?? []).compactMap { $0["v"] as? String } }
    }
    d.loadUsage(agent: "gpt", force: true)
    // 读完就往下走；期限只防卡死。机器很忙时假 CLI 光启动就可能超过几秒。
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    waitUntil(runLoop: true, interval: 0.02) { d.procLock.lock(); defer { d.procLock.unlock() }; return !d.usageLoading.contains("gpt") }
    eq(models, ["new-codex-model"], "未预热时模型菜单从 app-server 读取 model/list")
}

// 先放入答完后的握手进程，再模拟同一会话开始打字；用协议阶段确认 resume 已经答复。
func testTypingResume() {
    let d = AppDelegate(), fm = FileManager.default
    let root = NSTemporaryDirectory() + "aipethub-typing-" + UUID().uuidString
    try! fm.createDirectory(atPath: root + "/sessions", withIntermediateDirectories: true)
    try! fm.createDirectory(atPath: root + "/conversations", withIntermediateDirectories: true)
    defer { d.dropWarm(); try? fm.removeItem(atPath: root) }
    d.hooks.prewarmWithoutBundle = true
    defer { d.hooks.prewarmWithoutBundle = false }   // 先于上面的 dropWarm 关掉：收尾时迟到的预热不再起进程
    d.hooks.codexEnvironment = ["CODEX_HOME":root]; d.hooks.geminiCliDir = root
    let commands = DispatchSemaphore(value: 0)
    d.hooks.jsSink = { fn, data in
        if fn == "onAgentCommands", (data["commands"] as? [[String:String]])?.first?["name"] == "compact" { commands.signal() }
    }
    let cli = root + "/cli"
    try! installFakeCLI(at: cli, behavior: "initialization")
    try! "ok".write(toFile: cli + ".mode", atomically: true, encoding: .utf8)
    d.hooks.cliExecutable = cli
    // Codex 打字时不续接（会占住写锁），由 testCodexWriterBusy 测。
    for (agent,cid) in [("gemini","session")] {
        let req = AskRequest(agent: agent, reqId: 81, prompt: "test", model: "model", effort: "low",
                             permissionMode: "default", workspace: root, conversationId: cid, browserTools: false)
        let file = agent == "gpt" ? root + "/sessions/rollout-fixture-thread.jsonl" : d.geminiConversationDb(cid)
        try! Data().write(to: URL(fileURLWithPath:file))
        let process = (agent == "gpt" ? d.warmCodex(req) : d.warmGemini(req))!
        process.warmKey = d.warmKey(req); d.keepWarm(agent, process)
        d.prewarm(req)
        // 接上就往下走；期限只防卡死。机器很忙时假 CLI 起来、答完 initialize 和 resume 可能要好几秒，
        // 没等到 stage 3 时还没有基线快照，下面「改动也丢弃」会退回 8 秒宽限而误判。
        waitUntil { process.withWarmLock { process.stage >= 3 } }
        eq(process.withWarmLock { process.stage }, 3, "\(agent) 打字复用答完后的进程，并提前接上旧会话")
        if agent == "gemini" {
            check(waitSignal(commands), "打字预热收到的斜杠命令在发送前就发布")
        }
        try! Data("change".utf8).write(to: URL(fileURLWithPath: agent == "gemini" ? file + "-wal" : file))
        let taken = d.takeWarm(req)
        check(taken == nil, "\(agent) 接上后头 8 秒改动也丢弃，不复用旧快照")
        if let taken = taken { taken.input?.close() }
        _ = process.waitForExit()
    }
    // 进入真正的打字续接回调，等它在预热锁内查完状态后再检查 ACP 阶段。
    d.hooks.geminiCliDir = root + "/antigravity-cli"
    d.hooks.geminiProbeTTL = 0   // 这里测的是续接本身，状态在测试里瞬间切换；扫描结果的复用另由 testGeminiProbeCache 测
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
        check(waitSignal(queried), "打字续接前查询桌面进程状态")
        if running == false {
            check(waitSignal(commands), "桌面退出后打字预热照常接入")
        } else {
            eq(process.withWarmLock { process.stage }, 1, "桌面仍可能在运行时预热只完成握手")
            d.hooks.geminiDesktopRunning = { false }
            d.prewarm(desk)
            check(waitSignal(commands), "退出桌面后继续打字，同一预热进程可以续接")
        }
        d.dropWarm(); _ = process.waitForExit()
    }
    d.hooks.geminiCliDir = root
    let req = AskRequest(agent: "gemini", reqId: 82, prompt: "test", model: "model", effort: "low",
                         permissionMode: "default", workspace: root, conversationId: "session", browserTools: false)
    // 第一个 agy 已成功预热；此时外部客户端才打开同一个库。文件内容完全不动，只有发送前的持库检查能拦住。
    let warm = d.warmGemini(req)!
    warm.warmKey = d.warmKey(req); d.keepWarm("gemini", warm); d.prewarm(req)
    check(waitSignal(commands), "第二次打字预热已接入会话")
    let holder = Process(), ready = Pipe(), release = Pipe(), other = root + "/agy"
    try! fm.copyItem(atPath: CommandLine.arguments[0], toPath: other)
    holder.executableURL = URL(fileURLWithPath: other)
    holder.arguments = ["hold-session-file", d.geminiConversationDb("session")]
    holder.standardOutput = ready; holder.standardInput = release
    try! holder.run()
    eq(ready.fileHandleForReading.availableData, Data("ready".utf8), "预热后外部 agy 已打开同一库")
    let watchdog = DispatchWorkItem { d.cancel(agent: req.agent, reqId: req.reqId) }
    // 只防卡死：拦住时立即返回；看门狗太早取消会让忙机器上正常的拦截也拿不到「其他客户端」的答复。
    DispatchQueue.global().asyncAfter(deadline: .now() + testWaitLimit, execute: watchdog)
    let blocked = withTestAsk(d, req.key) { d.runGemini(req) }
    watchdog.cancel()
    release.fileHandleForWriting.closeFile(); holder.waitUntilExit()
    check(blocked.reply.contains("其他客户端"), "接手已预热的会话也拦住新出现的 agy")
    let log = try! String(contentsOfFile: cli + ".log", encoding: .utf8)
    check(!log.contains("session/prompt"), "外部持库时没有提交提问")

    d.hooks.warmTypingIdle = 1
    let idle = d.warmGemini(req)!
    idle.warmKey = d.warmKey(req); d.keepWarm("gemini", idle)
    // 闲置期限只有 1 秒，从第一次打字算起。机器很忙时接上会话本身就可能超过 1 秒，进程会在接上前被闲置回收。
    // 所以接上之前一直「在打字」（同一预热进程只刷新打字时间，不会再发 resume），接上后才停手，
    // 要证明的仍是：停止打字后，已接上会话的预热进程自行退出并从缓存移除。
    var attached = false
    let attachBy = Date().addingTimeInterval(testWaitLimit)
    while !attached && idle.proc.isRunning && Date() < attachBy {
        d.prewarm(req)
        attached = commands.wait(timeout: .now() + 0.05) == .success
    }
    check(attached, "停止打字前已接上会话")
    let expired = idle.waitForExit(until: .now() + testWaitLimit) { terminateTree(idle.proc.processIdentifier) }
    check(!expired.timedOut && d.takeWarm(req) == nil, "打字闲置后预热进程自行退出并从缓存移除")

}

// 另一个 Codex 客户端占着会话的写锁：只打字不能抢先占住它，发送时被占着要立即说清楚，不白等、不退回同样拿不到锁的 codex exec。
func testCodexWriterBusy() {
    let d = AppDelegate(), fm = FileManager.default
    let root = NSTemporaryDirectory() + "aipethub-writer-" + UUID().uuidString
    try! fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { d.dropWarm(); try? fm.removeItem(atPath: root) }
    d.hooks.prewarmWithoutBundle = true
    defer { d.hooks.prewarmWithoutBundle = false }   // 先于上面的 dropWarm 关掉：收尾时迟到的预热不再起进程
    d.hooks.codexEnvironment = ["CODEX_HOME": root]
    d.hooks.jsSink = { _, _ in }
    let cli = root + "/cli", log = cli + ".log"
    try! installFakeCLI(at: cli, behavior: "initialization")
    try! "writer-busy".write(toFile: cli + ".mode", atomically: true, encoding: .utf8)
    d.hooks.cliExecutable = cli
    let req = AskRequest(agent: "gpt", reqId: 86, prompt: "test", model: "model", effort: "low",
                         permissionMode: "default", workspace: root, conversationId: "thread", browserTools: false)
    let warm = d.warmCodex(req)!
    warm.warmKey = d.warmKey(req); d.keepWarm("gpt", warm)
    // 握手完成就往下走；期限只防卡死。
    waitUntil { warm.withWarmLock { warm.stage >= 1 } }
    eq(warm.withWarmLock { warm.stage }, 1, "CW 预热已完成握手")
    d.prewarm(req)   // 用户在这个旧会话里开始打字
    d.procLock.lock(); let typed = d.warmIntents["gpt"]?.lastTyped; d.procLock.unlock()
    check(typed == nil, "CW 打字预热不进入续接旧会话的流程（实际记下了打字时间 \(String(describing: typed))）")
    let methods = { ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { d.jsonObject($0)?["method"] as? String } }
    let beforeSend = methods()
    let watchdog = DispatchWorkItem { d.cancel(agent: req.agent, reqId: req.reqId) }
    DispatchQueue.global().asyncAfter(deadline: .now() + testWaitLimit, execute: watchdog)
    let reply = withTestAsk(d, req.key) { d.runCodex(req) }
    watchdog.cancel()
    let sent = methods()
    check(!beforeSend.contains("thread/resume"), "CW 打字时没有发 thread/resume（实际 \(beforeSend)）")
    eq(sent.filter { $0 == "thread/resume" }.count, 1, "CW 写锁被占时只续接一次，不反复重试")
    check(!sent.contains("oneshot"), "CW 写锁被占时不退回 codex exec resume（实际 \(sent)）")
    check(!reply.cancelled, "CW 写锁被占时自己结束，不是挂到看门狗取消")   // 卡住的唯一可能是挂到看门狗
    check(reply.reply.hasPrefix("⚠️") && reply.reply.contains("别的 Codex 客户端"), "CW 给出明确提示，网页保留重试（实际：\(reply.reply.prefix(80))）")
    eq(reply.turn?["outcome"] as? String, "failed", "CW 这一轮标为失败")
    eq(reply.conversationId, "thread", "CW 失败后仍指向原会话")
    check(reply.restoreDraft, "CW turn/start 没发出，原话和附件退回原会话草稿")
}

/// 别的客户端的 agy 起会话、查模型时会顺手打开最近用过的另一个会话库，约 0.1 秒就关（agy 1.5.x 实测）。
/// 发送、删除前的持库检查刚好撞上这一下时不能当成「正在其他客户端打开」；一直开着库的仍要拦住。
/// 冒充的 agy 在 App 看到它、要复查之前（geminiHeldRecheck）关掉库，确定地卡在这个窗口里。
func testGeminiTransientHolder() {
    print("· Gemini 持库检查：别的 agy 只是顺手打开一下，不算被占")
    let d = AppDelegate(), fm = FileManager.default
    let root = NSTemporaryDirectory() + "aipethub-transient-" + UUID().uuidString
    defer { try? fm.removeItem(atPath: root) }
    try! fm.createDirectory(atPath: root + "/conversations", withIntermediateDirectories: true)
    let cli = root + "/cli", agy = root + "/agy"
    try! installFakeCLI(at: cli, behavior: "backend")
    try! fm.copyItem(atPath: CommandLine.arguments[0], toPath: agy)
    d.hooks.cliExecutable = cli; d.hooks.geminiCliDir = root
    d.hooks.geminiDesktopRunning = { false }
    var deleted: [String: Any]?
    d.hooks.jsSink = { fn, data in if fn == "onConversationDeleted" { deleted = data } }
    let db = d.geminiConversationDb("existing")
    /// 起一个以 agy 的名字开着库的外部进程（不归本 App 管），确认打开后返回；release 关掉它的 stdin 并等它退出。
    func holder() -> (proc: Process, release: () -> Void) {
        let p = Process(), ready = Pipe(), release = Pipe()
        p.executableURL = URL(fileURLWithPath: agy); p.arguments = ["hold-session-file", db]
        p.standardOutput = ready; p.standardInput = release
        try! p.run()
        eq(ready.fileHandleForReading.availableData, Data("ready".utf8), "TH 外部 agy 已打开库")
        return (p, { if p.isRunning { release.fileHandleForWriting.closeFile(); p.waitUntilExit() } })
    }
    var req = AskRequest(agent: "gemini", reqId: 86, prompt: "OK", model: "model", effort: "low",
                         permissionMode: "default", workspace: root, conversationId: "existing")
    req.browserTools = false

    try! Data("ready\n".utf8).write(to: URL(fileURLWithPath: db))
    var brief = holder(), rechecks = 0
    d.hooks.geminiHeldRecheck = { rechecks += 1; brief.release() }
    let sent = withTestAsk(d, req.key) { d.runGemini(req) }
    brief.release()
    eq(sent.reply, "fixture-ok", "TH 发送时别的 agy 只开了一下库，照常发送")
    check(rechecks > 0, "TH 看到外部 agy 后复查过")
    check(!sent.restoreDraft, "TH 照常发出的不退回草稿")
    // agy 在提问前拒绝所选模型：这句没交给它，原话和附件退回原会话草稿
    try! "model-refused".write(toFile: root + "/mode", atomically: true, encoding: .utf8)
    let refused = withTestAsk(d, req.key) { d.runGemini(req) }
    try! fm.removeItem(atPath: root + "/mode")
    check(refused.reply.contains("拒绝了所选模型") && refused.restoreDraft,
          "Gemini 拒绝所选模型时退回原会话草稿，实际=\(refused.reply.prefix(60))、退回=\(refused.restoreDraft)")

    brief = holder(); rechecks = 0
    d.deleteConversation(agent: "gemini", cid: "existing")
    d.geminiQueue.sync {}; d.geminiQueue.sync {}
    brief.release()
    eq(deleted?["ok"] as? Bool, true, "TH 删除时别的 agy 只开了一下库，照常删除（reason：\(str(deleted, "reason"))）")
    check(!fm.fileExists(atPath: db), "TH 库已移走")

    // 一直开着库的外部 agy：复查时还是它，照旧拦住
    try! Data("ready\n".utf8).write(to: URL(fileURLWithPath: db))
    d.hooks.geminiHeldRecheck = nil
    let steady = holder()
    let busy = withTestAsk(d, req.key) { d.runGemini(req) }
    check(busy.reply.contains("其他客户端"), "TH 一直开着库的外部 agy 仍拦住发送（实际：\(busy.reply.prefix(60))）")
    check(busy.restoreDraft, "TH 拦住发送时原话退回原会话草稿")
    deleted = nil
    d.deleteConversation(agent: "gemini", cid: "existing")
    d.geminiQueue.sync {}; d.geminiQueue.sync {}
    eq(deleted?["ok"] as? Bool, false, "TH 一直开着库时仍拦住删除")
    check(fm.fileExists(atPath: db), "TH 拦住删除时库还在")
    steady.release()

    let live = GeminiLiveTurn(app: d, req: req, agy: cli, fullModel: "model")
    var probe: (() -> Void)?, closed = ""
    d.hooks.geminiQuestionCheckScheduled = { probe = $0 }
    d.hooks.jsSink = { name, data in if name == "onAgentRequestClosed" { closed = str(data, "requestId") } }
    live.handle(line: #"{"id":7,"method":"elicitation/create","params":{"mode":"form","requestedSchema":{"properties":{}}}}"#)
    let competing = holder()
    probe?()
    eq(closed, "acp-7", "B3-2 等待作答期间出现第二个持库者，撤掉失效的提问卡")
    live.answer("acp-7", ["answers": ["a": "旧问题的回答"]])
    live.input.close()
    let sentAfterConflict = String(decoding: live.input.pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    check(!sentAfterConflict.contains("accept"), "B3-2 冲突后不提交旧卡答复，实际=\(sentAfterConflict)")
    competing.release()
}
