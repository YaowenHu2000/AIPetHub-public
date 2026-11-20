// Codex 的交互式回答：`codex app-server`（JSON-RPC，一行一条），一次回答起一个进程：
// initialize → thread/start（或 thread/resume）→ turn/start → 一路通知 → turn/completed 后关掉输入让它退出。
// 相比 `codex exec`：能审批（命令 / 改文件 / MCP 工具）、能回答它提的问题、能中途补充（turn/steer）、能请它停（turn/interrupt），
// 回答文字是逐字给的，文件改动带 diff。
import Cocoa

/// 一次交互式回答。流程：initialize(1) → thread/start 或 thread/resume(2) → turn/start(3) → 一路通知 → turn/completed。
/// 预热进程的 stage 为 1 时，initialize 已完成。
final class CodexLiveTurn: LiveTurn {
    override var waitsForInitialization: Bool { true }
    private let codex: String
    private let model: String
    private let effort: String
    private let sandbox: String
    private lazy var parser = CodexAppParser(turn: builder)
    private var nextId = 10
    private var calls: [Int: String] = [:]        // 我们发出的请求：id → 用途
    private var steers: [(id: String, text: String, images: [String])] = []
    private var convertingSteers = 0               // 还在后台转图片的补充（steer）
    private let steerQueue = DispatchQueue(label: "aipethub.codex-steer-images")
    private var userSeen = 0
    private var failure: String?                   // 开场就失败（接不上会话等）
    private var gotResponse = false
    private var writerBusy = false                 // 会话的写锁在别的 Codex 客户端手里
    private var skillsQueried = false              // 这一轮已经查过技能（/技能名 提交前先查的）
    private var skillThread: String?               // /技能名 等技能清单时，查完要提交到的会话
    private var skillsCwd: String { app.validWorkspace(req.workspace) ?? app.home }
    private let retryQuietInterval: TimeInterval
    private let retryPollInterval: TimeInterval
    private let retryReader: (String, Date, pid_t?) -> CodexRetryRecord?
    private let retryQueue = DispatchQueue(label: "aipethub.codex-retry", qos: .utility)
    private var retryTimer: DispatchSourceTimer?
    private var retryGeneration = 0
    private var retrySince = Date()
    private var lastEventUptime = 0.0
    private var lastRetryID: Int64?
    private var retryFinished = false

    init(app: AppDelegate, req: AskRequest, codex: String, model: String, effort: String, sandbox: String,
         retryQuietInterval: TimeInterval = 20, retryPollInterval: TimeInterval = 10,
         retryReader: ((String, Date, pid_t?) -> CodexRetryRecord?)? = nil) {
        self.codex = codex
        self.model = model
        self.effort = effort
        self.sandbox = sandbox
        self.retryQuietInterval = retryQuietInterval
        self.retryPollInterval = retryPollInterval
        self.retryReader = retryReader ?? { app.codexLatestRetry(threadId: $0, since: $1, processID: $2) }
        super.init(app: app, req: req)
    }

    deinit { retryTimer?.cancel() }

