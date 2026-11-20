// ACP 握手、预热接手与 CLI 兼容回退；build/selftest offline。
import Foundation
import Cocoa
import SQLite3

func testAcpResponses() {
    print("· ACP 重复和无关答复")
    let d = AppDelegate()
    d.hooks.jsSink = { _, _ in }
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
    d.hooks.jsSink = { _, _ in }
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
    d.hooks.jsSink = { fn, p in if fn == "onAgentModels" { menu = p["models"] as? [[String: Any]] ?? [] } }
    d.noteGeminiModels(["models": ["availableModels": [
        ["modelId":"gemini-4-hydrogen-xhigh", "name":"Hydrogen (Extra High)"],
        ["modelId":standalone, "name":"Orchestrator (Argon)"]]]])
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    eq(menu.first?["efforts"] as? [String], ["xhigh"], "会话模型列表也保留 xhigh 变体")
    eq(menu.last?["v"] as? String, standalone, "独立模型不剥掉型号后缀")
    eq(menu.last?["efforts"] as? [String], ["default"], "没有强度变体的型号标成固定档，面板不补出可拖的三档")
    // 面板对固定档发 effort=default；以前存的 High 也照样落回 CLI 公布的原始 ID。
    for effort in ["default", "high"] {
        let ask = AskRequest(agent: "gemini", reqId: 0, prompt: "", model: standalone, effort: effort, permissionMode: "", workspace: "", conversationId: "")
        d.hooks.cliExecutable = "/unused"
        let full = d.geminiSetup(ask)?.fullModel ?? ""
        eq((rpcMethods(standalone, full, [standalone, "previous"]).first { $0["method"] as? String == "session/set_model" }?["params"] as? [String: Any])?["modelId"] as? String,
           standalone, "固定档型号按 \(effort) 发送时仍用原始 ID")
    }
    d.hooks.cliExecutable = nil
    let alreadySet = rpcMethods(standalone, standalone, [standalone], current: standalone, mode: "default")
    eq(alreadySet.compactMap { $0["method"] as? String }, ["session/new", "session/prompt"], "agy 已确认当前模型和权限时直接发送")
    let calls = rpcMethods(standalone, standalone + "-high", [standalone, "previous"])
    eq((calls.first { $0["method"] as? String == "session/set_model" }?["params"] as? [String: Any])?["modelId"] as? String,
       standalone, "原样使用 CLI 公布的独立模型 ID")
    for rows in [rpcMethods("missing", "missing-high", ["previous"]), rpcMethods("base", "base-high", ["base-high"], reject: true)] {
        check(!rows.contains { $0["method"] as? String == "session/prompt" }, "模型不存在或设置失败均不得用旧模型发送")
    }
    let modeCalls = rpcMethods("model", "model", ["model"], reject: true, current: "model")
    eq(modeCalls.compactMap { $0["method"] as? String }, ["session/new", "session/set_mode"], "B3-10 拒绝切换权限模式后不再发送提问")
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
        d.hooks.jsSink = { _, _ in }
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
            check(waitSignal(ready), "预热 stage \(stage) 完成初始化")
            d.keepWarm("gemini", warm)
        }
        // 期限只防卡死：往返做完 run() 就返回，不等满。假 CLI 每行都要起一次 sed，
        // 机器满载时冷启动一轮能超过 4 秒，旧期限会把正常往返取消掉，误报成没走完。
        let timeout = DispatchWorkItem { d.cancel(agent: req.agent, reqId: req.reqId) }
        DispatchQueue.global().asyncAfter(deadline: .now() + testWaitLimit, execute: timeout)
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
            d.hooks.jsSink = { _, _ in }
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
            DispatchQueue.global().asyncAfter(deadline: .now() + testWaitLimit, execute: timeout)
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

