// CLIProcess、LiveInput、停止、退出与恢复；build/selftest offline。
import Foundation
import Cocoa
import SQLite3

func testProcessBoundaries() {
    print("· 子进程、输入队列与资源回收")
    let d = AppDelegate()
    let env = ProcessInfo.processInfo.environment
    let buffer = OutputBuffer(limit: 31)
    DispatchQueue.concurrentPerform(iterations: 1000) { _ in buffer.append(Data(repeating: 120, count: 97)) }
    eq(buffer.string, String(repeating: "x", count: 31), "并发输出始终只留限定尾部")

    let input = LiveInput(), cli = CLIProcess(input: nil, streamsOutput: false)
    // 不读输入的进程不能卡住 send / close；退出后堵住的写入应释放。
    var blocked: LiveInput? = LiveInput()
    weak let released = blocked
    let t0 = Date()
    check(blocked!.send(["text": String(repeating: "x", count: 1 << 20)]), "大输入可在启动前排队")
    blocked!.close()
    check(Date().timeIntervalSince(t0) < 1, "send / close 不等待管道排空")
    blocked!.abandon()
    blocked = nil
    let releaseDeadline = Date().addingTimeInterval(2)
    while released != nil && Date() < releaseDeadline { Thread.sleep(forTimeInterval: 0.01) }
    check(released == nil, "放弃启动后输入队列不再持有对象")

    let echo = CLIProcess(input: input, outputLimit: nil, streamsOutput: false)
    do { try echo.start(executable: "/bin/cat", arguments: [], cwd: NSTemporaryDirectory(), environment: env) }
    catch { check(false, "启动 cat：\(error)"); return }
    DispatchQueue.concurrentPerform(iterations: 200) { i in input.send(["id": i, "text": "中文🙂" + String(repeating: "x", count: 500)]) }
    input.close()
    let echoed = echo.waitForExit(until: .now() + 5) { terminateTree(echo.proc.processIdentifier) }
    check(!echoed.timedOut, "并发写入后 EOF 能结束子进程")
    let ids = echoed.out.split(separator: "\n").compactMap { d.jsonObject($0)?["id"] as? Int }
    eq(ids.sorted(), Array(0..<200), "200 条并发 JSON 没有串行损坏或丢失")
    check(!input.send(["late": true]), "close 后拒绝新输入")

    let silentInput = LiveInput(), silent = CLIProcess(input: silentInput)
    do { try silent.start(executable: "/bin/sleep", arguments: ["0.2"], cwd: NSTemporaryDirectory(), environment: env) }
    catch { check(false, "启动不读输入的进程：\(error)"); return }
    let sendAt = Date()
    silentInput.send(["text": String(repeating: "x", count: 1 << 20)])
    silentInput.close()
    check(Date().timeIntervalSince(sendAt) < 1, "子进程不读输入时调用方仍立即返回")
    let stopped = silent.waitForExit(until: .now() + 3) { terminateTree(silent.proc.processIdentifier) }
    check(!stopped.timedOut, "不读输入的子进程退出不会拖住读取收尾")

    let missing = CLIProcess(input: LiveInput())
    missing.input?.send(["text": String(repeating: "x", count: 100_000)])
    do {
        try missing.start(executable: "/aipethub-does-not-exist", arguments: [], cwd: NSTemporaryDirectory(), environment: env)
        check(false, "不存在的命令应启动失败")
    } catch { check(missing.input?.send(["late": true]) == false, "启动失败时关闭输入") }

    let out = d.runTool("/bin/sh", ["-c", "head -c 300000 /dev/zero & head -c 300000 /dev/zero >&2 & wait"],
                        cwd: NSTemporaryDirectory(), environment: env, timeout: 5)
    eq(out.status, 0, "stdout / stderr 同时大输出不互相堵住")
    eq(out.out.utf8.count, 300000, "辅助命令保留完整 stdout")
    eq(out.err.utf8.count, 300000, "辅助命令保留完整 stderr")

    let timeoutAt = Date()
    let timed = d.runTool("/bin/sleep", ["10"], cwd: NSTemporaryDirectory(), environment: env, timeout: 0.15)
    eq(timed.status, -2, "辅助命令超时状态")
    check(Date().timeIntervalSince(timeoutAt) < 2, "超时不再等待进程自然退出")
    let grandchildAt = Date()
    let held = d.runTool("/bin/sh", ["-c", "sleep 10 & echo $!"], cwd: NSTemporaryDirectory(), environment: env, timeout: 2)
    if let pid = Int32(trimmed(held.out)) { kill(pid, SIGKILL) }
    eq(held.status, 0, "父进程正常退出不算超时")
    check(Date().timeIntervalSince(grandchildAt) < 5, "孙进程持有管道最多等 3 秒")

    // 非交互式停止以及启动前停止，均不能留下登记项。
    let cancelled = withTestAsk(d, "test#1") {
        d.cancel(agent: "test", reqId: 1)
        let result = d.runCLI(agent: "test#1", executable: "/bin/sleep", arguments: ["10"], cwd: NSTemporaryDirectory())
        check(testAskState(d, "test#1")?.cancelled == true, "启动前停止标记保留到回答结束")
        check(testAskState(d, "test#1")?.proc == nil, "启动前停止不挂进程")
        return result
    }
    check(cancelled.cancelled && testAsksEmpty(d), "启动前停止并清理登记")
    let registry = ChildProcesses()
    let ended = DispatchGroup()
    for _ in 0..<30 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        ended.enter()
        do { try registry.start(p) { ended.leave() } }
        catch { ended.leave(); check(false, "快速子进程启动：\(error)") }
    }
    check(ended.wait(timeout: .now() + 5) == .success, "快速退出的子进程全部回调")
    check(registry.beginShutdown().isEmpty, "退出登记不残留已结束 PID")
    do { try registry.start(cli.proc); check(false, "退出标记之后不能再启动") }
    catch { check(true, "退出标记之后拒绝启动") }

    let beforeFDs = (0..<1024).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
    for _ in 0..<40 {
        autoreleasepool {
            _ = d.runTool("/usr/bin/true", [], cwd: NSTemporaryDirectory(), environment: env, timeout: 2)
        }
    }
    let afterFDs = (0..<1024).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
    check(afterFDs <= beforeFDs + 4, "连续 40 次辅助命令不累积描述符（\(beforeFDs) → \(afterFDs)）")
}