    /// 只在已开始的回合里计静默时间。正常事件流只推迟 timer，不读日志。
    private func retryEventReceived() {
        retryGeneration += 1
        retrySince = Date()  // 恢复事件之后不再展示恢复之前的旧重试。
        lastEventUptime = ProcessInfo.processInfo.systemUptime
        guard !retryFinished, !stopping, parser.status == nil,
              !parser.threadId.isEmpty, !parser.turnId.isEmpty else {
            retryTimer?.cancel(); retryTimer = nil
            return
        }
        if retryTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: retryQueue)
            let read = retryReader
            timer.setEventHandler { [weak self] in
                guard let snapshot = self?.retrySnapshot() else { return }
                // 不持有这一轮的锁或 self；查询期间的停止、事件恢复都能立即生效。
                let record = read(snapshot.thread, snapshot.since, snapshot.pid)
                self?.locked {
                    guard let self = self, !self.retryFinished, !self.stopping,
                          self.retryGeneration == snapshot.generation,
                          let record = record, record.id != self.lastRetryID else { return }
                    self.lastRetryID = record.id
                    self.parser.noteRetry(record)
                }
            }
            timer.schedule(deadline: .now() + retryQuietInterval, repeating: retryPollInterval)
            retryTimer = timer
            timer.resume()
        } else {
            retryTimer?.schedule(deadline: .now() + retryQuietInterval, repeating: retryPollInterval)
        }
    }

    private func retrySnapshot() -> (thread: String, since: Date, pid: pid_t?, generation: Int)? {
        locked {
            guard !retryFinished, !stopping, parser.status == nil, retryTimer != nil,
                  ProcessInfo.processInfo.systemUptime - lastEventUptime >= retryQuietInterval else { return nil }
            return (parser.threadId, retrySince, app.runningPid(req.key), retryGeneration)
        }
    }

    private func stopRetryChecks() {
        locked {
            retryFinished = true
            retryGeneration += 1
            retryTimer?.cancel(); retryTimer = nil
        }
    }

    /// 返回 nil：这个版本的 codex 没有 app-server、或者它接不上这个会话，调用方退回 `codex exec`。
    func run() -> AgentReply? {
        parser.onUserMessage = { [weak self] _ in self?.userMessageSeen() }
        if warm == nil { input.send(app.codexInitialize) }
        let res = run(executable: codex, arguments: ["app-server"], cwd: app.validWorkspace(req.workspace) ?? app.home)
        stopRetryChecks()  // 进程退出（包括启动失败）也必须收掉；在 builder.finish 之前完成。
        if res.warmDied {
            return AgentReply(reply: app.fallbackReply(res, cli: "Codex"), conversationId: req.conversationId)
        }
        if let e = res.launchError {
            return AgentReply(reply: "⚠️ 无法启动 codex：\(e)", conversationId: req.conversationId)
        }
        // 提问还没送出：标成失败，网页留着这句供重试；提示只在正文里说一次，不再另列「出错」步骤。
        // Codex 的记录里没有这句，原话和附件退回原会话草稿，切走再回来、重开都还在
        if !res.cancelled, locked({ writerBusy }) {
            let text = "⚠️ 这个会话正在别的 Codex 客户端里打开。请先在那边关掉或切到别的会话，再重试发送。"
            var built = builder.finish(finalText: nil, outcome: "failed", includeEnding: false)
            built["text"] = text
            return AgentReply(reply: text, conversationId: req.conversationId, restoreDraft: true, turn: built)
        }
        // app-server 用不了（老版本没有这个子命令），或者接不上这个会话：还什么都没做，退回 codex exec
        let (failed, answered, submitted, timedOut) = locked { (failure, gotResponse, initialPromptSubmitted, initializationTimedOut) }
        if !res.cancelled, !submitted, timedOut || !answered || failed != nil {
            fputs("AIPetHub：Codex 交互式没成（\(failed ?? (timedOut ? "初始化阶段 300 秒没有推进" : "app-server 没有答复"))），退回 codex exec\n", stderr)
            return nil
        }
        // 已有会话的追问，turn/start 还没发出就停了：Codex 的记录里没有这一句，退回原会话草稿（新会话由网页退回）
        if res.cancelled, !req.conversationId.isEmpty, !submitted {
            return AgentReply(reply: unsentFollowUpReply, conversationId: req.conversationId, cancelled: true, restoreDraft: true)
        }
        return reply(res)
    }

    private func reply(_ res: CLIResult) -> AgentReply {
        let convId = parser.threadId.isEmpty ? req.conversationId : parser.threadId
        return app.codexReply(req, res:res, builder:builder, cid:convId, turnId:parser.turnId, status:parser.status,
                              text:parser.lastAgentMessage, partial:parser.unfinishedAgentMessage,
                              errors:parser.errors, compacted:parser.compacted)
    }

    /// 一句话：图片作为本机图片交给它（不是把路径写在话里）。
    private func userInput(_ text: String, images: [String]) -> [[String: Any]] {
        images.map { ["type": "localImage", "path": $0] } + [["type": "text", "text": text, "text_elements": [Any]()]]
    }

    @discardableResult
    private func call(_ method: String, _ params: [String: Any], tag: String) -> Bool {
        let id: Int = locked { nextId += 1; calls[nextId] = tag; return nextId }
        return input.send(["id": id, "method": method, "params": params])
    }

    // MARK: 网页发来的

    override func steer(_ text: String, images: [String], id: String) -> Bool {
        guard !parser.threadId.isEmpty, !parser.turnId.isEmpty, parser.status == nil else { return false }
        guard convertingSteers > 0 || !images.allSatisfy(app.codexReadsImage) else { return sendSteer(text, images: images, id: id) }
        // HEIC 等要先转成 JPEG，一张大照片要零点几秒，而这里在主线程上、拿着这一轮的锁：和 DeepSeek 一样放到后台转，转完再送。
        // 前面还有补充在转时，这一句也排进同一个队列，免得后发的先送进去
        convertingSteers += 1
        steerQueue.async { [weak self] in
            guard let self else { return }
            let usable = images.compactMap(self.app.codexImagePath)
            self.locked {
                self.convertingSteers -= 1
                // 转不了的图片不送进这一轮：退回排队，等这一轮结束再作为新提问发，那时 runCodex 会在发送前提示
                if usable.count < images.count || !self.sendSteer(text, images: usable, id: id) { self.noteSteer(id, "rejected") }
            }
        }
        return true
    }

    /// 把补充送进这一轮；这一轮已经结束、送不进去时返回 false（网页留着排队，等这一轮结束再发）。
    private func sendSteer(_ text: String, images: [String], id: String) -> Bool {
        guard !parser.threadId.isEmpty, !parser.turnId.isEmpty, parser.status == nil else { return false }
        locked { steers.append((id, text, images)) }
        guard call("turn/steer", ["threadId": parser.threadId, "expectedTurnId": parser.turnId, "input": userInput(text, images: images)], tag: "steer:\(id)") else {
            locked { steers.removeAll { $0.id == id } }
            return false
        }
        noteSteer(id, "sent")
        return true
    }

    override func interrupt() {
        markStopping()
        stopRetryChecks()
        cancelMCPElicitations { input.send(["id": $0["rpcId"] ?? NSNull(), "result": ["action": "cancel", "content": NSNull(), "_meta": NSNull()]]) }
        if parser.threadId.isEmpty || parser.turnId.isEmpty { input.close(); return }   // 回合还没开始：直接收
        call("turn/interrupt", ["threadId": parser.threadId, "turnId": parser.turnId], tag: "interrupt")
    }

    override func answer(_ requestId: String, _ body: [String: Any]) {
        guard let info = pending.take(requestId), let rpcId = info["rpcId"] else { return }
        let decision = body["decision"] as? String ?? "deny"
        switch info["kind"] as? String {
        case "question":
            // 网页按题目 id 交回答案（两题文字相同也不会串）；用户选了「不回答」就都留空。
            // 多选题网页用「、」连着，拆回一个个选项；整句就是一个选项时不拆（选项文字里本来就可能有「、」）
            var answers: [String: Any] = [:]
            let given = body["answers"] as? [String: Any] ?? [:]
            for q in info["questions"] as? [[String: Any]] ?? [] {
                guard let qid = q["id"] as? String else { continue }
                if decision != "deny", let parts = questionAnswerParts(body, qid) {
                    answers[qid] = ["answers": parts.selected + (parts.custom.isEmpty ? [] : [parts.custom])]
                    continue
                }
                let a = decision == "deny" ? "" : (given[qid] as? String ?? "")
                let labels = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                let parts = q["multiSelect"] as? Bool == true && !labels.contains(a) ? a.components(separatedBy: "、") : [a]
                answers[qid] = ["answers": parts.filter { !$0.isEmpty }]
            }
            input.send(["id": rpcId, "result": ["answers": answers]])
        case "mcpTool":
            // MCP 工具审批：「这一轮都允许」用 persist session（App 一个回合一个进程，就是这一轮）；不用 always，那会写进用户的配置
            if decision == "allowAll" { pending.allowAll("mcp") }
            let accept = decision == "allow" || decision == "allowAll"
            input.send(["id": rpcId, "result": ["action": accept ? "accept" : "decline", "content": accept ? [String: Any]() as Any : NSNull(),
                                                "_meta": decision == "allowAll" ? ["persist": "session"] as Any : NSNull()]])
        case "elicitation":
            let (action, content) = mcpElicitationResult(info, body)
            input.send(["id": rpcId, "result": ["action": action, "content": content.map { $0 as Any } ?? NSNull(), "_meta": NSNull()]])
        case "permissions":
            if decision == "allowAll" { pending.allowAll("permissions") }
            let granted = decision == "deny" ? [String: Any]() : info["permissions"] as? [String: Any] ?? [:]
            input.send(["id": rpcId, "result": ["permissions": granted, "scope": decision == "allowAll" ? "session" : "turn"]])
        default:
            if decision == "allowAll" { pending.allowAll(info["allowKey"] as? String ?? "") }
            input.send(["id": rpcId, "result": ["decision": decision == "allow" ? "accept" : (decision == "allowAll" ? "acceptForSession" : "decline")]])
        }
        app.closeRequest(req, id: requestId)
    }

    // MARK: app-server 发来的

    /// 预热只做到握手（stage 1），接手后在这里开会话。
    override func adopted() {
        guard let w = warm, w.stage >= 1 else { return }
        locked { gotResponse = true }
        initializationProgress("initialize")
        if w.stage == 1 { app.codexOpenThread(req, input, model: model, effort: effort, sandbox: sandbox) }
    }

    override func handle(line: String) {
        guard !initializationTimedOut else { return }
        guard let obj = app.jsonObject(line) else { return }
        defer { retryEventReceived() }
        if let method = obj["method"] as? String {
            let params = obj["params"] as? [String: Any] ?? [:]
            if let rpcId = obj["id"] { handleRequest(rpcId, method, params) } else { handleNotification(method, params) }
            return
        }
        // 我们的请求的答复
        guard let id = (obj["id"] as? NSNumber)?.intValue else { return }
        let tag: String = locked { gotResponse = true; return calls.removeValue(forKey: id) ?? "" }
        handleResponse(id, tag: tag, result: obj["result"] as? [String: Any] ?? [:],
                       error: (obj["error"] as? [String: Any])?["message"] as? String)
    }

    private func handleNotification(_ method: String, _ params: [String: Any]) {
        if method == "serverRequest/resolved", let r = params["requestId"] {   // 请求在别处了结了（比如被中断）
            if pending.take("codex-\(r)") != nil { app.closeRequest(req, id: "codex-\(r)") }
        }
        if method == "thread/tokenUsage/updated", let usage = params["tokenUsage"] as? [String: Any],
           let last = usage["last"] as? [String: Any], let max = (usage["modelContextWindow"] as? NSNumber)?.intValue, max > 0 {
            // 这个会话的上下文用了多少：最近一次请求带进去的加上它答出来的
            let n: (String) -> Int = { (last[$0] as? NSNumber)?.intValue ?? 0 }
            let (used, parts) = codexContextTokens(total: n("totalTokens"), input: n("inputTokens"),
                                                   cachedInput: n("cachedInputTokens"), output: n("outputTokens"))
            app.noteContext(agent: "gpt", conversationId: params["threadId"] as? String ?? parser.threadId, used: used, max: max, parts: parts)
        }
        parser.notify(method, params)
        noteConversation(parser.threadId)
        if method == "turn/completed" {   // 答完了：还挂着的 MCP 请求回 cancel，关掉输入，它自己退出
            stopRetryChecks()
            cancelMCPElicitations { input.send(["id": $0["rpcId"] ?? NSNull(), "result": ["action": "cancel", "content": NSNull(), "_meta": NSNull()]]) }
            input.close()
        }
    }

    /// 它要我们答复的请求：审批（命令 / 改文件 / MCP 工具 / 额外权限）、提问、MCP 服务器要用户输入；
    /// 别的说不支持（codex 当成拒绝，这一轮照常继续），并记一行日志，CLI 升级加了新回调时能发现。
    private func handleRequest(_ rpcId: Any, _ method: String, _ params: [String: Any]) {
        let rid = "codex-\(rpcId)"
        switch method {
        case "item/commandExecution/requestApproval":
            if autoAccept("command", rpcId) { return }
            pending.add(rid, ["rpcId": rpcId, "allowKey": "command"])
            var fields: [String: Any] = ["tool": "command", "title": "运行命令", "stepKind": "command",
                                         "detail": unwrapShell(params["command"] as? String ?? "")]
            if let reason = params["reason"] as? String, !reason.isEmpty { fields["title"] = "运行命令（\(clip(reason, 60))）" }
            app.sendRequest(req, id: rid, kind: "permission", fields)
        case "item/fileChange/requestApproval":
            if autoAccept("file", rpcId) { return }
            pending.add(rid, ["rpcId": rpcId, "allowKey": "file"])
            let list = parser.changes[params["itemId"] as? String ?? ""] ?? []
            var fields: [String: Any] = ["tool": "file", "stepKind": "edit",
                                         "title": list.count == 1 ? "修改 \(fileBaseName(list[0].path))" : "修改 \(list.count) 个文件"]
            if list.count == 1 { fields["path"] = list[0].path }
            let diff = list.map { (list.count > 1 ? "# \($0.path)\n" : "") + $0.diff }.joined(separator: "\n")
            if !trimmed(diff).isEmpty { fields["diff"] = clip(diff, 20_000) }
            app.sendRequest(req, id: rid, kind: "permission", fields)
        case "item/tool/requestUserInput":
            let questions = params["questions"] as? [[String: Any]] ?? []
            pending.add(rid, ["rpcId": rpcId, "kind": "question", "questions": questions])
            let shown = questions.map { q -> [String: Any] in
                ["id": q["id"] as? String ?? "", "question": q["question"] as? String ?? "", "header": q["header"] as? String ?? "",
                 "multiSelect": q["multiSelect"] as? Bool ?? false, "isOther": q["isOther"] as? Bool ?? true,
                 "isSecret": q["isSecret"] as? Bool ?? false, "options": q["options"] as? [[String: Any]] ?? []]
            }
            app.sendRequest(req, id: rid, kind: "question", ["questions": shown])
        case "mcpServer/elicitation/request":
            mcpElicitation(rpcId, params)
        case "item/permissions/requestApproval":
            // 原样给回它要的，去掉值为 null 的项（答复里这两项只能缺省、不能是 null）
            let granted = (params["permissions"] as? [String: Any] ?? [:]).filter { !($0.value is NSNull) }
            if pending.isAllowed("permissions") {
                input.send(["id": rpcId, "result": ["permissions": granted, "scope": "session"]])
                return
            }
            pending.add(rid, ["rpcId": rpcId, "kind": "permissions", "permissions": granted])
            var what: [String] = []
            if ((granted["network"] as? [String: Any])?["enabled"] as? Bool) == true { what.append("网络") }
            let fs = granted["fileSystem"] as? [String: Any] ?? [:]
            what += (fs["read"] as? [String] ?? []).map { "读 \($0)" } + (fs["write"] as? [String] ?? []).map { "写 \($0)" }
            var fields: [String: Any] = ["tool": "permissions", "stepKind": "tool", "title": "申请额外权限：" + (what.isEmpty ? "其他" : what.joined(separator: " / "))]
            if let reason = params["reason"] as? String, !reason.isEmpty { fields["detail"] = reason }
            app.sendRequest(req, id: rid, kind: "permission", fields)
        case "item/tool/call":
            // 动态工具：App 没有注册过，真来了也给一个能让它继续工作的结果，而不是报错
            input.send(["id": rpcId, "result": ["contentItems": [["type": "inputText", "text": "AIPetHub 没有这个工具"]], "success": false]])
        default:
            fputs("AIPetHub：Codex 发来不认识的请求 \(method)，回了不支持\n", stderr)
            input.send(["id": rpcId, "error": ["code": -32601, "message": "AIPetHub 不支持这个请求"]])
        }
    }

    /// MCP 的 elicitation。_meta.codex_approval_kind 为 mcp_tool_call 的是 codex 自己在「每次询问」下调 MCP 工具前的审批
    /// （App 的内置浏览器工具也走这条），用审批卡；其余是 MCP 服务器自己要用户输入，用提问卡 / 链接卡（MCPElicitation.swift）。
    private func mcpElicitation(_ rpcId: Any, _ params: [String: Any]) {
        let rid = "codex-\(rpcId)"
        let server = params["serverName"] as? String ?? "MCP"
        let meta = params["_meta"] as? [String: Any] ?? [:]
        if meta["codex_approval_kind"] as? String == "mcp_tool_call" {
            if pending.isAllowed("mcp") {
                input.send(["id": rpcId, "result": ["action": "accept", "content": [String: Any](), "_meta": ["persist": "session"]]])
                return
            }
            pending.add(rid, ["rpcId": rpcId, "kind": "mcpTool"])
            var fields: [String: Any] = ["tool": "mcp", "stepKind": "tool", "title": "运行 MCP 工具 \(server).\(meta["tool_name"] as? String ?? "")"]
            let detail = mcpToolParamsText(meta)
            if !detail.isEmpty { fields["detail"] = clip(detail, 20_000) }
            app.sendRequest(req, id: rid, kind: "permission", fields)
            return
        }
        let shown = showMCPElicitation(id: rid, info: ["rpcId": rpcId], server: server, mode: params["mode"] as? String ?? "",
                                       message: params["message"] as? String ?? "", schema: params["requestedSchema"] as? [String: Any],
                                       order: nil, url: params["url"] as? String)
        if !shown { input.send(["id": rpcId, "result": ["action": "decline", "content": NSNull(), "_meta": NSNull()]]) }
    }

    /// 这一轮里用户已经选过「都允许」的那一类操作：直接答应。
    private func autoAccept(_ kind: String, _ rpcId: Any) -> Bool {
        guard pending.isAllowed(kind) else { return false }
        input.send(["id": rpcId, "result": ["decision": "accept"]])
        return true
    }

    private func handleResponse(_ id: Int, tag: String, result: [String: Any], error: String?) {
        switch id {
        case 1:   // initialize
            if let e = error { fail(e); return }
            guard initializationProgress("initialize") else { return }
            app.codexInitialized(input)
            app.codexOpenThread(req, input, model: model, effort: effort, sandbox: sandbox)
        case 2:   // thread/start 或 thread/resume
            // 写锁在别的 Codex 客户端手里：App 自己的预热不再提前续接，上一轮的进程也在回复前就退出了，
            // 所以这只能是外部占用，重试和退回 codex exec resume 都拿不到锁，只会让用户白等。立即结束这一轮。
            if let e = error, e.contains("active writer") {
                locked { writerBusy = true }
                fail(e); return
            }
            guard error == nil, let tid = (result["thread"] as? [String: Any])?["id"] as? String, !tid.isEmpty else {
                fail(error ?? "没有拿到会话"); return
            }
            guard initializationProgress("thread") else { return }
            parser.threadId = tid
            noteConversation(tid)
            startTurn(threadId: tid)
        case 3:   // turn/start（或 /compact）
            if let e = error { parser.errors.append(codexReadableError(e)); input.close(); return }
            if let t = (result["turn"] as? [String: Any])?["id"] as? String, parser.turnId.isEmpty { parser.turnId = t }
            if stopping { call("turn/interrupt", ["threadId": parser.threadId, "turnId": parser.turnId], tag: "interrupt") }   // 回合开始前就点了停止
        case 8:   // model/list
            app.noteCodexModels(result)
        case 9:   // skills/list
            if error == nil { app.noteCodexSkills(result, cwd: skillsCwd, workspace: req.workspace) }
            // /技能名 在等这份清单：查到（或查失败）都接着提交，查失败就按普通文字发
            if let thread = locked({ () -> String? in defer { skillThread = nil }; return skillThread }) { startTurn(threadId: thread) }
        default:
            // 补充的话没送进去（这一轮刚好结束了之类）：告诉网页，留到这一轮结束后再发
            if tag.hasPrefix("steer:"), error != nil {
                let sid = String(tag.dropFirst(6))
                locked { steers.removeAll { $0.id == sid } }
                noteSteer(sid, "rejected")
            }
        }
    }

    private func fail(_ message: String) {
        locked { failure = message }
        input.close()
    }

    /// 会话接上了：发提问。/compact 是让它把前面的对话压缩成摘要；以 /技能名 开头是调用那个技能。
    private func startTurn(threadId: String) {
        let words = trimmed(req.prompt)
        if words == "/compact" {
            if !submitInitialPrompt({ input.send(["id": 3, "method": "thread/compact/start", "params": ["threadId": threadId]]) }) { input.close() }
            return
        }
        var items: [[String: Any]]
        let name = words.hasPrefix("/") ? words.dropFirst().split(separator: " ", maxSplits: 1).first.map(String.init) : nil
        let skills = app.codexSkills(in: skillsCwd)
        // 技能表按工作目录记：项目级技能可以同名，别的目录的表会发错路径。这个目录还没查过就先查再提交，普通提问不等。
        if name != nil, skills == nil, !skillsQueried {
            locked { skillsQueried = true; skillThread = threadId }
            input.send(["id": 9, "method": "skills/list", "params": ["cwds": [skillsCwd]]])
            return
        }
        if let name, let path = skills?[name] {
            items = req.images.map { ["type": "localImage", "path": $0] } + [["type": "skill", "name": name, "path": path]]
            let rest = trimmed(String(words.dropFirst(name.count + 1)))
            if !rest.isEmpty { items.append(["type": "text", "text": rest, "text_elements": [Any]()]) }
        } else {
            items = userInput(req.prompt, images: req.images)
        }
        if let note = app.codexBrowserNote(threadId: threadId, isNew: req.conversationId.isEmpty, on: app.browserMCP(req) != nil) {
            items.append(["type": "text", "text": note, "text_elements": [Any]()])
        }
        guard submitInitialPrompt({ input.send(["id": 3, "method": "turn/start", "params": ["threadId": threadId, "input": items]]) }) else {
            input.close(); return
        }
        // 顺便问一下它有哪些技能（输入框里打 / 时列出来）；提交前刚查过就不再问
        if !skillsQueried { input.send(["id": 9, "method": "skills/list", "params": ["cwds": [skillsCwd]]]) }
    }

    /// 用户的话轮到了：第一条是提问本身；之后每来一条，就是轮到了一句中途补充的话。
    private func userMessageSeen() {
        let steer: (id: String, text: String, images: [String])? = locked {
            userSeen += 1
            return userSeen > 1 && !steers.isEmpty ? steers.removeFirst() : nil
        }
        if let s = steer { noteSteerConsumed(s.id, text: s.text, images: s.images) }
    }
}
