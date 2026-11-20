// 向 Codex 提问：找命令、拼参数；app-server 的握手和开会话参数、技能和模型清单、预热、本机记下的回合结局；
// 交互式回答见 CodexLive.swift，用不了退回 codex exec。拼参数和预热放在 *Run，和另外三位的分工一致。
//
// Codex 续接会占住会话写锁，所以打字时不续接、发送时才续接，续问只取线程信息（`excludeTurns`），省去整段历史回传；写锁在别的 Codex 客户端手里时立即结束这一轮并提示，
// 不重试、不退回 `codex exec`。
//
// Codex 的回合被用户停止或本轮进程异常退出时，CLI 可能只记下中断、或没有任何结束记录；两种 Codex 入口共用 `codexReply`，App 按回合 ID（单次 exec 只报告线程时按原问和发送时间）在 UserDefaults 记下当时显示的正文和结局（最近 40 条），
// 重开时历史里同一回合没有完成记录，就把遗留的运行中改成这个结局（带重试），缺的正文补回。
import Cocoa

extension AppDelegate {
    /// codex 在哪、这次用的模型、思考强度、沙盒。没装 codex 返回 nil。
    func codexExecutable() -> String? {
        if let path = hooks.cliExecutable { return path }
        return findExecutable([
            "\(home)/.local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ])
    }

    func codexSetup(_ req: AskRequest) -> (codex: String, model: String, effort: String, sandbox: String)? {
        guard let codex = codexExecutable() else { return nil }
        let model = req.model.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil ? req.model : "gpt-6-astra"
        let effort = ["low", "medium", "high", "xhigh", "ultra", "max"].contains(req.effort) ? req.effort : "high"
        // 交互式「每次询问」同时使用工作区沙箱和审批策略。
        let sandbox = ["read-only", "workspace-write", "danger-full-access"].contains(req.permissionMode)
            ? req.permissionMode : (req.permissionMode == "ask" ? "workspace-write" : "danger-full-access")
        return (codex, model, effort, sandbox)
    }

    func runCodex(_ req: AskRequest) -> AgentReply {
        guard let setup = codexSetup(req) else {
            return AgentReply(reply: "⚠️ 没有找到 codex CLI。", conversationId: req.conversationId)
        }
        // Codex 认不出的格式（HEIC 等）先转好；转不了就不发，不然它只收到占位文字、却照常「答完」
        var req = req
        var images: [String] = []
        for path in req.images {
            guard let usable = codexImagePath(path) else {
                return AgentReply(reply: "⚠️ 图片「\(fileBaseName(path))」转换失败，这句话没有发送。可以换成 PNG 或 JPEG 再试。", conversationId: req.conversationId)
            }
            images.append(usable)
        }
        req.images = images
        let codex = setup.codex, model = setup.model, effort = setup.effort, sandbox = setup.sandbox
        let workspace = validWorkspace(req.workspace)
        // 交互式（能审批、提问、中途补充，回答逐字出来）；这个版本的 codex 用不了 app-server 时退回 codex exec
        if let reply = runLive({ CodexLiveTurn(app: self, req: req, codex: codex, model: model, effort: effort, sandbox: sandbox) }, { $0.run() }) { return reply }
        if req.permissionMode == "ask" {
            return AgentReply(reply: "⚠️ 当前 Codex 单次模式无法使用「每次询问」。已退回草稿，请检查权限设置后重发。", conversationId: req.conversationId, restoreDraft: true)
        }
        let resuming = !req.conversationId.isEmpty
        req.images = durableImagePaths(req.images)   // 历史里只剩提问中的路径

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
        parser.wasCancelled = {
            self.procLock.lock(); defer { self.procLock.unlock() }
            return self.asks[req.key]?.cancelled == true
        }
        let noteConversation = conversationWatcher(req)
        let res = runCLI(agent: req.key, executable: codex, arguments: args, cwd: workspace ?? home, onStdoutLine: { [weak self] line in
            if let obj = self?.jsonObject(line) { parser.feed(obj) }
            noteConversation(parser.threadId)
        })
        if let e = res.launchError {
            return AgentReply(reply: "⚠️ 无法启动 codex：\(e)", conversationId: req.conversationId)
        }
        let convId = parser.threadId.isEmpty ? req.conversationId : parser.threadId
        return codexReply(req, res:res, builder:turn, cid:convId, turnId:"", status:parser.status,
                          text:parser.lastAgentMessage, partial:"", errors:parser.errors, compacted:false)
    }

    /// 两种输出协议只负责读事件；实时回答和本机结局必须取同一份最终正文。
    func codexReply(_ req: AskRequest, res: CLIResult, builder: TurnBuilder, cid: String, turnId: String,
                    status: String?, text: String, partial: String, errors: [String], compacted: Bool) -> AgentReply {
        let outcome: String
        switch status {
        case _ where res.cancelled, "interrupted": outcome = "interrupted"
        case "completed": outcome = "completed"
        case nil, "failed": outcome = "failed"
        default: outcome = "incomplete"
        }
        let reason = status == nil && !res.cancelled ? "⚠️ Codex 出错（退出码 \(res.status)）：\n" + (trimmed(res.err).isEmpty ? "进程在本轮完成前退出了。" : String(trimmed(res.err).suffix(1500))) : errors.joined(separator:"\n")
        let body = outcome != "completed" && !partial.isEmpty ? partial : text
        var turn = builder.finish(finalText:body, outcome:outcome, error:res.cancelled ? nil : reason)
        var reply = turn["text"] as? String ?? ""
        if !res.cancelled {
            if reply.isEmpty && !errors.isEmpty { reply = "⚠️ Codex 出错：\n" + errors.joined(separator:"\n") }
            if compacted {
                turn["compacted"] = true
                if reply.isEmpty { reply = codexCompactNote }
            }
            if reply.isEmpty && ((turn["steps"] as? [Any]) ?? []).isEmpty { reply = fallbackReply(res, cli:"Codex", preferStderr:true) }
        }
        turn["text"] = reply
        if !turnId.isEmpty { turn["turnKey"] = turnId }
        let result = AgentReply(reply:reply, conversationId:cid, cancelled:res.cancelled, turn:turn)
        rememberReplyEnding(req, result, reason:res.cancelled ? nil : reason, codexTurn:turnId)
        return result
    }
}

/// 应用自动附在用户的话后面的说明，都以它开头（读历史时从这里起去掉，不显示）。
let codexNoteMarker = "[AIPetHub 提示]"
/// /compact 做完时的那句提示：实时收起的提示和重新读历史时的压缩条目用同一句，切回来对账才不会换字
let codexCompactNote = "前面的对话已经压缩成摘要，腾出了上下文空间。"

extension AppDelegate {
    var codexInitialize: [String: Any] {
        ["id": 1, "method": "initialize",
         "params": ["clientInfo": ["name": "aipethub", "title": "AIPetHub", "version": "1.0"], "capabilities": NSNull()]]
    }

    /// skills/list 的答复：记下技能（名字 → 路径），并告诉网页（输入框里打 / 时列出来，连同我们替它接的 /compact）。
    /// 项目级技能只在自己的目录里认：回包带上网页发来的工作空间，网页按项目分别存候选，切项目后菜单不列上一项目的技能。
    func noteCodexSkills(_ result: [String: Any], cwd: String, workspace: String) {
        var found: [(name: String, desc: String, path: String)] = []
        for entry in result["data"] as? [[String: Any]] ?? [] {
            for s in entry["skills"] as? [[String: Any]] ?? [] where (s["enabled"] as? Bool) != false {
                guard let name = s["name"] as? String, let path = s["path"] as? String, !found.contains(where: { $0.name == name }) else { continue }
                found.append((name, (s["shortDescription"] as? String) ?? (s["description"] as? String) ?? "", path))
            }
        }
        procLock.lock(); codexSkills[cwd] = Dictionary(found.map { ($0.name, $0.path) }, uniquingKeysWith: { a, _ in a }); procLock.unlock()
        var list: [[String: String]] = [["name": "compact", "desc": "把前面的对话压缩成摘要，腾出上下文空间"]]
        list += found.map { ["name": $0.name, "desc": clip($0.desc.replacingOccurrences(of: "\n", with: " "), 80)] }
        sendToJS("onAgentCommands", ["agent": "gpt", "commands": list, "workspace": workspace])
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

    /// 这个工作目录上次查到的技能（名字 → 路径）；还没查过返回 nil，/技能名 要先查再提交。
    func codexSkills(in cwd: String) -> [String: String]? {
        procLock.lock(); defer { procLock.unlock() }
        return codexSkills[cwd]
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
            p["excludeTurns"] = true   // 续问只取线程编号，正文已经从历史库载入。
            input.send(["id": 2, "method": "thread/resume", "params": p])
        }
    }

    /// 接着聊一个已有的会话时，内置浏览器工具的开关和这个会话上一次不一样：给这一句附一段说明。
    /// 工具本身每一轮都按开关配好了（进程是新起的），但 Codex 只在会话开头看一次「有哪些工具」，之后不会自己再去查，
    /// 不说的话，后来打开它不知道有、后来关掉它还会去调。新会话不用说（开头它自己会看到）。
    func codexBrowserNote(threadId: String, isNew: Bool, on: Bool) -> String? {
        let key = "codexBrowserTools"
        var states = hooks.codexBrowserStates ?? UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        let before = states[threadId]
        guard before != on else { return nil }
        if states.count > 400 { states.removeAll() }   // 只是个小本子，记太多就清掉重记
        states[threadId] = on
        if hooks.codexBrowserStates != nil { hooks.codexBrowserStates = states } else { UserDefaults.standard.set(states, forKey: key) }
        if isNew || (before == nil && !on) { return nil }
        return on
            ? "\(codexNoteMarker) 从这一句起可以用内置浏览器的工具（MCP 服务 aipethub_browser：browser_open、browser_screenshot、browser_console、browser_text、browser_eval）。工具列表里没有直接列出的话，在 exec 里用 tools.mcp__aipethub_browser__browser_open({url}) 这样调用。这段是应用自动加的，不用回应。"
            : "\(codexNoteMarker) 内置浏览器的工具（aipethub_browser）从这一句起关掉了，不要再调用。这段是应用自动加的，不用回应。"
    }

    /// 用户停止、本轮进程异常退出时，CLI 可能只落盘 turn_aborted 而没有回答条目，或者什么结束记录都没有；
    /// 重开只靠历史就会丢掉已显示的正文、或一直显示「在别处运行中」。按回合 ID 记下本机确认的结局，
    /// 放在 UserDefaults 里，切换会话和重开 App 后都还在；回合 ID 用于匹配结局，会话 ID 用于刷新对应的搜索缓存。
    func noteCodexKnownEnding(turnId: String, outcome: String, text: String, error: String, compact: Bool = false, cid: String = "", reqId: Int? = nil, exec: AskRequest? = nil) {
        let key = "codexKnownEndings"
        procLock.lock(); defer { procLock.unlock() }
        var all = hooks.codexKnownEndings ?? UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Any]] ?? [:]
        // 只需要撑到用户再打开这几个会话：留最近 40 条，正文截断，免得这本小本子越记越大。
        all[turnId] = ["cid": cid, "outcome": outcome, "text": clip(text, endingTextLimit), "error": clip(error, 2000), "at": Date().timeIntervalSince1970]
        all[turnId]?["reqId"] = reqId
        if let exec {
            all[turnId]?["prompt"] = exec.promptWithImagePaths
            all[turnId]?["start"] = exec.startedAt.timeIntervalSince1970
        }
        if compact { all[turnId]?["compact"] = true }
        let stale = all.sorted { ($0.value["at"] as? Double ?? 0) > ($1.value["at"] as? Double ?? 0) }.dropFirst(40).map(\.key)
        stale.forEach { all[$0] = nil }
        if hooks.codexKnownEndings != nil { hooks.codexKnownEndings = all } else { UserDefaults.standard.set(all, forKey: key) }
    }

