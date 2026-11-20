// Gemini 的交互式回答：`agy acp`（Agent Client Protocol，JSON-RPC 一行一条），一次回答一个进程：
// initialize → session/new（或 session/resume）→ 设模型 / 模式 → session/prompt → 一路 session/update → 答复里带结束原因。
// 相比 `agy -p`：用得了内置浏览器的工具（MCP）、能请它停（session/cancel）、看得到思考、非最高权限时改文件跑命令前能来问、
// 它用 ask_question 提问时（elicitation/create 表单）在提问卡里作答。
// 它给字比 `agy -p` 粗（几十个字一撮），界面按帧匀着放出来（stream.js 的 streamTo）。
// 回答进行中补充一句：再发一条 session/prompt（agy 1.5.0 起支持）。agy 收下时立刻用 end_turn 答复上一条 prompt，这一轮接着跑，
// 最后由最新那条 prompt 的答复结束；它在等审批或提问的答复时会拒收（-32603），这句话留在网页的队列里，这一轮结束后再发。
import Cocoa

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
    private var storeRetries = 0   // 新会话建库被挡后重建了几次
    private var queue: [(method: String, params: [String: Any])] = []   // 会话接上后依次做的事，最后一件是提问
    private var nextId = 2
    private var modelRequestId: Int?
    private var modeRequestId: Int?
    private var promptId = -1
    private var awaitingId: Int? = 1
    /// 发出去、agy 还没收下的补充（rpc 是那条 session/prompt 的 ID）
    private var steers: [(id: String, rpc: Int, text: String, images: [String])] = []

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
        // 拦在提问前的（拒绝所选模型或模式、会话被别处占着等）：agy 的记录里没有这句，已有会话的原话和附件退回原会话草稿；
        // 等作答时才被别处打开的已经问出去了，照旧留「重试」
        if !res.cancelled, let (reason, unsent) = locked({ sendBlock.map { ($0, !initialPromptSubmitted) } }) {
            return AgentReply(reply: reason, conversationId: parser.sessionId.isEmpty ? asked : store.key(parser.sessionId), restoreDraft: unsent && !asked.isEmpty)
        }
        // acp 用不了、没登录、接不上这个会话：还什么都没做，退回 agy -p
        let (failed, answered, submitted, timedOut) = locked { (failure, gotResponse, initialPromptSubmitted, initializationTimedOut) }
        if !res.cancelled, !submitted, timedOut || !answered || failed != nil { return nil }
        return reply(res)
    }

    private func reply(_ res: CLIResult) -> AgentReply {
        let convId = parser.sessionId.isEmpty ? req.conversationId : app.geminiStore(req.conversationId).key(parser.sessionId)
        // 停止后 agy 可能不再回 prompt 的答复：正在写的那段要先收进正文，否则正文和本机补记都退回工具前的引言。
        if res.cancelled { parser.finish(stopReason: parser.stopReason) }
        var built = builder.finish(finalText: parser.response, outcome: res.cancelled ? "interrupted" : "completed")
        var reply = built["text"] as? String ?? ""
        if res.cancelled { return AgentReply(reply: reply, conversationId: convId, cancelled: true, turn: built) }
        // 做到一半出错：做过的步骤留在工作过程里，正文换成出错提示（以 ⚠️ 开头，界面会给出「重试」）
        let (pErr, refusedAny) = locked { (promptError, refused > 0) }
        let stop = parser.stopReason ?? ""
        if let e = pErr ?? (parser.stopReason == nil ? ("agy 意外退出（退出码 \(res.status)）" + (trimmed(res.err).isEmpty ? "" : "：" + String(trimmed(res.err).suffix(1500)))) : nil) {
            if builder.steps.isEmpty {
                let text = "⚠️ agy 出错：\(e)"
                return AgentReply(reply: text, conversationId: convId, turn: builder.finish(finalText: text, outcome: "failed", error: e))
            }
            // 正文写到一半断了（上游连接失败）：用户正在读的就是回答，留作正文（「拷贝回答」拿到的是它），原因进末尾的「出错」步骤，
            // 和 Claude、Codex、DeepSeek 一样；本机补记存的也是这段，重开一致。最后一步是工具时那段字只是引言，仍换成出错提示
            if builder.steps.last?["kind"] as? String == "text" {
                built = builder.finish(finalText: nil, outcome: "failed", error: e)
                return AgentReply(reply: built["text"] as? String ?? "", conversationId: convId, turn: built)
            }
            built = builder.finish(finalText: "⚠️ agy 中途出错，这次没有做完：\(e)\n\n会话和已经做完的步骤都还在：可以点「重试」，或者发一句「继续」让它接着做。", outcome: "failed", error: e)
            return AgentReply(reply: built["text"] as? String ?? "", conversationId: convId, turn: built)
        }
        if stop == "max_tokens" {
            built = builder.finish(finalText: parser.response, outcome: "failed", error: outputLimitHint)
            return AgentReply(reply: built["text"] as? String ?? "", conversationId: convId, turn: built)
        }
        if ["max_turn_requests", "refusal", "cancelled"].contains(stop) {
            let why = "agy 提前结束：\(stop)"
            built = builder.finish(finalText:reply.isEmpty ? why : reply, outcome:stop == "cancelled" ? "interrupted" : "failed", error:why)
            return AgentReply(reply: built["text"] as? String ?? why, conversationId:convId, turn:built)
        }
        if stop != "end_turn", !stop.isEmpty {
            let why = "agy 提前结束：\(stop)"
            built = builder.finish(finalText:reply.isEmpty ? "⚠️ " + why : reply, outcome:"incomplete", error:why)
            return AgentReply(reply:built["text"] as? String ?? why, conversationId:convId, turn:built)
        }
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
            if n.method == "session/set_mode" { modeRequestId = nextId }
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

    /// 一句话：有图片就放在文字前面一起发（真正的图片，不是路径）
    private func promptBlocks(_ text: String, images: [String]) -> [[String: Any]] {
        var blocks: [[String: Any]] = images.compactMap { path in
            app.attachmentData(path).map { ["type": "image", "data": $0.base64, "mimeType": $0.mime] }
        }
        blocks.append(["type": "text", "text": text])
        return blocks
    }

    // MARK: 网页发来的

    /// 提问还没送出（还在握手、设模型）或这一轮已经在收尾时不接，网页排着，这一轮结束后再发。
    override func steer(_ text: String, images: [String], id: String) -> Bool {
        guard initialPromptSubmitted, !stopping, promptId >= 0, !parser.sessionId.isEmpty else { return false }
        nextId += 1
        let rpcId = nextId
        steers.append((id, rpcId, text, images))
        guard rpc(["id": rpcId, "method": "session/prompt", "params": ["sessionId": parser.sessionId, "prompt": promptBlocks(text, images: images)]]) else {
            steers.removeAll { $0.id == id }
            return false
        }
        noteSteer(id, "sent")
        return true
    }

    override func interrupt() {
        markStopping()
        // cancel 可能让 agy 先退出、把命令变成孤儿；要在发送前取得名单并安排强制收尾。
        // 名单一次取全、父进程在前、中间不再查进程表：`sleep 120; echo x > f` 这种命令，sleep 先结束而外层 shell 晚一步收到信号时，
        // shell 不到 1 毫秒就接着执行了后半段；先结束 shell，它就没有机会。
        if let pid = app.runningPid(req.key) {
            let tree = processIdentities(descendants(of: pid).reversed())
            for p in tree { kill(p.pid, SIGTERM); app.hooks.stopSignalSent?(p.pid) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                for p in tree where processStartTime(p.pid) == p.start { kill(p.pid, SIGKILL) }
            }
        }
        for (rid, info) in pending.drain() {   // 等着用户决定的请求：告诉它取消了
            let cancelled: [String: Any] = info["kind"] as? String == "question" ? ["action": "cancel"] : ["outcome": ["outcome": "cancelled"]]
            if let rpcId = info["rpcId"] { rpc(["id": rpcId, "result": cancelled]) }
            app.closeRequest(req, id: rid)
        }
        if parser.sessionId.isEmpty { input.close(); return }
        rpc(["method": "session/cancel", "params": ["sessionId": parser.sessionId]])
    }

    override func answer(_ requestId: String, _ body: [String: Any]) {
        let cid = parser.sessionId.isEmpty ? req.conversationId : app.geminiStore(req.conversationId).key(parser.sessionId)
        if pending.contains(requestId), app.geminiSessionHeld(cid, confirm: false) == true {
            DispatchQueue.global(qos: .userInitiated).async {
                let conflict = self.app.geminiSessionHeld(cid) == true
                self.locked {
                    if conflict { self.closeConflictingCard(requestId) }
                    else { self.sendAnswer(requestId, body) }
                }
            }
            return
        }
        sendAnswer(requestId, body)
    }

    private func sendAnswer(_ requestId: String, _ body: [String: Any]) {
        guard let info = pending.take(requestId), let rpcId = info["rpcId"] else { return }
        if info["kind"] as? String == "question" {
            let result: [String: Any] = body["decision"] as? String == "deny" ? ["action": "decline"] : questionAnswers(info, body)
            rpc(["id": rpcId, "result": result])
            app.closeRequest(req, id: requestId)
            return
        }
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
        // 还没被收下的补充自己有了答复：报错是被拒（等审批 / 提问时、正在停）；正常答复不该先于上一条 prompt 来，来了也只当收下
        if let id = (obj["id"] as? NSNumber)?.intValue, let i = steers.firstIndex(where: { $0.rpc == id }) {
            let s = steers.remove(at: i)
            if obj["error"] != nil { noteSteer(s.id, "rejected") } else { noteSteerConsumed(s.id, text: s.text, images: s.images) }
            return
        }
        // 一次只等一个答复；重复或无关的 ID 不能推动配置队列、再次发送提问。
        guard let id = (obj["id"] as? NSNumber)?.intValue, id == awaitingId else { return }
        awaitingId = nil
        let isPrompt: Bool = locked { gotResponse = true; return id == promptId }
        let error = (obj["error"] as? [String: Any]).map { $0["message"] as? String ?? "agy 返回了错误" }
        handleResponse(id, isPrompt: isPrompt, result: obj["result"] as? [String: Any] ?? [:],
                       error: error)
    }

    /// 它要我们答复的请求：审批、提问（表单）；别的说不支持。
    private func handleRequest(_ rpcId: Any, _ method: String, _ params: [String: Any]) {
        if method == "elicitation/create", params["mode"] as? String == "form" {
            askQuestion(rpcId, params)
            return
        }
        guard method == "session/request_permission" else {
            fputs("AIPetHub：Gemini 发来不认识的请求 \(method)，回了不支持\n", stderr)   // agy 升级加了新回调时能发现
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

    /// agy 的 ask_question 编成的表单（agy 1.5.11 实测）：qN 是一道题，单选是带 oneOf 的字符串、多选是 items 带 anyOf 的数组，
    /// 选项的 const 是编号、title 是文字；qN_other 是同一题自己写的回答。用网页现有的提问卡显示，答复时再按这份对照换回编号。
    private func askQuestion(_ rpcId: Any, _ params: [String: Any]) {
        let rid = "acp-\(rpcId)"
        let props = (params["requestedSchema"] as? [String: Any])?["properties"] as? [String: [String: Any]] ?? [:]
        // JSON 对象解出来不保序：按 q1、q2…… 的数字顺序排回题目原来的顺序
        let keys = props.keys.filter { !$0.hasSuffix("_other") }.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        var shown: [[String: Any]] = [], fields: [[String: Any]] = []
        for key in keys {
            let p = props[key] ?? [:]
            let multi = p["type"] as? String == "array"
            let holder = multi ? p["items"] as? [String: Any] ?? [:] : p
            let choices = (holder["oneOf"] ?? holder["anyOf"]) as? [[String: Any]] ?? []
            let options = choices.compactMap { c -> [String: Any]? in
                guard let value = c["const"] else { return nil }
                return ["label": c["title"] as? String ?? "\(value)", "value": value]
            }
            let title = p["title"] as? String ?? key
            shown.append(["id": key, "question": title, "header": "", "multiSelect": multi, "isOther": options.isEmpty || props[key + "_other"] != nil,
                          "options": options.map { ["label": $0["label"] ?? "", "description": ""] }])
            fields.append(["key": key, "question": title, "multi": multi, "options": options,
                           "other": props[key + "_other"] == nil ? "" : key + "_other"])
        }
        pending.add(rid, ["rpcId": rpcId, "kind": "question", "fields": fields])
        app.sendRequest(req, id: rid, kind: "question", ["questions": shown])
        let cid = parser.sessionId.isEmpty ? req.conversationId : app.geminiStore(req.conversationId).key(parser.sessionId)
        watchQuestion(rid, cid: cid)
    }

    private func watchQuestion(_ rid: String, cid: String) {
        let check = { [weak self] in
            guard let self, self.pending.contains(rid) else { return }
            let conflict = self.app.geminiSessionHeld(cid) == true
            self.locked {
                guard self.pending.contains(rid) else { return }
                if conflict { self.closeConflictingCard(rid) }
                else { self.watchQuestion(rid, cid: cid) }
            }
        }
        if let schedule = app.hooks.geminiQuestionCheckScheduled { schedule(check) }
        else { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: check) }
    }

    private func closeConflictingCard(_ rid: String) {
        guard pending.take(rid) != nil else { return }
        sendBlock = "⚠️ 等待作答时，另一个 agy 打开了这个 Gemini 会话。请先关闭终端里的同一会话，再打开历史核对后重试。"
        app.closeRequest(req, id: rid)
        input.close()
    }

    /// 选项要换回协议编号，自填文字只能放进对应的 qN_other。
    private func questionAnswers(_ info: [String: Any], _ body: [String: Any]) -> [String: Any] {
        let given = body["answers"] as? [String: Any] ?? [:]
        var content: [String: Any] = [:]
        for f in info["fields"] as? [[String: Any]] ?? [] {
            guard let key = f["key"] as? String else { continue }
            let options = f["options"] as? [[String: Any]] ?? []
            let text = (given[key] ?? given[f["question"] as? String ?? ""]) as? String ?? ""
            let value = { (label: String) in options.first { $0["label"] as? String == label }?["value"] }
            var picked: [Any] = [], rest: [String] = []
            if let parts = questionAnswerParts(body, key) {
                picked = parts.selected.compactMap(value)
                if !parts.custom.isEmpty { rest = [parts.custom] }
            } else if let v = value(text) { picked = [v] }   // 整句就是一个选项（选项文字里本来就可能有「、」）
            else {
                for part in text.components(separatedBy: "、") where !part.isEmpty {
                    if let v = value(part) { picked.append(v) } else { rest.append(part) }
                }
            }
            if f["multi"] as? Bool == true { content[key] = picked } else if let v = picked.first { content[key] = v }
            let other = f["other"] as? String ?? ""
            if !rest.isEmpty {
                if !other.isEmpty { content[other] = rest.joined(separator: "、") }
                else if options.isEmpty { content[key] = text }   // 没有选项的题：整句就是回答
            }
        }
        return ["action": "accept", "content": content]
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
            // 新会话的库没建成：还没提问，换一个重建（见 geminiStoreFailed）。一直被挡就用最后一个照常问，不让用户白等。
            if req.conversationId.isEmpty, storeRetries < 2, app.geminiStoreFailed(sid, pid: app.runningPid(req.key)) {
                storeRetries += 1
                app.discardFailedGeminiStore(sid)
                awaitingId = 2
                app.acpOpenSession(req, input)
                return
            }
            if app.geminiStore(req.conversationId).desktop && sid != geminiRawId(req.conversationId) {
                sendBlock = "⚠️ agy 未能恢复选中的桌面会话。"
                input.close()
                return
            }
            initializationProgress("session")
            sessionReady(sid, result)
        default:
            if (id == modelRequestId || id == modeRequestId), let e = error {
                let setting = id == modeRequestId ? "权限模式" : "模型"
                sendBlock = "⚠️ agy 拒绝了所选\(setting)：\(e)"
                input.close()
                return
            }
            guard isPrompt else { initializationProgress("configure-\(id)"); sendNext(); return }
            // 有补充在路上：这是 agy 收下补充时给上一条 prompt 的答复（或者上一条刚好答完、补充接着作为新的一问），
            // 这一轮还没完，改等那条补充的答复。正在停时不接力：停止以这条答复为准。
            if !stopping, !steers.isEmpty {
                let s = steers.removeFirst()
                locked { promptId = s.rpc }
                awaitingId = s.rpc
                noteSteerConsumed(s.id, text: s.text, images: s.images)
                return
            }
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
        let blocks = promptBlocks(req.prompt, images: req.images)
        notePromptImages(blocks)
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
