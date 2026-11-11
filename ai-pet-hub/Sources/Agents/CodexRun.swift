// 向 Codex 提问：先试交互式（CodexLive.swift），用不了就退回 codex exec。
import Cocoa

extension AppDelegate {
    /// codex 在哪、这次用的模型、思考强度、沙盒。没装 codex 返回 nil。
    func codexExecutable() -> String? {
        findExecutable([
            "\(home)/.local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ])
    }

    func codexSetup(_ req: AskRequest) -> (codex: String, model: String, effort: String, sandbox: String)? {
        guard let codex = codexExecutable() else { return nil }
        let model = req.model.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil ? req.model : "gpt-6-astra"
        let effort = ["low", "medium", "high", "xhigh", "ultra", "max"].contains(req.effort) ? req.effort : "high"
        // 「每次询问」（ask）只有交互式才做得到；退回 codex exec 时当作「仅工作空间可写」
        let sandbox = ["read-only", "workspace-write", "danger-full-access"].contains(req.permissionMode)
            ? req.permissionMode : (req.permissionMode == "ask" ? "workspace-write" : "danger-full-access")
        return (codex, model, effort, sandbox)
    }

    func runCodex(_ req: AskRequest) -> AgentReply {
        guard let setup = codexSetup(req) else {
            return AgentReply(reply: "⚠️ 没有找到 codex CLI。", conversationId: req.conversationId)
        }
        let codex = setup.codex, model = setup.model, effort = setup.effort, sandbox = setup.sandbox
        let workspace = validWorkspace(req.workspace)
        // 交互式（能审批、提问、中途补充，回答逐字出来）；这个版本的 codex 用不了 app-server 时退回 codex exec
        if let reply = CodexLiveTurn(app: self, req: req, codex: codex, model: model, effort: effort, sandbox: sandbox).run() { return reply }
        let resuming = !req.conversationId.isEmpty

        var args = ["exec"]
        if resuming { args.append("resume") }
        args += ["--json", "--skip-git-repo-check", "-m", model,
                 "-c", "model_reasoning_effort=\"\(effort)\"", "-c", "sandbox_mode=\"\(sandbox)\""]
        if !resuming, let ws = workspace { args += ["-C", ws] }
        args.append("--")
        if resuming { args.append(req.conversationId) }
        args.append(req.promptWithImagePaths)

        let turn = turnBuilder(for: req)
        let parser = CodexStreamParser(turn: turn)
        let noteConversation = conversationWatcher(req)
        let res = runCLI(agent: req.key, executable: codex, arguments: args, cwd: workspace ?? home, onStdoutLine: { [weak self] line in
            if let obj = self?.jsonObject(line) { parser.feed(obj) }
            noteConversation(parser.threadId)
        })
        if let e = res.launchError {
            return AgentReply(reply: "⚠️ 无法启动 codex：\(e)", conversationId: req.conversationId)
        }
        let convId = parser.threadId.isEmpty ? req.conversationId : parser.threadId
        var built = turn.finish(finalText: parser.lastAgentMessage)
        var reply = built["text"] as? String ?? ""
        if res.cancelled { return AgentReply(reply: reply, conversationId: convId, cancelled: true, turn: built) }
        if reply.isEmpty && !parser.errors.isEmpty { reply = "⚠️ Codex 出错：\n" + parser.errors.joined(separator: "\n") }
        if reply.isEmpty && ((built["steps"] as? [Any]) ?? []).isEmpty { reply = fallbackReply(res, cli: "Codex", preferStderr: true) }
        built["text"] = reply
        return AgentReply(reply: reply, conversationId: convId, turn: built)
    }
}
