// AskState：用真实 ask() 卡在各个停止阶段上，确认登记和自己起的进程都收干净；build/selftest offline 和 ask-state。
import Foundation

// 用真实 ask() 跑生命周期；回调只收集证据，所有断言在测试线程执行。
private final class AskStateProbe {
    private let lock = NSLock()
    private var replies: [String: [String: Any]] = [:]
    private var processes: [String: [Process]] = [:]
    private var facts: [String: Bool] = [:]
    private var counts: [String: Int] = [:]

    func receive(_ name: String, _ payload: [String: Any]) {
        guard name == "onAgentResponse", let agent = payload["agent"] as? String, let id = payload["reqId"] as? Int else { return }
        lock.lock(); replies["\(agent)#\(id)"] = payload; lock.unlock()
    }
    func reply(_ key: String) -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return replies[key] }
    func started(_ key: String, _ proc: Process) { lock.lock(); processes[key, default: []].append(proc); lock.unlock() }
    func procs(_ key: String) -> [Process] { lock.lock(); defer { lock.unlock() }; return processes[key] ?? [] }
    func note(_ key: String, _ value: Bool) { lock.lock(); facts[key] = value; lock.unlock() }
    func fact(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return facts[key] == true }
    @discardableResult func increment(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; counts[key, default: 0] += 1; return counts[key]! }
    func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key] ?? 0 }
}

private func awaitAskState(_ condition: () -> Bool, timeout: TimeInterval = 8) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
    return condition()
}

private func askStateRequest(_ agent: String, _ id: Int, _ workspace: String) -> AskRequest {
    AskRequest(agent: agent, reqId: id, prompt: "fixture", model: "model", effort: "low",
               permissionMode: "default", workspace: workspace, conversationId: "", browserTools: false)
}

private func assertAskFinished(_ app: AppDelegate, _ req: AskRequest, _ probe: AskStateProbe,
                               cancelled: Bool, label: String) {
    let finished = awaitAskState { probe.reply(req.key) != nil && testAskState(app, req.key) == nil }
    if !finished {
        app.cancel(agent: req.agent, reqId: req.reqId)
        probe.procs(req.key).filter { $0.isRunning }.forEach { terminateTree($0.processIdentifier) }
        _ = awaitAskState({ testAskState(app, req.key) == nil }, timeout: 6)
    }
    check(finished, "\(label)：最终响应并由 ask() 删除记录")
    eq(probe.reply(req.key)?["cancelled"] as? Bool, cancelled, "\(label)：cancelled")
    let gone = awaitAskState { probe.procs(req.key).allSatisfy { !$0.isRunning && kill($0.processIdentifier, 0) != 0 } }
    check(gone, "\(label)：自己启动的进程均已退出")
    check(testAskState(app, req.key) == nil, "\(label)：asks 不留键")
}

// 每个阶段都是用 TestHooks 卡在确定的位置上再点停止的，结果不靠碰运气，所以每种情况只跑几轮；
// 多跑几十轮只会把断言数刷大、让测试变慢，查不出更多东西。
func testAskStateStages() {
    print("· AskState：六个停止阶段、启动失败及批量回收")
    let dir = NSTemporaryDirectory() + "aipethub-ask-state-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/cli"
    try! installFakeCLI(at: path, behavior: "backend")
    try! "ok".write(toFile: dir + "/mode", atomically: true, encoding: .utf8)
    // 每条路径重复 20 次；复用 AppDelegate，旧键如果留下来会累积在同一本 asks 里。
    for stage in ["received", "live", "registered", "started", "exited", "finishing", "launch-failed", "normal"] {
        let d = AppDelegate(), probe = AskStateProbe()
        d.hooks.cliExecutable = stage == "launch-failed" ? dir + "/missing" : path
        d.jsSink = probe.receive
        d.hooks.cliStarted = { key, proc in probe.started(key, proc) }
        for iteration in 0..<3 {
            let req = askStateRequest("gemini", 5000 + iteration, dir)
            let cancel = {
                d.cancel(agent: req.agent, reqId: req.reqId)
                probe.note(req.key + "-marked", testAskState(d, req.key)?.cancelled == true)
            }
            d.hooks.askReceived = { current in
                if stage == "received" {
                    let state = testAskState(d, current.key)
                    probe.note(req.key + "-stage", state != nil && state?.proc == nil && state?.live == nil)
                    cancel()
                }
            }
            d.hooks.liveRegistered = { key, live in
                if stage == "live" {
                    let state = testAskState(d, key)
                    probe.note(req.key + "-stage", state?.live === live && state?.proc == nil)
                    cancel()
                }
            }
            d.hooks.cliRegistered = { key, proc in
                if stage == "registered" || stage == "launch-failed" {
                    probe.note(req.key + "-stage", testAskState(d, key)?.proc === proc && !proc.isRunning)
                    cancel()
                }
            }
            d.hooks.cliStarted = { key, proc in
                probe.started(key, proc)
                if stage == "started" {
                    probe.note(req.key + "-stage", proc.isRunning && d.runningPid(key) == proc.processIdentifier)
                    cancel()
                }
            }
            d.hooks.cliExited = { key, proc in
                if stage == "exited" {
                    probe.note(req.key + "-stage", !proc.isRunning && testAskState(d, key)?.proc === proc)
                    cancel()
                }
            }
            d.hooks.askFinishing = { current in
                if stage == "finishing" {
                    let state = testAskState(d, current.key)
                    probe.note(req.key + "-stage", state != nil && state?.proc == nil && state?.live == nil)
                    cancel()
                }
            }
            d.ask(req)
            // 收尾阶段才点的停止来不及了：照常算答完，但记录仍要被删掉
            assertAskFinished(d, req, probe, cancelled: stage != "normal" && stage != "finishing", label: "\(stage)/\(iteration)")
            if stage != "normal" {
                check(probe.fact(req.key + "-stage"), "\(stage)：确定到达目标阶段")
                check(probe.fact(req.key + "-marked"), "\(stage)：停止后记录上的标记为真")
            }
            if ["received", "live", "launch-failed"].contains(stage) {
                eq(probe.procs(req.key).count, 0, "\(stage)：没有成功启动进程")
            }
        }
        check(testAsksEmpty(d), "\(stage)：连续 20 次后 asks 为空")
        d.hooks = TestHooks()
    }
}

