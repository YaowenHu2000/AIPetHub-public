// 向 Gemini 提问：先试交互式（GeminiLive.swift），用不了就退回 agy -p。
import Cocoa

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
        if let levels = efforts[id] { model["efforts"] = geminiEffortLevels.filter(levels.contains) }
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
        var args = ["-p", req.promptWithImagePaths, "--output-format", "stream-json", "--model", printModel, "--effort", effort]
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
        let res = runCLI(agent: req.key, executable: agy, arguments: args, cwd: workspace ?? home, onStdoutLine: { [weak self] line in
            if let obj = self?.jsonObject(line) { parser.feed(obj) }
            noteConversation(parser.conversationId)
        })
        if let e = res.launchError {
            return AgentReply(reply: "⚠️ 无法启动 agy：\(e)", conversationId: req.conversationId)
        }
        let convId = parser.conversationId.isEmpty ? req.conversationId : parser.conversationId
        var built = turn.finish(finalText: parser.response, outcome: res.cancelled ? "interrupted" : "completed")
        var reply = built["text"] as? String ?? ""
        if res.cancelled { return AgentReply(reply: reply, conversationId: convId, cancelled: true, turn: built) }
        // 做到一半出错（最常见的是连不上服务器、重试几次后放弃）：agy 给的 response 只是出错前最后一段中途说明，
        // 以前被当成正式回答，看起来像做到一半莫名其妙停了。做过的步骤（包括那段说明）留在工作过程里，
        // 正文换成出错提示：以 ⚠️ 开头，界面会给出「重试」。一步都没做就出错的（比如模型名不对）照旧走下面的 stderr。
        if let failure = parser.failure(exitStatus: res.status, stderr: res.err), !turn.steps.isEmpty {
            let notice = agyFailureNotice(failure)
            built = turn.finish(finalText: notice.text, outcome: "failed", error: notice.reason, includeEnding: !parser.abandonedRetry)
            return AgentReply(reply: built["text"] as? String ?? "", conversationId: convId, turn: built)
        }
        if reply.isEmpty && !parser.denied.isEmpty {
            reply = "⚠️ 当前权限模式不允许「\(parser.denied.joined(separator: "、"))」，没有产出回答。可以把权限切到「最高权限」再试。"
        }
        if reply.isEmpty && ((built["steps"] as? [Any]) ?? []).isEmpty { reply = fallbackReply(res, cli: "agy", preferStderr: true) }
        built["text"] = reply
        return AgentReply(reply: reply, conversationId: convId, turn: built)
    }
}
