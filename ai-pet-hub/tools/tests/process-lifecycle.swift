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
    // 「不等满产品期限」类断言的门槛（用户 2026-11-18 定按机制取）：坏路径时长说得清时取它的一半；坏路径由测试自己的假进程决定时，
    // 把它拉到比统一上限长、门槛用 testWaitLimit；两者只差几秒时改比两件事的先后。这里的坏路径是永久阻塞
    check(Date().timeIntervalSince(t0) < testWaitLimit, "send / close 不等待管道排空")
    blocked!.abandon()
    blocked = nil
    waitUntil { released == nil }
    check(released == nil, "放弃启动后输入队列不再持有对象")

    let echo = CLIProcess(input: input, outputLimit: nil, streamsOutput: false)
    do { try echo.start(executable: "/bin/cat", arguments: [], cwd: NSTemporaryDirectory(), environment: env) }
    catch { check(false, "启动 cat：\(error)"); return }
    DispatchQueue.concurrentPerform(iterations: 200) { i in input.send(["id": i, "text": "中文🙂" + String(repeating: "x", count: 500)]) }
    input.close()
    let echoed = echo.waitForExit(until: .now() + testWaitLimit) { terminateTree(echo.proc.processIdentifier) }
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
    // 坏路径是等子进程退出（sleep 0.2 之后写入失败），只多 0.2 秒，挂钟分不出；这条只防永久阻塞，门槛给统一上限免得负载下误报
    check(Date().timeIntervalSince(sendAt) < testWaitLimit, "子进程不读输入时调用方仍立即返回")
    let stopped = silent.waitForExit(until: .now() + testWaitLimit) { terminateTree(silent.proc.processIdentifier) }
    check(!stopped.timedOut, "不读输入的子进程退出不会拖住读取收尾")

    let missing = CLIProcess(input: LiveInput())
    missing.input?.send(["text": String(repeating: "x", count: 100_000)])
    do {
        try missing.start(executable: "/aipethub-does-not-exist", arguments: [], cwd: NSTemporaryDirectory(), environment: env)
        check(false, "不存在的命令应启动失败")
    } catch { check(missing.input?.send(["late": true]) == false, "启动失败时关闭输入") }

    let out = d.runTool("/bin/sh", ["-c", "head -c 300000 /dev/zero & head -c 300000 /dev/zero >&2 & wait"],
                        cwd: NSTemporaryDirectory(), environment: env, timeout: testWaitLimit)
    eq(out.status, 0, "stdout / stderr 同时大输出不互相堵住")
    eq(out.out.utf8.count, 300000, "辅助命令保留完整 stdout")
    eq(out.err.utf8.count, 300000, "辅助命令保留完整 stderr")

    let timeoutAt = Date()
    let timed = d.runTool("/bin/sleep", ["600"], cwd: NSTemporaryDirectory(), environment: env, timeout: 0.15)
    eq(timed.status, -2, "辅助命令超时状态")
    check(Date().timeIntervalSince(timeoutAt) < testWaitLimit, "超时不再等待进程自然退出")   // 自然退出要 600 秒
    let grandchildAt = Date()
    let held = d.runTool("/bin/sh", ["-c", "sleep 600 & echo $!"], cwd: NSTemporaryDirectory(), environment: env, timeout: 2)
    if let pid = Int32(trimmed(held.out)) { kill(pid, SIGKILL) }
    eq(held.status, 0, "父进程正常退出不算超时")
    check(Date().timeIntervalSince(grandchildAt) < testWaitLimit, "孙进程持有管道最多等 3 秒")   // 等孙进程放开管道要 600 秒

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
    check(waitSignal(ended), "快速退出的子进程全部回调")
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
    d.hooks.jsSink = { _, _ in }
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
    if !early { check(waitSignal(looked), "历史队列释放后预热查询完成") }

    // 模型列表检查和发布必须在同一条主队列上，否则旧列表能覆盖新列表。
    var modelEvents = 0
    d.hooks.jsSink = { name, _ in if name == "onAgentModels" { modelEvents += 1 } }
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
    d.hooks.jsSink = { _, _ in }
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
    d.hooks.jsSink = { _, _ in }
    let req = AskRequest(agent: "deepseek", reqId: 92, prompt: "test", model: "", effort: "",
                         permissionMode: "", workspace: "", conversationId: "")
    for kind in ["completed","aborted","interrupted","blocked","error","max-tokens","unrecognized"] {
        for body in ["半句",""] {
            let turn = DeepSeekLiveTurn(app:d,req:req)
            var events: [[String:Any]] = [["type":"turn/start"], ["type":"user/message","data":["source":["kind":"user"],"content":[["type":"text","text":"原问"]]]]]
            if !body.isEmpty { events.append(["type":"assistant/message","data":["message":["content":[["type":"text","text":body]]]]]) }
            events.append(["type":"turn/end","data":["reason":["kind":kind]]])
            for event in events { turn.receiveForTest(["type":"session/event","event":event]) }
            let actual = turn.replyForTest, disk = dshTurns(events.map { ["event":$0] }).last
            let expected = kind == "completed" ? (body.isEmpty ? "failed" : "completed") :
                (["aborted","interrupted"].contains(kind) ? "interrupted" : (kind == "unrecognized" ? "incomplete" : "failed"))
            eq(actual.turn?["outcome"] as? String,expected,"DeepSeek 实时 \(kind) 有正文=\(!body.isEmpty)")
            eq(str(disk,"outcome"),expected,"DeepSeek 重开 \(kind) 有正文=\(!body.isEmpty)")
            eq(disk?["text"] as? String,actual.reply,"DeepSeek 重开 \(kind) 与实时正文相同")
            turn.input.abandon()
        }
    }
    let timers = DshFinishTimers(d)
    defer { d.hooks.dshIdleFinishScheduled = nil }
    let live = DeepSeekLiveTurn(app: d, req: req)
    func status(_ running: Bool) { live.receiveForTest(["type": "host/session-status", "running": running]) }
    status(true)
    status(false)
    status(true)
    let stale = timers.all
    stale.forEach { $0.expire() }
    check(!live.finishedForTest, "不运行→重新运行→旧回调到点，不应结束")
    status(false)
    stale.forEach { $0.expire() }   // 再次不运行之后上一次安排的旧回调才到点：按代次作废
    check(!live.finishedForTest, "再次不运行后，上一次安排的旧回调到点也不结束")
    eq(timers.last?.delay, live.idleFallback, "没点停止：不运行之后继续等 turn/end，不在 1.5 秒时收尾")
    check(!live.finishedForTest, "没点停止：安排兜底时还没结束")
    live.markStopping()   // 点了停止：这个版本的 dsh 写不出 turn/end，短等待兜底
    status(false)
    eq(timers.last?.delay, 1.5, "点了停止之后不运行，按 1.5 秒延迟结束")
    timers.last?.expire()
    check(live.finishedForTest, "点了停止之后不运行，到点就结束")
    live.input.abandon()
}


