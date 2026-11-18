// Gemini 的交互式回答：`agy acp`（Agent Client Protocol，JSON-RPC 一行一条），一次回答一个进程：
// initialize → session/new（或 session/resume）→ 设模型 / 模式 → session/prompt → 一路 session/update → 答复里带结束原因。
// 相比 `agy -p`：用得了内置浏览器的工具（MCP）、能请它停（session/cancel）、看得到思考、非最高权限时改文件跑命令前能来问。
// 它给字比 `agy -p` 粗（几十个字一撮），界面按帧匀着放出来（stream.js 的 streamTo）。
// 回答进行中不能插话（协议不允许同时两个 prompt）：补充的话由网页排着，可以「立即发送」打断。
import Cocoa

extension AppDelegate {
    func acpInitialize() -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
            "clientInfo": ["name": "aipethub", "title": "AIPetHub", "version": "1.0"]]]
    }

    func acpSessionParams(_ req: AskRequest) -> [String: Any] {
        var servers: [[String: Any]] = []
        if let mcp = browserMCP(req) {   // 内置浏览器的工具（BrowserTools.swift）
            servers.append(["name": "aipethub-browser", "command": mcp.command, "args": mcp.args, "env": [Any]()])
        }
        var p: [String: Any] = ["cwd": validWorkspace(req.workspace) ?? home, "mcpServers": servers]
        if !req.conversationId.isEmpty { p["sessionId"] = geminiRawId(req.conversationId) }
        return p
    }

    func acpOpenSession(_ req: AskRequest, _ input: LiveInput) {
        input.send(["jsonrpc": "2.0", "id": 2, "method": req.conversationId.isEmpty ? "session/new" : "session/resume",
                    "params": acpSessionParams(req)])
    }

    func acpArgs(_ req: AskRequest) -> [String] {
        ["acp"] + (geminiStore(req.conversationId).desktop ? ["--app-data-dir", "antigravity"] : [])
            + (["accept-edits", "plan", "default"].contains(req.permissionMode) ? [] : ["--dangerously-skip-permissions"])
    }

    /// 会话接上时 agy 报的配置项：能选的模型（模型菜单跟着它走）。
    func noteGeminiModels(_ result: [String: Any]) {
        let raw = (result["models"] as? [String: Any])?["availableModels"] as? [[String: Any]] ?? []
        var models = geminiMenuModels(raw.compactMap { m in
            guard let id = m["modelId"] as? String else { return nil }
            return (id, m["name"] as? String ?? id)
        })
        if models.isEmpty {
            let options = result["configOptions"] as? [[String: Any]] ?? []
            models = (options.first { $0["id"] as? String == "model" }?["options"] as? [[String: Any]] ?? []).compactMap { m -> [String: Any]? in
                guard let value = m["value"] as? String else { return nil }
                return ["v": value, "name": m["name"] as? String ?? value, "desc": m["description"] as? String ?? ""]
            }
        }
        guard !models.isEmpty else { return }
        DispatchQueue.main.async {
            // 与完整模型列表的发布排在一起，不能让迟到的会话列表覆盖它。
            if self.geminiModelsFromCLI { return }
            self.sendToJS("onAgentModels", ["agent": "gemini", "models": models, "complete": false])
        }
    }

    /// 答完后只握手，打字时才提前接入空闲的旧会话。
    func warmGemini(_ req: AskRequest) -> CLIProcess? {
        guard let setup = geminiSetup(req) else { return nil }
        let cli = CLIProcess(input: LiveInput())
        cli.warmFilter = { [weak self, weak cli] line in
            guard let self = self, let cli = cli, let obj = self.jsonObject(line) else { return false }
            if obj["method"] as? String == "session/update", let params = obj["params"] as? [String: Any],
               let update = params["update"] as? [String: Any], update["sessionUpdate"] as? String == "available_commands_update" {
                let commands = acpCommands(update)
                if !commands.isEmpty { self.sendToJS("onAgentCommands", ["agent": "gemini", "commands": commands]) }
                return true
            }
            guard obj["method"] == nil, let id = (obj["id"] as? NSNumber)?.intValue else { return false }
            if id == 1, cli.stage > 0 { return true }
            if id == 2, cli.stage == 2 { return self.warmResumeReply(cli, req: req, result: obj["result"] as? [String: Any]) }
            guard id == 1, obj["error"] == nil else { return false }
            cli.stage = 1
            cli.resumeWhenReady()
            return true
        }
        guard (try? cli.start(executable: setup.agy, arguments: acpArgs(req), cwd: validWorkspace(req.workspace) ?? home,
                              environment: cliEnvironment())) != nil else { cli.input?.abandon(); return nil }
        cli.input?.send(acpInitialize())
        return cli
    }
}

