// 向 Gemini 提问：找 agy、拼参数（agy -p 与 agy acp 的握手、开会话参数）、模型清单、预热；
// 交互式回答见 GeminiLive.swift，用不了退回 agy -p。拼参数和预热放在 *Run，和另外三位的分工一致。
//
// Gemini 单次模式在退出时收齐尚未推送的文字；若没有结果帧且步骤仍在运行，就按未完成收尾。
import Cocoa
import SQLite3

let geminiEffortLevels = ["low", "medium", "high", "xhigh", "max"]

/// 两种目录（agy models 和 ACP）使用同样的型号。只把 CLI 认识的强度后缀归到基础型号。
func geminiMenuModels(_ choices: [(String, String)]) -> [[String: Any]] {
    var order: [String] = [], names: [String: String] = [:], efforts: [String: Set<String>] = [:]
    for (raw, label) in choices {
        var id = raw, name = label
        if let level = geminiEffortLevels.first(where: { raw.hasSuffix("-" + $0) }) {
            id = String(raw.dropLast(level.count + 1))
            efforts[id, default: []].insert(level)
            if let paren = name.range(of: " (", options: .backwards), name.hasSuffix(")") { name = String(name[..<paren.lowerBound]) }
        }
        if names[id] == nil { names[id] = name; order.append(id) }
    }
    return order.map { id in
        var model: [String: Any] = ["v": id, "name": names[id] ?? id, "desc": ""]
        // 没有任何强度变体的型号（如三个 Orchestrator）只能按原始 ID 发，标成固定档：面板显示「模型默认」，不再补出拖了也不生效的三档。
        model["efforts"] = efforts[id].map { levels in geminiEffortLevels.filter(levels.contains) } ?? ["default"]
        return model
    }
}

extension AppDelegate {
    /// agy 在哪、这次用哪个模型（带思考强度后缀的全名）和思考强度。没装 agy 返回 nil。
    func geminiSetup(_ req: AskRequest) -> (agy: String, fullModel: String, effort: String)? {
        guard let agy = hooks.cliExecutable ?? findExecutable([
            "\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy",
            "/Applications/Antigravity.app/Contents/Resources/app/bin/agy"
        ]) else { return nil }
        let model = req.model.isEmpty ? "gemini-4-argon" : req.model
        let suffix = geminiEffortLevels.first { model.hasSuffix("-" + $0) }
        let effort = suffix ?? (model == "gpt-oss-120b" ? "medium" : (geminiEffortLevels.contains(req.effort) ? req.effort : "medium"))
        // agy 的模型名带思考强度后缀，例如 gemini-3.8-flash-low；GPT-OSS 只有 medium。
        let fullModel = suffix == nil ? "\(model)-\(effort)" : model
        return (agy, fullModel, effort)
    }