func testGeminiCancelOrphan() {
    print("· Gemini 取消时 CLI 先退出、命令忽略 TERM")
    let d = AppDelegate()
    d.hooks.jsSink = { _, _ in }
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
    // 等到读得出 pid 才算数：只看文件在不在的话，可能读到写了一半的空内容
    var child: pid_t?
    waitUntil { child = Int32(trimmed((try? String(contentsOfFile: path + ".child", encoding: .utf8)) ?? "")); return child != nil }
    check(child != nil, "假 ACP 已启动忽略 TERM 的命令")
    defer { if let child = child, kill(child, 0) == 0 { kill(child, SIGKILL) } }
    d.cancel(agent: req.agent, reqId: req.reqId)
    check(waitSignal(done) && cancelled, "CLI 在 cancel 后立即退出，仍返回 cancelled")
    check(registrationsCleared && testAsksEmpty(d), "取消带子进程的回答后摘掉进程/live，记录清空")
    // GeminiLive.interrupt 3 秒后 SIGKILL，或 cancel() 宽限期里 terminateRecorded 收走；子进程自己要睡 600 秒，等到了就是被收走的
    waitUntil(interval: 0.02) { child.map { kill($0, 0) != 0 } ?? true }
    check(child.map { kill($0, 0) != 0 } ?? false, "CLI 退出后仍强制收走取消前登记的子进程")
}

