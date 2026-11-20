// 预热：用户开始打字、或上一轮刚答完时，先按当前设置把 CLI 起好、做完开场，发送时直接接手，回答的开头少等两三秒。
//
// 用户开始打字或上一轮答完时，App 按会话、模型、权限和工作空间预热。
// Codex 和 Gemini 答完后只握手。
//
// 新会话仍在发送时创建。
// Codex 在握手后查询模型和这个工作目录的技能（还没在这个项目里发过话时，打 / 也能列出它的技能）。
// 每位最多保留一个预热进程，其余预热 10 分钟过期。
//
// Claude 只预热新对话，已有会话在发送时按最新记录续接。
import Cocoa

extension AppDelegate {
    // 回答的开头有一段等待是 CLI 自己在启动（起进程、读配置、接上会话）。用户开始打字、或者上一轮刚答完时，
    // 先按当前的设置把进程起好、开场白做完，等着；发送时设置对得上就直接接手它，这段等待就省了。
    // 每位最多留一个。Gemini 打字接入旧会话后空闲 90 秒就释放写锁，其余预热最多保留 10 分钟。
    /// 这次提问会用什么设置起进程：对得上才能接手预热的那个。
    func warmKey(_ req: AskRequest) -> String {
        [req.agent, req.model, req.effort, req.permissionMode, validWorkspace(req.workspace) ?? "", req.conversationId,
         req.browserTools ? "b" : "", req.fast ? "f" : "", req.fork ? "k" : ""].joined(separator: "\u{1}")
    }

    /// 取走这位预热好的进程（设置对得上、还活着才给）；对不上的顺手结束掉。
    func takeWarm(_ req: AskRequest) -> CLIProcess? {
        procLock.lock()
        let lastTyped = warmIntents.removeValue(forKey: req.agent)?.lastTyped
        let w = warmProcs.removeValue(forKey: req.agent)
        procLock.unlock()
        guard let warm = w else { return nil }
        if warm.warmKey == warmKey(req), warm.proc.isRunning,
           Date().timeIntervalSince(lastTyped ?? warm.startedAt) < (lastTyped == nil ? 600 : (hooks.warmTypingIdle ?? 90)), warm.withWarmLock({ !changedElsewhere(warm) }) {
            procLock.lock(); warmAdopted += 1; procLock.unlock()
            return warm
        }
        if warm.proc.isRunning {
            terminateTree(warm.proc.processIdentifier)
            if warm.withWarmLock({ warm.stage >= 2 }), ["gpt", "gemini"].contains(req.agent) {
                warm.proc.waitUntilExit()
            }
        }
        return nil
    }

    /// 这位某个会话的记录文件（预热之后有没有被别处改过，看它的修改时间）。
    func conversationFile(agent: String, cid: String) -> String? {
        guard !cid.isEmpty else { return nil }
        switch agent {
        case "claude": return claudeQueue.sync { findClaudeSession(cid: cid) }   // 缓存由历史队列读写，预热也要排队
        case "gpt": return findRollout(cid: cid, hint: "")
        case "deepseek": return nil   // 没有「这一次回答的进程」，不存在预热之后记录又变了的问题
        default: return geminiConversationDb(cid)
        }
    }

    /// 预热之后，这个会话又在别处（终端里）接着聊过：预热的进程读到的是旧内容，不能用。
    /// agy 从 resume 答复那一刻起比对主文件和 WAL。Claude 沿用原来的启动宽限。
    func changedElsewhere(_ warm: CLIProcess) -> Bool {
        if let saved = warm.warmBaseline {
            guard let file = warm.warmFile else { return true }
            return saved != warmStamp(file)
        }
        guard let file = warm.warmFile else { return false }
        let latest = [file, file + "-wal"].compactMap { modificationDate($0) }.max()
        return latest.map { $0 > warm.startedAt.addingTimeInterval(8) } ?? false
    }

    func warmStamp(_ file: String) -> [String] {
        [file, file + "-wal"].map(conversationSearchFileStamp)
    }

    /// 在 CLI 输出锁内记录快照，原始答复仍留给正常的发送流程处理。
    func warmResumeReply(_ cli: CLIProcess, req: AskRequest, result: [String: Any]?) -> Bool {
        guard let result = result else { cli.stage = 1; return true }
        let thread = result["thread"] as? [String: Any]
        let path = thread?["path"] as? String ?? conversationFile(agent: req.agent, cid: req.conversationId)
        guard let path = path, fm.fileExists(atPath: path) else {
            // 没有可核对的记录，发送时只能使用当时的会话。
            cli.warmBaseline = []
            cli.input?.close()
            return true
        }
        cli.warmFile = path
        cli.warmBaseline = warmStamp(path)
        cli.stage = 3
        return false
    }

