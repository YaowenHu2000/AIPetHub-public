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
        if !req.conversationId.isEmpty { p["sessionId"] = req.conversationId }
        return p
    }

    func acpOpenSession(_ req: AskRequest, _ input: LiveInput) {
        input.send(["jsonrpc": "2.0", "id": 2, "method": req.conversationId.isEmpty ? "session/new" : "session/resume",
                    "params": acpSessionParams(req)])
    }

    func acpArgs(_ req: AskRequest) -> [String] {
        ["acp"] + (["accept-edits", "plan", "default"].contains(req.permissionMode) ? [] : ["--dangerously-skip-permissions"])
    }

    /// 会话接上时 agy 报的配置项：能选的模型（模型菜单跟着它走）。
    func noteGeminiModels(_ result: [String: Any]) {
        if geminiModelsFromCLI { return }   // `agy models` 那份更全（带每个模型的强度），有了就以它为准（Usage.swift）
        let options = result["configOptions"] as? [[String: Any]] ?? []
        let models = (options.first { $0["id"] as? String == "model" }?["options"] as? [[String: Any]] ?? []).compactMap { m -> [String: Any]? in
            guard let value = m["value"] as? String else { return nil }
            return ["v": value, "name": m["name"] as? String ?? value, "desc": m["description"] as? String ?? ""]
        }
        if !models.isEmpty { sendToJS("onAgentModels", ["agent": "gemini", "models": models]) }
    }

    /// 预热：起好进程、做完 initialize；接着的是已有会话就连会话也接上（新会话等真发话时再建，免得留下空会话）。
    func warmGemini(_ req: AskRequest) -> CLIProcess? {
        guard let setup = geminiSetup(req) else { return nil }
        let cli = CLIProcess(input: LiveInput())
        cli.warmFilter = { [weak self, weak cli] line in
            guard let self = self, let cli = cli, let obj = self.jsonObject(line), obj["method"] == nil,
                  (obj["id"] as? NSNumber)?.intValue == 1, obj["error"] == nil, let input = cli.input else { return false }
            if req.conversationId.isEmpty { cli.stage = 1 } else { self.acpOpenSession(req, input); cli.stage = 2 }
            return true
        }
        guard (try? cli.start(executable: setup.agy, arguments: acpArgs(req), cwd: validWorkspace(req.workspace) ?? home,
                              environment: cliEnvironment())) != nil else { return nil }
        cli.input?.send(acpInitialize())
        return cli
    }
}

/// 一次交互式回答。流程：initialize(1) → session/new 或 session/resume(2) → 设模型、设模式 → session/prompt → 一路 session/update → prompt 的答复。
/// 预热过的进程可能已经做完前一两步（CLIProcess.stage：1 = initialize 做完，2 = 会话也在接了）。
final class GeminiLiveTurn: LiveTurn {
    private let agy: String
    private let fullModel: String
    private lazy var parser = AcpParser(turn: builder)
    /// 最高权限以外的模式：改文件、跑命令前它会来问
    private var asksFirst: Bool { ["accept-edits", "plan", "default"].contains(req.permissionMode) }
    private var failure: String?
    private var gotResponse = false
    private var promptError: String?
    private var refused = 0   // 用户拒绝了几个操作
    private var queue: [(method: String, params: [String: Any])] = []   // 会话接上后依次做的事，最后一件是提问
    private var nextId = 2
    private var promptId = -1

    init(app: AppDelegate, req: AskRequest, agy: String, fullModel: String) {
        self.agy = agy
        self.fullModel = fullModel
        super.init(app: app, req: req)
    }

    /// 返回 nil：这个版本的 agy 没有 acp、没登录、或者接不上这个会话，调用方退回 `agy -p`。
    func run() -> AgentReply? {
        parser.onCommands = { [weak app] list in app?.sendToJS("onAgentCommands", ["agent": "gemini", "commands": list]) }
        let asked = req.conversationId
        parser.onUsage = { [weak app, weak parser] used, size in
            let sid = parser?.sessionId ?? ""
            app?.noteContext(agent: "gemini", conversationId: sid.isEmpty ? asked : sid, used: used, max: size)
        }
        if warm == nil { input.send(app.acpInitialize()) }
        let res = run(executable: agy, arguments: app.acpArgs(req), cwd: app.validWorkspace(req.workspace) ?? app.home)
        if let e = res.launchError {
            return AgentReply(reply: "⚠️ 无法启动 agy：\(e)", conversationId: req.conversationId)
        }
        // acp 用不了、没登录、接不上这个会话：还什么都没做，退回 agy -p
        let (failed, answered) = locked { (failure, gotResponse) }
        if !res.cancelled, !answered || failed != nil { return nil }
        return reply(res)
    }

