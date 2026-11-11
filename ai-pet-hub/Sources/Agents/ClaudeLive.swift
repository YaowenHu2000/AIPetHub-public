// Claude Code 的交互式回答：`claude -p --input-format stream-json --permission-prompt-tool stdio`，一次回答一个进程。
// 标准输入开着：提问、中途补充的话是一条条 user 消息；它要批准操作、提问、提交计划时发 control_request，我们答 control_response；
// 请它停是 interrupt。带 --replay-user-messages：真正轮到一句话时它原样回显一遍，据此知道补充的话有没有被看到、这一轮算不算答完。
import Cocoa

final class ClaudeLiveTurn: LiveTurn {
    typealias Command = (executable: String, prefix: [String], reclaude: Bool)
    private let command: Command
    private lazy var parser = ClaudeStreamParser(turn: builder)
    // 发出去的话和 CLI 确认轮到的（回显）。第一句是提问本身，之后每句是一条中途补充
    private var sent = 1
    private var acked = 0
    private var sawEvent = false
    private var steers: [(id: String, text: String)] = []

    init(app: AppDelegate, req: AskRequest, command: Command) {
        self.command = command
        super.init(app: app, req: req)
    }

    /// 返回 nil：这个 CLI 不认交互式的参数（没有任何输出就报错退出了），调用方退回一问一答。
    func run() -> AgentReply? {
        _ = parser   // 先建好：之后读输出的线程和这里都会用到
        if warm == nil { input.send(claudeInitializeRequest) }   // 预热过的已经问过了
        input.send(userMessage(req.prompt, images: req.images))
        let res = run(executable: command.executable, arguments: app.claudeArgs(req, command, live: true),
                      cwd: app.validWorkspace(req.workspace) ?? app.home)
        if let e = res.launchError {
            return AgentReply(reply: "⚠️ 无法启动 Claude Code：\(e)", conversationId: req.conversationId)
        }
        let started = locked { sawEvent }
        if !started && !res.cancelled && res.status != 0 && res.err.lowercased().contains("unknown option") { return nil }
        return app.claudeReply(req, res: res, parser: parser, turn: builder)
    }

    /// 一句话：有图片就把图片放在文字前面（真正的图片，不是路径）。
    private func userMessage(_ text: String, images: [String]) -> [String: Any] {
        var content: [[String: Any]] = images.compactMap { path in
            app.attachmentData(path).map { ["type": "image", "source": ["type": "base64", "media_type": $0.mime, "data": $0.base64]] }
        }
        content.append(["type": "text", "text": text])
        return ["type": "user", "message": ["role": "user", "content": content]]
    }

    // MARK: 网页发来的

    override func steer(_ text: String, images: [String], id: String) -> Bool {
        locked { steers.append((id, text)); sent += 1 }
        guard input.send(userMessage(text, images: images)) else {
            locked { steers.removeAll { $0.id == id }; sent -= 1 }
            return false
        }
        noteSteer(id, "sent")
        return true
    }

    override func interrupt() {
        markStopping()
        input.send(["type": "control_request", "request_id": "stop-\(req.reqId)", "request": ["subtype": "interrupt"]])
    }

    override func answer(_ requestId: String, _ body: [String: Any]) {
        guard let info = pending.take(requestId) else { return }
        let tool = info["tool"] as? String ?? ""
        var toolInput = info["input"] as? [String: Any] ?? [:]
        let decision = body["decision"] as? String ?? "deny"
        let response: [String: Any]
        if decision == "allow" || decision == "allowAll" {
            if tool == "AskUserQuestion", let answers = body["answers"] as? [String: Any] { toolInput["answers"] = answers }
            response = ["behavior": "allow", "updatedInput": toolInput]
            if decision == "allowAll" { pending.allowAll(tool) }
        } else {
            let why = trimmed(body["message"] as? String)
            response = ["behavior": "deny", "message": why.isEmpty ? "用户拒绝了这个操作。" : "用户没有同意，并说：\(why)"]
        }
        respond(requestId, response)
        // 计划批准后 CLI 会回到「每步都问」；用户选了「批准并自动执行」就把权限调回去
        if tool == "ExitPlanMode", decision == "allow", let mode = body["mode"] as? String, ["bypassPermissions", "acceptEdits"].contains(mode) {
            input.send(["type": "control_request", "request_id": "mode-\(requestId)", "request": ["subtype": "set_permission_mode", "mode": mode]])
        }
        app.closeRequest(req, id: requestId)
    }

    private func respond(_ requestId: String, _ response: [String: Any]) {
        input.send(["type": "control_response", "response": ["subtype": "success", "request_id": requestId, "response": response]])
    }

