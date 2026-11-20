// 一次提问的完整流程：检查工作空间 → 记下 git 状态 → 交给对应的 CLI → 把回答、步骤、改动的文件发给网页。
//
// 工作目录不可用或附件已移走时，原文和附件退回原会话草稿。
// 同一条失败提问反复点重试只退回一次。
import Cocoa

extension AppDelegate {
    private func finishAsk(_ req: AskRequest, _ payload: [String:Any]) {
        procLock.lock(); let queue = asks[req.key]?.supplementQueue; procLock.unlock()
        // 网页收到结局就可能把补充提升成下一问，先交付已接收补充的快照回执。
        if let queue { queue.sync { sendToJS("onAgentResponse",payload) } }
        else { sendToJS("onAgentResponse",payload) }
    }

    /// 提问可能在读取历史原图前就被拒收。让草稿取得仍可恢复的附件，保留缺失位置以免后面的图错位。
    func rejectUnsentAsk(_ req: AskRequest, reason: String) {
        let payload: [String: Any] = ["agent":req.agent, "reqId":req.reqId, "conversationId":req.conversationId,
            "cancelled":false, "duration":0, "cwd":validWorkspace(req.workspace) ?? home,
            "outcome":"failed", "restoreDraft":true, "reply":reason]
        if req.imageRefs.isEmpty { finishAsk(req,payload); return }
        DispatchQueue.global(qos: .userInitiated).async { [self, payload] in
            var reply = payload
            let paths = req.imageRefs.map { restoredImagePath($0) ?? "" }
            // 草稿保留可复核的原路径；读图的消费者沿用相应副本，等待用户重发期间原路径仍可能变化。
            let names = zip(req.imageRefs,paths).map { ref, copy in copy.isEmpty ? "" : verifiedImagePath(ref) ?? copy }
            reply["draftImagePaths"] = names
            reply["draftImageCopies"] = paths
            if paths.contains("") { reply["reply"] = reason + "\n部分历史原图无法恢复，请重新附上。" }
            finishAsk(req,reply)
        }
    }

