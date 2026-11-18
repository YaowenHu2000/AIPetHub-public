// 向 DeepSeek 提问：走 dsh 的本机服务（DeepSeekServer.swift），事件翻译成工作步骤（Parsing/DeepSeekEvents.swift）。
import Cocoa

extension AppDelegate {
    /// dsh 装在哪。它是个 npm 包，常见的几处都看一眼，没有再去登录 shell 的 PATH 里找。
    func dshExecutable() -> String? {
        hooks.cliExecutable ?? findExecutable(["\(home)/.local/bin/dsh", "/opt/homebrew/bin/dsh", "/usr/local/bin/dsh"])   // 都没有时 findExecutable 会去登录 shell 的 PATH 里找
    }

    /// 让 dsh 的本机服务跑起来。成功返回 nil，否则是给用户看的原因。第一次起来时顺便问它有哪些模型。
    func dshReady() -> String? {
        guard let exe = dshExecutable() else { return "没有找到 dsh（DeepSeek Harness）。用 npm install -g @deepseek-ai/dsh 装好后再试。" }
        let wasRunning = dshServer.isRunning
        if let err = dshServer.ensure(executable: exe, environment: cliEnvironment(), cwd: home) { return err }
        if !wasRunning { DispatchQueue.global(qos: .utility).async { self.noteDshModels() } }
        return nil
    }

