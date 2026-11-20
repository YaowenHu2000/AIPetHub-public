// 交互式回答的真实测试（要用真的 CLI，会花一点额度）：build/selftest live <agent> <空目录> [模型]
//   ① 每次询问：跑命令前来问，允许后命令执行  ② 拒绝：命令没执行  ③ 中途补充一句：这一轮里就看到了
//   ④ 停止：请它自己停下来，几秒内结束  ⑦ 提问卡：作答后它拿到答案
import Cocoa

private struct LiveRun {
    var requests: [[String: Any]] = []
    var steers: [String] = []
    var steps: [String] = []
    var final: [String: Any] = [:]
    var seconds = 0.0
}

/// 发一句，回答进行中按 onEvent 的安排答复请求 / 补充 / 停止，等回答结束。
private func liveAsk(_ d: AppDelegate, _ req: AskRequest, timeout: TimeInterval = 240,
                     onEvent: @escaping (_ name: String, _ payload: [String: Any]) -> Void = { _, _ in }) -> LiveRun {
    var run = LiveRun()
    let sem = DispatchSemaphore(value: 0)
    let lock = NSLock()
    d.hooks.jsSink = { name, payload in
        lock.lock()
        switch name {
        case "onAgentRequest": run.requests.append(payload)
        case "onAgentSteer": run.steers.append("\(payload["state"] ?? "")")
        case "onAgentStep":
            if let st = payload["step"] as? [String: Any] { run.steps.append("[\(st["kind"] ?? "")] \(st["title"] ?? "")") }
        case "onAgentResponse": run.final = payload
        default: break
        }
        lock.unlock()
        onEvent(name, payload)
        if name == "onAgentResponse" { sem.signal() }
    }
    let t0 = Date()
    d.ask(req)
    if sem.wait(timeout: .now() + timeout) == .timedOut { print("   ✗ 超时"); d.cancel(agent: req.agent, reqId: req.reqId) }
    d.hooks.jsSink = nil
    run.seconds = Date().timeIntervalSince(t0)
    return run
}

private func report(_ ok: Bool, _ what: String) { print(ok ? "   ✓ \(what)" : "   ✗ \(what)") }