// 第六轮审查：停止落在「已登记进程、还没接手预热进程」之间。中断先写进空闲的进程不起作用，
// 接手后不能再把提问写进去，否则它照常执行到 4 秒宽限期满才被强杀。
func testWarmStopBeforeAdopt() {
    print("· 预热进程接手前点停止：提问不再写进去，进程自己收尾（三位）")
    let dir = NSTemporaryDirectory() + "aipethub-warm-stop-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/cli", log = path + ".log"
    try! installFakeCLI(at: path, behavior: "cold-retry")
    for agent in ["claude", "gpt", "gemini"] {
        try? FileManager.default.removeItem(atPath: log)
        let d = AppDelegate()
        d.hooks.jsSink = { _, _ in }
        d.hooks.cliExecutable = path
        if let key = d.claudePartialCacheKey(path) { d.partialSupport[key] = true }
        var req = AskRequest(agent: agent, reqId: 96, prompt: "once-only", model: "model", effort: "low",
                             permissionMode: "default", workspace: dir, conversationId: "")
        req.browserTools = false
        d.procLock.lock(); d.asks[req.key] = AskState(); d.procLock.unlock()
        let warm: CLIProcess
        switch agent {
        case "claude":
            warm = CLIProcess(input: LiveInput())
            try! warm.start(executable: path, arguments: [], cwd: dir, environment: ProcessInfo.processInfo.environment)
            warm.input?.send(claudeInitializeRequest)
        case "gpt": warm = d.warmCodex(req)!
        default: warm = d.warmGemini(req)!
        }
        warm.warmKey = d.warmKey(req)
        waitUntil { agent == "claude" || warm.stage >= 1 }
        d.keepWarm(agent, warm)
        let lock = NSLock()
        var graces: [() -> Void] = [], forced = false
        d.hooks.stopGraceScheduled = { g in lock.lock(); graces.append(g); lock.unlock() }
        d.hooks.cliAdopting = { key, proc in
            guard key == req.key, proc === warm.proc else { return }
            d.cancel(agent: agent, reqId: req.reqId)
        }
        // 修好前 Claude 照常答完不会卡；万一卡住，到统一上限时执行宽限期强杀收尾
        let watchdog = DispatchWorkItem {
            lock.lock(); forced = true; let g = graces; lock.unlock()
            g.forEach { $0() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + testWaitLimit, execute: watchdog)
        let result: AgentReply
        switch agent {
        case "claude": result = d.runClaude(req)
        case "gpt": result = d.runCodex(req)
        default: result = d.runGemini(req)
        }
        watchdog.cancel()
        d.hooks.cliAdopting = nil
        lock.lock(); let graced = forced; let pending = graces; lock.unlock()
        let rows = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        let prompts = rows.filter { $0.contains("once-only") && ($0.contains("\"type\":\"user\"") || $0.contains("turn/start") || $0.contains("session/prompt")) }
        eq(prompts.count, 0, "\(agent)：接手前已停止，提问没写进预热进程")
        check(result.cancelled, "\(agent)：按停止收尾（\(result.reply.prefix(60))）")
        check(!graced, "\(agent)：进程自己退出，不靠宽限期强杀")
        eq(rows.filter { $0 == "launch" }.count, 1, "\(agent)：没另起进程")
        if !graced { pending.forEach { $0() } }   // 宽限期到点的回调里只结束已经不在的进程，照样执行一遍收尾
        d.procLock.lock(); d.asks[req.key] = nil; d.procLock.unlock()
    }
}

// hunt6 longrun 第 4 条：预热进程在接手前读到提问、执行后退出，App 冷启动重建时不能再执行一遍。
func testWarmExitNoReplay() {
    print("· 预热进程接手前退出：提问只执行一次（三位）")
    let dir = NSTemporaryDirectory() + "aipethub-warm-replay-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/cli", log = path + ".log"
    try! installFakeCLI(at: path, behavior: "cold-retry")
    // 预热进程：读到的每一行都记进同一个日志，一读到提问就退出（模拟执行完提问后上游断开）
    let warmScript = """
    while IFS= read -r line; do
        printf 'warm %s\\n' "$(printf '%s' "$line" | /usr/bin/sed 's#\\\\/#/#g')" >> "$1"
        case "$line" in *'"type":"user"'*|*'"turn/start"'*|*'"session/prompt"'*) exit 1 ;; esac
    done
    """
    for agent in ["claude", "gpt", "gemini"] {
        try? FileManager.default.removeItem(atPath: log)
        let d = AppDelegate()
        d.hooks.jsSink = { _, _ in }
        d.hooks.cliExecutable = path
        if let key = d.claudePartialCacheKey(path) { d.partialSupport[key] = true }
        var req = AskRequest(agent: agent, reqId: 94, prompt: "once-only", model: "model", effort: "low",
                             permissionMode: "default", workspace: dir, conversationId: "")
        req.browserTools = false
        d.procLock.lock(); d.asks[req.key] = AskState(); d.procLock.unlock()
        let warm = CLIProcess(input: LiveInput())
        warm.warmKey = d.warmKey(req)
        try! warm.start(executable: "/bin/sh", arguments: ["-c", warmScript, "sh", log], cwd: dir,
                        environment: ProcessInfo.processInfo.environment)
        d.keepWarm(agent, warm)
        // 卡在「挂好回合、还没接手」：关掉预热进程的输入并等它退出。此前已排进管道的内容它都会读到并记下。
        d.hooks.liveRegistered = { _, live in
            guard let w = live.warm, w === warm else { return }
            w.input?.close()
            _ = w.waitForExit()
        }
        let timeout = DispatchWorkItem { d.cancel(agent: agent, reqId: req.reqId) }
        DispatchQueue.global().asyncAfter(deadline: .now() + testWaitLimit, execute: timeout)
        let result: AgentReply
        switch agent {
        case "claude": result = d.runClaude(req)
        case "gpt": result = d.runCodex(req)
        default: result = d.runGemini(req)
        }
        timeout.cancel()
        d.hooks.liveRegistered = nil
        let rows = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        let prompts = rows.filter { $0.contains("once-only") && ($0.contains("\"type\":\"user\"") || $0.contains("turn/start") || $0.contains("session/prompt")) }
        eq(prompts.filter { $0.hasPrefix("warm ") }.count, 0, "\(agent)：接手前退出的预热进程没收到提问")
        eq(prompts.count, 1, "\(agent)：提问恰好执行一次")
        eq(result.reply, "cold-ok", "\(agent)：没送达就冷启动重建并成功")
        d.procLock.lock(); d.asks[req.key] = nil; d.procLock.unlock()
    }

    // 对照：Claude 预热进程活着被接手时，提问在接手后送进去一次，不另起进程
    try? FileManager.default.removeItem(atPath: log)
    let d = AppDelegate()
    d.hooks.jsSink = { _, _ in }
    d.hooks.cliExecutable = path
    if let key = d.claudePartialCacheKey(path) { d.partialSupport[key] = true }
    var req = AskRequest(agent: "claude", reqId: 95, prompt: "once-only", model: "model", effort: "low",
                         permissionMode: "default", workspace: dir, conversationId: "")
    req.browserTools = false
    d.procLock.lock(); d.asks[req.key] = AskState(); d.procLock.unlock()
    let warm = CLIProcess(input: LiveInput())
    warm.warmKey = d.warmKey(req)
    try! warm.start(executable: path, arguments: [], cwd: dir, environment: ProcessInfo.processInfo.environment)
    warm.input?.send(claudeInitializeRequest)
    d.keepWarm("claude", warm)
    let result = d.runClaude(req)
    let rows = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n")
    eq(rows.filter { $0 == "launch" }.count, 1, "Claude：接手活着的预热进程，不另起")
    eq(rows.filter { $0.contains("once-only") && $0.contains("\"type\":\"user\"") }.count, 1, "Claude：接手后提问送达一次")
    eq(result.reply, "cold-ok", "Claude：接手后正常答完")
    d.procLock.lock(); d.asks[req.key] = nil; d.procLock.unlock()
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
    d.hooks.jsSink = { _, _ in }
    var req = AskRequest(agent: "gemini", reqId: 200, prompt: "fixture", model: "fixture", effort: "low", permissionMode: "bypassPermissions", workspace: dir, conversationId: "")
    req.browserTools = false
    func mode(_ value: String) { try! value.write(toFile: dir + "/mode", atomically: true, encoding: .utf8) }
    for m in ["offline", "max-tokens", "ok", "drop", "ok", "slow", "unsupported", "missing", "handshake", "ok"] {
        mode(m)
        let watchdog = DispatchWorkItem { d.cancel(agent: req.agent, reqId: req.reqId) }
        // 看门狗只防卡死；没被它取消就说明不是靠取消返回的，不再另卡挂钟（slow 模式本身要 2 秒，机器忙时整轮能超过 8 秒）
        DispatchQueue.global().asyncAfter(deadline: .now() + testWaitLimit, execute: watchdog)
        let reply = withTestAsk(d, req.key) { d.runGemini(req) }
        watchdog.cancel()
        check(!reply.cancelled, "\(m)：不靠取消才返回")
        if m == "max-tokens" {
            eq(responseOutcome(agent: "gemini", turn: reply.turn) as? String, "failed", "B5 Gemini 输出上限交给网页重试")
            eq(str((reply.turn?["steps"] as? [[String: Any]])?.last, "detail").contains("输出上限"), true, "B5 保留正文并追加结束原因")
        }
        if m == "drop" {
            let steps = reply.turn?["steps"] as? [[String: Any]]
            eq(steps?.first { str($0, "kind") == "command" }?["status"] as? String, "error", "ACP 在命令运行时退出，实时步骤结束")
        }
        check(m == "offline" || m == "drop" ? reply.reply.contains("⚠️") : reply.reply == "fixture-ok", "\(m)：正确回答或明确错误（\(reply.reply.prefix(80))）")
    }
    for stop in ["max_turn_requests","refusal","cancelled","unknown_stop"] {
        mode(stop)
        let partial = withTestAsk(d,req.key) { d.runGemini(req) }
        eq(str(partial.turn,"outcome"),stop == "cancelled" ? "interrupted" : (stop == "unknown_stop" ? "incomplete" : "failed"),"Gemini 有正文的异常结束 \(stop)")
        eq(partial.reply,"fixture-ok","Gemini 保留异常结束前的正文")
    }
    mode("print-partial")
    let printPartial = withTestAsk(d, req.key) { d.runGemini(req) }
    eq(str(printPartial.turn, "outcome"), "incomplete", "Gemini 单次模式在未写完的步骤退出零也能重试")
    eq(printPartial.reply, "半句", "Gemini 单次模式收齐最后一批增量")
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
        DispatchQueue.global().asyncAfter(deadline:.now()+testWaitLimit,execute:watchdog)
        let reply = withTestAsk(d, compatibility.key) { agent == "claude" ? d.runClaude(compatibility) : d.runCodex(compatibility) }
        watchdog.cancel()
        let manual = AskRequest(agent:agent,reqId:202,prompt:"fixture",model:"fixture",effort:"low",permissionMode:agent == "claude" ? "manual" : "ask",workspace:dir,conversationId:"",browserTools:false)
        let refused = withTestAsk(d,manual.key) { agent == "claude" ? d.runClaude(manual) : d.runCodex(manual) }
        check(refused.restoreDraft && refused.reply.contains("每次询问"), "\(agent) 询问权限下不发送，实际=\(refused.reply)")
        check(!reply.cancelled && reply.reply == "compat-ok", "\(agent)：交互参数不认识时退回一问一答，忽略未知事件")
    }
    for m in ["hang-models", "hang-usage", "ok"] {
        mode(m)
        d.loadUsage(agent: "gemini", force: true)
        // 假进程挂 600 秒，比等待上限长：没有原生期限就等不到释放
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let idle = waitUntil(runLoop: true, interval: 0.02) { d.procLock.lock(); defer { d.procLock.unlock() }; return d.usageLoading.isEmpty }
        check(idle, "\(m)：模型/用量查询有原生期限并释放 usageLoading")
        if !idle {
            // 修前的挂死进程也只按这个实例登记的 PID 清理。
            for key in ["gemini#models", "gemini#usage"] { if let pid = d.runningPid(key) { terminateTree(pid) } }
            mode("offline")
            waitUntil(runLoop: true, interval: 0.02) { d.procLock.lock(); defer { d.procLock.unlock() }; return d.usageLoading.isEmpty }
        }
    }
    d.procLock.lock(); let left = d.usageCache["gemini"]?.items.first?["left"] as? Int; d.procLock.unlock()
    check(left == 80, "恢复连接后重新拿到用量")
    // 固定先生成的持久化快照晚写回；只写测试内存，不碰 UserDefaults。
    let other = AppDelegate(); other.hooks.cliExecutable = cli; other.hooks.jsSink = { _,_ in }
    let first = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0), stored = DispatchSemaphore(value:0), storeLock = NSLock()
    var saved: [String:Any] = [:]
    other.hooks.usageStore = { snapshot in
        if snapshot.count == 1 { first.signal(); _ = release.wait(timeout: .now() + testHoldLimit) }
        storeLock.lock(); saved = snapshot; storeLock.unlock(); stored.signal()
    }
    other.loadUsage(agent:"gemini",force:true)
    check(waitSignal(first),"首份用量快照已生成")
    DispatchQueue.global().async { other.loadUsage(agent:"gpt",force:true) }
    // 只给 gpt 查询一点时间排到锁上；机器忙时只会让下面这条测得弱一些，不会误报
    Thread.sleep(forTimeInterval:0.6)
    release.signal()
    check(waitSignal(stored) && waitSignal(stored),"两位用量完成写回")
    storeLock.lock(); let savedCount = saved.count; storeLock.unlock()
    check(savedCount == 2,"较早生成的快照不能覆盖新用量")
    let env = d.cliEnvironment(["HTTPS_PROXY": "http://127.0.0.1:1"])
    check(env["HTTPS_PROXY"] == "http://127.0.0.1:1", "显式测试代理传递到 CLI，不改系统设置")
}