    /// dsh 现在能用的模型和各自的思考强度：模型菜单跟着它走。
    func noteDshModels() {
        guard let groups = (dshServer.call("llm.models").value as? [String: Any])?["groups"] as? [[String: Any]] else { return }
        var providers: [String: String] = [:]
        var models: [[String: Any]] = []
        for g in groups {
            for m in g["models"] as? [[String: Any]] ?? [] {
                guard let id = m["id"] as? String else { continue }
                providers[id] = g["id"] as? String ?? ""
                var item: [String: Any] = ["v": id, "name": m["name"] as? String ?? id, "desc": ""]
                let efforts = ((m["reasoning"] as? [String: Any])?["efforts"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                if !efforts.isEmpty { item["efforts"] = efforts }
                models.append(item)
            }
        }
        guard !models.isEmpty else { return }
        procLock.lock(); dshProviders = providers; procLock.unlock()
        DispatchQueue.main.async { self.sendToJS("onAgentModels", ["agent": "deepseek", "models": models]) }
    }

    func runDeepSeek(_ req: AskRequest) -> AgentReply {
        DeepSeekLiveTurn(app: self, req: req).run()
    }
}

/// 一次回答。和另外三位的区别：没有「这一次回答的进程」，事件从共用的服务里按会话分过来。
final class DeepSeekLiveTurn: LiveTurn {
    private lazy var parser = DshParser(turn: builder)
    private var sid = ""
    private var asked = false          // 提问已经送进去了（之前的运行状态变化不算这一轮的）
    private var running = false
    private var finishGeneration = 0
    /// 没点停止、又一直等不到 turn/end 时，安静多久才收尾（有事件进来就顺延）。测试里会调短，免得真等半分钟。
    var idleFallback: TimeInterval = 30
    private var idleHint = false
    private var agentError = ""
    private var dropped = false        // 服务断了
    private var refused = 0
    private let done = DispatchSemaphore(value: 0)
    private var finished = false
    private var steers: [String: (id: String, text: String)] = [:]   // 中途补充的话：调用编号 → 网页那边的编号和内容（它看到时按调用编号认）
    private var reopened = 0
    private var ctxUsed = 0, ctxMax = 0, ctxParts: [[String: Any]] = []   // 上下文用量：最近一次报的

    func run(ready: (() -> String?)? = nil) -> AgentReply {
        app.registerLive(req.key, self)
        defer {
            app.unregisterLive(req.key)
            pending.takeAll().forEach { app.closeRequest(req, id: $0) }
        }
        if let err = (ready ?? app.dshReady)() { return AgentReply(reply: "⚠️ \(err)", conversationId: req.conversationId) }
        let server = app.dshServer
        let cwd = app.validWorkspace(req.workspace) ?? app.home
        var isNew = false
        locked { sid = req.conversationId }
        if locked({ sid.isEmpty }) {
            let made = server.call("session.create", ["cwd": cwd])
            guard let id = (made.value as? [String: Any])?["sessionId"] as? String else {
                return AgentReply(reply: "⚠️ dsh 没能新建会话：\(made.error ?? "没有答复")", conversationId: "")
            }
            locked { sid = id }
            isNew = true
        }
        noteConversation(sid)
        let token = server.listen(sid) { [weak self] frame in self?.locked { self?.handle(frame) } }
        defer { server.unlisten(sid, token) }

        // 读图放在事务外；真正提交前再检查停止，配置和提问则共用会话串行队列。
        var blocks: [[String: Any]] = [], asPaths: [String] = []
        for path in req.images {
            if let a = app.attachmentData(path), a.base64.count < 6_000_000 { blocks.append(["type": "image", "mediaType": a.mime, "data": a.base64]) }
            else { asPaths.append(path) }
        }
        blocks.append(["type": "text", "text": asPaths.isEmpty ? req.prompt : req.prompt + "\n\n" + asPaths.joined(separator: "\n")])
        var earlyReply: AgentReply?
        let error = app.dshConfigure(sid, req, isNew: isNew) {
            guard !self.stopping else { return }
            // /compact 不经过模型的一轮；停止后即使底层压缩成功也不能再报成功。
            if self.req.prompt.trimmingCharacters(in: .whitespacesAndNewlines) == "/compact" {
                let r = server.call("commands/execute", ["agentId": self.sid, "line": "/compact"], typert: true, timeout: 300)
                if self.cancelIfStopped() { return }
                Thread.sleep(forTimeInterval: 1.2)   // 等它把压缩后的上下文用量报过来
                if self.cancelIfStopped() { return }
                earlyReply = self.locked {
                    if self.stopping { return AgentReply(reply: "", conversationId: self.sid, cancelled: true) }
                    if let e = r.error { return AgentReply(reply: "⚠️ 没能压缩上下文：\(e)", conversationId: self.sid) }
                    return AgentReply(reply: dshCompactReply(r.value), conversationId: self.sid)
                }
                return
            }
            guard self.locked({ if self.stopping { return false }; self.asked = true; return true }) else { return }
            var sent = server.call("session.prompt", ["sessionId": self.sid, "mode": "queue", "content": blocks])
            if self.cancelIfStopped() { return }
            if sent.error != nil, blocks.count > 1 {   // 带图片被拒了：改成只发路径
                guard !self.stopping else { return }
                let text = self.req.prompt + "\n\n" + self.req.images.joined(separator: "\n")
                sent = server.call("session.prompt", ["sessionId": self.sid, "mode": "queue", "content": [["type": "text", "text": text]]])
                if self.cancelIfStopped() { return }
            }
            if let e = sent.error {
                let hint = sent.code == "session-not-found" ? "这个会话在 dsh 里找不到了（可能已被删除）。" : ""
                earlyReply = AgentReply(reply: "⚠️ 没能把话发给 DeepSeek：\(hint)\(e)", conversationId: self.sid)
            }
        }
        if stopping { return locked { reply() } }
        if let e = error { return AgentReply(reply: "⚠️ 没能应用 DeepSeek 的设置：\(e) 请检查设置后重试。", conversationId: sid) }
        if let r = earlyReply { return r }

        // 等这一轮结束。服务要是自己退了（崩了、被结束）也别一直等
        while done.wait(timeout: .now() + 2) != .success {
            if !server.isRunning { locked { dropped = true }; break }
        }
        return locked { reply() }
    }

    /// 请求可能在第一次 cancel 之后才被服务接收，回包后必须补停；调用者不持回合锁。
    @discardableResult
    private func cancelIfStopped() -> Bool {
        guard stopping else { return false }
        let id = locked { sid }
        if !id.isEmpty { _ = app.dshServer.call("session.cancel", ["sessionId": id], timeout: 15) }
        return true
    }

    private func scheduleFinishFallback() {
        finishGeneration += 1
        let generation = finishGeneration
        DispatchQueue.global().asyncAfter(deadline: .now() + (stopping ? 1.5 : idleFallback)) { [weak self] in
            self?.locked {
                guard let self = self, self.finishGeneration == generation, self.idleHint else { return }
                self.finish()
            }
        }
    }

    private func reply() -> AgentReply {
        let interrupted = stopping || parser.ended?.kind == "aborted"
        var built = builder.finish(finalText: parser.response, outcome: interrupted ? "interrupted" : "completed")
        var text = built["text"] as? String ?? ""
        if interrupted { return AgentReply(reply: text, conversationId: sid, cancelled: stopping, turn: built) }
        let hasSteps = !((built["steps"] as? [Any]) ?? []).isEmpty
        var problem: String?
        if let e = parser.ended {
            switch e.kind {
            case "completed": break
            case "error": problem = dshReadableError(e.message.isEmpty ? parser.failure : e.message, code: e.code)
            case "max-tokens": problem = "这一轮的输出到上限了，没有写完。发一句「继续」可以让它接着写。"
            default: if text.isEmpty { problem = "这一轮提前结束了（\(e.kind)）。" }
            }
        } else if dropped {
            problem = "dsh 的本机服务中途退出了。"
        } else if !agentError.isEmpty || !parser.failure.isEmpty {
            problem = dshReadableError(agentError.isEmpty ? parser.failure : agentError, code: "")
        }
        if let p = problem {
            // 做到一半出错：做过的步骤留在工作过程里，正文换成出错提示（以 ⚠️ 开头，界面会给出「重试」）
            if !hasSteps { return AgentReply(reply: "⚠️ DeepSeek 出错：\(p)", conversationId: sid) }
            built = builder.finish(finalText: "⚠️ DeepSeek 中途出错，这次没有做完：\(p)\n\n会话和已经做完的步骤都还在：可以点「重试」，或者发一句「继续」让它接着做。", outcome: "failed", includeEnding: false)
            return AgentReply(reply: built["text"] as? String ?? "", conversationId: sid, turn: built)
        }
        if text.isEmpty, refused > 0 { text = "你没有同意它要做的操作，它就停在这里了。想让它换个做法，直接告诉它。" }
        if text.isEmpty, !hasSteps { text = "⚠️ DeepSeek 这一轮没有给出任何内容。" }
        built["text"] = text
        return AgentReply(reply: text, conversationId: sid, turn: built)
    }

    private func finish() {
        if finished { return }
        finished = true
        done.signal()
    }

    #if HUB_SELFTEST
    func receiveForTest(_ frame: [String: Any]) { locked { asked = true; handle(frame) } }
    var finishedForTest: Bool { locked { finished } }
    var replyForTest: AgentReply { locked { reply() } }
    #endif

    // MARK: 服务发来的（已经在锁里）

    private func handle(_ frame: [String: Any]) {
        // 正常结束认 turn/end；idle 之后只要仍有事件，缺失 turn/end 的长兜底就顺延。
        if idleHint, !stopping { scheduleFinishFallback() }
        switch frame["type"] as? String {
        case "session/event":
            guard asked, let event = frame["event"] as? [String: Any] else { return }
            // 中途补充的话被它看到了（在下一步开始前插进去）：作为一步「你补充说」记进工作过程
            if event["type"] as? String == "user/message",
               let rpc = ((event["data"] as? [String: Any])?["source"] as? [String: Any])?["rpcId"] as? String, let s = steers.removeValue(forKey: rpc) {
                noteSteerConsumed(s.id, text: s.text)
                return
            }
            parser.feed(event, view: frame["view"] as? [String: Any])
            guard let end = parser.ended else { return }
            if end.kind == "completed", !steers.isEmpty, !stopping {
                // 这一轮结束时还有补充的话没被看到（刚好发在最后一步之后）：它会为这句话再开一轮，接着等。
                // 20 秒里没有动静就不等了，那句话退给网页（它会当成下一句重新发）
                parser.reopen()
                reopened += 1
                let mark = reopened
                DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in
                    self?.locked {
                        guard let self = self, self.reopened == mark, !self.steers.isEmpty, self.parser.ended == nil else { return }
                        self.steers.values.forEach { self.noteSteer($0.id, "rejected") }
                        self.steers = [:]
                        self.finish()
                    }
                }
                return
            }
            finish()
        case "session/projection":
            // 上下文用了多少、是什么占的：模型面板里显示。两样是分开报的，哪样来了就连同另一样最近的值一起告诉网页
            guard let v = frame["value"] as? [String: Any] else { return }
            let n: (String) -> Int? = { (v[$0] as? NSNumber)?.intValue }
            if frame["key"] as? String == "contextPressure" {
                // projectedTokens 是「下一次请求要带多少」，压缩之后马上就变；没有它才用上一次请求的实际大小
                if let used = n("projectedTokens") ?? n("pressureTokens") { ctxUsed = used }
                if let window = n("contextWindow") { ctxMax = window }
            } else if frame["key"] as? String == "contextBreakdown" {
                ctxParts = deepSeekContextParts(v)
            } else { return }
            if ctxUsed > 0, ctxMax > 0 { app.noteContext(agent: "deepseek", conversationId: sid, used: ctxUsed, max: ctxMax, parts: ctxParts, estimated: true, seq: frame["seq"] as? Int) }
        case "approval/requested":
            approval(frame)
        case "approval/resolved":
            if let id = frame["approvalId"] as? String, pending.take("dsh-" + id) != nil { app.closeRequest(req, id: "dsh-" + id) }
        case "host/session-status":
            guard asked, let isRunning = frame["running"] as? Bool else { return }
            if isRunning { finishGeneration += 1; running = true; idleHint = false; return }
            guard running || parser.started else { return }
            idleHint = true
            // 被停止时这个版本的 dsh 写不出 turn/end，才用短等待；正常双流允许迟到。
            scheduleFinishFallback()
        case "host/agent-error":
            let message = frame["message"] as? String ?? ""
            // 停止引出来的那条（turn/end 写不出去）不是真的出错
            if !message.contains("non-JSON-serializable") { agentError = message }
        case "_disconnected":
            dropped = true
            finish()
        default:
            break
        }
    }

    /// 它要做一件超出当前权限的事，来问。帧里只有工具名和原因，具体要做什么从对应的那一步里找。
    private func approval(_ frame: [String: Any]) {
        guard let approvalId = frame["approvalId"] as? String, let rpcId = frame["_rpcId"] as? String else { return }
        let tool = frame["toolName"] as? String ?? "tool"
        if pending.isAllowed(tool) {   // 这一轮里用户已经选过「都允许」
            let sid = self.sid, server = app.dshServer
            DispatchQueue.global().async { [weak self] in
                let outcome = self?.stopping == false ? "allowed-once" : "rejected"
                server.respond(rpcId: rpcId, value: ["sessionId": sid, "approvalId": approvalId, "outcome": outcome])
            }
            return
        }
        let rid = "dsh-" + approvalId
        pending.add(rid, ["rpcId": rpcId, "approvalId": approvalId, "tool": tool])
        let step = (frame["callId"] as? String).flatMap { builder.step($0) } ?? [:]
        var fields: [String: Any] = ["tool": tool, "title": step["title"] ?? "调用 \(tool)", "stepKind": step["kind"] ?? "tool"]
        let detail = [step["detail"] as? String, frame["reason"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !detail.isEmpty { fields["detail"] = detail }
        if let p = step["path"] { fields["path"] = p }
        app.sendRequest(req, id: rid, kind: "permission", fields)
    }

    // MARK: 网页发来的

    /// 中途补充一句：用它的插话模式（steer）发进去，它在下一步开始之前会看到，不用等这一轮结束。
    override func steer(_ text: String, images: [String], id: String) -> Bool {
        guard asked, !sid.isEmpty, !finished, !stopping, parser.ended == nil, running || parser.started else { return false }
        let rpc = dshSteerPrefix + id
        steers[rpc] = (id, text)
        let sid = self.sid
        let server = app.dshServer
        // HTTP 和附件读取都可能慢：登记后先还给主线程，等待期间不占这一轮的锁。
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            var blocks: [[String: Any]] = images.compactMap { path in
                self.app.attachmentData(path).flatMap { $0.base64.count < 6_000_000 ? ["type": "image", "mediaType": $0.mime, "data": $0.base64] : nil }
            }
            blocks.append(["type": "text", "text": text])
            server.sessionQueue(sid).sync {
                guard self.locked({ !self.stopping && !self.finished && self.steers[rpc] != nil }) else { return }
                let sent = server.call("session.prompt", ["sessionId": sid, "mode": "steer", "content": blocks], rpcId: rpc, timeout: 10)
                if self.cancelIfStopped() { return }
                self.locked {
                    // 事件可能比 HTTP 回包更早到；已结束或已消费的补充不能再退回 sent。
                    guard !self.stopping, !self.finished, self.steers[rpc] != nil else { return }
                    if sent.error == nil { self.noteSteer(id, "sent") }
                    else {
                        self.steers[rpc] = nil
                        self.noteSteer(id, "rejected")
                    }
                }
            }
        }
        return true
    }

    override func interrupt() {
        markStopping()
        if idleHint { scheduleFinishFallback() }
        let waiting = pending.drain()
        let sid = self.sid
        let server = app.dshServer
        waiting.forEach { app.closeRequest(req, id: $0.id) }
        DispatchQueue.global().async { [weak self] in
            for w in waiting {   // 等着用户决定的请求：告诉它不同意
                if let rpcId = w.info["rpcId"] as? String, let aid = w.info["approvalId"] as? String {
                    server.respond(rpcId: rpcId, value: ["sessionId": sid, "approvalId": aid, "outcome": "rejected"])
                }
            }
            if !sid.isEmpty { _ = server.call("session.cancel", ["sessionId": sid], timeout: 15) }
            // 停不下来（或者还没开始跑）也别让界面一直等
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { self?.locked { self?.finish() } }
        }
    }

    override func answer(_ requestId: String, _ body: [String: Any]) {
        guard let info = pending.take(requestId), let rpcId = info["rpcId"] as? String, let aid = info["approvalId"] as? String else { return }
        let outcome: String
        switch body["decision"] as? String ?? "deny" {
        case "allow":
            outcome = "allowed-once"
        case "allowAll":
            outcome = "allowed-once"
            pending.allowAll(info["tool"] as? String ?? "")   // 它没有「一直允许」：这一轮里同一种操作我们替用户答
        default:
            outcome = "rejected"
            refused += 1
        }
        let sid = self.sid, server = app.dshServer
        DispatchQueue.global().async { server.respond(rpcId: rpcId, value: ["sessionId": sid, "approvalId": aid, "outcome": outcome]) }
        app.closeRequest(req, id: requestId)
    }
}

extension AppDelegate {
    /// 给这个会话设好模型、思考强度和权限。和上次给它设的一样就不设（每设一次都是一次调用）。
    /// 注意：dsh 的「选模型」会顺手把它记成以后新会话的默认值（写进 ~/.dsh/settings.yaml）——它自带的界面也是这样，
    /// 在这里选了什么，等于在 dsh 里选了什么。
    @discardableResult
    func dshConfigure(_ sid: String, _ req: AskRequest, isNew: Bool, submit: () -> Void = {}) -> String? {
        dshServer.sessionQueue(sid).sync {
            let perm = ["read-only", "workspace-write", "danger-full-access"].contains(req.permissionMode) ? req.permissionMode : "danger-full-access"
            let effort = ["off", "low", "high", "max"].contains(req.effort) ? req.effort : ""
            let want = "\(req.model)|\(effort)|\(perm)"
            procLock.lock()
            let same = dshApplied[sid] == want
            let provider = dshProviders[req.model] ?? "deepseek-official"
            procLock.unlock()
            if !same {
                // 部分配置成功也不能保留旧缓存；队列保证成功发布前不会插入更新的配置。
                procLock.lock(); dshApplied[sid] = nil; procLock.unlock()
                if !req.model.isEmpty {
                    var p: [String: Any] = ["sessionId": sid, "provider": provider, "model": req.model]
                    if !effort.isEmpty { p["reasoningEffort"] = effort }
                    var r = dshServer.call("session.selectModel", p)
                    if r.error != nil, !effort.isEmpty {   // 这个模型不认这一档：不带强度再设一次（一直是这样，不算失败）
                        p["reasoningEffort"] = nil
                        r = dshServer.call("session.selectModel", p)
                    }
                    if let e = r.error { return "模型设置失败：\(e)" }
                }
                let permission = dshServer.call("commands/execute", ["agentId": sid, "line": "/permission \(perm)"], typert: true)
                if let e = permission.error { return "权限设置失败：\(e)" }
                procLock.lock(); dshApplied[sid] = want; procLock.unlock()
            }
            submit()
            return nil
        }
    }

}