/// 一次交互式回答。流程：initialize(1) → session/new 或 session/resume(2) → 设模型、设模式 → session/prompt → 一路 session/update → prompt 的答复。
/// 预热进程的 stage 为 1 时，initialize 已完成。
final class GeminiLiveTurn: LiveTurn {
    override var waitsForInitialization: Bool { true }
    private let agy: String
    private let fullModel: String
    private lazy var parser = AcpParser(turn: builder)
    /// 最高权限以外的模式：改文件、跑命令前它会来问
    private var asksFirst: Bool { ["accept-edits", "plan", "default"].contains(req.permissionMode) }
    private var failure: String?
    private var sendBlock: String?
    private var gotResponse = false
    private var promptError: String?
    private var refused = 0   // 用户拒绝了几个操作
    private var queue: [(method: String, params: [String: Any])] = []   // 会话接上后依次做的事，最后一件是提问
    private var nextId = 2
    private var modelRequestId: Int?
    private var promptId = -1
    private var awaitingId: Int? = 1

    init(app: AppDelegate, req: AskRequest, agy: String, fullModel: String) {
        self.agy = agy
        self.fullModel = fullModel
        super.init(app: app, req: req)
    }

    /// 返回 nil：这个版本的 agy 没有 acp、没登录、或者接不上这个会话，调用方退回 `agy -p`。
    func run() -> AgentReply? {
        parser.onCommands = { [weak app] list in app?.sendToJS("onAgentCommands", ["agent": "gemini", "commands": list]) }
        let asked = req.conversationId
        let store = app.geminiStore(asked)
        parser.onUsage = { [weak app, weak parser] used, size in
            let sid = parser?.sessionId ?? ""
            app?.noteContext(agent: "gemini", conversationId: sid.isEmpty ? asked : store.key(sid), used: used, max: size)
        }
        if warm == nil { input.send(app.acpInitialize()) }
        let res = run(executable: agy, arguments: app.acpArgs(req), cwd: app.validWorkspace(req.workspace) ?? app.home)
        if res.warmDied {
            return AgentReply(reply: app.fallbackReply(res, cli: "Gemini"), conversationId: req.conversationId)
        }
        if let e = res.launchError {
            return AgentReply(reply: "⚠️ 无法启动 agy：\(e)", conversationId: req.conversationId)
        }
        if !res.cancelled, let reason = locked({ sendBlock }) { return AgentReply(reply: reason, conversationId: parser.sessionId.isEmpty ? asked : store.key(parser.sessionId)) }
        // acp 用不了、没登录、接不上这个会话：还什么都没做，退回 agy -p
        let (failed, answered, submitted, timedOut) = locked { (failure, gotResponse, initialPromptSubmitted, initializationTimedOut) }
        if !res.cancelled, !submitted, timedOut || !answered || failed != nil { return nil }
        return reply(res)
    }