func testBackendBoundaries() {
    print("· 后端时序与半写记录")
    let d = AppDelegate()
    d.jsSink = { _, _ in }
    let req = AskRequest(agent: "deepseek", reqId: 71, prompt: "test", model: "", effort: "",
                         permissionMode: "", workspace: "", conversationId: "")
    d.procLock.lock(); d.asks[req.key] = AskState(); d.procLock.unlock()
    d.cancel(agent: req.agent, reqId: req.reqId)
    let live = LiveTurn(app: d, req: req)
    d.registerLive(req.key, live)
    check(live.stopping, "登记前点停止：LiveTurn 接手停止标记")
    d.unregisterLive(req.key)
    d.procLock.lock(); d.asks[req.key] = nil; d.asks[req.key] = AskState(); d.procLock.unlock()
    d.cancel(agent: req.agent)
    check(testAskState(d, req.key)?.cancelled == true, "停止这一位全部回答：包含尚未登记进程的提问")
    d.procLock.lock(); d.asks[req.key] = nil; d.procLock.unlock()
    live.input.abandon()

    let marker = #"{"type":"custom-title""#
    let rows = #"{"type":"custom-title","customTitle":"原来的标题"}"# + "\n" +
        #"{"type":"custom-title","customTitle":"尚未写完"#
    eq(d.lastLine(startingWith: marker, in: Data(rows.utf8))?["customTitle"] as? String,
       "原来的标题", "标题尾行半写：仍取上一条完整标题")

    // 预热在全局队列上找记录，必须等历史队列完成缓存的写入。
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0), looked = DispatchSemaphore(value: 0)
    let path = NSTemporaryDirectory() + "aipethub-cache-" + UUID().uuidString
    try! Data().write(to: URL(fileURLWithPath: path))
    defer { try? FileManager.default.removeItem(atPath: path) }
    d.claudeQueue.sync { d.claudeCache["test-cache"] = (0, nil, path) }
    d.claudeQueue.async { entered.signal(); release.wait() }
    entered.wait()
    DispatchQueue.global().async {
        started.signal()
        _ = d.conversationFile(agent: "claude", cid: "test-cache")
        looked.signal()
    }
    started.wait()
    let early = looked.wait(timeout: .now() + 0.15) == .success
    release.signal()
    check(!early, "预热查 Claude 缓存与历史队列串行")
    if !early { check(looked.wait(timeout: .now() + 2) == .success, "历史队列释放后预热查询完成") }

    // 模型列表检查和发布必须在同一条主队列上，否则旧列表能覆盖新列表。
    var modelEvents = 0
    d.jsSink = { name, _ in if name == "onAgentModels" { modelEvents += 1 } }
    d.noteGeminiModels(["configOptions": [["id": "model", "options": [["value": "old"]]]]])
    d.geminiModelsFromCLI = true
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.main.async { drained.signal() }
    while drained.wait(timeout: .now()) != .success { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    eq(modelEvents, 0, "完整 Gemini 模型已到：排队中的会话模型不能覆盖它")
}

