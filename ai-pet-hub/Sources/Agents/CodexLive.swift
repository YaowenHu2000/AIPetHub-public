// Codex 的交互式回答：`codex app-server`（JSON-RPC，一行一条），一次回答起一个进程：
// initialize → thread/start（或 thread/resume）→ turn/start → 一路通知 → turn/completed 后关掉输入让它退出。
// 相比 `codex exec`：能审批（命令 / 改文件）、能回答它提的问题、能中途补充（turn/steer）、能请它停（turn/interrupt），
// 回答文字是逐字给的，文件改动带 diff。
import Cocoa

/// 应用自动附在用户的话后面的说明，都以它开头（读历史时从这里起去掉，不显示）。
let codexNoteMarker = "[AIPetHub 提示]"

extension AppDelegate {
    var codexInitialize: [String: Any] {
        ["id": 1, "method": "initialize",
         "params": ["clientInfo": ["name": "aipethub", "title": "AIPetHub", "version": "1.0"], "capabilities": NSNull()]]
    }

    /// skills/list 的答复：记下技能（名字 → 路径），并告诉网页（输入框里打 / 时列出来，连同我们替它接的 /compact）。
    func noteCodexSkills(_ result: [String: Any]) {
        var found: [(name: String, desc: String, path: String)] = []
        for entry in result["data"] as? [[String: Any]] ?? [] {
            for s in entry["skills"] as? [[String: Any]] ?? [] where (s["enabled"] as? Bool) != false {
                guard let name = s["name"] as? String, let path = s["path"] as? String, !found.contains(where: { $0.name == name }) else { continue }
                found.append((name, (s["shortDescription"] as? String) ?? (s["description"] as? String) ?? "", path))
            }
        }
        procLock.lock(); codexSkills = Dictionary(found.map { ($0.name, $0.path) }, uniquingKeysWith: { a, _ in a }); procLock.unlock()
        var list: [[String: String]] = [["name": "compact", "desc": "把前面的对话压缩成摘要，腾出上下文空间"]]
        list += found.map { ["name": $0.name, "desc": clip($0.desc.replacingOccurrences(of: "\n", with: " "), 80)] }
        sendToJS("onAgentCommands", ["agent": "gpt", "commands": list])
    }