    private func reply(_ res: CLIResult) -> AgentReply {
        let convId = parser.sessionId.isEmpty ? req.conversationId : app.geminiStore(req.conversationId).key(parser.sessionId)
        var built = builder.finish(finalText: parser.response, outcome: res.cancelled ? "interrupted" : "completed")
        var reply = built["text"] as? String ?? ""
        if res.cancelled { return AgentReply(reply: reply, conversationId: convId, cancelled: true, turn: built) }
        // 做到一半出错：做过的步骤留在工作过程里，正文换成出错提示（以 ⚠️ 开头，界面会给出「重试」）
        let (pErr, refusedAny) = locked { (promptError, refused > 0) }
        let stop = parser.stopReason ?? ""
        if let e = pErr ?? (parser.stopReason == nil ? "agy 意外退出（退出码 \(res.status)）" : nil) {
            if builder.steps.isEmpty { return AgentReply(reply: "⚠️ agy 出错：\(e)", conversationId: convId) }
            built = builder.finish(finalText: "⚠️ agy 中途出错，这次没有做完：\(e)\n\n会话和已经做完的步骤都还在：可以点「重试」，或者发一句「继续」让它接着做。", outcome: "failed", error: e)
            return AgentReply(reply: built["text"] as? String ?? "", conversationId: convId, turn: built)
        }
        if reply.isEmpty, stop != "end_turn", !stop.isEmpty { reply = "⚠️ agy 提前结束：\(stop)" }
        if reply.isEmpty, refusedAny { reply = "你没有同意它要做的操作，它就停在这里了。想让它换个做法，直接告诉它。" }
        // 压缩上下文的命令：agy 照做但什么都不回，这里补一句，免得看着像没反应
        let said = req.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if reply.isEmpty, said == "/compact" || said == "/compress" { reply = "已经让它压缩前面的对话（agy 不回报压缩结果）" }
        if reply.isEmpty && ((built["steps"] as? [Any]) ?? []).isEmpty { reply = app.fallbackReply(res, cli: "agy", preferStderr: true) }
        built["text"] = reply
        return AgentReply(reply: reply, conversationId: convId, turn: built)
    }

    @discardableResult
    private func rpc(_ obj: [String: Any]) -> Bool {
        var o = obj
        o["jsonrpc"] = "2.0"
        return input.send(o)
    }

    /// 做队列里的下一件事（设模型 → 设模式 → 提问）。
    private func sendNext() {
        let next: (id: Int, method: String, params: [String: Any])? = locked {
            guard !queue.isEmpty, !stopping, !initializationTimedOut else { return nil }
            let n = queue.removeFirst()
            nextId += 1
            awaitingId = nextId
            if n.method == "session/set_model" { modelRequestId = nextId }
            if n.method == "session/prompt" { promptId = nextId }
            return (nextId, n.method, n.params)
        }
        if let n = next {
            if n.method == "session/prompt" {
                if let reason = app.geminiResumeBlock(req.conversationId) {
                    locked { sendBlock = reason }
                    input.close()
                    return
                }
                if !submitInitialPrompt({ rpc(["id": n.id, "method": n.method, "params": n.params]) }) { input.close() }
            } else { rpc(["id": n.id, "method": n.method, "params": n.params]) }
        }
    }

    // MARK: 网页发来的（中途补充：协议不允许同时两个 prompt，用基类的默认——不接，网页会排着）

    override func interrupt() {
        markStopping()
        // cancel 可能让 agy 先退出、把命令变成孤儿；要在发送前取得名单并安排强制收尾。
        if let pid = app.runningPid(req.key) {
            descendants(of: pid).forEach { terminateTree($0) }
        }
        for (rid, info) in pending.drain() {   // 等着用户决定的请求：告诉它取消了
            if let rpcId = info["rpcId"] { rpc(["id": rpcId, "result": ["outcome": ["outcome": "cancelled"]]]) }
            app.closeRequest(req, id: rid)
        }
        if parser.sessionId.isEmpty { input.close(); return }
        rpc(["method": "session/cancel", "params": ["sessionId": parser.sessionId]])
    }