    func runGemini(_ req: AskRequest) -> AgentReply {
        if let reason = geminiDesktopSendBlock(req.conversationId) {
            return AgentReply(reply: reason, conversationId: req.conversationId)
        }
        guard let setup = geminiSetup(req) else {
            return AgentReply(reply: "⚠️ 没有找到 agy（Antigravity CLI）。", conversationId: req.conversationId)
        }
        let cid = req.conversationId
        if !cid.isEmpty {
            procLock.lock(); let acquired = geminiResuming.insert(cid).inserted; procLock.unlock()
            guard acquired else { return AgentReply(reply: "⚠️ 这个 Gemini 会话已有一轮正在发送，请等它结束后重试。", conversationId: cid) }
        }
        defer {
            if !cid.isEmpty { procLock.lock(); geminiResuming.remove(cid); procLock.unlock() }
        }
        // 先记提问在本库里的位置；同一句话可以连续问，退出后再按文字倒找会改错上一轮。
        var position = 0
        if !cid.isEmpty {
            var count: Int?
            _ = withReadableSQLite(geminiConversationDb(cid)) { db in
                queryRows(db, "SELECT COUNT(*) FROM steps WHERE step_type=14") { count = Int(sqlite3_column_int64($0, 0)) }
            }
            position = count ?? (readGeminiConversation(cid: cid)["messages"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "user" }.count
        }
        let result = sendGemini(req, setup: setup)
        rememberReplyEnding(req, result, position:position)
        return result
    }

    private func sendGemini(_ req: AskRequest, setup: (agy: String, fullModel: String, effort: String)) -> AgentReply {
        let cid = req.conversationId
        let agy = setup.agy, fullModel = setup.fullModel, effort = setup.effort
        // 交互式（用得了内置浏览器、能请它停、看得到思考、非最高权限时能来问）；这个版本的 agy 用不了 acp 时退回 agy -p
        if let reply = runLive({ GeminiLiveTurn(app: self, req: req, agy: agy, fullModel: fullModel) }, { $0.run() }) { return reply }

        // 当前 agy 的单次模式不接受 --app-data-dir，回退会把桌面会话送进 CLI 目录。
        if geminiStore(cid).desktop {
            let reason = geminiResumeBlock(cid) ?? "⚠️ agy 未能通过 ACP 恢复这个桌面会话，请稍后重试。"
            return AgentReply(reply: reason, conversationId: cid)
        }

        // 不支持 ACP 的旧版本也按 CLI 公布的原始 ID 发送；已查过菜单时复用那一份。
        procLock.lock(); let needCatalog = geminiModelIds.isEmpty; procLock.unlock()
        if needCatalog { _ = refreshGeminiModels(agy) }
        procLock.lock(); let ids = geminiModelIds; procLock.unlock()
        let printModel = ids.contains(req.model) && !ids.contains(fullModel) ? req.model : fullModel
        var oneShot = req
        oneShot.images = durableImagePaths(req.images)   // 历史里只剩提问中的路径
        var args = ["-p", oneShot.promptWithImagePaths, "--output-format", "stream-json", "--model", printModel, "--effort", effort]
        // 注意：--disable-slash-commands 会让 --mode 失效，所以只在最高权限时加上
        switch req.permissionMode {
        case "accept-edits", "plan":
            args += ["--mode", req.permissionMode]
        case "default":
            break
        default:
            args += ["--dangerously-skip-permissions", "--disable-slash-commands"]
        }
        if let reason = geminiResumeBlock(cid) { return AgentReply(reply: reason, conversationId: cid) }
        if !cid.isEmpty { args += ["--conversation", cid] }
        let workspace = validWorkspace(req.workspace)
        if let ws = workspace { args += ["--add-dir", ws] }

        let turn = turnBuilder(for: req)
        let parser = AgyStreamParser(turn: turn)
        let noteConversation = conversationWatcher(req)
        var marked = false
        let res = runCLI(agent: req.key, executable: agy, arguments: args, cwd: workspace ?? home, onStdoutLine: { [weak self] line in
            if let obj = self?.jsonObject(line) { parser.feed(obj) }
            if !marked, cid.isEmpty, !parser.conversationId.isEmpty {
                // App 回退到单次模式仍是用户发起的对话。
                UserDefaults.standard.set(true, forKey: "geminiPrintFromHub." + parser.conversationId)
                marked = true
            }
            noteConversation(parser.conversationId)
        })
        if let e = res.launchError {
            return AgentReply(reply: "⚠️ 无法启动 agy：\(e)", conversationId: req.conversationId)
        }
        let convId = parser.conversationId.isEmpty ? req.conversationId : parser.conversationId
        parser.finishStreamingText()
        // 旧版可以正常退出而没有 result；有未结束的流式步骤时，退出码不能证明回答已写完。
        let partial = parser.status == nil && turn.steps.contains { $0["status"] as? String == "running" }
        var built = turn.finish(finalText: parser.response, outcome: res.cancelled ? "interrupted" : (partial ? "incomplete" : "completed"))
        var reply = built["text"] as? String ?? ""
        if res.cancelled { return AgentReply(reply: reply, conversationId: convId, cancelled: true, turn: built) }
        // 做到一半出错（最常见的是连不上服务器、重试几次后放弃）：agy 给的 response 只是出错前最后一段中途说明，
        // 以前被当成正式回答，看起来像做到一半莫名其妙停了。做过的步骤（包括那段说明）留在工作过程里，
        // 正文换成出错提示：以 ⚠️ 开头，界面会给出「重试」。一步都没做就出错的（比如模型名不对）照旧走下面的 stderr。
        if let failure = parser.failure(exitStatus: res.status, stderr: res.err) {
            if turn.steps.isEmpty {
                let text = fallbackReply(res, cli: "agy", preferStderr: true)
                return AgentReply(reply: text, conversationId: convId, turn: turn.finish(finalText: text, outcome: "failed", error: failure))
            }
            let notice = agyFailureNotice(failure)
            built = turn.finish(finalText: notice.text, outcome: "failed", error: notice.reason, includeEnding: !parser.abandonedRetry)
            return AgentReply(reply: built["text"] as? String ?? "", conversationId: convId, turn: built)
        }
        if reply.isEmpty && !parser.denied.isEmpty {
            built["outcome"] = "failed"
            reply = "⚠️ 当前权限模式不允许「\(parser.denied.joined(separator: "、"))」，没有产出回答。可以把权限切到「最高权限」再试。"
        }
        if reply.isEmpty && ((built["steps"] as? [Any]) ?? []).isEmpty { reply = fallbackReply(res, cli: "agy", preferStderr: true) }
        built["text"] = reply
        return AgentReply(reply: reply, conversationId: convId, turn: built)
    }
}

extension AppDelegate {
    func acpInitialize() -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": 1,
            // 声明能填表单：agy 的 ask_question 才会发 elicitation/create 来问，否则它把问题写进正文就结束这一轮
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false, "elicitation": ["form": [String: Any]()]],
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