    private func reply(_ res: CLIResult) -> AgentReply {
        let convId = parser.sessionId.isEmpty ? req.conversationId : parser.sessionId
        var built = builder.finish(finalText: parser.response)
        var reply = built["text"] as? String ?? ""
        if res.cancelled { return AgentReply(reply: reply, conversationId: convId, cancelled: true, turn: built) }
        // 做到一半出错：做过的步骤留在工作过程里，正文换成出错提示（以 ⚠️ 开头，界面会给出「重试」）
        let (pErr, refusedAny) = locked { (promptError, refused > 0) }
        let stop = parser.stopReason ?? ""
        if let e = pErr ?? (parser.stopReason == nil ? "agy 意外退出（退出码 \(res.status)）" : nil) {
            if builder.steps.isEmpty { return AgentReply(reply: "⚠️ agy 出错：\(e)", conversationId: convId) }
            built = builder.finish(finalText: "⚠️ agy 中途出错，这次没有做完：\(e)\n\n会话和已经做完的步骤都还在：可以点「重试」，或者发一句「继续」让它接着做。")
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
            guard !queue.isEmpty else { return nil }
            let n = queue.removeFirst()
            nextId += 1
            if n.method == "session/prompt" { promptId = nextId }
            return (nextId, n.method, n.params)
        }
        if let n = next { rpc(["id": n.id, "method": n.method, "params": n.params]) }
    }

    // MARK: 网页发来的（中途补充：协议不允许同时两个 prompt，用基类的默认——不接，网页会排着）

    override func interrupt() {
        markStopping()
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

    /// 预热已经做完 initialize：新会话这时才建（已有会话预热时就接上了，答复还在路上或者存着）。
    override func adopted() {
        guard let w = warm, w.stage >= 1 else { return }
        locked { gotResponse = true }
        if w.stage == 1 { app.acpOpenSession(req, input) }
    }

    override func handle(line: String) {
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
        guard let id = (obj["id"] as? NSNumber)?.intValue else { return }
        let isPrompt: Bool = locked { gotResponse = true; return id == promptId }
        handleResponse(id, isPrompt: isPrompt, result: obj["result"] as? [String: Any] ?? [:],
                       error: (obj["error"] as? [String: Any])?["message"] as? String)
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

    private func handleResponse(_ id: Int, isPrompt: Bool, result: [String: Any], error: String?) {
        switch id {
        case 1:   // initialize
            if let e = error { fail(e); return }
            app.acpOpenSession(req, input)
        case 2:   // session/new 或 session/resume
            let sid = (result["sessionId"] as? String) ?? req.conversationId
            guard error == nil, !sid.isEmpty else { fail(error ?? "没有拿到会话"); return }
            sessionReady(sid, result)
        default:
            guard isPrompt else { sendNext(); return }   // 设模型 / 模式的答复（设不上也接着做）
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
        noteConversation(sid)
        app.noteGeminiModels(result)
        let available = ((result["models"] as? [String: Any])?["availableModels"] as? [[String: Any]] ?? []).compactMap { $0["modelId"] as? String }
        // 有图片就放在文字前面一起发（真正的图片，不是路径）
        var blocks: [[String: Any]] = req.images.compactMap { path in
            app.attachmentData(path).map { ["type": "image", "data": $0.base64, "mimeType": $0.mime] }
        }
        blocks.append(["type": "text", "text": req.prompt])
        locked {
            if available.isEmpty || available.contains(fullModel) { queue.append(("session/set_model", ["sessionId": sid, "modelId": fullModel])) }
            if asksFirst { queue.append(("session/set_mode", ["sessionId": sid, "modeId": req.permissionMode])) }
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
        if stopping, let pid = app.runningPid(req.key) { app.descendants(of: pid).forEach { kill($0, SIGTERM) } }
        input.close()
    }
}