    override func answer(_ requestId: String, _ body: [String: Any]) {
        guard let info = pending.take(requestId), let rpcId = info["rpcId"] else { return }
        let options = info["options"] as? [[String: Any]] ?? []
        let pick = { (kinds: [String]) -> String? in
            for k in kinds { if let o = options.first(where: { $0["kind"] as? String == k }) { return o["optionId"] as? String } }
            return nil
        }
        let optionId: String?
        switch body["decision"] as? String ?? "deny" {
        case "allow":
            optionId = pick(["allow_once", "allow_always"])
        case "allowAll":
            optionId = pick(["allow_always", "allow_once"])
            pending.allowAll(info["tool"] as? String ?? "")   // 它没有「一直允许」时，这一轮里同一种操作我们替用户答
        default:
            optionId = pick(["reject_once", "reject_always"])
            locked { refused += 1 }
        }
        let outcome: [String: Any] = optionId.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
        rpc(["id": rpcId, "result": ["outcome": outcome]])
        app.closeRequest(req, id: requestId)
    }

    // MARK: agy 发来的

    /// 打字时已发出的 resume 由同一条答复继续推进，不能重新发送。
    override func adopted() {
        guard let w = warm, w.stage >= 1 else { return }
        locked { gotResponse = true }
        initializationProgress("initialize")
        awaitingId = 2
        if w.stage == 1 { openSession() }
        else if let reason = app.geminiResumeBlock(req.conversationId) {
            sendBlock = reason
            awaitingId = nil
            input.close()
        }
    }

    override func handle(line: String) {
        guard !initializationTimedOut else { return }
        guard let obj = app.jsonObject(line) else { return }
        let params = obj["params"] as? [String: Any] ?? [:]
        if let method = obj["method"] as? String {
            if let rpcId = obj["id"] {
                handleRequest(rpcId, method, params)
            } else if method == "session/update", let u = params["update"] as? [String: Any] {
                parser.update(u)
            }
            return
        }
        // 我们的请求的答复
        // 一次只等一个答复；重复或无关的 ID 不能推动配置队列、再次发送提问。
        guard let id = (obj["id"] as? NSNumber)?.intValue, id == awaitingId else { return }
        awaitingId = nil
        let isPrompt: Bool = locked { gotResponse = true; return id == promptId }
        let error = (obj["error"] as? [String: Any]).map { $0["message"] as? String ?? "agy 返回了错误" }
        handleResponse(id, isPrompt: isPrompt, result: obj["result"] as? [String: Any] ?? [:],
                       error: error)
    }

    /// 它要我们答复的请求：只有审批；别的说不支持。
    private func handleRequest(_ rpcId: Any, _ method: String, _ params: [String: Any]) {
        guard method == "session/request_permission" else {
            rpc(["id": rpcId, "error": ["code": -32601, "message": "AIPetHub 不支持这个请求"]])
            return
        }
        let call = params["toolCall"] as? [String: Any] ?? [:]
        let options = params["options"] as? [[String: Any]] ?? []
        let name = call["name"] as? String ?? (call["title"] as? String ?? "tool")
        let toolArgs = (call["args"] as? [String: Any]) ?? (call["rawInput"] as? [String: Any]) ?? [:]
        // 这一轮里用户已经选过「都允许」的那一类操作：直接答应
        if pending.isAllowed(name), let o = options.first(where: { ($0["kind"] as? String ?? "").hasPrefix("allow") }),
           let oid = o["optionId"] as? String {
            rpc(["id": rpcId, "result": ["outcome": ["outcome": "selected", "optionId": oid]]])
            return
        }
        let rid = "acp-\(rpcId)"
        pending.add(rid, ["rpcId": rpcId, "options": options, "tool": name])
        let step = agyToolStep(name: name, params: toolArgs)
        var fields: [String: Any] = ["tool": name, "title": step["title"] ?? name, "stepKind": step["kind"] ?? "tool"]
        if let d = step["detail"] { fields["detail"] = d }
        if let p = step["path"] { fields["path"] = p }
        if let diff = agyDiff(toolArgs), !trimmed(diff).isEmpty { fields["diff"] = clip(diff, 20_000) }
        app.sendRequest(req, id: rid, kind: "permission", fields)
    }

