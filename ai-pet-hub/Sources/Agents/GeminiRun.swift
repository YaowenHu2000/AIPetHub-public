// 向 Gemini 提问：先试交互式（GeminiLive.swift），用不了就退回 agy -p。
import Cocoa

extension AppDelegate {
    /// agy 在哪、这次用哪个模型（带思考强度后缀的全名）和思考强度。没装 agy 返回 nil。
    func geminiSetup(_ req: AskRequest) -> (agy: String, fullModel: String, effort: String)? {
        guard let agy = findExecutable([
            "\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy",
            "/Applications/Antigravity.app/Contents/Resources/app/bin/agy"
        ]) else { return nil }
        let model = req.model.isEmpty ? "gemini-4-argon" : req.model
        let effort = ["low", "medium", "high"].contains(req.effort) ? req.effort : "medium"
        // agy 的模型名带思考强度后缀，例如 gemini-3.8-flash-low；GPT-OSS 只有 medium。
        let fullModel: String
        if model == "gpt-oss-120b" {
            fullModel = "gpt-oss-120b-medium"
        } else if model.hasSuffix("-low") || model.hasSuffix("-medium") || model.hasSuffix("-high") {
            fullModel = model
        } else {
            fullModel = "\(model)-\(effort)"
        }
        return (agy, fullModel, effort)
    }

    func runGemini(_ req: AskRequest) -> AgentReply {
        guard let setup = geminiSetup(req) else {
            return AgentReply(reply: "⚠️ 没有找到 agy（Antigravity CLI）。", conversationId: req.conversationId)
        }
        let agy = setup.agy, fullModel = setup.fullModel, effort = setup.effort
        // 交互式（用得了内置浏览器、能请它停、看得到思考、非最高权限时能来问）；这个版本的 agy 用不了 acp 时退回 agy -p
        if let reply = GeminiLiveTurn(app: self, req: req, agy: agy, fullModel: fullModel).run() { return reply }

        var args = ["-p", req.promptWithImagePaths, "--output-format", "stream-json", "--model", fullModel, "--effort", effort]
        // 注意：--disable-slash-commands 会让 --mode 失效，所以只在最高权限时加上
        switch req.permissionMode {
        case "accept-edits", "plan":
            args += ["--mode", req.permissionMode]
        case "default":
            break
        default:
            args += ["--dangerously-skip-permissions", "--disable-slash-commands"]
        }
        if !req.conversationId.isEmpty { args += ["--conversation", req.conversationId] }
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
        var built = turn.finish(finalText: parser.response)
        var reply = built["text"] as? String ?? ""
        if res.cancelled { return AgentReply(reply: reply, conversationId: convId, cancelled: true, turn: built) }
        // 做到一半出错（最常见的是连不上服务器、重试几次后放弃）：agy 给的 response 只是出错前最后一段中途说明，
        // 以前被当成正式回答，看起来像做到一半莫名其妙停了。做过的步骤（包括那段说明）留在工作过程里，
        // 正文换成出错提示：以 ⚠️ 开头，界面会给出「重试」。一步都没做就出错的（比如模型名不对）照旧走下面的 stderr。
        if let failure = parser.failure(exitStatus: res.status, stderr: res.err), !turn.steps.isEmpty {
            let reason = failure.contains("network issue") ? "网络连接出了问题（\(failure)）" : failure
            built = turn.finish(finalText: "⚠️ agy 中途出错，这次没有做完：\(reason)\n\n"
                                + "会话和已经做完的步骤都还在：可以点「重试」，或者发一句「继续」让它接着做。")
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
