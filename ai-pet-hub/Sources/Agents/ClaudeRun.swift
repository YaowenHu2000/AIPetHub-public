// 向 Claude Code 提问：找到命令、拼参数、交互式回答（stream-json 双向）、预热；CLI 太旧时退回一问一答。
//
// Claude 立即排入提问，不走这项回退期限；其参数能力按可执行文件指纹缓存，包装器每次探测，CLI 升级后会刷新。
import Cocoa

/// 开场的 initialize 请求（预热时发，没预热就在提问前发）：答复里带着命令和模型列表。
let claudeInitializeId = "aipethub-init"
let claudeContextId = "aipethub-context"
let claudeInitializeRequest: [String: Any] = ["type": "control_request", "request_id": claudeInitializeId, "request": ["subtype": "initialize"]]

extension AppDelegate {
    /// 用哪个命令跑 Claude Code。装了 reclaude 就只用它（`reclaude cli …`），和以前完全一样；
    /// 没装才找标准的 `claude`（别人克隆下来也能用），这时历史会话读 ~/.claude/projects。
    func claudeCommand() -> (executable: String, prefix: [String], reclaude: Bool)? {
        if let path = hooks.cliExecutable { return (path, [], false) }
        // 指定用哪个 claude（测试标准 claude 的路径时用；平时不用设）
        if let forced = ProcessInfo.processInfo.environment["AIPETHUB_CLAUDE"], fm.isExecutableFile(atPath: forced) { return (forced, [], false) }
        if let r = findExecutable(["\(home)/.local/bin/reclaude"]) { return (r, ["cli"], true) }
        if let c = findExecutable(["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                                   "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]) { return (c, [], false) }
        return nil
    }

    /// 选项值 → claude CLI 的 --model 参数（沿用原 Claude娘 的映射）。
    func claudeCliModel(_ model: String) -> String {
        switch model {
        case "", "claude-opus-5-5", "claude-opus-5-5[1m]": return "opus"
        case "claude-fable-5-1[1m]", "claude-fable-5[1m]": return "fable"
        case "claude-sonnet-5-5", "claude-sonnet-5-5[1m]": return "sonnet"
        default: return model
        }
    }

    /// 升级既可能覆盖原文件，也可能把同一个链接切到新版本；两种情况都要重新探测能力。
    func claudePartialCacheKey(_ executable: String) -> String? {
        let path = (executable as NSString).resolvingSymlinksInPath
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date, let size = attrs[.size] as? NSNumber else { return nil }
        return "\(path)\u{0}\(modified.timeIntervalSince1970)\u{0}\(size)\u{0}\(attrs[.systemFileNumber] ?? "")"
    }

    func claudeSupportsPartial(_ executable: String, prefix: [String]) -> Bool {
        // reclaude 等包装器的文件不变，底层 CLI 也可能升级；不根据包装器时间猜它的能力。
        let key = prefix.isEmpty ? claudePartialCacheKey(executable) : nil
        if let key = key {
            procLock.lock()
            if let known = partialSupport[key] { procLock.unlock(); return known }
            procLock.unlock()
        }
        let res = runTool(executable, prefix + ["--help"], cwd: home,
                          environment: ProcessInfo.processInfo.environment, timeout: 15)
        guard res.status == 0, !trimmed(res.out).isEmpty else { return false }
        let ok = res.out.contains("--include-partial-messages")
        if let key = key {
            procLock.lock()
            partialSupport[key] = ok
            procLock.unlock()
        }
        return ok
    }