    private func openSession() {
        if let reason = app.geminiResumeBlock(req.conversationId) {
            sendBlock = reason
            input.close()
            return
        }
        app.acpOpenSession(req, input)
    }

    private func handleResponse(_ id: Int, isPrompt: Bool, result: [String: Any], error: String?) {
        switch id {
        case 1:   // initialize
            if let e = error { fail(e); return }
            initializationProgress("initialize")
            awaitingId = 2
            openSession()
        case 2:   // session/new 或 session/resume
            let sid = (result["sessionId"] as? String) ?? geminiRawId(req.conversationId)
            guard error == nil, !sid.isEmpty else { fail(error ?? "没有拿到会话"); return }
            if app.geminiStore(req.conversationId).desktop && sid != geminiRawId(req.conversationId) {
                sendBlock = "⚠️ agy 未能恢复选中的桌面会话。"
                input.close()
                return
            }
            initializationProgress("session")
            sessionReady(sid, result)
        default:
            if id == modelRequestId, let e = error {
                sendBlock = "⚠️ agy 拒绝了所选模型：\(e)"
                input.close()
                return
            }
            guard isPrompt else { initializationProgress("configure-\(id)"); sendNext(); return }
            promptFinished(result, error)
        }
    }

    private func fail(_ message: String) {
        locked { failure = message }
        input.close()
    }

    /// 会话接上了：排好「设模型 → 设模式 → 提问」，开始做。
    private func sessionReady(_ sid: String, _ result: [String: Any]) {
        parser.sessionId = sid
        noteConversation(app.geminiStore(req.conversationId).key(sid))
        app.noteGeminiModels(result)
        let models = result["models"] as? [String: Any]
        let available = (models?["availableModels"] as? [[String: Any]] ?? []).compactMap { $0["modelId"] as? String }
        // 有的模型 ID 自身带后缀或根本没有强度变体，优先按本次会话公布的 ID 匹配。
        let selected = available.contains(fullModel) || available.isEmpty ? fullModel : req.model
        guard available.isEmpty || available.contains(selected) else {
            sendBlock = "⚠️ 这个 agy 会话不支持所选模型 \(fullModel)，请重新选择模型。"
            input.close()
            return
        }
        // 有图片就放在文字前面一起发（真正的图片，不是路径）
        var blocks: [[String: Any]] = req.images.compactMap { path in
            app.attachmentData(path).map { ["type": "image", "data": $0.base64, "mimeType": $0.mime] }
        }
        blocks.append(["type": "text", "text": req.prompt])
        locked {
            if models?["currentModelId"] as? String != selected {
                queue.append(("session/set_model", ["sessionId": sid, "modelId": selected]))
            }
            if asksFirst, (result["modes"] as? [String: Any])?["currentModeId"] as? String != req.permissionMode {
                queue.append(("session/set_mode", ["sessionId": sid, "modeId": req.permissionMode]))
            }
            queue.append(("session/prompt", ["sessionId": sid, "prompt": blocks]))
        }
        if stopping { input.close(); return }   // 还没开始问就点了停止
        sendNext()
    }

    /// 提问的答复到了：这一轮结束。
    private func promptFinished(_ result: [String: Any], _ error: String?) {
        if let e = error { locked { promptError = e } }
        parser.finish(stopReason: result["stopReason"] as? String)
        // 被停止时：它启动的命令还在跑，退出前一起结束（它自己不管）
        if stopping, let pid = app.runningPid(req.key) { descendants(of: pid).forEach { kill($0, SIGTERM) } }
        input.close()
    }
}