func testAskStateParallel() {
    print("· AskState：同一位两请求，只停一条与全部停止")
    let dir = NSTemporaryDirectory() + "aipethub-ask-parallel-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/cli"
    try! installFakeCLI(at: path, behavior: "backend")
    for stopAll in [false, true] {
        for iteration in 0..<3 {
            let d = AppDelegate(), probe = AskStateProbe()
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            d.jsSink = probe.receive; d.hooks.cliExecutable = path
            d.hooks.cliStarted = { key, proc in
                probe.started(key, proc); entered.signal(); _ = release.wait(timeout: .now() + 8)
            }
            let a = askStateRequest("gemini", 6000 + iteration * 2, dir)
            let b = askStateRequest("gemini", 6001 + iteration * 2, dir)
            d.ask(a); d.ask(b)
            let bothStarted = entered.wait(timeout: .now() + 5) == .success && entered.wait(timeout: .now() + 5) == .success
            check(bothStarted, "双请求都已启动，固定在接手前")
            if stopAll { d.cancel(agent: "gemini") } else { d.cancel(agent: "gemini", reqId: a.reqId) }
            check(testAskState(d, a.key)?.cancelled == true, "A 已停止")
            eq(testAskState(d, b.key)?.cancelled, stopAll, "B 的停止状态隔离")
            release.signal(); release.signal()
            assertAskFinished(d, a, probe, cancelled: true, label: "并行 A/\(stopAll)/\(iteration)")
            assertAskFinished(d, b, probe, cancelled: stopAll, label: "并行 B/\(stopAll)/\(iteration)")
            if !stopAll { eq(probe.reply(b.key)?["reply"] as? String, "fixture-ok", "未停止的 B 正常答完") }
            check(testAsksEmpty(d), "两个请求都结束后 asks 为空")
        }
    }
}

func testAskStateFallback() {
    print("· AskState：三家停止后均不启动一问一答回退")
    let dir = NSTemporaryDirectory() + "aipethub-ask-fallback-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/cli"
    try! installFakeCLI(at: path, behavior: "backend")
    for (agent, mode) in [("claude", "claude-unsupported"), ("gpt", "codex-unsupported"), ("gemini", "unsupported")] {
        try! mode.write(toFile: dir + "/mode", atomically: true, encoding: .utf8)
        for stage in ["exited", "unregistered"] {
            let d = AppDelegate(), probe = AskStateProbe()
            d.jsSink = probe.receive; d.hooks.cliExecutable = path; d.partialSupport[path] = true
            d.hooks.cliStarted = { key, proc in probe.started(key, proc) }
            for iteration in 0..<3 {
                let req = askStateRequest(agent, 7000 + iteration, dir)
                d.hooks.cliExited = { _, _ in if stage == "exited" { d.cancel(agent: agent, reqId: req.reqId) } }
                d.hooks.liveUnregistered = { key in
                    if stage == "unregistered" {
                        probe.note(key + "-gap", testAskState(d, key)?.proc == nil && testAskState(d, key)?.live == nil)
                        d.cancel(agent: agent, reqId: req.reqId)
                    }
                }
                d.ask(req)
                assertAskFinished(d, req, probe, cancelled: true, label: "\(agent)/fallback-\(stage)/\(iteration)")
                eq(probe.procs(req.key).count, 1, "\(agent)/\(stage)：只起交互进程，未再起一问一答")
                if stage == "unregistered" { check(probe.fact(req.key + "-gap"), "回退间隙只有 AskState，没有 live/proc") }
            }
            check(testAsksEmpty(d), "\(agent)/\(stage)：连续 20 次失败取消后无残留键")
            d.hooks = TestHooks()
        }
    }
}