    func codexKnownEndings() -> [String:[String:Any]] {
        procLock.lock(); defer { procLock.unlock() }
        return hooks.codexKnownEndings ?? UserDefaults.standard.dictionary(forKey:"codexKnownEndings") as? [String:[String:Any]] ?? [:]
    }

    /// 只握手和查模型，打字时也不接入旧线程：续接会占住会话写锁，挡住别的 Codex 客户端（Prewarm.swift）。
    func warmCodex(_ req: AskRequest) -> CLIProcess? {
        guard let setup = codexSetup(req) else { return nil }
        let cli = CLIProcess(input: LiveInput()), cwd = validWorkspace(req.workspace) ?? home
        cli.warmFilter = { [weak self, weak cli] line in
            guard let self = self, let cli = cli, let obj = self.jsonObject(line), obj["method"] == nil,
                  let id = (obj["id"] as? NSNumber)?.intValue else { return false }
            if id == 1, cli.stage > 0 { return true }
            if id == 8 {   // 模型列表：预热时就告诉网页，不用等到真发话
                self.noteCodexModels(obj["result"] as? [String: Any] ?? [:])
                return true
            }
            if id == 9 {   // 技能清单：还没在这个项目里发过话时，打 / 也能列出这个项目的技能
                if obj["error"] == nil { self.noteCodexSkills(obj["result"] as? [String: Any] ?? [:], cwd: cwd, workspace: req.workspace) }
                return true
            }
            guard id == 1, obj["error"] == nil, let input = cli.input else { return false }
            self.codexInitialized(input)
            input.send(["id": 9, "method": "skills/list", "params": ["cwds": [cwd]]])
            cli.stage = 1
            return true
        }
        guard (try? cli.start(executable: setup.codex, arguments: ["app-server"], cwd: cwd,
                              environment: cliEnvironment())) != nil else { cli.input?.abandon(); return nil }
        cli.input?.send(codexInitialize)
        return cli
    }
}