// 命令是 `sleep 120; echo unexpected > f` 这种：先结束 sleep、隔一会儿才结束外层 shell，shell 就接着写了尾部。
// 钩子在每个 TERM 之后停 0.3 秒，固定住机器忙时两次信号之间的间隔；宽限期交给测试不执行，只看停止当下 App 怎么收命令。
func testGeminiStopTail() {
    print("· Gemini 停止时正在跑的命令不再执行后半段")
    let d = AppDelegate()
    d.hooks.jsSink = { _, _ in }
    let dir = NSTemporaryDirectory() + "aipethub-stop-tail-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/cli"
    try! installFakeCLI(at: path, behavior: "cancel-tail")
    d.hooks.cliExecutable = path
    d.hooks.stopGraceScheduled = { _ in }
    d.hooks.stopSignalSent = { _ in Thread.sleep(forTimeInterval: 0.3) }
    var req = AskRequest(agent: "gemini", reqId: 97, prompt: "test", model: "model", effort: "low",
                         permissionMode: "bypassPermissions", workspace: dir, conversationId: "")
    req.browserTools = false
    d.procLock.lock(); d.asks[req.key] = AskState(); d.procLock.unlock()
    let done = DispatchSemaphore(value: 0)
    var cancelled = false
    DispatchQueue.global().async {
        cancelled = d.runGemini(req).cancelled
        d.procLock.lock(); d.asks[req.key] = nil; d.procLock.unlock()
        done.signal()
    }
    var shell: pid_t?
    waitUntil(interval: 0.02) {
        shell = Int32(trimmed((try? String(contentsOfFile: path + ".child", encoding: .utf8)) ?? ""))
        return shell.map { !descendants(of: $0).isEmpty } ?? false   // sleep 也起来了
    }
    let tree = shell.map { descendants(of: $0) + [$0] } ?? []
    check(tree.count == 2, "假 ACP 已用 zsh 前台跑起 sleep（实际 \(tree)）")
    defer { tree.forEach { if kill($0, 0) == 0 { kill($0, SIGKILL) } } }
    d.cancel(agent: req.agent, reqId: req.reqId)
    check(waitSignal(done) && cancelled, "停止后返回 cancelled")
    waitUntil(interval: 0.02) { !tree.contains { kill($0, 0) == 0 } }
    check(!tree.contains { kill($0, 0) == 0 }, "停止当下 shell 和 sleep 都结束了")
    check(!FileManager.default.fileExists(atPath: path + ".child.tail"), "停止后命令的后半段没有执行")
    check(testAsksEmpty(d), "停止后记录清空")
}

private func lpParentPid(_ pid: pid_t) -> pid_t? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

// 宽限期由钩子交给测试：先等根进程真的退出、子命令被系统收养，再执行到点的那一步，不靠等满 4 秒碰时机。
func testLPStopOrphans() {
    print("· LP：Claude / Codex 停止时 CLI 先退出，留下的命令在宽限期后收走")
    for agent in ["claude", "gpt"] {
        let d = AppDelegate()
        d.hooks.jsSink = { _, _ in }
        let dir = NSTemporaryDirectory() + "aipethub-lp-stop-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/cli"
        try! installFakeCLI(at: path, behavior: "stop-orphan")
        d.hooks.cliExecutable = path
        let graceLock = NSLock()
        var grace: (() -> Void)?
        d.hooks.stopGraceScheduled = { work in graceLock.lock(); grace = work; graceLock.unlock() }
        let req = AskRequest(agent: agent, reqId: 96, prompt: "fixture", model: "model", effort: "low",
                             permissionMode: "bypassPermissions", workspace: dir, conversationId: "", browserTools: false)
        d.procLock.lock(); d.asks[req.key] = AskState(); d.procLock.unlock()
        let done = DispatchSemaphore(value: 0)
        var cancelled = false
        DispatchQueue.global().async {
            cancelled = (agent == "claude" ? d.runClaude(req) : d.runCodex(req)).cancelled
            d.procLock.lock(); d.asks[req.key] = nil; d.procLock.unlock()
            done.signal()
        }
        var child: pid_t?
        waitUntil(interval: 0.02) { child = Int32(trimmed((try? String(contentsOfFile: path + ".child", encoding: .utf8)) ?? "")); return child != nil }
        check(child != nil, "LP \(agent)：假 CLI 已启动子命令")
        defer { if let child = child, kill(child, 0) == 0 { kill(child, SIGKILL) } }
        d.cancel(agent: agent, reqId: req.reqId)
        check(waitSignal(done) && cancelled, "LP \(agent)：中断后 CLI 自己退出，返回停止结果")
        check(child.map { kill($0, 0) == 0 } ?? false, "LP \(agent)：CLI 退出时子命令还在（复现的前提）")
        graceLock.lock(); let scheduled = grace; graceLock.unlock()
        check(scheduled != nil, "LP \(agent)：停止时安排了宽限期")
        scheduled?()
        waitUntil(interval: 0.02) { child.map { kill($0, 0) != 0 } ?? true }
        let survivor = child.flatMap { kill($0, 0) == 0 ? $0 : nil }
        check(survivor == nil, "LP \(agent)：宽限期到点后收走这一轮留下的子命令（实际仍存活，父 PID \(survivor.flatMap(lpParentPid).map(String.init) ?? "?")）")
        check(testAsksEmpty(d), "LP \(agent)：记录清空")
    }
}


