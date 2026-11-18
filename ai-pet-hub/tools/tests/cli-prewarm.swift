// ACP 握手、预热接手与 CLI 兼容回退；build/selftest offline。
import Foundation
import Cocoa
import SQLite3

func testAcpResponses() {
    print("· ACP 重复和无关答复")
    let d = AppDelegate()
    d.jsSink = { _, _ in }
    var req = AskRequest(agent: "gemini", reqId: 72, prompt: "test", model: "model", effort: "",
                         permissionMode: "default", workspace: "", conversationId: "")
    req.browserTools = false
    let live = GeminiLiveTurn(app: d, req: req, agy: "/unused", fullModel: "model")
    for line in [
        #"{"id":1,"result":{}}"#, #"{"id":1,"result":{}}"#,
        #"{"id":2,"result":{"sessionId":"s"}}"#, #"{"id":2,"result":{"sessionId":"s"}}"#,
        #"{"id":999,"result":{}}"#, #"{"id":3,"result":{}}"#, #"{"id":3,"result":{}}"#,
        #"{"id":4,"result":{}}"#, #"{"id":5,"result":{"stopReason":"end_turn"}}"#
    ] { live.locked { live.handle(line: line) } }
    live.input.close()
    let data = live.input.pipe.fileHandleForReading.readDataToEndOfFile()
    let sent = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { d.jsonObject($0) }
    eq(sent.compactMap { $0["method"] as? String },
       ["session/new", "session/set_model", "session/set_mode", "session/prompt"],
       "仅当前请求的答复推进队列，每个动作只发送一次")
}

func testAcpModelSelection() {
    let d = AppDelegate()
    d.jsSink = { _, _ in }
    func rpcMethods(_ model: String, _ full: String, _ available: [String], reject: Bool = false, current: String = "previous", mode: String = "") -> [[String: Any]] {
        var req = AskRequest(agent: "gemini", reqId: 62, prompt: "test", model: model, effort: "high",
                             permissionMode: "default", workspace: "", conversationId: "")
        req.browserTools = false
        let live = GeminiLiveTurn(app: d, req: req, agy: "/unused", fullModel: full)
        let result: [String: Any] = ["sessionId":"s", "models":["currentModelId":current, "availableModels":available.map { ["modelId":$0] }], "modes":["currentModeId":mode]]
        for row: [String: Any] in [["id":1,"result":[:]], ["id":2,"result":result],
                                   reject ? ["id":3,"error":["message":"refused"]] : ["id":3,"result":[:]], ["id":4,"result":[:]]] {
            let line = String(decoding: try! JSONSerialization.data(withJSONObject: row), as: UTF8.self)
            live.locked { live.handle(line: line) }
        }
        live.input.close()
        return String(decoding: live.input.pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator:"\n").compactMap { d.jsonObject($0) }
    }
    let standalone = "gemini-pro-orchestrator-argon"
    var menu: [[String: Any]] = []
    d.jsSink = { fn, p in if fn == "onAgentModels" { menu = p["models"] as? [[String: Any]] ?? [] } }
    d.noteGeminiModels(["models": ["availableModels": [
        ["modelId":"gemini-4-hydrogen-xhigh", "name":"Hydrogen (Extra High)"],
        ["modelId":standalone, "name":"Orchestrator (Argon)"]]]])
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    eq(menu.first?["efforts"] as? [String], ["xhigh"], "会话模型列表也保留 xhigh 变体")
    eq(menu.last?["v"] as? String, standalone, "独立模型不剥掉型号后缀")
    let alreadySet = rpcMethods(standalone, standalone, [standalone], current: standalone, mode: "default")
    eq(alreadySet.compactMap { $0["method"] as? String }, ["session/new", "session/prompt"], "agy 已确认当前模型和权限时直接发送")
    let calls = rpcMethods(standalone, standalone + "-high", [standalone, "previous"])
    eq((calls.first { $0["method"] as? String == "session/set_model" }?["params"] as? [String: Any])?["modelId"] as? String,
       standalone, "原样使用 CLI 公布的独立模型 ID")
    for rows in [rpcMethods("missing", "missing-high", ["previous"]), rpcMethods("base", "base-high", ["base-high"], reject: true)] {
        check(!rows.contains { $0["method"] as? String == "session/prompt" }, "模型不存在或设置失败均不得用旧模型发送")
    }
    let req = AskRequest(agent: "gemini", reqId: 0, prompt: "", model: "gemini-4-hydrogen-xhigh", effort: "low", permissionMode: "", workspace: "", conversationId: "")
    d.hooks.cliExecutable = "/unused"
    eq(d.geminiSetup(req)?.fullModel, "gemini-4-hydrogen-xhigh", "旧设置中的完整 xhigh 型号不再拼接强度")

    let root = NSTemporaryDirectory() + "aipethub-agy-model-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let cli = root + "/agy"; try! installFakeCLI(at: cli, behavior: "backend")
    try! "standalone-print".write(toFile: root + "/mode", atomically: true, encoding: .utf8)
    d.hooks.cliExecutable = cli
    for model in [standalone, "gemini-4-hydrogen-xhigh"] {
        let ask = AskRequest(agent: "gemini", reqId: 63, prompt: "test", model: model, effort: "low",
                             permissionMode: "default", workspace: root, conversationId: "", browserTools: false)
        let reply = withTestAsk(d, ask.key) { d.runGemini(ask) }
        eq(reply.reply, model, "agy -p 同样收到目录中的完整模型 ID")
    }
}