    func runClaude(_ req: AskRequest) -> AgentReply {
        // 装了 reclaude 就一直走 reclaude（含续接历史会话），不回落到 ~/.claude-pro 的 claude；没装 reclaude 才用标准的 claude。
        guard let cmd = claudeCommand() else {
            return AgentReply(reply: "⚠️ 没有找到 Claude Code（claude 命令）。用 npm install -g @anthropic-ai/claude-code 装好、在终端运行 claude 登录后再试。", conversationId: req.conversationId)
        }
        // 这个会话正开在别的程序里（Claude 桌面端、终端）：不往同一个会话里再塞一个副本，分叉出一个新会话来答
        var req = req
        var unavailable = false
        if !req.conversationId.isEmpty, let live = claudeLiveElsewhere(req.conversationId, fresh: true, unavailable: { unavailable = true }) {
            req.fork = true
            let from = req.conversationId, reqId = req.reqId
            DispatchQueue.main.async {
                self.sendToJS("onAgentForked", ["agent": "claude", "reqId": reqId, "from": from, "status": live.status, "name": live.name])
            }
        }
        if unavailable {
            // 还没起 CLI，这句不在会话记录里：原话和附件退回原会话草稿，切走再回来、重开都还在
            return AgentReply(reply: "⚠️ 无法确认这个 Claude 会话是否在别处打开，请稍后重试。", conversationId: req.conversationId, restoreDraft: true)
        }
        // 交互式（能审批、提问、中途补充）；这个版本的 CLI 不认交互式的参数时，退回一问一答
        let journal: FileHandle? = req.conversationId.isEmpty || req.fork ? nil : claudeQueue.sync {
            findClaudeSession(cid: req.conversationId).flatMap(FileHandle.init(forReadingAtPath:))
        }
        defer { journal?.closeFile() }
        journal?.seekToEndOfFile()
        var result = runLive({ ClaudeLiveTurn(app: self, req: req, command: cmd) }) { $0.run() } ?? runClaudeOneShot(req, cmd)
        let appended = journal?.readDataToEndOfFile() ?? Data()
        // 停止时退回草稿的前提是这句没进会话记录：记录里多了 user 行（或者找不到记录没法确认），重开会看到它，不能再退回一份
        if result.cancelled, result.restoreDraft, journal == nil || appended.range(of: Data("\"type\":\"user\"".utf8)) != nil {
            result.restoreDraft = false
            result.reply = ""
        }
        if !appended.isEmpty {
            let notes = claudeBranchNotes(appended, ids: claudeSideBranch(appended))
            if !notes.isEmpty {
                var turn = result.turn ?? ["text":result.reply]
                turn["steps"] = (turn["steps"] as? [[String:Any]] ?? []) + [claudeBranchStep(notes.map(\.text))]
                result.turn = turn
            }
        }
        return result
    }