    // MARK: CLI 发来的

    override func handle(line: String) {
        guard let brace = line.firstIndex(of: "{"), let obj = app.jsonObject(line[brace...]) else { return }
        locked { sawEvent = true }
        let type = obj["type"] as? String
        switch type {
        case "control_request":
            handleControlRequest(obj)
        case "control_cancel_request":   // CLI 自己撤回了一个请求（比如被中断）
            if let rid = obj["request_id"] as? String, pending.take(rid) != nil { app.closeRequest(req, id: rid) }
        case "control_response":
            let response = obj["response"] as? [String: Any]
            if response?["request_id"] as? String == claudeInitializeId { app.noteClaudeInitialize(obj) }
            if response?["request_id"] as? String == claudeContextId {   // 这一轮答完后问的上下文用量：记下来，然后收
                if let usage = response?["response"] as? [String: Any], let used = (usage["totalTokens"] as? NSNumber)?.intValue,
                   let max = (usage["maxTokens"] as? NSNumber)?.intValue {
                    app.noteContext(agent: "claude", conversationId: parser.sessionId.isEmpty ? req.conversationId : parser.sessionId, used: used, max: max)
                }
                input.close()
            }
        case "user" where (obj["isReplay"] as? Bool) == true:
            handleReplay()
        default:
            if type == "system", obj["subtype"] as? String == "init", let names = obj["slash_commands"] as? [String] {
                app.noteClaudeCommands(names.map { ["name": $0, "desc": ""] })
            }
            parser.feed(obj)
            noteConversation(parser.sessionId)
        }
        if type == "result" { handleResult() }
    }

    /// 它要批准一个操作（can_use_tool）：提问和计划各有自己的界面，其余是「允许 / 拒绝」。
    private func handleControlRequest(_ obj: [String: Any]) {
        guard let rid = obj["request_id"] as? String, let r = obj["request"] as? [String: Any] else { return }
        guard r["subtype"] as? String == "can_use_tool" else {
            input.send(["type": "control_response", "response": ["subtype": "error", "request_id": rid, "error": "AIPetHub 不支持这个请求"]])
            return
        }
        let tool = r["tool_name"] as? String ?? ""
        let toolInput = r["input"] as? [String: Any] ?? [:]
        if pending.isAllowed(tool) {   // 这一轮里用户已经选过「都允许」
            respond(rid, ["behavior": "allow", "updatedInput": toolInput])
            return
        }
        pending.add(rid, ["tool": tool, "input": toolInput])
        switch tool {
        case "AskUserQuestion":
            app.sendRequest(req, id: rid, kind: "question", ["questions": toolInput["questions"] ?? []])
        case "ExitPlanMode":
            app.sendRequest(req, id: rid, kind: "plan", ["plan": toolInput["plan"] as? String ?? ""])
        default:
            let (step, file) = claudeToolStep(name: tool, input: toolInput)
            var fields: [String: Any] = ["tool": tool, "title": step["title"] ?? tool, "stepKind": step["kind"] ?? "tool"]
            if let d = step["detail"] { fields["detail"] = d }
            if let p = step["path"] { fields["path"] = p }
            if let f = file { fields["diff"] = clip(f.diff, 20_000) }
            app.sendRequest(req, id: rid, kind: "permission", fields)
        }
    }

    /// 它回显了一句话：第一句是提问本身；之后每回显一句，就是轮到了一句中途补充的话。
    private func handleReplay() {
        let steer: (id: String, text: String)? = locked {
            acked += 1
            return acked > 1 && !steers.isEmpty ? steers.removeFirst() : nil
        }
        if let s = steer { noteSteerConsumed(s.id, text: s.text) }
    }

    /// 这一轮答完了。发出去的话都轮到过了（或者要停）：关掉输入，CLI 收尾退出；
    /// 还有没轮到的补充：留着输入，CLI 会接着答那一句，再来一个 result。
    private func handleResult() {
        let stop = stopping
        if stop {
            input.close()
        } else if locked({ acked == 0 || acked >= sent }) {
            // 答完了：收之前顺便问一下这个会话的上下文用了多少（模型面板里显示）；它不答也照常收
            input.send(["type": "control_request", "request_id": claudeContextId, "request": ["subtype": "get_context_usage"]])
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.input.close() }
        }
        // 是被停下来的：别让它接着去答还排在它那边的话（那些话界面会重新发），收尾半秒就结束
        if stop {
            let key = req.key
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak app] in
                if let pid = app?.runningPid(key) { app?.terminateTree(pid) }
            }
        }
    }
}
