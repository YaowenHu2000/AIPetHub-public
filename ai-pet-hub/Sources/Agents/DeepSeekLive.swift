// DeepSeek 的一次回答：没有自己的进程，事件从共用服务按会话分过来（DeepSeekServer.swift），翻译成工作步骤靠 Parsing/DeepSeekEvents.swift；
// 提问用自带的调用编号认出本轮，补充走 steer，停止走 session.cancel。
//
// DeepSeek Flash 拒收图片时，首问和补充共用 `submitImagePaths`。
// 实际传给模型的快照路径与按调用编号留给历史的文件内容一致，调用编号记录每个路径的 UTF-8 长度。
// 明确失败就清理本次副本，回执丢失仍保留，供后续核对服务是否已接手。
//
// DeepSeek 正文流单独重连时沿用状态流确认的运行状态，慢回合仍可停止。
//
// 取消回执和空闲状态都已确认时，重开按本次调用编号补回缺失的中断结局，后续回合仍按自己的事件判断。
// 服务确认已接手的回合停止后，界面立即收尾，即使原提问的 HTTP 回执仍在途中。
//
// 服务崩溃时按提问调用编号保存已显示的正文和退出原因，重开时只补到对应的未完成或中断回合。
//
// 提问用自己指定的调用编号（`aph-ask-` 开头）发，dsh 把它记在这句话的 `user/message` 里；新会话首问尚未提交就停止时，原文和附件退回新对话草稿；已有会话的追问同样退回原会话草稿。
// 已在 dsh 网页归档的会话不再续写，发送前拦下并退回原文和附件；归档时已经开始的回答照常收尾。
// 新会话的编号等 dsh 收下首问（回执成功、事件流里见到这句，或回执丢失、可能已收下）才告诉网页：首问被明确拒收时 dsh 不留这个空会话、
// 侧栏也不列，回复不带编号，网页按新对话把原文和附件退回原项目的草稿。
// 首次带图只在 dsh 明确拒绝图片输入时改发路径，回执中断就提示核对会话记录，存储错误保留原原因。
// 补充的回执中断时保留原编号等待消费事件，状态仍未知时提示核对历史。
// 回答看到它才开始算这一轮，排在前面的那一轮留给「在别处运行」的同步。
//
// 正文事件流重连后，在途提问按原调用编号回读历史，补齐本轮的正文和结局；若已空闲或后续回合已开始，却找不到本轮结束记录，则标为未完成。
import Cocoa

/// 提问（session.prompt 的 queue 模式）调用编号的开头。dsh 把它原样记在这句话的 user/message 里，回答时靠它认出本轮从哪开始。
let dshAskPrefix = "aph-ask-"

/// 一次回答。和另外三位的区别：没有「这一次回答的进程」，事件从共用的服务里按会话分过来。
final class DeepSeekLiveTurn: LiveTurn {
    private lazy var parser = DshParser(turn: builder)
    private var sid = ""
    // asked、own、finished、reply()、handle(_:) 不设 private：tools/tests/support.swift 的 receiveForTest 等要直接读写。
    var asked = false          // 提问已经送进去了（之前的运行状态变化不算这一轮的）
    private var running = false
    private var finishGeneration = 0
    /// 没点停止、又一直等不到 turn/end 时，安静多久才收尾（有事件进来就顺延）。测试里会调短，免得真等半分钟。
    var idleFallback: TimeInterval = 30
    private var idleHint = false
    private var agentError = ""
    private var streamGap = false
    private var serviceErrors: OutputBuffer?  // 重起服务后仍取本轮那一代的退出原因。
    private var dropped = false        // 服务断了
    private var refused = 0
    private let done = DispatchSemaphore(value: 0)
    private var cancelAcknowledged = false, savedStop = false
    var finished = false
    private var promptTask: URLSessionDataTask?
    // 回执未到或断开时，dsh 仍可能已执行指令；只有明确拒绝才允许网页重发。
    private var unconfirmedSteers = Set<String>()
    private var steers: [String: (id: String, text: String, images: [String])] = [:]   // 中途补充的话：调用编号 → 网页那边的编号和内容（它看到时按调用编号认）
    // 这句话可能排在 dsh 自己开的一轮（后台任务唤醒、子智能体回报）后面：那一轮的事件和 turn/end 不是这句话的回答。
    // 所以提问用自己指定的调用编号发，看到带着它的 user/message（dsh 先写 turn/start 再写这一句）才开始算这一轮；
    // 之前的留给「在别处运行」的同步（网页按历史显示）。
    private let ownRpc: String