func runLiveTests(_ args: [String]) {
    guard args.count >= 3 else { print("用法：live <agent> <空目录> [模型] [只跑第几项，如 5]"); return }
    let agent = args[1], dir = args[2], model = args.count >= 4 ? args[3] : ""
    let only = args.count >= 5 ? args[4] : ""
    let want = { (n: String) in only.isEmpty || only.contains(n) }
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let d = AppDelegate()
    let askPerm = ["claude": "manual", "gpt": "ask", "gemini": "default"][agent] ?? "manual"
    let fullPerm = ["claude": "bypassPermissions", "gpt": "danger-full-access", "gemini": "bypassPermissions"][agent] ?? ""
    var reqId = 100
    func req(_ prompt: String, _ perm: String) -> AskRequest {
        reqId += 1
        return AskRequest(agent: agent, reqId: reqId, prompt: prompt, model: model, effort: "low", permissionMode: perm,
                          workspace: dir, conversationId: "")
    }
    func answer(_ decision: String) -> (String, [String: Any]) -> Void {
        return { name, p in
            guard name == "onAgentRequest", let rid = p["requestId"] as? String, let r = (p["reqId"] as? NSNumber)?.intValue else { return }
            print("   · 请求：\(p["kind"] ?? "") \(p["title"] ?? "") \(String(describing: p["detail"] ?? "").prefix(60))")
            d.answerRequest(agent: agent, reqId: r, requestId: rid, body: ["decision": decision])
        }
    }

    var r = LiveRun()
    if want("1") {
    print("① 每次询问 → 允许")
    let f1 = "\(dir)/allowed.txt"
    try? fm.removeItem(atPath: f1)
    r = liveAsk(d, req("用终端命令运行：echo yes > allowed.txt 。运行完只回答「好了」。", askPerm), onEvent: answer("allow"))
    report(!r.requests.isEmpty, "来问过（\(r.requests.count) 次）")
    report(fm.fileExists(atPath: f1), "允许后命令执行了")
    print("   回答：\(String(describing: r.final["reply"] ?? "").prefix(80))  用时 \(String(format: "%.1f", r.seconds))s")

    }
    if want("2") {
    print("② 每次询问 → 拒绝")
    let f2 = "\(dir)/denied.txt"
    try? fm.removeItem(atPath: f2)
    r = liveAsk(d, req("用终端命令运行：echo no > denied.txt 。如果被拒绝就不要再试，只回答「被拒绝了」。", askPerm), onEvent: answer("deny"))
    report(!r.requests.isEmpty, "来问过（\(r.requests.count) 次）")
    report(!fm.fileExists(atPath: f2), "拒绝后命令没有执行")
    print("   回答：\(String(describing: r.final["reply"] ?? "").prefix(80))  用时 \(String(format: "%.1f", r.seconds))s")

    }
    if want("3") {
    print("③ 中途补充一句")
    var steered = false
    r = liveAsk(d, req("用终端命令依次运行这三条，每条单独运行：sleep 4; echo one  然后 sleep 4; echo two  然后 sleep 4; echo three 。最后告诉我三个输出。", fullPerm)) { name, p in
        guard name == "onAgentStep", !steered, let rq = (p["reqId"] as? NSNumber)?.intValue else { return }
        steered = true
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { d.steer(agent: agent, reqId: rq, text: "补充：回答的最后请加上「收到补充」这四个字。", images: [], steerId: "s1") }
    }
    report(r.steers.contains("sent") || r.steers.contains("consumed"), "补充的话送进去了（\(r.steers.joined(separator: " → "))）")
    report(String(describing: r.final["reply"] ?? "").contains("收到补充"), "这一轮的回答里照做了")
    print("   回答：\(String(describing: r.final["reply"] ?? "").prefix(120).replacingOccurrences(of: "\n", with: " "))  用时 \(String(format: "%.1f", r.seconds))s")

    }
    if want("4") {
    print("④ 停止")
    var stopAt: Date?
    r = liveAsk(d, req("用终端命令运行：sleep 60; echo done 。然后告诉我输出。", fullPerm)) { name, p in
        guard name == "onAgentStep", stopAt == nil, let st = p["step"] as? [String: Any], st["kind"] as? String == "command",
              let rq = (p["reqId"] as? NSNumber)?.intValue else { return }
        stopAt = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { stopAt = Date(); d.cancel(agent: agent, reqId: rq) }
    }
    report(r.final["cancelled"] as? Bool == true, "记为已停止")
    let lag = stopAt.map { Date().timeIntervalSince($0) } ?? -1
    report(lag >= 0 && lag < 8, "点停止后 \(String(format: "%.1f", lag)) 秒结束")
    sleep(5)
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", "sleep 60"]
    let out = Pipe(); p.standardOutput = out; try? p.run(); p.waitUntilExit()
    report(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "它启动的命令也结束了")
    }
    if want("5") {
    print("⑤ 接着同一个会话问")
    r = liveAsk(d, req("我最喜欢的数字是 7391，先记一下。只回答「记住了」。", fullPerm))
    let cid = r.final["conversationId"] as? String ?? ""
    report(!cid.isEmpty, "拿到会话 ID \(cid.prefix(12))…")
    reqId += 1
    r = liveAsk(d, AskRequest(agent: agent, reqId: reqId, prompt: "我刚才说我最喜欢的数字是多少？只回答数字。", model: model, effort: "low",
                              permissionMode: fullPerm, workspace: dir, conversationId: cid))
    report(String(describing: r.final["reply"] ?? "").contains("7391"), "接着问时还记得（回答：\(String(describing: r.final["reply"] ?? "").prefix(40))）")
    report(r.final["conversationId"] as? String == cid, "还是同一个会话")
    }
    if want("6") {
    print("⑥ 预热：先把进程起好，发话时接手它")
    d.hooks.prewarmWithoutBundle = true
    func timed(_ rq: AskRequest) -> (LiveRun, Double) {
        var first = 0.0
        let t0 = Date()
        let run = liveAsk(d, rq) { name, _ in if name == "onAgentStep", first == 0 { first = Date().timeIntervalSince(t0) } }
        return (run, first)
    }
    // 新会话：不预热 vs 预热
    var (cold, coldFirst) = timed(req("我最喜欢的数字是 4826，先记一下。只回答「记住了」。", fullPerm))
    let cid = cold.final["conversationId"] as? String ?? ""
    print("   不预热：第一步出现用了 \(String(format: "%.1f", coldFirst))s，整轮 \(String(format: "%.1f", cold.seconds))s")
    // 接着这个会话：先预热，等它准备好，再问
    reqId += 1
    let follow = AskRequest(agent: agent, reqId: reqId, prompt: "我刚才说我最喜欢的数字是多少？只回答数字。", model: model, effort: "low",
                            permissionMode: fullPerm, workspace: dir, conversationId: cid)
    d.prewarm(follow)
    sleep(6)
    let before = d.warmAdopted
    var (warm, warmFirst) = timed(follow)
    report(d.warmAdopted == before + 1, "接手了预热的进程")
    report(String(describing: warm.final["reply"] ?? "").contains("4826"), "接着问答对了（\(String(describing: warm.final["reply"] ?? "").prefix(30))）")
    print("   预热后：第一步出现用了 \(String(format: "%.1f", warmFirst))s，整轮 \(String(format: "%.1f", warm.seconds))s")
    // 新会话的预热
    let fresh = req("只回答：好", fullPerm)
    d.prewarm(fresh)
    sleep(5)
    let before2 = d.warmAdopted
    (warm, warmFirst) = timed(fresh)
    report(d.warmAdopted == before2 + 1, "新会话也接手了预热的进程")
    report(!String(describing: warm.final["reply"] ?? "").isEmpty && !(String(describing: warm.final["reply"] ?? "").hasPrefix("⚠️")), "新会话答了（\(String(describing: warm.final["reply"] ?? "").prefix(20))）")
    print("   新会话预热后：第一步出现用了 \(String(format: "%.1f", warmFirst))s，整轮 \(String(format: "%.1f", warm.seconds))s")
    // 设置对不上的不接手
    reqId += 1
    d.prewarm(AskRequest(agent: agent, reqId: reqId, prompt: "", model: model, effort: "low", permissionMode: fullPerm, workspace: dir, conversationId: cid))
    sleep(3)
    let before3 = d.warmAdopted
    (cold, coldFirst) = timed(req("只回答：好", fullPerm))   // 新会话，而预热的是接着旧会话的
    report(d.warmAdopted == before3, "设置对不上时不接手，照常新起")
    report(!String(describing: cold.final["reply"] ?? "").isEmpty, "照常答了")
    // 模拟别处更新。Claude 丢弃旧快照，Codex / Gemini 接手后才读取会话。
    reqId += 1
    let again = AskRequest(agent: agent, reqId: reqId, prompt: "只回答：好", model: model, effort: "low",
                           permissionMode: fullPerm, workspace: dir, conversationId: cid)
    d.prewarm(again)
    sleep(10)
    if let f = d.conversationFile(agent: agent, cid: cid) { try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: f) }
    let before4 = d.warmAdopted
    (warm, warmFirst) = timed(again)
    report(d.warmAdopted == before4 + (agent == "claude" ? 0 : 1), "会话在别处被改过：按预热是否持有旧快照决定接手")
    report(!String(describing: warm.final["reply"] ?? "").isEmpty, "照常答了")
    d.dropWarm()
    }
    if want("7") {
    // Codex 默认协作模式下没有 request_user_input 工具（要在 config.toml 开 features.default_mode_request_user_input），这时只会用文字问
    print("⑦ 提问卡：让它用提问工具问一题，选第二个选项")
    let tool = ["claude": "AskUserQuestion", "gpt": "request_user_input", "gemini": "ask_question"][agent] ?? ""
    for perm in [fullPerm, askPerm] {
        r = liveAsk(d, req("请调用 \(tool) 工具问我一个问题：我最喜欢的颜色是什么，给两个选项「红色」和「蓝色」。拿到回答后用一句话复述我的选择然后结束；没有这个工具就直接回答「没有这个工具」。不要做其他事。", perm)) { name, p in
            guard name == "onAgentRequest", p["kind"] as? String == "question", let rid = p["requestId"] as? String,
                  let rq = (p["reqId"] as? NSNumber)?.intValue, let q = (p["questions"] as? [[String: Any]])?.first,
                  let label = (q["options"] as? [[String: Any]])?.last?["label"] as? String else { return }
            d.answerRequest(agent: agent, reqId: rq, requestId: rid, body: ["decision": "allow", "answers": [(q["id"] ?? q["question"]) as? String ?? "": label]])
        }
        let reply = String(describing: r.final["reply"] ?? "")
        report(r.requests.contains { $0["kind"] as? String == "question" }, "\(perm)：出现提问卡（\(r.requests.count) 张）")
        report(reply.contains("蓝"), "\(perm)：作答后它拿到了答案（回答：\(reply.prefix(40))）")
    }
    }
}