// 必须最后运行：真实退出会永久禁止当前进程继续启动子进程。
// 已有会话里追问，在交给 CLI 之前点了停止：CLI 的记录里没有这一句，切走再回来就只剩上一轮。
// 只有确认没提交时才让网页把原话和附件退回原会话的输入框；CLI 已经收下的仍按停止显示，不然重开会多出一份。
func testUnsentFollowUpStop() {
    print("· UF：Claude / Codex 已有会话的追问在交给 CLI 前停止，原话退回草稿")
    for agent in ["claude", "gpt"] {
        for mode in ["unsent", "sent"] {
            let label = "UF \(agent)/\(mode)"
            let d = AppDelegate()
            d.hooks.jsSink = { _, _ in }
            let dir = NSTemporaryDirectory() + "aipethub-unsent-" + UUID().uuidString
            try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let path = dir + "/cli", journal = dir + "/session.jsonl", cid = "unsent-" + agent
            try! installFakeCLI(at: path, behavior: "unsent-stop")
            try! mode.write(toFile: path + ".mode", atomically: true, encoding: .utf8)
            try! journal.write(toFile: path + ".journal", atomically: true, encoding: .utf8)
            try! #"{"type":"user","message":{"role":"user","content":"上一问"}}"#.appending("\n").write(toFile: journal, atomically: true, encoding: .utf8)
            d.claudeCache[cid] = (0, nil, journal)
            d.hooks.cliExecutable = path
            let graceLock = NSLock()
            var grace: (() -> Void)?
            d.hooks.stopGraceScheduled = { work in graceLock.lock(); grace = work; graceLock.unlock() }
            let req = AskRequest(agent: agent, reqId: 97, prompt: "追问", model: "model", effort: "low",
                                 permissionMode: "bypassPermissions", workspace: dir, conversationId: cid, browserTools: false)
            d.procLock.lock(); d.asks[req.key] = AskState(); d.procLock.unlock()
            let done = DispatchSemaphore(value: 0)
            var result: AgentReply?
            DispatchQueue.global().async {
                result = agent == "claude" ? d.runClaude(req) : d.runCodex(req)
                d.procLock.lock(); d.asks[req.key] = nil; d.procLock.unlock()
                done.signal()
            }
            check(waitUntil { FileManager.default.fileExists(atPath: path + ".started") }, "\(label) 假 CLI 走到停止的位置")
            d.cancel(agent: agent, reqId: req.reqId)
            check(waitSignal(done), "\(label) 停止后这一轮收尾")
            graceLock.lock(); let scheduled = grace; graceLock.unlock()
            scheduled?()
            eq(result?.cancelled, true, "\(label) 结果是停止")
            eq(result?.restoreDraft, mode == "unsent", "\(label) 只有没交给 CLI 的追问退回草稿")
            if mode == "unsent" { eq(result?.conversationId, cid, "\(label) 仍属于原会话") }
            if mode == "unsent" { check(result?.reply.contains("已退回草稿") == true, "\(label) 告诉用户已退回草稿，实际=\(result?.reply ?? "")") }
            check(testAsksEmpty(d), "\(label) 记录清空")
        }
    }
}