    override init(app: AppDelegate, req: AskRequest) {
        // Flash 只收文字时，历史只剩拼好的正文。把附件字节长度记在原本就会落盘的调用编号中，
        // 重开可按原顺序还原路径，即使文件已移走或文件名含换行，也不把普通文字提及算作附件。
        let lengths = req.images.map { String($0.utf8.count) }.joined(separator: ".")
        ownRpc = dshAskPrefix + UUID().uuidString + (lengths.isEmpty ? "" : ":files:" + lengths)
        super.init(app: app, req: req)
    }
    var own = false
    private var heldStart: [String: Any]?
    private var continuationRpc: String?
    private var reopened = 0
    private var ctxUsed = 0, ctxMax = 0, ctxParts: [[String: Any]] = []   // 上下文用量：最近一次报的

    private func rejectsImage(code: String, message: String?) -> Bool {
        code == "attachment-error" && message?.contains("does not support image input") == true
    }

    private typealias PromptResult = (value:Any?, error:String?, code:String)

    /// 首问和补充的路径回退必须以同一批字节落盘。明确拒绝或中途停下就撤掉本次副本，
    /// 回执丢失时服务可能已经收下请求，后续打开历史仍要能按原调用编号找回。
    private func submitImagePaths(_ text: String, images: [String], rpc: String, submit: (String) -> PromptResult?) throws -> PromptResult? {
        var saved = [URL]()
        defer { saved.forEach { try? FileManager.default.removeItem(at:$0) } }
        for (index,path) in images.enumerated() {
            let key = String(rpc.prefix { $0 != ":" }) + "." + String(index)
            guard let url = dshFallbackImageURL(key) else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(), withIntermediateDirectories:true)
            saved.append(url)
            // 路径模式实际读取发送端冻结的文件。大图即便在被拒的图片块中已缩小，也要保留这份文件。
            try FileManager.default.copyItem(at:URL(fileURLWithPath:path),to:url)
        }
        let result = submit(text + "\n\n" + images.joined(separator:"\n"))
        if let result, result.error == nil || result.code == "transport" { saved.removeAll() }
        return result
    }

    func run(ready: (() -> String?)? = nil) -> AgentReply {
        var result = receiveReply(ready: ready)
        // 断线回读可能取到补充所在的末段；整轮的快照仍从最初被接手的提问算起。
        if locked({ own }) { result.turn?["turnKey"] = ownRpc }
        return result
    }

    private func receiveReply(ready: (() -> String?)?) -> AgentReply {
        app.registerLive(req.key, self)
        defer {
            app.unregisterLive(req.key)
            pending.takeAll().forEach { app.closeRequest(req, id: $0) }
        }
        if let err = (ready ?? app.dshReady)() { return AgentReply(reply: "⚠️ \(err)", conversationId: req.conversationId) }
        let server = app.dshServer
        serviceErrors = server.currentErrorOutput()
        let cwd = app.validWorkspace(req.workspace) ?? app.home
        var isNew = false
        // 不先挡住的话，设置模型这一步就会以「找不到会话」失败，提示成设置有问题
        if !req.conversationId.isEmpty, server.isDeleted(req.conversationId) {
            return AgentReply(reply: "⚠️ 这个会话已经删除了，不能接着问。请开新对话。", conversationId: req.conversationId)
        }
        // 在 dsh 网页归档了：列表已不列它，再续写的回答切走就找不到。dsh 还没收到这句，原话和附件退回草稿；已经开始的回答不受影响
        if !req.conversationId.isEmpty, DshServer.archivedSessionIds().contains(req.conversationId) {
            return AgentReply(reply: "⚠️ 这个会话已经在 dsh 网页归档了，不能接着问。原话和附件已退回输入框，可以开新对话再发。",
                              conversationId: req.conversationId, restoreDraft: true)
        }
        var target = req.conversationId
        if target.isEmpty {
            let made = server.call("session.create", ["cwd": cwd])
            guard let id = (made.value as? [String: Any])?["sessionId"] as? String else {
                return AgentReply(reply: "⚠️ dsh 没能新建会话：\(made.error ?? "没有答复")", conversationId: "")
            }
            target = id
            isNew = true
            app.hooks.dshSessionCreated?()
        }
        if let why = app.dshReloadIfChangedElsewhere(target, attaching: true, except: req.key) {
            return AgentReply(reply: "⚠️ \(why)", conversationId: target)
        }
        locked { sid = target }
        if !isNew { noteConversation(sid) }
        let token = server.listen(sid) { [weak self] frame in self?.locked { self?.handle(frame) } }
        defer { server.unlisten(sid, token) }

        // 读图放在事务外；真正提交前再检查停止，配置和提问则共用会话串行队列。
        var blocks: [[String: Any]] = [], asPaths: [String] = []
        for path in req.images {
            if let a = app.attachmentData(path), a.base64.count < 6_000_000 {
                blocks.append(["type": "image", "mediaType": a.mime, "data": a.base64])
            }
            else { asPaths.append(path) }
        }
        blocks.append(["type": "text", "text": asPaths.isEmpty ? req.prompt : req.prompt + "\n\n" + asPaths.joined(separator: "\n")])
        notePromptImages(blocks)
        var earlyReply: AgentReply?
        var submitted = false
        let error = app.dshConfigure(sid, req, isNew: isNew, onDefaultEffort: {
            self.locked { _ = self.builder.add(makeStep("tool", "本轮使用默认思考强度", detail: "dsh 未接受所选的思考强度，下一轮会重试。")) }
        }) {
            guard !self.stopping else { return }
            // /compact 不经过模型的一轮；停止后即使底层压缩成功也不能再报成功。
            if self.req.prompt.trimmingCharacters(in: .whitespacesAndNewlines) == "/compact" {
                submitted = true
                self.noteConversation(self.sid)
                defer {
                    let stopped = self.stopping
                    if stopped { earlyReply = AgentReply(reply:"压缩已停止。", conversationId:self.sid, cancelled:true, turn:["outcome":"interrupted"]) }
                    if let result = earlyReply { self.app.rememberReplyEnding(self.req, result) }
                }
                let r = server.call("commands/execute", ["agentId": self.sid, "line": "/compact"], typert: true, timeout: 300)
                if self.cancelIfStopped() { return }
                Thread.sleep(forTimeInterval: 1.2)   // 等它把压缩后的上下文用量报过来
                if self.cancelIfStopped() { return }
                earlyReply = self.locked {
                    if self.stopping { return AgentReply(reply: "", conversationId: self.sid, cancelled: true) }
                    if let e = r.error ?? dshCommandError(r.value) {
                        return AgentReply(reply: dshCompactReply(e, failed:true), conversationId: self.sid, turn: ["outcome":"failed"])
                    }
                    // 成功压成摘要时命令才会带回摘要事件序号；历史太短也会返回 success。
                    let result = (r.value as? [String: Any])?["result"] as? [String: Any]
                    return AgentReply(reply: dshCompactReply(r.value), conversationId: self.sid,
                                      turn: ["compacted": result?["sourceEventSeq"] is Int])
                }
                return
            }
            guard self.locked({ if self.stopping { return false }; self.asked = true; return true }) else { return }
            submitted = true
            let trackPrompt = { (task: URLSessionDataTask) in self.locked { self.promptTask = task } }
            defer { self.locked { self.promptTask = nil } }
            var sent = server.call("session.prompt", ["sessionId": self.sid, "mode": "queue", "content": blocks], rpcId: self.ownRpc, onTask: trackPrompt)
            if self.cancelIfStopped(prompt:true) { return }
            if blocks.count > 1, self.rejectsImage(code: sent.code, message: sent.error) {   // 带图片被拒了：改成只发路径（被拒的那次没进会话，编号照用）
                guard !self.stopping else { return }
                do {
                    guard let result = try self.submitImagePaths(self.req.prompt, images:self.req.images, rpc:self.ownRpc, submit:{ text in
                        guard !self.stopping else { return nil }
                        return server.call("session.prompt", ["sessionId":self.sid,"mode":"queue","content":[["type":"text","text":text]]],
                                           rpcId:self.ownRpc, onTask:trackPrompt)
                    }) else { return }
                    sent = result
                } catch {
                    earlyReply = AgentReply(reply:"⚠️ 无法保存当次图片：\(error.localizedDescription)", conversationId:isNew ? "" : self.sid, restoreDraft:!isNew)
                    return
                }
                if self.cancelIfStopped(prompt:true) { return }
            }
            if let e = sent.error {
                if sent.code == "transport" {
                    // 本次调用已在事件流中确认，继续从那里收尾，免得用户重复执行已接手的提问。
                    if self.locked({ self.own }) { return }
                    self.noteConversation(self.sid)
                    earlyReply = AgentReply(reply: "⚠️ 发送状态待确认，请查看会话记录。DeepSeek 回执中断：\(e)", conversationId: self.sid)
                    return
                }
                let hint = sent.code == "session-not-found" ? "这个会话在 dsh 里找不到了（可能已被删除）。" : ""
                // 明确拒收、事件流里也没见到这句：dsh 的记录里没有它，原话和附件退回草稿（新会话按新对话退回，已有会话退回原会话）
                let unsent = !self.locked({ self.own })
                earlyReply = AgentReply(reply: "⚠️ 没能把话发给 DeepSeek：\(hint)\(e)", conversationId: isNew && unsent ? "" : self.sid, restoreDraft: !isNew && unsent)
            } else { self.noteConversation(self.sid) }
        }
        if stopping {
            if let result = earlyReply, result.cancelled { return result }
            // dsh 不保存没有首问的空会话；保留新对话的草稿身份，用户切回来仍能重发。
            if isNew && !submitted {
                return AgentReply(reply: "首问还没发出，已退回草稿。", conversationId: "", cancelled: true, restoreDraft: true)
            }
            // 已有会话的追问没调 session.prompt 就停了：dsh 的记录里没有它，原话和附件退回原会话草稿
            if !submitted {
                return AgentReply(reply: unsentFollowUpReply, conversationId: sid, cancelled: true, restoreDraft: true)
            }
            if locked({ own && !finished }) { done.wait() }
            return locked { reply() }
        }
        // 设置没成就不会提问：已有会话的原话和附件退回原会话草稿；新会话还是空的，不带编号，网页按新对话退回
        if let e = error { return AgentReply(reply: "⚠️ 没能应用 DeepSeek 的设置：\(e) 请检查设置后重试。", conversationId: isNew ? "" : sid, restoreDraft: !isNew) }
        if let r = earlyReply { return r }

        // 等这一轮结束。服务要是自己退了（崩了、被结束）也别一直等
        while true {
            if done.wait(timeout: .now() + 2) != .success {
                if server.isRunning { continue }
                return locked { dropped = true; return reply() }
            }
            let state = locked { (recover: streamGap && !stopping && !dropped, finished: finished, rpc: continuationRpc ?? ownRpc) }
            if state.recover {
                // HTTP 在回答线程上读；另一条流仍可交审批、停止和空闲通知。
                let saved = app.dshRecoveredTurn(sid, rpc: state.rpc)
                if let result: AgentReply = locked({
                    if stopping { return reply() }
                    if let turn = saved.turn, saved.ended, steers.isEmpty, state.rpc == (continuationRpc ?? ownRpc) {
                        return AgentReply(reply: turn["text"] as? String ?? "", conversationId: sid, turn: turn)
                    }
                    guard state.finished || (saved.superseded && steers.isEmpty) else {
                        // 空闲帧本身也可能丢失；重连后仍无运行信号时，静默期满再核对一次历史。
                        if !running && !idleHint { idleHint = true; scheduleFinishFallback() }
                        app.hooks.dshGapChecked?()
                        return nil
                    }
                    let local = parser.finishedTurn()
                    var turn = saved.turn ?? local
                    let body = trimmed(local["text"] as? String), recorded = trimmed(turn["text"] as? String)
                    if recorded.isEmpty || body.hasPrefix(recorded) { turn["text"] = body }
                    turn["outcome"] = "incomplete"
                    let result = AgentReply(reply:turn["text"] as? String ?? "", conversationId:sid, turn:turn)
                    if own { app.rememberReplyEnding(req, result, rpc:state.rpc) }
                    return result
                }) { return result }
            } else if state.finished { return locked { reply() } }
        }
    }

    /// 请求可能在第一次 cancel 之后才被服务接收，回包后必须补停；调用者不持回合锁。
    @discardableResult
    private func cancelIfStopped(prompt: Bool = false) -> Bool {
        guard stopping else { return false }
        let id = locked { prompt && own && finished ? "" : sid }
        if !id.isEmpty { cancelSession(id) }
        return true
    }

    private func cancelSession(_ id: String) {
        let result = app.dshServer.call("session.cancel", ["sessionId": id], timeout: 15)
        if result.error == nil {
            locked {
                cancelAcknowledged = true
                if finished { rememberConfirmedStop() }
                app.hooks.dshCancelAcknowledged?()
            }
        }
    }

    private func scheduleFinishFallback() {
        finishGeneration += 1
        let generation = finishGeneration
        let expire = { [weak self] in
            self?.locked {
                guard let self = self, self.finishGeneration == generation, self.idleHint else { return }
                self.finish()
            }
        }
        let delay = stopping ? 1.5 : idleFallback
        if let schedule = app.hooks.dshIdleFinishScheduled { schedule(delay) { expire() }; return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { expire() }
    }

    func reply() -> AgentReply {
        var problem: String?
        if dropped {
            let detail = trimmed(serviceErrors?.string)
            problem = "dsh 的本机服务中途退出了。" + (detail.isEmpty ? "" : "\n" + DshServer.startupFailure(detail))
        } else if !agentError.isEmpty { problem = dshReadableError(agentError, code:"") }
        let built = parser.finishedTurn(stopped:stopping, problem:problem, refused:refused > 0)
        let result = AgentReply(reply:built["text"] as? String ?? "", conversationId:sid, cancelled:stopping, turn:built)
        if own && !stopping && parser.ended == nil && (dropped || finished) {
            app.rememberReplyEnding(req, result, reason:problem, rpc:continuationRpc ?? ownRpc)
        }
        return result
    }

    // 空闲和取消回执可按任一顺序到达。回执晚到只补历史，不拖住窗口的停止提示。
    private func rememberConfirmedStop() {
        guard !savedStop, stopping, own, cancelAcknowledged, idleHint, parser.ended == nil else { return }
        savedStop = true
        app.rememberReplyEnding(req, reply(), rpc:continuationRpc ?? ownRpc)
    }

    private func finish() {
        if finished { return }
        finished = true
        rememberConfirmedStop()
        // 事件流已经确认本轮被接手且结束；取消本次 HTTP 等待就能释放配置事务和界面。
        if stopping && own { promptTask?.cancel() }
        done.signal()
    }

    // MARK: 服务发来的（已经在锁里）

    func handle(_ frame: [String: Any]) {
        // 正常结束认 turn/end；idle 之后只要仍有事件，缺失 turn/end 的长兜底就顺延。
        if idleHint, !stopping { scheduleFinishFallback() }
        switch frame["type"] as? String {
        case "session/event":
            guard asked, let event = frame["event"] as? [String: Any] else { return }
            // 中途补充的话被它看到了（在下一步开始前插进去）：作为一步「你补充说」记进工作过程
            if event["type"] as? String == "user/message",
               let rpc = ((event["data"] as? [String: Any])?["source"] as? [String: Any])?["rpcId"] as? String, let s = steers.removeValue(forKey: rpc) {
                unconfirmedSteers.remove(rpc)
                if reopened > 0 { continuationRpc = rpc }
                noteSteerConsumed(s.id, text: s.text, images: s.images)
                return
            }
            if !own {
                switch event["type"] as? String {
                case "user/message":
                    guard ((event["data"] as? [String: Any])?["source"] as? [String: Any])?["rpcId"] as? String == ownRpc else { return }
                    own = true
                    noteConversation(sid)   // 新会话：dsh 已经记下首问，回执还在路上也先告诉网页编号
                    app.hooks.dshPromptConsumed?()
                    if let start = heldStart { parser.feed(start) }
                    heldStart = nil
                case "turn/start": heldStart = event
                case "turn/end": heldStart = nil
                default: break
                }
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
                        for (rpc, steer) in self.steers {
                            self.noteSteer(steer.id, self.unconfirmedSteers.contains(rpc) ? "uncertain" : "rejected")
                        }
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
        case "question/requested":
            // 模型调了 ask_user_question（或 exit_plan_mode 交计划）：不答它就一直等。用和 Claude / Codex 同一张提问卡（计划卡），
            // 答复时按这一帧的 rpcId 交回去（DeepSeekRequests.swift）
            guard frame["_rpcId"] is String, let id = dshRequestKey(frame) else { return }
            let card = dshCard(frame)
            pending.add(id, ["rpcId": frame["_rpcId"] ?? "", "kind": "question", "frame": frame, "card": card.fields, "cardKind": card.kind])
            app.sendRequest(req, id: id, kind: card.kind, card.fields)
        case "question/resolved":
            // 答掉了，或在别处（dsh 自带网页、停止）了结了：卡片撤掉
            if let id = frame["questionRpcId"] as? String, pending.take("dshq-" + id) != nil { app.closeRequest(req, id: "dshq-" + id) }
        case "host/session-status":
            guard asked, let isRunning = frame["running"] as? Bool else { return }
            if isRunning { finishGeneration += 1; running = true; idleHint = false; return }
            guard running || parser.started || streamGap else { return }
            idleHint = true
            // 被停止时这个版本的 dsh 写不出 turn/end，才用短等待；正常双流允许迟到。
            scheduleFinishFallback()
        case "host/agent-error":
            let message = frame["message"] as? String ?? ""
            // 停止引出来的那条（turn/end 写不出去）不是真的出错
            if !message.contains("non-JSON-serializable") { agentError = message }
        case "_streamGap":
            if asked { streamGap = true }   // 正文流断开时，独立状态流最后确认的运行状态仍有效。
        case "_streamReady":
            if asked {
                streamGap = true
                done.signal()
            }
        case "_disconnected":
            dropped = true
            finish()
        default:
            // dsh 要人答复的帧都叫 xxx/requested：认不出的记一行日志，dsh 升级加了新回调时能发现（不答它会一直等）
            if let type = frame["type"] as? String, type.hasSuffix("/requested") { fputs("AIPetHub：DeepSeek 发来不认识的请求 \(type)，没有答复\n", stderr) }
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
        let card = dshCard(frame, step: (frame["callId"] as? String).flatMap { builder.step($0) } ?? [:])
        pending.add(rid, ["rpcId": rpcId, "approvalId": approvalId, "tool": tool, "frame": frame, "card": card.fields, "cardKind": card.kind])
        app.sendRequest(req, id: rid, kind: card.kind, card.fields)
    }

    // MARK: 网页发来的

    /// 中途补充一句：用它的插话模式（steer）发进去，它在下一步开始之前会看到，不用等这一轮结束。
    override func steer(_ text: String, images: [String], id: String) -> Bool {
        guard asked, !sid.isEmpty, !finished, !stopping, parser.ended == nil, running || parser.started else { return false }
        let lengths = images.map { String($0.utf8.count) }.joined(separator: ".")
        let rpc = dshSteerPrefix + (images.isEmpty ? id : UUID().uuidString + ":files:" + lengths)
        steers[rpc] = (id, text, [])
        unconfirmedSteers.insert(rpc)
        let sid = self.sid
        let server = app.dshServer
        // HTTP 和附件读取都可能慢：登记后先还给主线程，等待期间不占这一轮的锁。
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            var attached: [String] = []
            var blocks: [[String: Any]] = images.compactMap { path in
                guard let image = self.app.attachmentData(path), image.base64.count < 6_000_000 else { return nil }
                attached.append(path)
                return ["type": "image", "mediaType": image.mime, "data": image.base64]
            }
            blocks.append(["type": "text", "text": text])
            server.sessionQueue(sid).sync {
                guard self.locked({ () -> Bool in
                    guard !self.stopping && !self.finished && self.steers[rpc] != nil else { return false }
                    self.steers[rpc] = (id, text, attached)
                    return true
                }) else { return }
                var sent = server.call("session.prompt", ["sessionId": sid, "mode": "steer", "content": blocks], rpcId: rpc, timeout: 10)
                if self.cancelIfStopped() { return }
                // 模型不收图片：和普通提问一样改发文字加路径，仍用这句补充的编号（它看到时靠编号认出来），不退回队列等下一轮
                if blocks.count > 1, self.rejectsImage(code: sent.code, message: sent.error) {
                    do {
                        guard let result = try self.submitImagePaths(text, images:images, rpc:rpc, submit:{ fallback in
                            guard self.locked({ () -> Bool in
                                guard !self.stopping && !self.finished && self.steers[rpc] != nil else { return false }
                                self.steers[rpc] = (id,text,images)
                                return true
                            }) else { return nil }
                            return server.call("session.prompt", ["sessionId":sid,"mode":"steer","content":[["type":"text","text":fallback]]],
                                               rpcId:rpc, timeout:10)
                        }) else { return }
                        sent = result
                    } catch {
                        self.locked {
                            self.steers[rpc] = nil
                            self.unconfirmedSteers.remove(rpc)
                            self.noteSteer(id, "rejected")
                        }
                        return
                    }
                    if self.cancelIfStopped() { return }
                }
                self.locked {
                    // 事件可能比 HTTP 回包更早到；已结束或已消费的补充不能再退回 sent。
                    guard !self.stopping, !self.finished, self.steers[rpc] != nil else { return }
                    if sent.code == "transport" {
                        self.noteSteer(id, "uncertain")
                        return
                    }
                    self.unconfirmedSteers.remove(rpc)
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
        DispatchQueue.global().async { [self] in
            for w in waiting {   // 等着用户决定的请求：审批告诉它不同意，提问（含计划评审）以 cancelled 作答
                guard let rpcId = w.info["rpcId"] as? String else { continue }
                if let aid = w.info["approvalId"] as? String {
                    server.respond(rpcId: rpcId, value: ["sessionId": sid, "approvalId": aid, "outcome": "rejected"])
                } else {
                    server.respond(rpcId: rpcId, result: dshCancelledResult)
                }
            }
            if !sid.isEmpty { cancelSession(sid) }
            // 停不下来（或者还没开始跑）也别让界面一直等
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { [weak self] in self?.locked { self?.finish() } }
        }
    }

    override func answer(_ requestId: String, _ body: [String: Any]) {
        guard let info = pending.take(requestId), let frame = info["frame"] as? [String: Any] else { return }
        if info["approvalId"] is String {
            switch body["decision"] as? String ?? "deny" {
            case "allow": break
            case "allowAll": pending.allowAll(info["tool"] as? String ?? "")   // 它没有「一直允许」：这一轮里同一种操作替用户答
            default: refused += 1
            }
        }
        let value = dshAnswerValue(frame, sid: sid, body)
        app.closeRequest(req, id: requestId)
        DispatchQueue.global().async { [weak self] in
            guard let self = self, let reason = self.app.dshDeliver(frame, value: value) else { return }
            // dsh 不收这个答复（请求还挂着）：卡片重新摆出来，用户换个答法。这一轮已经结束或在停就不摆了
            self.locked {
                guard !self.finished, !self.stopping, let waiting = self.app.dshServer.waitingRequest(requestId),
                      var fields = info["card"] as? [String: Any] else { return }
                fields["answerParts"] = waiting.frame["answerParts"]
                fields["message"] = reason
                self.pending.add(requestId, info)
                self.app.sendRequest(self.req, id: requestId, kind: info["cardKind"] as? String ?? "question", fields)
            }
        }
    }
}