    /// 网页：用户开始打字了 / 上一轮刚答完——按现在的设置预热。已经有对得上的就不动。
    func prewarm(_ req: AskRequest, typing: Bool = true) {
        guard Bundle.main.bundleIdentifier != nil || hooks.prewarmWithoutBundle else { return }
        if !req.workspace.isEmpty, validWorkspace(req.workspace) == nil { return }
        if req.agent == "deepseek" {
            DispatchQueue.global(qos: .utility).async { _ = self.dshReady() }
            return
        }
        let agent = req.agent, key = warmKey(req)
        // Codex 续接即拿下会话写锁，别的 Codex 客户端（终端、桌面版）在释放前都接不上；只打字不该挡住它们，所以 Codex 发送时才续接。
        let attach = typing && !req.conversationId.isEmpty && agent == "gemini"
        procLock.lock()
        let existing = warmProcs[agent]
        let reuse = existing?.warmKey == key && existing?.proc.isRunning == true
        let previous = warmIntents[agent].flatMap { $0.key == key && (reuse || existing == nil) ? $0 : nil }
        let pending = previous != nil && existing == nil
        let token = previous?.token ?? UUID()
        let lastTyped = previous?.lastTyped
        let beginTyping = attach && lastTyped == nil
        warmIntents[agent] = (key, token, attach ? Date() : lastTyped)
        if !reuse { warmProcs[agent] = nil }
        procLock.unlock()
        if beginTyping { scheduleTypingExpiry(agent, token: token, after: hooks.warmTypingIdle ?? 90) }
        if reuse || pending {
            // 上次打字可能因桌面版仍在运行而只握了手。退出后再次打字即可续接，已发过 resume 的由协议阶段去重。
            let retryDesktop = attach && agent == "gemini" && req.conversationId.hasPrefix("desktop:")
            if beginTyping || retryDesktop, let cli = existing {
                DispatchQueue.global(qos: .userInitiated).async { self.resumeForTyping(req, cli) }
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if let old = existing, old.proc.isRunning { terminateTree(old.proc.processIdentifier) }
            let cli: CLIProcess?
            switch agent {
            case "claude":
                cli = warmClaude(req)
            case "gpt": cli = warmCodex(req)
            default: cli = warmGemini(req)
            }
            cli?.warmKey = key
            procLock.lock()
            let current = warmIntents[agent]
            guard current?.token == token else {
                procLock.unlock()
                if let cli = cli, cli.proc.isRunning { terminateTree(cli.proc.processIdentifier) }
                return
            }
            warmProcs[agent] = cli
            if cli == nil { warmIntents[agent] = nil }
            procLock.unlock()
            if current?.lastTyped != nil, let cli = cli { resumeForTyping(req, cli) }
        }
    }

    private func resumeForTyping(_ req: AskRequest, _ cli: CLIProcess) {
        cli.requestWarmResume { [weak cli, weak self] in
            guard let self = self, let cli = cli, let input = cli.input else { return false }
            self.procLock.lock(); let waiting = self.warmProcs[req.agent] === cli; self.procLock.unlock()
            guard waiting else { return false }
            if req.agent == "gemini", self.geminiResumeBlock(req.conversationId, fresh: false) == nil {   // 打字时每个按键都会到这里：复用 2 秒内的扫描结果，发送前会现查
                self.acpOpenSession(req, input)
            } else { return false }
            return true
        }
    }

    private func scheduleTypingExpiry(_ agent: String, token: UUID, after delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.procLock.lock()
            guard let intent = self.warmIntents[agent], intent.token == token, let last = intent.lastTyped else {
                self.procLock.unlock(); return
            }
            let remaining = (self.hooks.warmTypingIdle ?? 90) - Date().timeIntervalSince(last)
            if remaining > 0 {
                self.procLock.unlock(); self.scheduleTypingExpiry(agent, token: token, after: remaining); return
            }
            let cli = self.warmProcs.removeValue(forKey: agent)
            self.warmIntents[agent] = nil
            self.procLock.unlock()
            if let cli = cli, cli.proc.isRunning { terminateTree(cli.proc.processIdentifier) }
        }
    }

    /// 删除会话前：打字续接的预热一直持着这个会话的库（停打 90 秒才放），而删除的持库检查连本 App 也算，会被它挡住。
    /// 只结束还在缓存里等着的预热（正在回答的已被取走，不受影响），并等它退出；还在起的预热清掉意图，起好后自行结束、不会续接。
    func releaseWarm(agent: String, cid: String) {
        func sameConversation(_ key: String) -> Bool {
            let parts = key.components(separatedBy: "\u{1}")   // 第 6 段是会话 ID，见 warmKey
            return parts.count > 5 && parts[5] == cid
        }
        procLock.lock()
        let warm = warmProcs[agent].flatMap { sameConversation($0.warmKey) ? $0 : nil }
        if warm != nil { warmProcs[agent] = nil }
        if let intent = warmIntents[agent], sameConversation(intent.key) { warmIntents[agent] = nil }
        procLock.unlock()
        guard let w = warm, w.proc.isRunning else { return }
        terminateTree(w.proc.processIdentifier)
        w.proc.waitUntilExit()
    }

    /// 等了太久没用上的、以及退出 App 时：都结束掉。
    func dropWarm(olderThan age: TimeInterval = 0) {
        procLock.lock()
        let stale = warmProcs.filter { Date().timeIntervalSince(warmIntents[$0.key]?.lastTyped ?? $0.value.startedAt) >= age }
        stale.keys.forEach { warmProcs[$0] = nil; warmIntents[$0] = nil }
        if age == 0 { warmIntents.removeAll() }
        procLock.unlock()
        stale.values.filter { $0.proc.isRunning }.forEach { terminateTree($0.proc.processIdentifier) }
    }

    func startWarmReaper() {
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.dropWarm(olderThan: 600) }
    }
}