func testExitAfterAdopt() {
    print("· 接手之后退出不标记 warmDied")
    let d = AppDelegate()
    d.jsSink = { _, _ in }
    let req = AskRequest(agent: "gemini", reqId: 93, prompt: "test", model: "", effort: "",
                         permissionMode: "", workspace: "", conversationId: "")
    let warm = CLIProcess(input: LiveInput())
    warm.warmKey = d.warmKey(req)
    try! warm.start(executable: "/bin/cat", arguments: [], cwd: NSTemporaryDirectory(),
                    environment: ProcessInfo.processInfo.environment)
    d.keepWarm(req.agent, warm)
    let live = ExitAfterAdoptTurn(app: d, req: req)
    let result = withTestAsk(d, req.key) {
        let result = live.run(executable: "/unused", arguments: [], cwd: NSTemporaryDirectory())
        check(testAskState(d, req.key)?.live == nil && testAskState(d, req.key)?.proc == nil, "接手后退出先摘掉 live 和进程")
        return result
    }
    check(live.adoptedWhileRegistered, "接手时已登记 LiveTurn")
    check(!result.warmDied && !live.warmDied, "接手后退出：CLIResult 和 LiveTurn 均不触发重试")
    check(result.launchError == nil, "已接手进程没有另起 /unused")
    check(testAskState(d, req.key) == nil, "接手后退出也清理登记")
}

func testDeepSeekDelayedFinish() {
    print("· DeepSeek 延迟结束回调的代次")
    let d = AppDelegate()
    d.jsSink = { _, _ in }
    let req = AskRequest(agent: "deepseek", reqId: 92, prompt: "test", model: "", effort: "",
                         permissionMode: "", workspace: "", conversationId: "")
    let live = DeepSeekLiveTurn(app: d, req: req)
    func status(_ running: Bool) { live.receiveForTest(["type": "host/session-status", "running": running]) }
    status(true)
    status(false)
    status(true)
    Thread.sleep(forTimeInterval: 1.8)
    check(!live.finishedForTest, "不运行→重新运行→旧回调到点，不应结束")
    status(false)
    Thread.sleep(forTimeInterval: 1.8)
    check(!live.finishedForTest, "没点停止：不运行之后继续等 turn/end，不在 1.5 秒时收尾")
    live.markStopping()   // 点了停止：这个版本的 dsh 写不出 turn/end，短等待兜底
    status(false)
    Thread.sleep(forTimeInterval: 1.8)
    check(live.finishedForTest, "点了停止之后不运行，按 1.5 秒延迟结束")
    live.input.abandon()
}