    func ask(_ req: AskRequest) {
        // 收到就登记（在派到后台之前），这样紧接着的停止也能记下
        procLock.lock(); asks[req.key] = AskState(); procLock.unlock()
        hooks.askReceived?(req)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // 回答期间不做 App Nap（窗口在后台也要及时读取 CLI 输出），也不让系统闲置睡眠（长任务不会被打断；屏幕可以照常熄灭）
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated,
                                                                 reason: "等待 \(req.agent) 的回答")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            defer {
                self.procLock.lock()
                self.asks[req.key] = nil
                self.procLock.unlock()
            }
            let workspace = self.validWorkspace(req.workspace)
            if !req.workspace.isEmpty && (workspace == nil || access(req.workspace, X_OK) != 0) {
                // 选的工作空间被移动、改名或删除了：不能悄悄换到主目录里用最高权限执行
                self.rejectUnsentAsk(req, reason:"⚠️ 工作空间「\(req.workspace)」不存在或无法访问（可能被移动、改名或删除了），为了安全没有执行。请在左栏重新选择工作空间。")
                return
            }
            // 重试历史消息时原文件已不在或被覆盖的图片：从会话记录取回原图写成临时文件，和其他附件一样发（读记录可能慢，所以放在后台）
            var req = req
            guard let snapshots = self.sentImagePaths(req.images) else {
                self.rejectUnsentAsk(req, reason:"⚠️ 无法保存当次图片，这句话没有发送。")
                return
            }
            guard let sent = self.resolveImageRefs(req.imageRefs, among:req.images.map { snapshots[$0] ?? $0 }) else {
                self.rejectUnsentAsk(req, reason:"⚠️ 有图片的原图从会话记录里读不到了，这句话没有发送。可以重新附上图片再发。")
                return
            }
            if !sent.paths.isEmpty {
                self.sendToJS("onAgentSentImages", ["agent":req.agent, "reqId":req.reqId, "paths":snapshots, "restoredPaths":sent.restored])
                req.images = sent.paths
            }
            let before = self.gitSnapshot(workspace)
            let plainMarks = before == nil ? self.plainFileMarks(workspace) : [:]
            let started = Date()
            let result: AgentReply
            switch req.agent {
            case "gemini": result = self.geminiNoteCompacted(req, self.runGemini(req))
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
            if result.restoreDraft { payload["restoreDraft"] = true }
            var files = (result.turn?["files"] as? [[String: Any]]) ?? []
            if let turn = result.turn {
                payload["turnKey"] = turn["turnKey"]
                payload["steps"] = turn["steps"] ?? []
                if let outcome = responseOutcome(agent: req.agent, turn: turn) { payload["outcome"] = outcome }
                // 压缩命令这一轮在 CLI 记录里留没留下一条：网页据此决定实时那条提示算不算历史条目（native-callbacks.js）
                if let compacted = turn["compacted"] { payload["compacted"] = compacted }
            }
            let norm = { (p: String) -> String in
                // 工作目录可以有别名，最后一级却可能就是这一轮改写的链接。
                let path = self.resolvePath(p, base: workspace ?? self.home) as NSString
                let parent = (path.deletingLastPathComponent as NSString).resolvingSymlinksInPath
                return (parent as NSString).appendingPathComponent(path.lastPathComponent)
            }
            if let before = before {
                // 同一文件可能又被命令改过；内容快照覆盖整轮，连改回原样的也能认出来。只有指纹时仍保留工具细节。
                let paths = Set(files.map { norm($0["path"] as? String ?? "") })
                var compared = Set<String>(), fromGit: [String: [String: Any]] = [:]
                for f in self.gitChangedFiles(since: before, toolPaths: paths, compared: { compared = $0 }) {
                    fromGit[norm(f["path"] as? String ?? "")] = f
                }
                let unchanged = files.compactMap { file -> String? in
                    let path = file["path"] as? String ?? "", key = norm(path)
                    return compared.contains(key) && fromGit[key] == nil ? path : nil
                }
                if !unchanged.isEmpty { payload["unchangedPaths"] = unchanged }
                files = files.compactMap { file in
                    let key = norm(file["path"] as? String ?? "")
                    let git = fromGit.removeValue(forKey: key)
                    if compared.contains(key) { return git }
                    guard let g = git, ((file["diff"] as? String) ?? "").isEmpty else { return file }
                    var filled = file
                    for field in ["diff", "added", "removed", "truncated"] { filled[field] = g[field] }
                    return filled
                }
                // 快照也会看到用户保存和同目录的其他回答；只有工具报告的路径能确认归属。
                for key in fromGit.keys { fromGit[key]?["workspaceOnly"] = true }
                files += fromGit.values.sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
            } else if !files.isEmpty {
                var unchanged: [String] = []
                files = files.compactMap { file in
                    let path = file["path"] as? String ?? ""
                    let key = norm(path)
                    var budget = 1_000_000
                    if let before = plainMarks[key], before == self.plainFileMark(key, budget:&budget) {
                        unchanged.append(path); return nil
                    }
                    var reported = file
                    reported["toolTotal"] = true
                    return reported
                }
                if !unchanged.isEmpty { payload["unchangedPaths"] = unchanged }
            }
            payload["files"] = files
            // 回答已经完整出来、只剩整理改动的这一小段里才点的停止来不及了：这一轮照常算答完（和以前一样），
            // 不把一个做完了的回答标成「已停止」。
            self.hooks.askFinishing?(req)
            self.finishAsk(req,payload)
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
                if req.agent == "claude", req.conversationId.isEmpty || req.fork {
                    UserDefaults.standard.set(true, forKey: "claudeDirectSession." + cid)
                }
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

/// 这一轮的结局（completed / failed / interrupted / incomplete）交给网页，它据此显示「重试」、处理排队的话。
/// 四位的后端能明确判断失败（意外退出、写锁冲突、CLI 报错、输出到上限）；正文只剩半句时，网页单靠开头的 ⚠️ 猜不出来。
func responseOutcome(agent: String, turn: [String: Any]?) -> Any? {
    ["gpt", "claude", "gemini", "deepseek"].contains(agent) ? turn?["outcome"] : nil
}
