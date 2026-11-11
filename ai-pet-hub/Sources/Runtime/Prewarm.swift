// 预热：用户开始打字、或上一轮刚答完时，先按当前设置把 CLI 起好、做完开场，发送时直接接手，回答的开头少等两三秒。
import Cocoa

extension AppDelegate {
    // 回答的开头有一段等待是 CLI 自己在启动（起进程、读配置、接上会话）。用户开始打字、或者上一轮刚答完时，
    // 先按当前的设置把进程起好、开场白做完，等着；发送时设置对得上就直接接手它，这段等待就省了。
    // 每位最多留一个；设置变了、换了会话、等了 10 分钟没用上，就结束掉。
    /// 这次提问会用什么设置起进程：对得上才能接手预热的那个。
    func warmKey(_ req: AskRequest) -> String {
        [req.agent, req.model, req.effort, req.permissionMode, validWorkspace(req.workspace) ?? "", req.conversationId,
         req.browserTools ? "b" : "", req.fast ? "f" : "", req.fork ? "k" : ""].joined(separator: "\u{1}")
    }

    /// 取走这位预热好的进程（设置对得上、还活着才给）；对不上的顺手结束掉。
    func takeWarm(_ req: AskRequest) -> CLIProcess? {
        procLock.lock()
        let w = warmProcs.removeValue(forKey: req.agent)
        procLock.unlock()
        guard let warm = w else { return nil }
        if warm.warmKey == warmKey(req), warm.proc.isRunning, !changedElsewhere(warm) {
            procLock.lock(); warmAdopted += 1; procLock.unlock()
            return warm
        }
        if warm.proc.isRunning { terminateTree(warm.proc.processIdentifier) }
        return nil
    }

    /// 这位某个会话的记录文件（预热之后有没有被别处改过，看它的修改时间）。
    func conversationFile(agent: String, cid: String) -> String? {
        guard !cid.isEmpty else { return nil }
        switch agent {
        case "claude": return findClaudeSession(cid: cid)
        case "gpt": return findRollout(cid: cid, hint: "")
        case "deepseek": return nil   // 没有「这一次回答的进程」，不存在预热之后记录又变了的问题
        default: return geminiConversationDb(cid)
        }
    }

    /// 预热之后，这个会话又在别处（终端里）接着聊过：预热的进程读到的是旧内容，不能用。
    /// 预热的进程自己接上会话时也可能动一下记录，所以起来后头 8 秒里的改动不算。
    func changedElsewhere(_ warm: CLIProcess) -> Bool {
        guard let file = warm.warmFile else { return false }
        let latest = [file, file + "-wal"].compactMap { modificationDate($0) }.max()
        return latest.map { $0 > warm.startedAt.addingTimeInterval(8) } ?? false
    }

    /// 把一个预热好的进程放进去等着（把原来那个换掉）。
    func keepWarm(_ agent: String, _ cli: CLIProcess) {
        procLock.lock()
        let old = warmProcs[agent]
        warmProcs[agent] = cli
        procLock.unlock()
        if let o = old, o.proc.isRunning { terminateTree(o.proc.processIdentifier) }
    }

    /// 网页：用户开始打字了 / 上一轮刚答完——按现在的设置预热。已经有对得上的就不动。
    func prewarm(_ req: AskRequest) {
        guard Bundle.main.bundleIdentifier != nil || ProcessInfo.processInfo.environment["AIPETHUB_PREWARM"] == "1" else { return }
        if !req.workspace.isEmpty, validWorkspace(req.workspace) == nil { return }
        if req.agent == "deepseek" {   // DeepSeek 的预热就是把它的本机服务先起好（DeepSeekServer.swift）
            DispatchQueue.global(qos: .utility).async { _ = self.dshReady() }
            return
        }
        let key = warmKey(req)
        procLock.lock()
        let have = warmProcs[req.agent].map { $0.warmKey == key && $0.proc.isRunning } ?? false
        procLock.unlock()
        if have { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            // 会话正开在别的程序里：不预热（预热也是「继续这个会话」，等于又多一个副本）；发问时会分叉，另起进程
            if req.agent == "claude", claudeLiveElsewhere(req.conversationId) != nil { return }
            let cli: CLIProcess?
            switch req.agent {
            case "claude": cli = warmClaude(req)
            case "gpt": cli = warmCodex(req)
            default: cli = warmGemini(req)
            }
            guard let c = cli else { return }
            c.warmKey = key
            c.warmFile = conversationFile(agent: req.agent, cid: req.conversationId)
            keepWarm(req.agent, c)
        }
    }

    /// 等了太久没用上的、以及退出 App 时：都结束掉。
    func dropWarm(olderThan age: TimeInterval = 0) {
        procLock.lock()
        let stale = warmProcs.filter { Date().timeIntervalSince($0.value.startedAt) >= age }
        stale.keys.forEach { warmProcs[$0] = nil }
        procLock.unlock()
        stale.values.filter { $0.proc.isRunning }.forEach { terminateTree($0.proc.processIdentifier) }
    }

    func startWarmReaper() {
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.dropWarm(olderThan: 600) }
    }
}