func testShutdownDuringDshStartup() {
    print("· DeepSeek 尚未报端口时退出，不等启动超时")
    let d = AppDelegate()
    let dir = NSTemporaryDirectory() + "aipethub-dsh-exit-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let cli = CLIProcess(input: LiveInput())
    let continued = DispatchSemaphore(value: 0)
    try! cli.start(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 600 & while IFS= read -r line; do echo continued; done; wait"], cwd: dir, environment: ProcessInfo.processInfo.environment)
    cli.adopt { _ in continued.signal() }
    d.procLock.lock(); d.asks["gemini#quit"] = AskState(proc: cli.proc); d.procLock.unlock()
    d.hooks.terminationReply = .alertSecondButtonReturn
    check(d.applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "退出确认取消分支")
    cli.input?.send(["probe": "continue"])
    check(waitSignal(continued) && cli.proc.isRunning, "取消退出后 CLI 仍能继续收发")
    let quitTree = descendants(of: cli.proc.processIdentifier) + [cli.proc.processIdentifier]
    let path = dir + "/dsh"
    try! installFakeCLI(at: path, behavior: "dsh-starting")
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    DispatchQueue.global().async {
        _ = d.dshServer.ensure(executable: path, environment: ProcessInfo.processInfo.environment, cwd: dir)
    }
    waitUntil { FileManager.default.fileExists(atPath: path + ".started") }
    check(FileManager.default.fileExists(atPath: path + ".started"), "假 dsh 已启动且尚未报端口")
    // LP：回答进行中退出时，回答线程还拿着回答前的 Git 快照，App 强杀子进程后直接结束，等不到它释放。
    // 另放一个同名前缀、不是本实例登记的目录，退出清理不能按名字把它也删了。
    let repo = dir + "/repo"
    try! FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    try! Data("tracked\n".utf8).write(to: URL(fileURLWithPath: repo + "/tracked.txt"))
    check(d.runGit(["init", "-q"], in: repo) != nil && d.runGit(["add", "tracked.txt"], in: repo) != nil
          && d.runGit(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], in: repo) != nil,
          "LP：创建临时仓库")
    try! Data(repeating: 120, count: 700_000).write(to: URL(fileURLWithPath: repo + "/untracked.bin"))
    let heldSnapshot = d.gitSnapshot(repo)
    let snapshotDir = heldSnapshot?.content?.directory.path
    check(snapshotDir.map { FileManager.default.fileExists(atPath: $0) } ?? false, "LP：回答前的 Git 快照已建好")
    let foreign = NSTemporaryDirectory() + "aipethub-git-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: foreign, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: foreign) }
    let began = Date()
    d.hooks.terminationReply = .alertFirstButtonReturn
    check(d.applicationShouldTerminate(NSApplication.shared) == .terminateNow, "退出确认确定分支")
    d.applicationWillTerminate(Notification(name: Notification.Name("test-exit")))
    _ = cli.waitForExit(); cli.input?.abandon()
    d.procLock.lock(); d.asks["gemini#quit"] = nil; d.procLock.unlock()
    _ = waitUntil { quitTree.allSatisfy { kill($0, 0) != 0 } }
    check(quitTree.allSatisfy { kill($0, 0) != 0 }, "确认退出后连忽略 TERM 的 CLI 和子进程都清理")
    check(Date().timeIntervalSince(began) < 15, "退出不被 ensure 持有的锁拖住 30 秒")   // ensure 等端口 30 秒（DeepSeekServer），取一半
    check(snapshotDir.map { !FileManager.default.fileExists(atPath: $0) } ?? false,
          "LP：退出清理删掉还被回答拿着的 Git 快照（实际 \(snapshotDir.map { FileManager.default.fileExists(atPath: $0) ? "仍在" : "已删" } ?? "没建成")）")
    check(FileManager.default.fileExists(atPath: foreign), "LP：不是本实例登记的同名前缀目录不删")
    withExtendedLifetime(heldSnapshot) {}
}