func testGeminiCancelOrphan() {
    print("· Gemini 取消时 CLI 先退出、命令忽略 TERM")
    let d = AppDelegate()
    d.jsSink = { _, _ in }
    let dir = NSTemporaryDirectory() + "aipethub-cancel-orphan-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/cli"
    try! installFakeCLI(at: path, behavior: "cancel-orphan")
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    d.hooks.cliExecutable = path
    var req = AskRequest(agent: "gemini", reqId: 94, prompt: "test", model: "model", effort: "low",
                         permissionMode: "bypassPermissions", workspace: dir, conversationId: "")
    req.browserTools = false
    d.procLock.lock(); d.asks[req.key] = AskState(); d.procLock.unlock()
    let done = DispatchSemaphore(value: 0)
    var cancelled = false, registrationsCleared = false
    DispatchQueue.global().async {
        cancelled = d.runGemini(req).cancelled
        registrationsCleared = testAskState(d, req.key)?.proc == nil && testAskState(d, req.key)?.live == nil
        d.procLock.lock(); d.asks[req.key] = nil; d.procLock.unlock()
        done.signal()
    }
    let ready = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: path + ".child"), Date() < ready { Thread.sleep(forTimeInterval: 0.02) }
    let child = Int32(trimmed((try? String(contentsOfFile: path + ".child", encoding: .utf8)) ?? ""))
    check(child != nil, "假 ACP 已启动忽略 TERM 的命令")
    defer { if let child = child, kill(child, 0) == 0 { kill(child, SIGKILL) } }
    d.cancel(agent: req.agent, reqId: req.reqId)
    check(done.wait(timeout: .now() + 6) == .success && cancelled, "CLI 在 cancel 后立即退出，仍返回 cancelled")
    check(registrationsCleared && testAsksEmpty(d), "取消带子进程的回答后摘掉进程/live，记录清空")
    let deadline = Date().addingTimeInterval(4)
    while let child = child, kill(child, 0) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    check(child.map { kill($0, 0) != 0 } ?? false, "CLI 退出后仍强制收走取消前登记的子进程")
}


// 必须最后运行：真实退出会永久禁止当前进程继续启动子进程。
func testShutdownDuringDshStartup() {
    print("· DeepSeek 尚未报端口时退出，不等启动超时")
    let d = AppDelegate()
    let dir = NSTemporaryDirectory() + "aipethub-dsh-exit-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let cli = CLIProcess(input: LiveInput())
    let continued = DispatchSemaphore(value: 0)
    try! cli.start(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 120 & while IFS= read -r line; do echo continued; done; wait"], cwd: dir, environment: ProcessInfo.processInfo.environment)
    cli.adopt { _ in continued.signal() }
    d.procLock.lock(); d.asks["gemini#quit"] = AskState(proc: cli.proc); d.procLock.unlock()
    d.hooks.terminationReply = .alertSecondButtonReturn
    check(d.applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "退出确认取消分支")
    cli.input?.send(["probe": "continue"])
    check(continued.wait(timeout: .now()+2) == .success && cli.proc.isRunning, "取消退出后 CLI 仍能继续收发")
    let quitTree = descendants(of: cli.proc.processIdentifier) + [cli.proc.processIdentifier]
    let path = dir + "/dsh"
    try! installFakeCLI(at: path, behavior: "dsh-starting")
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    DispatchQueue.global().async {
        _ = d.dshServer.ensure(executable: path, environment: ProcessInfo.processInfo.environment, cwd: dir)
    }
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: path + ".started"), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    check(FileManager.default.fileExists(atPath: path + ".started"), "假 dsh 已启动且尚未报端口")
    let began = Date()
    d.hooks.terminationReply = .alertFirstButtonReturn
    check(d.applicationShouldTerminate(NSApplication.shared) == .terminateNow, "退出确认确定分支")
    d.applicationWillTerminate(Notification(name: Notification.Name("test-exit")))
    _ = cli.waitForExit(); cli.input?.abandon()
    d.procLock.lock(); d.asks["gemini#quit"] = nil; d.procLock.unlock()
    let goneBy = Date().addingTimeInterval(2)
    while Date() < goneBy, quitTree.contains(where: { kill($0, 0) == 0 }) { Thread.sleep(forTimeInterval: 0.02) }
    check(quitTree.allSatisfy { kill($0, 0) != 0 }, "确认退出后连忽略 TERM 的 CLI 和子进程都清理")
    check(Date().timeIntervalSince(began) < 3, "退出不被 ensure 持有的锁拖住 30 秒")
}