func testAskStateWarmRetry() {
    print("· AskState：warmDied 重建期间停止及批量回收")
    let dir = NSTemporaryDirectory() + "aipethub-ask-warm-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/cli"
    try! installFakeCLI(at: path, behavior: "cold-retry")
    for agent in ["claude", "gpt", "gemini"] {
        for stopBeforeRetry in [true, false] {
            let d = AppDelegate(), probe = AskStateProbe()
            d.jsSink = probe.receive; d.hooks.cliExecutable = path; d.partialSupport[path] = true
            d.hooks.cliStarted = { key, proc in probe.started(key, proc) }
            for iteration in 0..<3 {
                let req = askStateRequest(agent, 8000 + iteration, dir)
                let warm = CLIProcess(input: LiveInput())
                warm.warmKey = d.warmKey(req)
                try! warm.start(executable: path, arguments: [], cwd: dir, environment: d.cliEnvironment())
                d.keepWarm(agent, warm)
                d.hooks.liveTurnCreated = { live in
                    let generation = probe.increment(req.key)
                    if generation == 1 {
                        live.warm?.input?.close(); _ = live.warm?.waitForExit()
                        probe.note(req.key + "-warm", live.warm != nil && !warm.proc.isRunning)
                    }
                    if (stopBeforeRetry && generation == 1) || (!stopBeforeRetry && generation == 2) {
                        d.cancel(agent: agent, reqId: req.reqId)
                    }
                    if generation == 2 { probe.note(req.key + "-retry", testAskState(d, req.key)?.cancelled == true) }
                }
                d.ask(req)
                assertAskFinished(d, req, probe, cancelled: true, label: "\(agent)/warm-\(stopBeforeRetry)/\(iteration)")
                eq(probe.count(req.key), 2, "warmDied 确实重建了一轮")
                check(probe.fact(req.key + "-warm") && probe.fact(req.key + "-retry"), "死预热后的新一轮仍看到停止")
                eq(probe.procs(req.key).count, 0, "停止后没有重启冷进程或一问一答")
                check(!warm.proc.isRunning && kill(warm.proc.processIdentifier, 0) != 0, "取走的预热进程也已退出")
            }
            check(testAsksEmpty(d), "\(agent)：20 次 warmDied 后 asks 为空")
            d.hooks = TestHooks()
        }
    }
}

func testAskStateNoProcess() {
    print("· AskState：DeepSeek 无独立进程及 runCLI 自有临时记录")
    let d = AppDelegate(); d.jsSink = { _, _ in }
    for iteration in 0..<5 {
        let req = askStateRequest("deepseek", 9000 + iteration, "")
        withTestAsk(d, req.key) {
            let live = DeepSeekLiveTurn(app: d, req: req)
            d.registerLive(req.key, live)
            d.cancel(agent: req.agent, reqId: req.reqId)
            check(live.stopping && live.replyForTest.cancelled, "无独立进程也返回 cancelled")
            check(testAskState(d, req.key)?.cancelled == true && testAskState(d, req.key)?.proc == nil, "无进程停止标记保持到 owner 收尾")
            d.unregisterLive(req.key); live.input.abandon()
        }
        check(testAsksEmpty(d), "DeepSeek 测试 owner 完整收尾后无陈旧键")
    }
    let dir = NSTemporaryDirectory() + "aipethub-ask-standalone-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/cli"
    try! installFakeCLI(at: path, behavior: "backend")
    for iteration in 0..<3 {
        for key in ["gemini", "fixture#\(iteration)"] {
            let result = d.runCLI(agent: key, executable: path, arguments: ["-p", "fixture"], cwd: dir)
            check(!result.cancelled && result.status == 0 && result.out.contains("fixture-ok"), "独立 runCLI 正常完成")
            check(testAsksEmpty(d), "runCLI 自己的临时记录由自己删除")
            let failed = d.runCLI(agent: key, executable: dir + "/missing", arguments: [], cwd: dir)
            check(failed.launchError != nil && !failed.cancelled && testAsksEmpty(d), "独立 runCLI 启动失败也删除临时记录")
            var stoppedProcess: Process?
            d.hooks.cliRegistered = { key, _ in d.cancel(agent: key) }
            d.hooks.cliStarted = { _, proc in stoppedProcess = proc }
            let stopped = d.runCLI(agent: key, executable: path, arguments: ["-p", "fixture"], cwd: dir)
            d.hooks = TestHooks()
            check(stopped.cancelled && testAsksEmpty(d), "独立 runCLI 停止后删除自己的临时记录")
            check(stoppedProcess.map { !$0.isRunning && kill($0.processIdentifier, 0) != 0 } == true, "独立 runCLI 停止后进程已退出")
        }
    }
}

func testAskStateLifecycle() {
    testAskStateStages()
    testAskStateParallel()
    testAskStateFallback()
    testAskStateWarmRetry()
    testAskStateNoProcess()
}

func runAskStateTests() -> Never {
    testAskStateLifecycle()
    print(failures == 0 ? "AskState 全部通过（\(checks) 项）" : "AskState：\(failures) / \(checks) 项没通过")
    exit(failures == 0 ? 0 : 1)
}
