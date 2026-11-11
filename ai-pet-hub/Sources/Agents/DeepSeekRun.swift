// 向 DeepSeek 提问：走 dsh 的本机服务（DeepSeekServer.swift），事件翻译成工作步骤（Parsing/DeepSeekEvents.swift）。
import Cocoa

extension AppDelegate {
    /// dsh 装在哪。它是个 npm 包，常见的几处都看一眼，没有再去登录 shell 的 PATH 里找。
    func dshExecutable() -> String? {
        findExecutable(["\(home)/.local/bin/dsh", "/opt/homebrew/bin/dsh", "/usr/local/bin/dsh"])   // 都没有时 findExecutable 会去登录 shell 的 PATH 里找
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
    private var agentError = ""
    private var dropped = false        // 服务断了
    private var refused = 0
    private let done = DispatchSemaphore(value: 0)
    private var finished = false
    private var steers: [String: (id: String, text: String)] = [:]   // 中途补充的话：调用编号 → 网页那边的编号和内容（它看到时按调用编号认）
    private var reopened = 0

    func run() -> AgentReply {
        app.registerLive(req.key, self)
        defer {
            app.unregisterLive(req.key)
            pending.takeAll().forEach { app.closeRequest(req, id: $0) }
        }
        if let err = app.dshReady() { return AgentReply(reply: "⚠️ \(err)", conversationId: req.conversationId) }
        let server = app.dshServer
        let cwd = app.validWorkspace(req.workspace) ?? app.home
        var isNew = false
        sid = req.conversationId
        if sid.isEmpty {
            let made = server.call("session.create", ["cwd": cwd])
            guard let id = (made.value as? [String: Any])?["sessionId"] as? String else {
                return AgentReply(reply: "⚠️ dsh 没能新建会话：\(made.error ?? "没有答复")", conversationId: "")
            }
            sid = id
            isNew = true
        }
        noteConversation(sid)
        let token = server.listen(sid) { [weak self] frame in self?.locked { self?.handle(frame) } }
        defer { server.unlisten(sid, token) }

        // 这个会话用哪个模型、多深的思考、什么权限：和上次给它设的一样就不用再设
        app.dshConfigure(sid, req, isNew: isNew)
        if stopping { return AgentReply(reply: "", conversationId: sid, cancelled: true) }   // 还没问就点了停止

        // 图片：小的直接作为图片交给它，放不进去的把路径写在话后面让它自己读
        var blocks: [[String: Any]] = [], asPaths: [String] = []
        for path in req.images {
            if let a = app.attachmentData(path), a.base64.count < 6_000_000 { blocks.append(["type": "image", "mediaType": a.mime, "data": a.base64]) }
            else { asPaths.append(path) }
        }
        blocks.append(["type": "text", "text": asPaths.isEmpty ? req.prompt : req.prompt + "\n\n" + asPaths.joined(separator: "\n")])
        locked { asked = true }
        var sent = server.call("session.prompt", ["sessionId": sid, "mode": "queue", "content": blocks])
        if sent.error != nil, blocks.count > 1 {   // 带图片被拒了：改成只发路径
            let text = req.prompt + "\n\n" + req.images.joined(separator: "\n")
            sent = server.call("session.prompt", ["sessionId": sid, "mode": "queue", "content": [["type": "text", "text": text]]])
        }
        if let e = sent.error {
            let hint = sent.code == "session-not-found" ? "这个会话在 dsh 里找不到了（可能已被删除）。" : ""
            return AgentReply(reply: "⚠️ 没能把话发给 DeepSeek：\(hint)\(e)", conversationId: sid)
        }

        // 等这一轮结束。服务要是自己退了（崩了、被结束）也别一直等
        while done.wait(timeout: .now() + 2) != .success {
            if !server.isRunning { locked { dropped = true }; break }
        }
        return locked { reply() }
    }

    private func reply() -> AgentReply {
        var built = builder.finish(finalText: parser.response)
        var text = built["text"] as? String ?? ""
        if stopping { return AgentReply(reply: text, conversationId: sid, cancelled: true, turn: built) }
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
            built = builder.finish(finalText: "⚠️ DeepSeek 中途出错，这次没有做完：\(p)\n\n会话和已经做完的步骤都还在：可以点「重试」，或者发一句「继续」让它接着做。")
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

    // MARK: 服务发来的（已经在锁里）

    private func handle(_ frame: [String: Any]) {
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
            // 上下文用了多少：模型面板里显示
            if frame["key"] as? String == "contextPressure", let v = frame["value"] as? [String: Any],
               let used = (v["pressureTokens"] as? NSNumber)?.intValue, let window = (v["contextWindow"] as? NSNumber)?.intValue {
                app.noteContext(agent: "deepseek", conversationId: sid, used: used, max: window)
            }
        case "approval/requested":
            approval(frame)
        case "approval/resolved":
            if let id = frame["approvalId"] as? String, pending.take("dsh-" + id) != nil { app.closeRequest(req, id: "dsh-" + id) }
        case "host/session-status":
            guard asked else { return }
            if frame["running"] as? Bool == true { running = true; return }
            guard running || parser.started else { return }
            // 不跑了。正常情况下 turn/end 会先到；被停止时它不会来（这个版本的 dsh 写不出那条记录），两条流之间也不保证先后——
            // 所以等一小会儿：turn/end 到了就按它算，没到就当这一轮到此为止
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.locked { self?.finish() } }
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
            app.dshServer.respond(rpcId: rpcId, value: ["sessionId": sid, "approvalId": approvalId, "outcome": "allowed-once"])
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
        var blocks: [[String: Any]] = images.compactMap { path in
            app.attachmentData(path).flatMap { $0.base64.count < 6_000_000 ? ["type": "image", "mediaType": $0.mime, "data": $0.base64] : nil }
        }
        blocks.append(["type": "text", "text": text])
        steers[rpc] = (id, text)
        let sent = app.dshServer.call("session.prompt", ["sessionId": sid, "mode": "steer", "content": blocks], rpcId: rpc, timeout: 10)
        guard sent.error == nil else { steers[rpc] = nil; return false }
        noteSteer(id, "sent")
        return true
    }

    override func interrupt() {
        markStopping()
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
    func dshConfigure(_ sid: String, _ req: AskRequest, isNew: Bool) {
        let perm = ["read-only", "workspace-write", "danger-full-access"].contains(req.permissionMode) ? req.permissionMode : "danger-full-access"
        let effort = ["off", "low", "high", "max"].contains(req.effort) ? req.effort : ""
        let want = "\(req.model)|\(effort)|\(perm)"
        procLock.lock()
        let same = dshApplied[sid] == want
        let provider = dshProviders[req.model] ?? "deepseek-official"
        procLock.unlock()
        if same { return }
        if !req.model.isEmpty {
            var p: [String: Any] = ["sessionId": sid, "provider": provider, "model": req.model]
            if !effort.isEmpty { p["reasoningEffort"] = effort }
            var r = dshServer.call("session.selectModel", p)
            if r.error != nil, !effort.isEmpty {   // 这个模型不认这一档：不带强度再设一次
                p["reasoningEffort"] = nil
                r = dshServer.call("session.selectModel", p)
            }
        }
        // 权限预设是一条斜杠命令（当成普通的话发过去会被直接交给模型，白花一轮）
        _ = dshServer.call("commands/execute", ["agentId": sid, "line": "/permission \(perm)"], typert: true)
        procLock.lock(); dshApplied[sid] = want; procLock.unlock()
    }

    // MARK: 历史会话

    /// 列出 dsh 里的会话。它一次给出所有目录的全部会话；没聊过的空会话不列。
    func listDeepSeek() {
        deepseekQueue.async { [self] in
            guard dshExecutable() != nil, dshReady() == nil,
                  let rows = (dshServer.call("session.list").value as? [String: Any])?["items"] as? [[String: Any]] else {
                sendToJS("onConversationsListed", ["agent": "deepseek", "items": [[String: Any]]()])
                return
            }
            var cwds: [String: String] = [:]
            let items: [[String: Any]] = rows.compactMap { r in
                guard let id = r["sessionId"] as? String, r["blank"] as? Bool != true else { return nil }
                let cwd = r["cwd"] as? String ?? ""
                cwds[id] = cwd
                let updated = Date(timeIntervalSince1970: ((r["updatedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000)
                let title = (((r["projections"] as? [String: Any])?["values"] as? [String: Any])?["title"] as? String) ?? ""
                return ["id": id, "title": titleFrom(title, fallbackId: id), "time": timeLabel(updated),
                        "timestamp": updated.timeIntervalSince1970, "cwd": cwd]
            }
            procLock.lock(); dshCwds = cwds; procLock.unlock()
            sendToJS("onConversationsListed", ["agent": "deepseek", "items": Array(items.prefix(historyListLimit))])
        }
    }

    /// 读一个会话的全部内容：它是从最后往前一页一页给的。
    func loadDeepSeek(cid: String) {
        deepseekQueue.async { [self] in
            var rows: [[String: Any]] = []
            var missing = false
            if dshReady() == nil {
                var before: Int?
                for _ in 0..<60 {   // 最多翻 60 页（一页 80 条消息）
                    var p: [String: Any] = ["sessionId": cid, "maxMessages": 80]
                    if let b = before { p["beforeSeq"] = b }
                    let r = dshServer.call("session.history", p, timeout: 90)
                    guard let v = r.value as? [String: Any], let page = v["events"] as? [[String: Any]] else {
                        if before == nil { missing = r.code == "session-not-found" }
                        break
                    }
                    rows = page + rows
                    guard v["hasMore"] as? Bool == true,
                          let first = ((page.first?["event"] as? [String: Any])?["seq"] as? NSNumber)?.intValue, first != before else { break }
                    before = first
                }
            }
            procLock.lock(); let cwd = dshCwds[cid] ?? ""; procLock.unlock()
            sendToJS("onConversationLoaded", recentHistory(dshTurns(rows), into: [
                "agent": "deepseek", "conversationId": cid, "cwd": cwd, "missing": missing
            ]))
        }
    }

    /// dsh 没有删除会话的接口：把这个会话在磁盘上的目录移到废纸篓（~/.dsh/sessions/<目录编码>/<会话编号>/）。
    /// 只认名字和会话编号完全一样的目录。
    func trashDeepSeek(cid: String) -> Bool {
        guard isSafeId(cid), cid.hasPrefix("session-") else { return false }
        let root = "\(home)/.dsh/sessions"
        var ok = false
        for group in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let dir = "\(root)/\(group)/\(cid)"
            if isDirectory(dir), fm.fileExists(atPath: "\(dir)/session.jsonl.zstd") || !((try? fm.contentsOfDirectory(atPath: dir)) ?? []).isEmpty {
                ok = trash(dir) || ok
            }
        }
        procLock.lock(); dshApplied[cid] = nil; dshCwds[cid] = nil; procLock.unlock()
        return ok
    }

    func deepseekIds(inWorkspace target: String) -> [String] {
        guard dshReady() == nil, let rows = (dshServer.call("session.list").value as? [String: Any])?["items"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard r["blank"] as? Bool != true, trimmedPath(r["cwd"] as? String ?? "") == target else { return nil }
            return r["sessionId"] as? String
        }
    }
}