func testAcpWarmResponses() {
    print("· 假 ACP CLI：冷启动和预热接手")
    let path = NSTemporaryDirectory() + "aipethub-acp-" + UUID().uuidString
    try! installFakeCLI(at: path, behavior: "acp-warm")
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    defer { try? FileManager.default.removeItem(atPath: path) }
    for stage in 0...2 {
        let d = AppDelegate()
        d.jsSink = { _, _ in }
        var req = AskRequest(agent: "gemini", reqId: 80 + stage, prompt: "test", model: "model", effort: "",
                             permissionMode: "default", workspace: NSTemporaryDirectory(), conversationId: stage == 2 ? "fake-session" : "")
        req.browserTools = false
        if stage > 0 {
            let warm = CLIProcess(input: LiveInput()), ready = DispatchSemaphore(value: 0)
            warm.warmKey = d.warmKey(req)
            warm.warmFilter = { [weak warm] line in
                guard let warm = warm, let obj = d.jsonObject(line), obj["id"] as? Int == 1 else { return false }
                warm.stage = 1
                ready.signal()
                return true
            }
            do { try warm.start(executable: path, arguments: [], cwd: NSTemporaryDirectory(), environment: ProcessInfo.processInfo.environment) }
            catch { check(false, "启动假预热 CLI：\(error)"); continue }
            warm.input?.send(d.acpInitialize())
            check(ready.wait(timeout: .now() + 30) == .success, "预热 stage \(stage) 完成初始化")
            d.keepWarm("gemini", warm)
        }
        // 期限只防卡死：往返做完 run() 就返回，不等满。假 CLI 每行都要起一次 sed，
        // 机器满载时冷启动一轮能超过 4 秒，旧期限会把正常往返取消掉，误报成没走完。
        let timeout = DispatchWorkItem { d.cancel(agent: req.agent, reqId: req.reqId) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        let result = withTestAsk(d, req.key) { GeminiLiveTurn(app: d, req: req, agy: path, fullModel: "model").run() }
        timeout.cancel()
        eq(result?.reply, "假 CLI 回答", "stage \(stage) 握手、配置、提问及 EOF 完整往返")
        check(result?.cancelled == false, "stage \(stage) 正常结束")
        d.procLock.lock(); let adopted = d.warmAdopted; d.procLock.unlock()
        eq(adopted, stage == 0 ? 0 : 1, "stage \(stage) 预热接手次数")
    }
}

// 由 /tmp/aipethub-warm-probe.swift 固化：死掉的预热进程不能复用已关闭的输入管道。
func testDeadWarmRetry() {
    print("· 死亡预热回退：三个真实入口、完整冷启动、停止与重试上限")
    let dir = NSTemporaryDirectory() + "aipethub-dead-warm-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/cli", log = path + ".log"
    try! installFakeCLI(at: path, behavior: "cold-retry")
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)

    for agent in ["claude", "gpt", "gemini"] {
        for mode in ["retry", "stop-before", "stop-between", "die-twice"] {
            try? FileManager.default.removeItem(atPath: log)
            let d = AppDelegate()
            d.jsSink = { _, _ in }
            d.hooks.cliExecutable = path
            if let key = d.claudePartialCacheKey(path) { d.partialSupport[key] = true }   // 假 CLI 不需要探测 --help
            var req = AskRequest(agent: agent, reqId: 91, prompt: "once-only", model: "model", effort: "low",
                                 permissionMode: "default", workspace: dir, conversationId: "")
            req.browserTools = false
            d.procLock.lock(); d.asks[req.key] = AskState(); d.procLock.unlock()
            var turns: [LiveTurn] = []
            var pushed = 0
            func makeWarm() -> CLIProcess {
                let warm = CLIProcess(input: LiveInput())
                warm.warmKey = d.warmKey(req)
                // 等待输入 EOF；由测试在 takeWarm 后确定地让它退出。
                try! warm.start(executable: "/bin/cat", arguments: [], cwd: dir,
                                environment: ProcessInfo.processInfo.environment)
                return warm
            }
            d.keepWarm(agent, makeWarm())
            d.hooks.liveTurnCreated = { live in
                check(testAskState(d, req.key)?.live == nil, "\(agent)/\(mode)：新一轮建立前旧登记已撤销")
                check(testAskState(d, req.key)?.proc == nil, "\(agent)/\(mode)：没有残留进程登记")
                if let previous = turns.last {
                    check(previous.warmDied, "第一轮记录 warmDied")
                    check(previous.builder.steps.isEmpty && previous.pending.takeAll().isEmpty, "第一轮没有步骤和 pending")
                    eq(pushed, 0, "第一轮没推送步骤")
                    check(previous.input !== live.input, "重试创建全新输入管道")
                    check(previous.input.send(["late": true]) == false, "旧输入已作废")
                }
                turns.append(live)
                live.builder.onChange = { _, _ in pushed += 1 }
                if let warm = live.warm {
                    warm.input?.close()
                    _ = warm.waitForExit()
                    check(!warm.proc.isRunning, "takeWarm 取走后、runCLI 接手前已退出")
                }
                if mode == "die-twice", turns.count == 1 { d.keepWarm(agent, makeWarm()) }
                if (mode == "stop-before" && turns.count == 1) || (mode == "stop-between" && turns.count == 2) {
                    d.cancel(agent: agent, reqId: req.reqId)
                }
                if mode == "stop-before", turns.count == 2 {
                    check(testAskState(d, req.key)?.cancelled == true, "warmDied 不消费停止标记")
                }
            }
            let timeout = DispatchWorkItem { d.cancel(agent: agent, reqId: req.reqId) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
            let result: AgentReply
            switch agent {
            case "claude": result = d.runClaude(req)
            case "gpt": result = d.runCodex(req)
            default: result = d.runGemini(req)
            }
            timeout.cancel()
            d.hooks.liveTurnCreated = nil
            let rows = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n")
            let sent = rows.compactMap { d.jsonObject($0) }
            let prompts = sent.filter {
                $0["type"] as? String == "user" || ["turn/start", "session/prompt"].contains($0["method"] as? String ?? "")
            }
            eq(turns.count, 2, "\(agent)/\(mode)：只重建一次 LiveTurn")
            eq(rows.filter { $0 == "launch" }.count, mode == "retry" ? 1 : 0, "只在正常重试时冷启动，停止或再次死亡不启动")
            eq(prompts.count, mode == "retry" ? 1 : 0, "\(agent)/\(mode)：提问恰好一次，停止或再次死亡不提问")
            if mode == "retry" {
                eq(result.reply, "cold-ok", "\(agent)：完整冷启动握手成功")
                eq(sent.filter { $0["method"] as? String == "initialize" || ($0["request"] as? [String: Any])?["subtype"] as? String == "initialize" }.count,
                   1, "冷启动重新 initialize 一次")
            } else if mode.hasPrefix("stop-") {
                check(result.cancelled && turns.last?.stopping == true, "\(agent)/\(mode)：重试接手停止请求")
                check(testAskState(d, req.key)?.cancelled == true, "取消标记保留到回答结束")
            } else { check(result.reply.hasPrefix("⚠️"), "第二次 warmDied 按普通失败返回，不触发一问一答") }
            check(testAskState(d, req.key)?.live == nil && testAskState(d, req.key)?.proc == nil, "退出后 live 和进程登记均为空")
            check(turns.allSatisfy { $0.pending.takeAll().isEmpty }, "退出后没有 pending")
            d.procLock.lock(); d.asks[req.key] = nil; d.procLock.unlock()
            check(testAsksEmpty(d), "测试拥有的回答结束后清除记录")
        }
    }
}

func testOfflineCLI() {
    print("· 假 CLI：断网、恢复、慢回答、升级和模型/用量挂死")
    let d = AppDelegate(), fm = FileManager.default
    let dir = NSTemporaryDirectory() + "aipethub-offline-" + UUID().uuidString
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    let cli = dir + "/cli.py"
    try! installFakeCLI(at: cli, behavior: "backend")
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli)
    d.hooks.cliExecutable = cli; d.hooks.toolTimeout = 1
    d.jsSink = { _, _ in }
    var req = AskRequest(agent: "gemini", reqId: 200, prompt: "fixture", model: "fixture", effort: "low", permissionMode: "bypassPermissions", workspace: dir, conversationId: "")
    req.browserTools = false
    func mode(_ value: String) { try! value.write(toFile: dir + "/mode", atomically: true, encoding: .utf8) }
    for m in ["offline", "ok", "drop", "ok", "slow", "unsupported", "missing", "handshake", "ok"] {
        mode(m)
        let watchdog = DispatchWorkItem { d.cancel(agent: req.agent, reqId: req.reqId) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: watchdog)
        let began = Date(), reply = withTestAsk(d, req.key) { d.runGemini(req) }
        watchdog.cancel()
        check(!reply.cancelled && Date().timeIntervalSince(began) < 8, "\(m)：不靠取消才返回")
        if m == "drop" {
            let steps = reply.turn?["steps"] as? [[String: Any]]
            eq(steps?.first { str($0, "kind") == "command" }?["status"] as? String, "error", "ACP 在命令运行时退出，实时步骤结束")
        }
        check(m == "offline" || m == "drop" ? reply.reply.contains("⚠️") : reply.reply == "fixture-ok", "\(m)：正确回答或明确错误（\(reply.reply.prefix(80))）")
    }
    mode("ok")
    let help = AppDelegate()
    check(help.claudeSupportsPartial(cli, prefix: []), "帮助文字改版仍按能力标记识别")
    mode("help-missing")
    let noPartial = AppDelegate()
    check(!noPartial.claudeSupportsPartial(cli, prefix: []), "帮助中缺可选参数时不启用")
    for (agent, m) in [("claude", "claude-unsupported"), ("gpt", "codex-unsupported")] {
        mode(m)
        var compatibility = AskRequest(agent:agent,reqId:201,prompt:"fixture",model:"fixture",effort:"low",permissionMode:"default",workspace:dir,conversationId:"")
        compatibility.browserTools = false
        let watchdog = DispatchWorkItem { d.cancel(agent: agent, reqId: 201) }
        DispatchQueue.global().asyncAfter(deadline:.now()+8,execute:watchdog)
        let reply = withTestAsk(d, compatibility.key) { agent == "claude" ? d.runClaude(compatibility) : d.runCodex(compatibility) }
        watchdog.cancel()
        check(!reply.cancelled && reply.reply == "compat-ok", "\(agent)：交互参数不认识时退回一问一答，忽略未知事件")
    }
    for m in ["hang-models", "hang-usage", "ok"] {
        mode(m)
        d.loadUsage(agent: "gemini", force: true)
        let until = Date().addingTimeInterval(5)
        var idle = false
        while Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            d.procLock.lock(); idle = d.usageLoading.isEmpty; d.procLock.unlock()
            if idle { break }
        }
        check(idle, "\(m)：模型/用量查询有原生期限并释放 usageLoading")
        if !idle {
            // 修前的挂死进程也只按这个实例登记的 PID 清理。
            for key in ["gemini#models", "gemini#usage"] { if let pid = d.runningPid(key) { terminateTree(pid) } }
            mode("offline")
            let cleanup = Date().addingTimeInterval(5)
            while Date() < cleanup {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                d.procLock.lock(); let clear = d.usageLoading.isEmpty; d.procLock.unlock()
                if clear { break }
            }
        }
    }
    d.procLock.lock(); let left = d.usageCache["gemini"]?.items.first?["left"] as? Int; d.procLock.unlock()
    check(left == 80, "恢复连接后重新拿到用量")
    // 固定先生成的持久化快照晚写回；只写测试内存，不碰 UserDefaults。
    let other = AppDelegate(); other.hooks.cliExecutable = cli; other.jsSink = { _,_ in }
    let first = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0), stored = DispatchSemaphore(value:0), storeLock = NSLock()
    var saved: [String:Any] = [:]
    other.hooks.usageStore = { snapshot in
        if snapshot.count == 1 { first.signal(); _ = release.wait(timeout:.now()+4) }
        storeLock.lock(); saved = snapshot; storeLock.unlock(); stored.signal()
    }
    other.loadUsage(agent:"gemini",force:true)
    check(first.wait(timeout:.now()+3) == .success,"首份用量快照已生成")
    DispatchQueue.global().async { other.loadUsage(agent:"gpt",force:true) }
    Thread.sleep(forTimeInterval:0.6)
    release.signal()
    check(stored.wait(timeout:.now()+5) == .success && stored.wait(timeout:.now()+5) == .success,"两位用量完成写回")
    storeLock.lock(); let savedCount = saved.count; storeLock.unlock()
    check(savedCount == 2,"较早生成的快照不能覆盖新用量")
    let env = d.cliEnvironment(["HTTPS_PROXY": "http://127.0.0.1:1"])
    check(env["HTTPS_PROXY"] == "http://127.0.0.1:1", "显式测试代理传递到 CLI，不改系统设置")
}

func runCLICompatibilityTests() -> Never { testOfflineCLI(); print("Offline failures=\(failures) checks=\(checks)"); exit(failures == 0 ? 0 : 1) }