    /// model/list 的答复：它现在能用的模型和各自支持的思考强度。
    func noteCodexModels(_ result: [String: Any]) {
        let models = (result["data"] as? [[String: Any]] ?? []).compactMap { m -> [String: Any]? in
            guard let id = (m["model"] as? String) ?? (m["id"] as? String), (m["hidden"] as? Bool) != true else { return nil }
            var item: [String: Any] = ["v": id, "name": m["displayName"] as? String ?? id, "desc": m["description"] as? String ?? ""]
            let efforts = (m["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
            if !efforts.isEmpty { item["efforts"] = efforts }
            if (m["isDefault"] as? Bool) == true { item["isDefault"] = true }
            // 有 Fast 档的模型（serviceTiers 里的 priority）：说明里写着快多少
            if let tier = (m["serviceTiers"] as? [[String: Any]] ?? []).first(where: { $0["id"] as? String == "priority" }) {
                item["fast"] = true
                if let d = tier["description"] as? String, !d.isEmpty { item["fastDesc"] = d }
            }
            return item
        }
        if !models.isEmpty { sendToJS("onAgentModels", ["agent": "gpt", "models": models]) }
    }

    func codexSkill(named name: String) -> (name: String, path: String)? {
        procLock.lock(); defer { procLock.unlock() }
        return codexSkills[name].map { (name, $0) }
    }

    /// initialize 答复之后：告诉它我们准备好了，顺便问它现在有哪些模型（模型菜单跟着它走）。
    func codexInitialized(_ input: LiveInput) {
        input.send(["method": "initialized"])
        input.send(["id": 8, "method": "model/list", "params": [String: Any]()])
    }

    /// 开会话（新建或接上已有的）：codexInitialized 之后发。
    func codexOpenThread(_ req: AskRequest, _ input: LiveInput, model: String, effort: String, sandbox: String) {
        let asking = req.permissionMode == "ask"
        var config: [String: Any] = ["model_reasoning_effort": effort]
        if let mcp = browserMCP(req) {   // 内置浏览器的工具（BrowserTools.swift）
            config["mcp_servers"] = ["aipethub_browser": ["command": mcp.command, "args": mcp.args]]
        }
        var p: [String: Any] = ["model": model, "sandbox": asking ? "workspace-write" : sandbox,
                                "approvalPolicy": asking ? "untrusted" : "never", "config": config]
        if let ws = validWorkspace(req.workspace) { p["cwd"] = ws }
        if req.fast { p["serviceTier"] = "priority" }   // Fast 档；不传就是默认档（会话不会记住上一次的）
        if req.conversationId.isEmpty {
            input.send(["id": 2, "method": "thread/start", "params": p])
        } else {
            p["threadId"] = req.conversationId
            input.send(["id": 2, "method": "thread/resume", "params": p])
        }
    }

    /// 接着聊一个已有的会话时，内置浏览器工具的开关和这个会话上一次不一样：给这一句附一段说明。
    /// 工具本身每一轮都按开关配好了（进程是新起的），但 Codex 只在会话开头看一次「有哪些工具」，之后不会自己再去查，
    /// 不说的话，后来打开它不知道有、后来关掉它还会去调。新会话不用说（开头它自己会看到）。
    func codexBrowserNote(threadId: String, isNew: Bool, on: Bool) -> String? {
        let key = "codexBrowserTools"
        var states = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        let before = states[threadId]
        guard before != on else { return nil }
        if states.count > 400 { states.removeAll() }   // 只是个小本子，记太多就清掉重记
        states[threadId] = on
        UserDefaults.standard.set(states, forKey: key)
        if isNew || (before == nil && !on) { return nil }
        return on
            ? "\(codexNoteMarker) 从这一句起可以用内置浏览器的工具（MCP 服务 aipethub_browser：browser_open、browser_screenshot、browser_console、browser_text、browser_eval）。工具列表里没有直接列出的话，在 exec 里用 tools.mcp__aipethub_browser__browser_open({url}) 这样调用。这段是应用自动加的，不用回应。"
            : "\(codexNoteMarker) 内置浏览器的工具（aipethub_browser）从这一句起关掉了，不要再调用。这段是应用自动加的，不用回应。"
    }

    /// 预热：起好 app-server、做完 initialize；接着的是已有会话就连会话也接上（新会话等真发话时再建，免得留下空会话）。
    func warmCodex(_ req: AskRequest) -> CLIProcess? {
        guard let setup = codexSetup(req) else { return nil }
        let cli = CLIProcess(input: LiveInput())
        cli.warmFilter = { [weak self, weak cli] line in
            guard let self = self, let cli = cli, let obj = self.jsonObject(line), obj["method"] == nil,
                  let id = (obj["id"] as? NSNumber)?.intValue else { return false }
            if id == 8 {   // 模型列表：预热时就告诉网页，不用等到真发话
                self.noteCodexModels(obj["result"] as? [String: Any] ?? [:])
                return true
            }
            guard id == 1, obj["error"] == nil, let input = cli.input else { return false }
            self.codexInitialized(input)
            if req.conversationId.isEmpty { cli.stage = 1 }
            else { self.codexOpenThread(req, input, model: setup.model, effort: setup.effort, sandbox: setup.sandbox); cli.stage = 2 }
            return true
        }
        guard (try? cli.start(executable: setup.codex, arguments: ["app-server"], cwd: validWorkspace(req.workspace) ?? home,
                              environment: cliEnvironment())) != nil else { return nil }
        cli.input?.send(codexInitialize)
        return cli
    }
}

/// 一次交互式回答。流程：initialize(1) → thread/start 或 thread/resume(2) → turn/start(3) → 一路通知 → turn/completed。
/// 预热过的进程可能已经做完前一两步（CLIProcess.stage：1 = initialize 做完，2 = 会话也在接了）。
final class CodexLiveTurn: LiveTurn {
    private let codex: String
    private let model: String
    private let effort: String
    private let sandbox: String
    private lazy var parser = CodexAppParser(turn: builder)
    private var nextId = 10
    private var calls: [Int: String] = [:]        // 我们发出的请求：id → 用途
    private var steers: [(id: String, text: String)] = []
    private var userSeen = 0
    private var failure: String?                   // 开场就失败（接不上会话等）
    private var gotResponse = false
    private var openRetries = 0                    // 会话被上一个进程占着时重接了几次

    init(app: AppDelegate, req: AskRequest, codex: String, model: String, effort: String, sandbox: String) {
        self.codex = codex
        self.model = model
        self.effort = effort
        self.sandbox = sandbox
        super.init(app: app, req: req)
    }

    /// 返回 nil：这个版本的 codex 没有 app-server、或者它接不上这个会话，调用方退回 `codex exec`。
    func run() -> AgentReply? {
        parser.onUserMessage = { [weak self] _ in self?.userMessageSeen() }
        if warm == nil { input.send(app.codexInitialize) }
        let res = run(executable: codex, arguments: ["app-server"], cwd: app.validWorkspace(req.workspace) ?? app.home)
        if let e = res.launchError {
            return AgentReply(reply: "⚠️ 无法启动 codex：\(e)", conversationId: req.conversationId)
        }
        // app-server 用不了（老版本没有这个子命令），或者接不上这个会话：还什么都没做，退回 codex exec
        let (failed, answered) = locked { (failure, gotResponse) }
        if !res.cancelled, !answered || failed != nil {
            fputs("AIPetHub：Codex 交互式没成（\(failed ?? "app-server 没有答复")），退回 codex exec\n", stderr)
            return nil
        }
        return reply(res)
    }

    private func reply(_ res: CLIResult) -> AgentReply {
        let convId = parser.threadId.isEmpty ? req.conversationId : parser.threadId
        var built = builder.finish(finalText: parser.lastAgentMessage)
        var reply = built["text"] as? String ?? ""
        if res.cancelled { return AgentReply(reply: reply, conversationId: convId, cancelled: true, turn: built) }
        if reply.isEmpty && !parser.errors.isEmpty { reply = "⚠️ Codex 出错：\n" + parser.errors.joined(separator: "\n") }
        if reply.isEmpty && parser.compacted { reply = "前面的对话已经压缩成摘要，腾出了上下文空间。" }
        if reply.isEmpty && ((built["steps"] as? [Any]) ?? []).isEmpty { reply = app.fallbackReply(res, cli: "Codex", preferStderr: true) }
        built["text"] = reply
        return AgentReply(reply: reply, conversationId: convId, turn: built)
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
        locked { steers.append((id, text)) }
        guard call("turn/steer", ["threadId": parser.threadId, "expectedTurnId": parser.turnId, "input": userInput(text, images: images)], tag: "steer:\(id)") else {
            locked { steers.removeAll { $0.id == id } }
            return false
        }
        noteSteer(id, "sent")
        return true
    }

    override func interrupt() {
        markStopping()
        if parser.threadId.isEmpty || parser.turnId.isEmpty { input.close(); return }   // 回合还没开始：直接收
        call("turn/interrupt", ["threadId": parser.threadId, "turnId": parser.turnId], tag: "interrupt")
    }

    override func answer(_ requestId: String, _ body: [String: Any]) {
        guard let info = pending.take(requestId), let rpcId = info["rpcId"] else { return }
        let decision = body["decision"] as? String ?? "deny"
        if info["kind"] as? String == "question" {
            // 回答按题目 ID 交回去；用户选了「不回答」就都留空
            var answers: [String: Any] = [:]
            let given = body["answers"] as? [String: Any] ?? [:]
            for q in info["questions"] as? [[String: Any]] ?? [] {
                guard let qid = q["id"] as? String else { continue }
                let a = decision == "deny" ? "" : (given[q["question"] as? String ?? ""] as? String ?? "")
                answers[qid] = ["answers": a.isEmpty ? [String]() : [a]]
            }
            input.send(["id": rpcId, "result": ["answers": answers]])
        } else {
            if decision == "allowAll" { pending.allowAll(info["allowKey"] as? String ?? "") }
            input.send(["id": rpcId, "result": ["decision": decision == "allow" ? "accept" : (decision == "allowAll" ? "acceptForSession" : "decline")]])
        }
        app.closeRequest(req, id: requestId)
    }

    // MARK: app-server 发来的

    /// 预热已经做完 initialize：新会话这时才建（已有会话预热时就接上了，答复还在路上或者存着）。
    override func adopted() {
        guard let w = warm, w.stage >= 1 else { return }
        locked { gotResponse = true }
        if w.stage == 1 { app.codexOpenThread(req, input, model: model, effort: effort, sandbox: sandbox) }
    }

    override func handle(line: String) {
        guard let obj = app.jsonObject(line) else { return }
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
            let used = n("totalTokens") > 0 ? n("totalTokens") : n("inputTokens") + n("outputTokens")
            app.noteContext(agent: "gpt", conversationId: params["threadId"] as? String ?? parser.threadId, used: used, max: max)
        }
        parser.notify(method, params)
        noteConversation(parser.threadId)
        if method == "turn/completed" { input.close() }   // 答完了：关掉输入，它自己退出
    }

    /// 它要我们答复的请求：审批（命令 / 改文件）、提问；别的一律说不支持。
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
                ["question": q["question"] as? String ?? "", "header": q["header"] as? String ?? "",
                 "multiSelect": false, "options": q["options"] as? [[String: Any]] ?? []]
            }
            app.sendRequest(req, id: rid, kind: "question", ["questions": shown])
        default:
            input.send(["id": rpcId, "error": ["code": -32601, "message": "AIPetHub 不支持这个请求"]])
        }
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
            app.codexInitialized(input)
            app.codexOpenThread(req, input, model: model, effort: effort, sandbox: sandbox)
        case 2:   // thread/start 或 thread/resume
            // 上一个进程（上一轮的、或者刚被换掉的预热进程）还没完全退出、还占着这个会话：等一下再接，不要因此退回 codex exec
            if let e = error, e.contains("active writer"), openRetries < 12 {
                openRetries += 1
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self = self else { return }
                    self.locked { self.app.codexOpenThread(self.req, self.input, model: self.model, effort: self.effort, sandbox: self.sandbox) }
                }
                return
            }
            guard error == nil, let tid = (result["thread"] as? [String: Any])?["id"] as? String, !tid.isEmpty else {
                fail(error ?? "没有拿到会话"); return
            }
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
            app.noteCodexSkills(result)
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
            input.send(["id": 3, "method": "thread/compact/start", "params": ["threadId": threadId]])
            return
        }
        var items: [[String: Any]]
        if words.hasPrefix("/"), let name = words.dropFirst().split(separator: " ", maxSplits: 1).first.map(String.init),
           let skill = app.codexSkill(named: name) {
            items = req.images.map { ["type": "localImage", "path": $0] } + [["type": "skill", "name": skill.name, "path": skill.path]]
            let rest = trimmed(String(words.dropFirst(name.count + 1)))
            if !rest.isEmpty { items.append(["type": "text", "text": rest, "text_elements": [Any]()]) }
        } else {
            items = userInput(req.prompt, images: req.images)
        }
        if let note = app.codexBrowserNote(threadId: threadId, isNew: req.conversationId.isEmpty, on: app.browserMCP(req) != nil) {
            items.append(["type": "text", "text": note, "text_elements": [Any]()])
        }
        input.send(["id": 3, "method": "turn/start", "params": ["threadId": threadId, "input": items]])
        // 顺便问一下它有哪些技能（输入框里打 / 时列出来）
        input.send(["id": 9, "method": "skills/list", "params": ["cwds": [app.validWorkspace(req.workspace) ?? app.home]]])
    }

    /// 用户的话轮到了：第一条是提问本身；之后每来一条，就是轮到了一句中途补充的话。
    private func userMessageSeen() {
        let steer: (id: String, text: String)? = locked {
            userSeen += 1
            return userSeen > 1 && !steers.isEmpty ? steers.removeFirst() : nil
        }
        if let s = steer { noteSteerConsumed(s.id, text: s.text) }
    }
}
