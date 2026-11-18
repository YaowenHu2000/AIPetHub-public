// 初始化握手卡住时只允许在提问排队前回退；期限由 TestHooks 确定触发。
// 直接调用生产期限的闭包，模拟它已开始执行：取消 DispatchWorkItem 不能替状态检查挡住旧期限。
import Cocoa

func testLiveInitialization() {
    let root = NSTemporaryDirectory() + "aipethub-initialization-" + UUID().uuidString
    let fm = FileManager.default
    try! fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }
    // 等的都是假 CLI（Python）真的起来、握手、退出这类会发生的事，条件一成立就往下走，期限只防卡死。
    // 机器很忙时光是起一个 Python 就可能要好几秒，所以期限给足；正常情况下用时不变。
    func wait(_ condition: () -> Bool, timeout: Double = 30) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        return condition()
    }
    func scenario(_ agent: String, _ mode: String, prompt: String = "once-only", warm: Bool = false, expireStage: Int? = nil,
                  _ inspect: (AppDelegate, AskRequest, () -> [() -> Void], () -> [String], () -> LiveTurn?, () -> Bool) -> Void) {
        let path = root + "/" + agent + "-" + mode + (prompt == "/compact" ? "-compact" : "") + (warm ? "-warm" : "")
        try! installFakeCLI(at: path, behavior: "initialization")
        try! mode.write(toFile: path + ".mode", atomically: true, encoding: .utf8)
        let app = AppDelegate(), state = NSLock(), done = DispatchSemaphore(value: 0)
        var timers: [() -> Void] = [], live: LiveTurn?, result: AgentReply?, finished = false
        app.jsSink = { _, _ in }
        app.hooks.cliExecutable = path
        app.hooks.liveInitializationScheduled = { timer in
            state.lock(); timers.append(timer); let stage = timers.count; state.unlock()
            if stage == expireStage { timer() }   // 锁仍在最后一个握手答复中，下一步尚未排队发送。
        }
        app.hooks.liveTurnCreated = { turn in state.lock(); live = turn; state.unlock() }
        var req = AskRequest(agent: agent, reqId: 171, prompt: prompt, model: "model", effort: "low",
                             permissionMode: "danger-full-access", workspace: root, conversationId: "")
        req.browserTools = false
        if warm {
            let process = agent == "gpt" ? app.warmCodex(req) : app.warmGemini(req)
            check(process != nil && wait { (process?.stage ?? 0) >= 1 }, "\(agent) 预热先完成 initialize")
            if let process = process { app.keepWarm(agent, process) }
        }
        DispatchQueue.global().async {
            let answer = withTestAsk(app, req.key) { agent == "gpt" ? app.runCodex(req) : app.runGemini(req) }
            state.lock(); result = answer; finished = true; state.unlock()
            done.signal()
        }
        func snapshot() -> [() -> Void] { state.lock(); defer { state.unlock() }; return timers }
        func current() -> LiveTurn? { state.lock(); defer { state.unlock() }; return live }
        func ended() -> Bool { state.lock(); defer { state.unlock() }; return finished }
        func methods() -> [String] {
            ((try? String(contentsOfFile: path + ".log", encoding: .utf8)) ?? "").split(separator: "\n").compactMap { app.jsonObject(String($0))?["method"] as? String }
        }
        inspect(app, req, snapshot, methods, current, ended)
        if !ended() { app.cancel(agent: agent, reqId: req.reqId) }
        // 前面的检查失败时才会走到上面的停止：交互式进程先请它自己停，4 秒后才强制结束，期限要比这段长出余量。
        check(done.wait(timeout: .now() + 30) == .success, "\(agent)/\(mode) 本次进程完整收尾")
        let records = ((try? String(contentsOfFile: path + ".log", encoding: .utf8)) ?? "").split(separator: "\n").compactMap { app.jsonObject(String($0)) }
        let pids = Set(records.compactMap { ($0["pid"] as? NSNumber)?.int32Value })
        check(wait { pids.allSatisfy { kill($0, 0) != 0 } }, "\(agent)/\(mode) 没有遗留本次假 CLI")
        check(testAsksEmpty(app), "\(agent)/\(mode) 回答登记已清理")
        if mode == "stall-initialize" {
            eq(result?.reply, "fallback-answer", "\(agent) 未发提问的未知握手超时退回一问一答")
        }
    }
    for agent in ["gpt", "gemini"] {
        scenario(agent, "stall-initialize") { _, _, timers, methods, _, ended in
            check(wait { methods().contains("reply:700") }, "\(agent) 确认未来握手已到达且进程继续等待")
            check(!ended() && !methods().contains("oneshot"), "\(agent) 原握手卡点未自行退出或回退")
            let armed = timers()
            check(armed.count == 1, "\(agent) 已启动进程的初始化有一个期限")
            armed.last?()
            check(wait(ended), "\(agent) 到期限后结束初始化并完成回退")
            check(!methods().contains("turn/start") && !methods().contains("session/prompt"), "\(agent) 回退前未发送原提问")
            eq(methods().filter { $0 == "oneshot" }.count, 1, "\(agent) 一问一答只调用一次")
        }
        scenario(agent, "stall-session") { app, req, timers, methods, live, ended in
            check(wait { methods().contains("reply:700") }, "\(agent) initialize 已成功，停在会话握手")
            let before = timers()
            check(before.count == 2, "\(agent) 有效 initialize 推进后期限重置")
            before.first?()
            check(!ended() && app.runningPid(req.key) != nil, "\(agent) 过期初始化期限不能结束新的阶段")
            live()?.input.send(["method": "fixture/duplicates"])
            check(wait { methods().contains("reply:701") }, "\(agent) 重复 ACK 和未知握手已全部处理")
            eq(timers().count, before.count, "\(agent) 重复 ACK 和未知消息不能续期")
            timers().last?()
            check(wait(ended), "\(agent) 已有 initialize 答复仍可在提交前超时回退")
            eq(methods().filter { $0 == "oneshot" }.count, 1, "\(agent) 初始化中段也只回退一次")
        }
        scenario(agent, "submitted-race", expireStage: agent == "gpt" ? 3 : 4) { _, _, _, methods, _, ended in
            check(wait(ended), "\(agent) 最后握手答复和提交之间的期限能确定胜出")
            check(!methods().contains("turn/start") && !methods().contains("session/prompt"), "\(agent) 超时胜出后迟到的握手处理不能继续提交")
            eq(methods().filter { $0 == "oneshot" }.count, 1, "\(agent) 超时与发送互斥，只有回退收到提问")
        }
        scenario(agent, "stall-initialize-hold") { app, req, timers, methods, _, ended in
            check(wait { methods().contains("reply:700") }, "\(agent) 旧进程停在初始化")
            timers().last?()
            check(wait { methods().contains("oneshot") }, "\(agent) 已切换到本次回退进程")
            timers().forEach { $0() }
            check(!ended() && app.runningPid(req.key) != nil, "\(agent) 旧期限不能误杀同一reqId下的回退进程")
            try! "release".write(toFile: (app.hooks.cliExecutable ?? "") + ".release", atomically: true, encoding: .utf8)
            check(wait(ended), "\(agent) 回退进程仍可正常完成")
        }
        scenario(agent, "submitted") { app, req, timers, methods, live, ended in
            let prompt = agent == "gpt" ? "turn/start" : "session/prompt"
            check(wait { methods().contains(prompt) }, "\(agent) 已排队发送提问，尚无回答")
            timers().forEach { $0() }
            check(!ended() && app.runningPid(req.key) != nil && !methods().contains("oneshot"), "\(agent) 已提交的慢回答不受初始化期限影响")
            live()?.input.send(["method": "fixture/finish"])
            check(wait(ended), "\(agent) 慢回答照常结束")
            timers().forEach { $0() }
            eq(methods().filter { $0 == prompt }.count, 1, "\(agent) 原提问只提交一次")
            eq(methods().filter { $0 == "oneshot" }.count, 0, "\(agent) 完成后的旧期限不能触发回退")
        }
        scenario(agent, "stall-initialize-stop") { app, req, timers, methods, _, ended in
            check(wait { methods().contains("reply:700") }, "\(agent) 停止测试处于初始化卡点")
            app.cancel(agent: agent, reqId: req.reqId)
            timers().forEach { $0() }
            check(wait(ended), "\(agent) 用户停止后完成收尾")
            eq(methods().filter { $0 == "oneshot" }.count, 0, "\(agent) 用户停止不能触发一问一答")
        }
        scenario(agent, "stall-session", warm: true) { _, _, timers, methods, _, ended in
            check(wait { methods().contains("reply:700") }, "\(agent) 接手预热后停在会话阶段")
            check(!timers().isEmpty, "\(agent) 预热接手同样有初始化期限")
            timers().last?()
            check(wait(ended), "\(agent) 预热接手的未提交提问也能回退")
            eq(methods().filter { $0 == "oneshot" }.count, 1, "\(agent) 预热初始化只回退一次")
        }
    }
    scenario("gpt", "submitted", prompt: "/compact") { app, req, timers, methods, live, ended in
        check(wait { methods().contains("thread/compact/start") }, "Codex 压缩命令已经提交")
        timers().forEach { $0() }
        check(!ended() && app.runningPid(req.key) != nil, "已提交的压缩命令不受初始化期限影响")
        live()?.input.send(["method": "fixture/finish"])
        check(wait(ended), "压缩命令仍可正常结束")
        check(!methods().contains("oneshot"), "压缩命令不会被一问一答重复执行")
    }
    print("初始化期限回归：累计 \(failures) / \(checks) 项未通过")
}