func testCodexRetryTiming() {
    print("· Codex 静默检测、事件恢复及释放")
    let d = AppDelegate()
    d.jsSink = { _, _ in }
    let req = AskRequest(agent: "gpt", reqId: 99231, prompt: "fixture", model: "gpt", effort: "low", permissionMode: "read-only", workspace: "", conversationId: "")
    let stateLock = NSLock()
    var reads = 0, recordID: Int64 = 1, block = false, onMain = false
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0)
    let read: (String, Date, pid_t?) -> CodexRetryRecord? = { thread, since, _ in
        stateLock.lock(); reads += 1; let id = recordID, shouldBlock = block; onMain = onMain || Thread.isMainThread; stateLock.unlock()
        if shouldBlock { entered.signal(); _ = release.wait(timeout: .now() + 3) }
        defer { if shouldBlock { returned.signal() } }
        return CodexRetryRecord(id: id, statusCode: 429, waitSeconds: id == 1 ? 487 : 106,
                                recordedAt: since.addingTimeInterval(0.01), message: "fixture \(thread) \(id)")
    }
    func count() -> Int { stateLock.lock(); defer { stateLock.unlock() }; return reads }
    func waitUntil(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(2)
        while !condition(), Date() < end { Thread.sleep(forTimeInterval: 0.005) }
        return condition()
    }
    func make() -> CodexLiveTurn {
        CodexLiveTurn(app: d, req: req, codex: "/usr/bin/true", model: "gpt", effort: "low", sandbox: "read-only",
                      retryQuietInterval: 0.12, retryPollInterval: 0.03, retryReader: read)
    }
    func event(_ live: CodexLiveTurn, _ method: String, _ params: [String: Any] = [:]) {
        let line = String(data: try! JSONSerialization.data(withJSONObject: ["method": method, "params": params]), encoding: .utf8)!
        live.locked { live.handle(line: line) }
    }
    var live: CodexLiveTurn? = make()
    weak let weakLive = live
    event(live!, "thread/started", ["thread": ["id": "fixture"]])
    Thread.sleep(forTimeInterval: 0.16)
    eq(count(), 0, "回合未开始不查询")
    event(live!, "turn/started", ["turn": ["id": "turn-fixture"]])
    for _ in 0..<10 { Thread.sleep(forTimeInterval: 0.02); event(live!, "thread/tokenUsage/updated") }
    eq(count(), 0, "事件正常流动时零查询")
    check(waitUntil { live!.locked { live!.builder.step("retry") != nil } }, "静默后出现提示")
    let firstReads = count()
    check(waitUntil { count() > firstReads }, "静默期间继续轮询")
    eq(live!.locked { live!.builder.steps.count }, 1, "反复读到同一日志不新增步骤")
    stateLock.lock(); recordID = 2; stateLock.unlock()
    check(waitUntil { live!.locked { str(live!.builder.step("retry"), "title").contains("2 分钟") } }, "新重试记录原地更新")
    eq(live!.locked { live!.builder.steps.count }, 1, "更新后仍只有一步")
    event(live!, "thread/tokenUsage/updated")
    let recoveredReads = count()
    for _ in 0..<10 { Thread.sleep(forTimeInterval: 0.02); event(live!, "thread/tokenUsage/updated") }
    eq(count(), recoveredReads, "恢复事件后停止查询，持续事件期间不查")
    stateLock.lock(); block = true; recordID = 3; stateLock.unlock()
    check(entered.wait(timeout: .now() + 2) == .success, "模拟后台查询正在进行")
    let before = Date()
    event(live!, "item/agentMessage/delta", ["itemId": "m", "delta": "恢复"])
    check(Date().timeIntervalSince(before) < 0.1, "查询不占回合锁，事件立即处理")
    release.signal(); _ = returned.wait(timeout: .now() + 1)
    Thread.sleep(forTimeInterval: 0.02)
    eq(live!.locked { str(live!.builder.step("retry"), "detail") }, "fixture fixture 2", "恢复后的在途旧查询不回写")
    event(live!, "turn/completed", ["turn": ["status": "completed"]])
    let endReads = count()
    Thread.sleep(forTimeInterval: 0.18)
    eq(count(), endReads, "回合结束后取消检查")
    live!.input.abandon(); live = nil
    check(weakLive == nil, "回合结束后可释放，无 timer 循环引用")
    stateLock.lock(); block = false; stateLock.unlock()
    for mode in ["interrupt", "deinit", "exit"] {
        var turn: CodexLiveTurn? = make()
        weak let weakTurn = turn
        event(turn!, "thread/started", ["thread": ["id": "fixture"]])
        event(turn!, "turn/started", ["turn": ["id": "turn-fixture"]])
        if mode == "interrupt" { turn!.locked { turn!.interrupt() } }
        if mode == "exit" { _ = withTestAsk(d, req.key) { turn!.run() } }
        let beforeCount = count()
        turn!.input.abandon(); turn = nil
        check(weakTurn == nil, "\(mode)：取消 timer 后对象释放")
        Thread.sleep(forTimeInterval: 0.18)
        eq(count(), beforeCount, "\(mode)：不留下后台查询")
    }
    // 真正卡在查询中的时刻停止或释放：不用等查询返回，返回后也不能再发布步骤。
    stateLock.lock(); block = true; stateLock.unlock()
    for mode in ["interrupt", "deinit"] {
        var turn: CodexLiveTurn? = make()
        weak let weakTurn = turn
        let builder = turn!.builder
        event(turn!, "thread/started", ["thread": ["id": "fixture"]])
        event(turn!, "turn/started", ["turn": ["id": "turn-fixture"]])
        check(entered.wait(timeout: .now() + 2) == .success, "\(mode)：进入在途查询")
        if mode == "interrupt" { turn!.locked { turn!.interrupt() } }
        turn!.input.abandon(); turn = nil
        check(weakTurn == nil, "\(mode)：在途查询也不持有回合")
        let beforeCount = count()
        release.signal(); _ = returned.wait(timeout: .now() + 1)
        Thread.sleep(forTimeInterval: 0.18)
        eq(count(), beforeCount, "\(mode)：在途查询完成后不再调度")
        check(builder.step("retry") == nil, "\(mode)：丢弃停止或释放后的查询结果")
    }
    stateLock.lock(); let didRunOnMain = onMain; stateLock.unlock()
    check(!didRunOnMain, "所有读取均在后台线程")
}

private final class ExitAfterAdoptTurn: LiveTurn {
    var adoptedWhileRegistered = false
    override func adopted() {
        adoptedWhileRegistered = app.liveTurn(agent: req.agent, reqId: req.reqId) === self
        warm?.proc.terminate()
    }
}
