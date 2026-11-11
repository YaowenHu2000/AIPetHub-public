// 一次提问的完整流程：检查工作空间 → 记下 git 状态 → 交给对应的 CLI → 把回答、步骤、改动的文件发给网页。
import Cocoa

extension AppDelegate {
    func ask(_ req: AskRequest) {
        // 收到就登记（在派到后台之前），这样紧接着的停止也能记下
        procLock.lock(); activeAsks.insert(req.key); procLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // 回答期间不做 App Nap（窗口在后台也要及时读取 CLI 输出），也不让系统闲置睡眠（长任务不会被打断；屏幕可以照常熄灭）
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated,
                                                                 reason: "等待 \(req.agent) 的回答")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            defer {
                self.procLock.lock()
                self.activeAsks.remove(req.key)
                self.cancelledAgents.remove(req.key)
                self.procLock.unlock()
            }
            let workspace = self.validWorkspace(req.workspace)
            if !req.workspace.isEmpty && workspace == nil {
                // 选的工作空间被移动、改名或删除了：不能悄悄换到主目录里用最高权限执行
                self.sendToJS("onAgentResponse", [
                    "agent": req.agent, "reqId": req.reqId, "conversationId": req.conversationId, "cancelled": false,
                    "duration": 0, "cwd": self.home,
                    "reply": "⚠️ 工作空间「\(req.workspace)」不存在或无法访问（可能被移动、改名或删除了），为了安全没有执行。请在左栏重新选择工作空间。"
                ])
                return
            }
            let before = self.gitSnapshot(workspace)
            let started = Date()
            let result: AgentReply
            switch req.agent {
            case "gemini": result = self.runGemini(req)
            case "claude": result = self.runClaude(req)
            case "deepseek": result = self.runDeepSeek(req)
            default: result = self.runCodex(req)
            }
            var payload: [String: Any] = [
                "agent": req.agent,
                "reqId": req.reqId,
                "reply": result.reply,
                "conversationId": result.conversationId,
                "cancelled": result.cancelled,
                "duration": Date().timeIntervalSince(started),
                "cwd": self.validWorkspace(req.workspace) ?? self.home
            ]
            var files = (result.turn?["files"] as? [[String: Any]]) ?? []
            if let turn = result.turn { payload["steps"] = turn["steps"] ?? [] }
            if let before = before {
                // 命令改的文件补进改动卡片；改文件工具已经报过的不重复（路径统一成绝对、解开符号链接再比）。
                // 工具报了但没带 diff 的（Codex 实时事件就是这样），用 git 的 diff 补上。
                let norm = { (p: String) in (self.resolvePath(p, base: workspace ?? self.home) as NSString).resolvingSymlinksInPath }
                var fromGit: [String: [String: Any]] = [:]
                for f in self.gitChangedFiles(since: before) { fromGit[norm(f["path"] as? String ?? "")] = f }
                for k in files.indices {
                    let key = norm(files[k]["path"] as? String ?? "")
                    guard let g = fromGit.removeValue(forKey: key) else { continue }
                    if ((files[k]["diff"] as? String) ?? "").isEmpty {
                        files[k]["diff"] = g["diff"]
                        files[k]["added"] = g["added"]
                        files[k]["removed"] = g["removed"]
                    }
                }
                files += fromGit.values.sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
            }
            payload["files"] = files
            self.sendToJS("onAgentResponse", payload)
            if !result.cancelled { self.noteReplyArrived(agent: req.agent, text: result.reply) }
        }
    }

    /// CLI 一报出会话 ID 就告诉网页，不等回答结束（长任务要十几分钟）。否则这段时间里网页只知道「新对话」，
    /// 而 CLI 已经把会话写进了自己的记录：左栏会同时出现「新对话」和它在 CLI 里的那一条，点开后者像是停了，
    /// 还能对着它再发一句、删掉它，同一个会话就有两个进程在跑。只报一次（和请求里的 ID 不同时）。
    func conversationWatcher(_ req: AskRequest) -> (String) -> Void {
        let lock = NSLock()
        var announced = false
        return { [weak self] cid in
            lock.lock()
            let announce = !announced && !cid.isEmpty && cid != req.conversationId
            if announce { announced = true }
            lock.unlock()
            if announce {
                self?.sendToJS("onAgentConversation", ["agent": req.agent, "reqId": req.reqId, "conversationId": cid])
            }
        }
    }

    /// 实时模式：每新增 / 更新一个工作步骤就推给网页。
    func turnBuilder(for req: AskRequest) -> TurnBuilder {
        let turn = TurnBuilder()
        turn.onChange = { [weak self] index, step in
            self?.sendToJS("onAgentStep", ["agent": req.agent, "reqId": req.reqId, "index": index, "step": step])
        }
        return turn
    }
}