func testCodexRetryTiming() {
    print("· Codex 静默检测、事件恢复及释放")
    let d = AppDelegate()
    d.hooks.jsSink = { _, _ in }
    let req = AskRequest(agent: "gpt", reqId: 99231, prompt: "fixture", model: "gpt", effort: "low", permissionMode: "read-only", workspace: "", conversationId: "")
    let stateLock = NSLock()
    var reads = 0, recordID: Int64 = 1, block = false, onMain = false
    var eventTimes: [Date] = [], readTimes: [(at: Date, since: Date)] = []
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0)
    let read: (String, Date, pid_t?) -> CodexRetryRecord? = { thread, since, _ in
        stateLock.lock(); reads += 1; readTimes.append((Date(), since)); let id = recordID, shouldBlock = block; onMain = onMain || Thread.isMainThread; stateLock.unlock()
        if shouldBlock { entered.signal(); _ = release.wait(timeout: .now() + testHoldLimit) }
        defer { if shouldBlock { returned.signal() } }
        return CodexRetryRecord(id: id, statusCode: 429, waitSeconds: id == 1 ? 487 : 106,
                                recordedAt: since.addingTimeInterval(0.01), message: "fixture \(thread) \(id)")
    }
    func count() -> Int { stateLock.lock(); defer { stateLock.unlock() }; return reads }
    // 只在真的静默之后才查：每次查询时它看到的最后一个事件（since）离查询已满静默间隔，且 since 之后、查询前一个静默间隔以前，测试没再发过事件。
    // 不比「零查询」：机器忙时事件间隔被拉长、真的静默了而去查，是对的。事件时刻在交给回合之前记，只会比回合自己记的早，不会冤枉它。
    func onlyQueriedWhenQuiet() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        let quiet = 0.12 - 0.01
        return readTimes.allSatisfy { read in
            read.at.timeIntervalSince(read.since) >= quiet
                && !eventTimes.contains { $0 > read.since && $0 <= read.at.addingTimeInterval(-quiet) }
        }
    }
    func make() -> CodexLiveTurn {
        CodexLiveTurn(app: d, req: req, codex: "/usr/bin/true", model: "gpt", effort: "low", sandbox: "read-only",
                      retryQuietInterval: 0.12, retryPollInterval: 0.03, retryReader: read)
    }
    func event(_ live: CodexLiveTurn, _ method: String, _ params: [String: Any] = [:]) {
        let line = String(data: try! JSONSerialization.data(withJSONObject: ["method": method, "params": params]), encoding: .utf8)!
        stateLock.lock(); eventTimes.append(Date()); stateLock.unlock()
        live.locked { live.handle(line: line) }
    }
    var live: CodexLiveTurn? = make()
    weak let weakLive = live
    event(live!, "thread/started", ["thread": ["id": "fixture"]])
    Thread.sleep(forTimeInterval: 0.16)
    eq(count(), 0, "回合未开始不查询")
    event(live!, "turn/started", ["turn": ["id": "turn-fixture"]])
    for _ in 0..<10 { Thread.sleep(forTimeInterval: 0.02); event(live!, "thread/tokenUsage/updated") }
    check(onlyQueriedWhenQuiet(), "事件正常流动时不查询，只在真的静默之后查")
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
    check(onlyQueriedWhenQuiet(), "恢复事件后停止查询，持续事件期间不查（恢复之后读了 \(count() - recoveredReads) 次）")
    stateLock.lock(); block = true; recordID = 3; stateLock.unlock()
    check(waitSignal(entered), "模拟后台查询正在进行")
    // 查询还卡着的时候事件就处理完了，才说明查询不占回合锁；放行要等这之后
    let handled = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { event(live!, "item/agentMessage/delta", ["itemId": "m", "delta": "恢复"]); handled.signal() }
    check(waitSignal(handled), "查询不占回合锁，事件立即处理")
    release.signal(); _ = waitSignal(returned)
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
        check(waitSignal(entered), "\(mode)：进入在途查询")
        if mode == "interrupt" { turn!.locked { turn!.interrupt() } }
        turn!.input.abandon(); turn = nil
        check(weakTurn == nil, "\(mode)：在途查询也不持有回合")
        let beforeCount = count()
        release.signal(); _ = waitSignal(returned)
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