    func claudeArgs(_ req: AskRequest, _ cmd: (executable: String, prefix: [String], reclaude: Bool), live: Bool) -> [String] {
        var args: [String] = cmd.prefix
        // ultracode：Claude Code 的最高档（/effort ultracode）——思考强度 xhigh，再加上多智能体编排，很费用量
        let effort = ["low", "medium", "high", "xhigh", "max", "ultracode"].contains(req.effort) ? req.effort : "medium"
        let perm = ["acceptEdits", "auto", "plan", "bypassPermissions", "manual"].contains(req.permissionMode)
            ? req.permissionMode : "bypassPermissions"
        args += ["-p", "--output-format", "stream-json", "--verbose"]
        if live { args += ["--input-format", "stream-json", "--replay-user-messages", "--permission-prompt-tool", "stdio"] }
        if claudeSupportsPartial(cmd.executable, prefix: cmd.prefix) { args.append("--include-partial-messages") }   // 回答文字流式输出
        args += ["--model", claudeCliModel(req.model), "--effort", effort,
                 "--permission-mode", perm]
        // 计划卡的「批准，直接做完」要在回答中途切到 bypassPermissions；CLI 只在启动时允许过才肯切（否则回 bypass_not_launched）。
        // 这个参数只放开切换，不改变计划模式本身：计划卡照样先出现
        if live && perm == "plan" { args.append("--allow-dangerously-skip-permissions") }
        if req.fast { args += ["--settings", #"{"fastMode":true}"#] }   // fast 模式：只管这一次，不写进它的设置文件
        if !req.conversationId.isEmpty {
            let firstFailed = localEndings(agent:"claude", cid:req.conversationId).last?["newWorkspace"] != nil
            if !firstFailed || claudeQueue.sync(execute: { findClaudeSession(cid:req.conversationId) != nil }) {
                args += ["--resume", req.conversationId] + (req.fork ? ["--fork-session"] : [])
            }
        }
        if let ws = validWorkspace(req.workspace) { args += ["--add-dir", ws] }
        // 内置浏览器的工具（BrowserTools.swift）：在用户自己配的 MCP 之外再加这一个
        if let mcp = browserMCP(req),
           let cfg = try? JSONSerialization.data(withJSONObject: ["mcpServers": ["aipethub-browser": ["command": mcp.command, "args": mcp.args]]]) {
            args += ["--mcp-config", String(decoding: cfg, as: UTF8.self)]
        }
        if !live { args += ["--", req.promptWithImagePaths] }
        return args
    }

    /// initialize 的答复：CLI 认得的斜杠命令（带说明）和它现在能用的模型——模型菜单跟着它走，CLI 升级后有了新模型不用改 App。
    /// complete：这份模型列表是完整的（Usage.swift 在临时目录里起的进程报的）。拿到过完整的以后，提问 / 预热的进程报的就不再用：
    /// 它在主目录下启动时只报 5 个，会把菜单里的旧版本冲掉。
    func noteClaudeInitialize(_ obj: [String: Any], complete: Bool = false) {
        let info = (obj["response"] as? [String: Any])?["response"] as? [String: Any] ?? [:]
        noteClaudeCommands((info["commands"] as? [[String: Any]] ?? []).compactMap { c in
            (c["name"] as? String).map { ["name": $0, "desc": c["description"] as? String ?? ""] }
        })
        let models = (info["models"] as? [[String: Any]] ?? []).compactMap { m -> [String: Any]? in
            guard let value = m["value"] as? String, !value.isEmpty else { return nil }
            var name = m["displayName"] as? String ?? value
            var desc = m["description"] as? String ?? ""
            // 有时名字只报「Opus」，版本号写在说明的开头（「Opus 5.5 · Best for …」）：名字用带版本号的那一段
            if let dot = desc.range(of: " · "), desc.hasPrefix(name + " ") {
                name = String(desc[..<dot.lowerBound])
                desc = String(desc[dot.upperBound...])
            }
            if value == "default" {   // 说明里写着它现在指向哪个模型（「Opus 5.5 · Best for …」）：只留模型名
                name = "默认（\(desc.components(separatedBy: " · ").first ?? desc)）"
                desc = "跟着 Claude Code 的默认模型走"
            }
            var item: [String: Any] = ["v": value, "name": name, "desc": desc]
            if let efforts = m["supportedEffortLevels"] as? [String], (m["supportsEffort"] as? Bool) != false {
                // CLI 报的档位里不含 ultracode（它是 xhigh 之上的一个开关）：有 xhigh 的模型都能开
                item["efforts"] = efforts.contains("xhigh") ? efforts + ["ultracode"] : efforts
            }
            if (m["supportsFastMode"] as? Bool) == true { item["fast"] = true }
            return item
        }
        procLock.lock()
        if complete { claudeModelsComplete = true }
        let skip = !complete && claudeModelsComplete
        procLock.unlock()
        if !models.isEmpty && !skip { sendToJS("onAgentModels", ["agent": "claude", "models": models, "complete": complete]) }
    }

    /// 把 CLI 认得的斜杠命令告诉网页（输入框里打 / 时列出来）。
    func noteClaudeCommands(_ list: [[String: String]]) {
        if !list.isEmpty { sendToJS("onAgentCommands", ["agent": "claude", "commands": list]) }
    }

    /// 预热：起好进程，先做 initialize（读配置、列出命令这些它平时等到第一句话才做的事）。
    func warmClaude(_ req: AskRequest) -> CLIProcess? {
        // --resume 会占用会话并固定上下文，发送前终端仍可能续写。
        guard req.conversationId.isEmpty, let cmd = claudeCommand() else { return nil }
        let cli = CLIProcess(input: LiveInput())
        cli.warmFilter = { [weak self] line in
            guard line.contains(claudeInitializeId), let brace = line.firstIndex(of: "{"), let obj = self?.jsonObject(line[brace...]),
                  obj["type"] as? String == "control_response" else { return false }
            self?.noteClaudeInitialize(obj)
            return true
        }
        guard (try? cli.start(executable: cmd.executable, arguments: claudeArgs(req, cmd, live: true),
                              cwd: validWorkspace(req.workspace) ?? home, environment: cliEnvironment(claudeEntrypointEnv))) != nil else { cli.input?.abandon(); return nil }
        cli.input?.send(claudeInitializeRequest)
        return cli
    }

    func claudeReply(_ req: AskRequest, res: CLIResult, parser: ClaudeStreamParser, turn: TurnBuilder) -> AgentReply {
        let convId = parser.sessionId.isEmpty ? req.conversationId : parser.sessionId
        let failedExit = !parser.completed && res.status != 0
        let outcome = res.cancelled ? "interrupted" : (failedExit || parser.isError || parser.outputLimited ? "failed" : (parser.completed || parser.compactNote != nil ? "completed" : "incomplete"))
        let error = parser.outputLimited ? outputLimitHint : failedExit ? "⚠️ Claude Code 出错（退出码 \(res.status)）：\n" + (trimmed(res.err).isEmpty ? "进程在本轮完成前退出了。" : String(trimmed(res.err).suffix(1500)))
            : (parser.isError ? (parser.result ?? parser.subtype) : nil)
        // 压缩上下文的那一轮没有回答正文：结果那句话就是回答
        let finalText = (parser.result ?? "").isEmpty ? (parser.compactNote ?? parser.result) : parser.result
        var built = turn.finish(finalText: res.cancelled && (finalText ?? "").hasPrefix("[ede_diagnostic]") ? nil : finalText,
                                outcome: outcome, error: res.cancelled ? nil : error)
        built["compacted"] = parser.compacted
        var reply = built["text"] as? String ?? ""
        if !res.cancelled && !parser.outputLimited {
            if reply.isEmpty, !parser.subtype.isEmpty, parser.subtype != "success" { reply = "Claude Code 提前结束：\(parser.subtype)" }
            if reply.isEmpty && ((built["steps"] as? [Any]) ?? []).isEmpty {
                reply = fallbackReply(res, cli: "Claude Code", preferStderr: true)
            } else if parser.isError && !reply.isEmpty { reply = "⚠️ " + reply }
        }
        built["text"] = reply
        let result = AgentReply(reply:reply, conversationId:convId, cancelled:res.cancelled, turn:built)
        if !parser.sessionId.isEmpty || !turn.isEmpty || parser.completed || parser.outputLimited {
            rememberReplyEnding(req, result, reason:res.cancelled ? nil : error)
        }
        return result
    }

    /// 一问一答（标准输入关着，中途不能审批、提问、补充）：只在 CLI 不支持交互式时用。
    func runClaudeOneShot(_ req: AskRequest, _ cmd: (executable: String, prefix: [String], reclaude: Bool)) -> AgentReply {
        if req.permissionMode == "manual" {
            return AgentReply(reply: "⚠️ 当前 Claude 单次模式无法使用「每次询问」。已退回草稿，请检查权限设置后重发。", conversationId: req.conversationId, restoreDraft: true)
        }
        let executable = cmd.executable
        var oneShot = req
        oneShot.images = durableImagePaths(req.images)   // 历史里只剩提问中的路径
        let args = claudeArgs(oneShot, cmd, live: false)
        let workspace = validWorkspace(req.workspace)

        let turn = turnBuilder(for: req)
        let parser = ClaudeStreamParser(turn: turn)
        let noteConversation = conversationWatcher(req)
        let res = runCLI(agent: req.key, executable: executable, arguments: args, cwd: workspace ?? home, onStdoutLine: { [weak self] line in
            guard let brace = line.firstIndex(of: "{"), let obj = self?.jsonObject(line[brace...]) else { return }
            parser.feed(obj)
            noteConversation(parser.sessionId)
        })
        if let e = res.launchError {
            return AgentReply(reply: "⚠️ 无法启动 Claude Code：\(e)", conversationId: req.conversationId)
        }
        return claudeReply(req, res: res, parser: parser, turn: turn)
    }
}
