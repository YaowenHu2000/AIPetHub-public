// 历史会话：列出、读取、删除，四位各自的实现在 Agents/ 下，这里按位分发。
//
// 继续历史会话时使用各 CLI 自带的恢复方式（`--resume`、`thread/resume`、`session/resume`），会话始终保存在 CLI 原有的位置。
//
// 四位助手的异常结局统一从本轮发给窗口的 `AgentReply` 补记（`rememberReplyEnding`）。
// 各历史读取器用自己的轮次身份认领补记，再由 `restoredEndingText` 选正文：同一段后来写全就取较长的一份，记录只剩工具前的说明时取当场的末段。
// 新补记带原请求编号，旧补记继续按原有轮次信息读取。
// 备份沿用最近 40 条、每条正文 5 万字的上限；磁盘或当前窗口里仍有全文时保留全文。
//
// 历史列表直接读取 CLI 自身的存储（Claude Code 的 JSONL、Codex 与 Antigravity 的 SQLite），以只读方式打开。
//
// 原生按 CLI 的实际存储判定来源。
// Claude 移走同编号的项目副本。
// Codex 优先认线程的归档位，无索引时核对活动和归档 rollout，避免历史投影单独复活。
// Gemini 按 CLI／桌面来源记住打开过的源文件和明确删除的编号，源文件恢复后仍能读取全文索引，只有索引的旧记录继续可读。
// DeepSeek 各实例共用移走的源目录（见 DeepSeekServer.swift 开头）。
//
// Claude 和 Gemini 的本机首问结局进入侧栏、项目清单和正文搜索，正式记录按编号去重。
// 旧版 Gemini 未记目录的首问列在未绑定工作空间；明确删除会话时一并撤下本机补记。
import Cocoa

extension AppDelegate {
    func listConversations(agent: String) {
        switch agent {
        case "gemini": listGemini()
        case "claude": listClaude()
        case "deepseek": listDeepSeek()
        default: listCodex()
        }
    }

    func loadConversation(agent: String, cid: String, reqId: Int? = nil) {
        switch agent {
        case "gemini": loadGemini(cid: cid, reqId: reqId)
        case "claude": loadClaude(cid: cid, reqId: reqId)
        case "deepseek": loadDeepSeek(cid: cid, reqId: reqId)
        default: loadCodex(cid: cid, reqId: reqId)
        }
    }

    /// 记录交给窗口的最终回答，避免停止、回退模式或补充入口另取一次正文和结局。
    func rememberReplyEnding(_ req: AskRequest, _ reply: AgentReply, position: Int? = nil, reason: String? = nil,
                             rpc: String? = nil, codexTurn: String? = nil) {
        guard let outcome = reply.turn?["outcome"] as? String, ["interrupted","failed","incomplete"].contains(outcome) else { return }
        if let id = codexTurn {
            guard !id.isEmpty || !reply.conversationId.isEmpty else { return }
            noteCodexKnownEnding(turnId:id.isEmpty ? UUID().uuidString : id, outcome:outcome, text:reply.reply, error:reason ?? "",
                                 compact:trimmed(req.prompt) == "/compact", cid:reply.conversationId, reqId:req.reqId, exec:id.isEmpty ? req : nil)
        } else {
            rememberLocalEnding(req, cid:reply.conversationId, text:reply.reply, outcome:outcome, position:position,
                                reason:reason, rpc:rpc, steps:req.agent == "gemini" ? reply.turn?["steps"] as? [[String:Any]] : nil)
        }
    }

    /// CLI 崩溃时可能连提问也没落盘；只在本机保留最近 40 轮，按会话和提问位置补回。
    func rememberLocalEnding(_ req: AskRequest, cid: String, text: String, outcome: String, position: Int? = nil, reason: String? = nil, rpc: String? = nil, steps: [[String: Any]]? = nil) {
        guard !cid.isEmpty else { return }
        // CLI 没落盘提问时，重开只能按这里记的路径找图：和单次模式一样放持久副本
        var row: [String: Any] = ["agent": req.agent, "cid": cid, "reqId": req.reqId, "prompt": req.prompt, "images": durableImagePaths(req.images),
                                  "text": clip(text, endingTextLimit), "outcome": outcome, "start": req.startedAt.timeIntervalSince1970,
                                  "end": Date().timeIntervalSince1970]
        if req.agent == "claude", req.conversationId.isEmpty,
           claudeQueue.sync(execute: { findClaudeSession(cid: cid) == nil }) {
            row["newWorkspace"] = req.workspace
        }
        if req.agent == "gemini", req.conversationId.isEmpty, !fm.fileExists(atPath: geminiConversationDb(cid)) {
            row["newWorkspace"] = req.workspace
        }
        row["rpc"] = rpc
        row["reason"] = reason
        row["position"] = position
        // 收尾时只保留最近步骤的可见文字，不把缩略图或整段命令输出再写进偏好设置。
        row["steps"] = steps?.suffix(40).map { step in
            var saved = [String: Any]()
            for key in ["kind", "title", "detail", "status", "path", "output"] {
                if let value = step[key] as? String { saved[key] = clip(value, 4096) }
            }
            if step["kind"] as? String == "user", let images = step["images"] as? [[String:Any]] {
                let paths = images.compactMap { $0["snapshot"] as? String }
                if !paths.isEmpty { saved["imageSources"] = paths.map { ["path":$0] } }
            }
            return saved
        }
        procLock.lock(); defer { procLock.unlock() }
        var rows = hooks.localEndings ?? UserDefaults.standard.array(forKey: "localTurnEndings") as? [[String: Any]] ?? []
        rows = Array(rows.suffix(39)) + [row]
        if hooks.localEndings != nil { hooks.localEndings = rows } else { UserDefaults.standard.set(rows, forKey: "localTurnEndings") }
    }

    func localEndings(agent: String, cid: String? = nil) -> [[String: Any]] {
        procLock.lock(); defer { procLock.unlock() }
        let rows = hooks.localEndings ?? UserDefaults.standard.array(forKey: "localTurnEndings") as? [[String: Any]] ?? []
        return rows.filter { $0["agent"] as? String == agent && (cid == nil || $0["cid"] as? String == cid) }
    }

    /// 首问可能只保存在本机。正式记录出现后由原来的列表项提供标题、目录和时间。
    func localFirstItems(_ agent: String, excluding seen: Set<String>) -> [[String:Any]] {
        var seen = seen
        return localEndings(agent:agent).reversed().compactMap { row in
            guard let cid = row["cid"] as? String else { return nil }
            // 旧版 Gemini 没记首问目录。源库也不存在时，仍可在未绑定工作空间里找回第零轮。
            let legacy = agent == "gemini" && row["position"] as? Int == 0 && !fm.fileExists(atPath:geminiConversationDb(cid))
            guard let cwd = row["newWorkspace"] as? String ?? (legacy ? "" : nil),
                  let at = row["end"] as? Double, seen.insert(cid).inserted,
                  agent != "gemini" || !geminiSourceMissing(cid) else { return nil }
            return ["id":cid, "cwd":cwd, "title":titleFrom(row["prompt"] as? String ?? "", fallbackId:cid),
                    "timestamp":at, "time":timeLabel(Date(timeIntervalSince1970:at))]
        }
    }

    /// 正式文件和本机补记都能提供侧栏入口，明确删除成功后应一起撤下。
    func forgetLocalEndings(_ agent: String, _ cid: String) -> Bool {
        procLock.lock(); defer { procLock.unlock() }
        let rows = hooks.localEndings ?? UserDefaults.standard.array(forKey:"localTurnEndings") as? [[String:Any]] ?? []
        let kept = rows.filter { $0["agent"] as? String != agent || $0["cid"] as? String != cid }
        guard rows.count != kept.count else { return false }
        if hooks.localEndings != nil { hooks.localEndings = kept } else { UserDefaults.standard.set(kept, forKey:"localTurnEndings") }
        return true
    }

    /// 每位的历史读写都在自己的串行队列上，避免和列表刷新同时改缓存。
    func queue(for agent: String) -> DispatchQueue {
        switch agent {
        case "gemini": return geminiQueue
        case "claude": return claudeQueue
        case "deepseek": return deepseekQueue
        default: return codexQueue
        }
    }

    /// 另一窗口可能正显示搜索结果，等当前助手的定时轮询会漏掉它。只传助手名，接收方自行核对自己的数据目录。
    func observeHistoryChanges(named name: Notification.Name) {
        historyNotification = name
        DistributedNotificationCenter.default().addObserver(self, selector:#selector(peerHistoryChanged(_:)),
                                                             name:name, object:nil, suspensionBehavior:.coalesce)
    }

    @objc private func peerHistoryChanged(_ note: Notification) {
        guard let agent = note.object as? String, note.userInfo?["sender"] as? String != historySender else { return }
        if let cid = note.userInfo?["taskConversation"] as? String {
            sendToJS("onTaskGroupChangedElsewhere", ["agent":agent, "conversationId":cid, "task":note.userInfo?["task"] as? String ?? "auto"])
            return
        }
        sendToJS("onHistoryChangedElsewhere", ["agent":agent])
    }

    /// 用户右键移进移出「任务会话」只记在本实例的网页存储里，WebKit 不在实例之间实时同步它；
    /// 另一实例按旧分组删除项目会多删或漏删，所以把这一条的结果（task / project / auto）交给其他实例。
    func notifyTaskGroupChanged(agent: String, cid: String, task: Bool?) {
        guard let name = historyNotification else { return }
        let value = task.map { $0 ? "task" : "project" } ?? "auto"
        DistributedNotificationCenter.default().postNotificationName(name, object:agent,
            userInfo:["sender":historySender, "taskConversation":cid, "task":value], deliverImmediately:true)
    }

    private func notifyHistoryChanged(_ agent: String) {
        guard let name = historyNotification else { return }
        DistributedNotificationCenter.default().postNotificationName(name, object:agent, userInfo:["sender":historySender], deliverImmediately:true)
    }

    /// 删掉一个会话（在该位的队列上调用）：Gemini / Claude 移到废纸篓，Codex 归档。
    func deleteOne(agent: String, cid: String, onBlocked: (String) -> Void = { _ in }) -> Bool {
        // 会话 ID 必须是个正经的名字：空的或带路径的 ID 拼出来的会是整个目录（比如 brain/），绝不能删
        guard validConversationId(cid, agent: agent) else { return false }
        switch agent {
        case "gemini":
            return deleteGemini(cid, onBlocked: onBlocked)
        case "claude":
            var unavailable = false
            if claudeLiveElsewhere(cid, fresh: true, unavailable: { unavailable = true }) != nil {
                onBlocked("这个 Claude 会话正在其他客户端打开，请先在那里关闭会话。")
                return false
            }
            if unavailable { onBlocked("无法确认这个 Claude 会话是否在别处打开，请稍后重试。"); return false }
            var ok = false, readError: String?
            // 列表把同编号的副本合成一项。只移走正在看的那份，刷新就会重新选中旧副本。
            let copies = claudeSessionFiles(matching:cid) { readError = $0 }
            if let readError { onBlocked(readError); return false }
            var paths = Set(copies.map(\.path))
            if let cached = claudeCache[cid], fm.fileExists(atPath:cached.path) { paths.insert(cached.path) }
            for path in paths {
                if !trash(path) && fm.fileExists(atPath:path) { return false }
                ok = true
                _ = trash(String(path.dropLast(6)))
            }
            claudeCache.removeValue(forKey: cid)
            return forgetLocalEndings(agent, cid) || ok
        case "deepseek":
            return trashDeepSeek(cid: cid, onBlocked: onBlocked)
        default:
            return archiveCodex([cid], onBlocked: onBlocked).contains(cid)
        }
    }

    func deleteConversation(agent: String, cid: String) {
        queue(for: agent).async { [self] in
            var result: [String: Any] = ["agent": agent, "conversationId": cid]
            let ok = deleteOne(agent: agent, cid: cid) { result["reason"] = $0 }
            result["ok"] = ok
            sendToJS("onConversationDeleted", result)
            if ok { notifyHistoryChanged(agent) }
            listConversations(agent: agent)
        }
    }

    /// 「删除项目」：一次删掉多个会话，最后只通知、刷新一次。
    func deleteConversations(agent: String, ids: [String], reqId: Int? = nil) {
        queue(for: agent).async { [self] in
            var result: [String: Any] = ["agent": agent]
            let ok = agent == "gpt" ? archiveCodex(ids) { result["reason"] = $0 } : Set(ids.filter { cid in
                deleteOne(agent: agent, cid: cid) { result["reason"] = $0 }
            })
            result["reqId"] = reqId
            result["deleted"] = ids.filter(ok.contains)
            result["failed"] = ids.filter { !ok.contains($0) }
            sendToJS("onConversationsDeleted", result)
            if !ok.isEmpty { notifyHistoryChanged(agent) }
            listConversations(agent: agent)
        }
    }

    /// 某个工作空间里这一位的全部会话（不受列表只显示 50 条的限制），「删除项目」先用它统计。
    func projectConversations(agent: String, workspace: String) {
        let target = trimmedPath(workspace)
        queue(for: agent).async { [self] in
            let ids: [String]
            var tasks: [String] = []   // 侧栏归进「任务会话」的，网页删项目时跳过
            switch agent {
            case "gemini": ids = geminiIds(inWorkspace: target) { tasks.append($0) }
            case "claude": ids = claudeIds(inWorkspace: target) { tasks.append($0) }
            case "deepseek": ids = deepseekIds(inWorkspace: target) { tasks.append($0) }
            default: ids = codexIds(inWorkspace: target) { tasks.append($0) }
            }
            sendToJS("onProjectConversations", ["agent": agent, "workspace": workspace, "ids": ids, "taskIds": tasks])
        }
    }

    /// 只有文字的记录（Gemini 历史）：每轮最后一段回答是正式回答，前面的算工作过程。
    /// 历史会话默认只发最近 300 条消息（太长的会话全部渲染会卡），并告诉网页省略了多少条；
    /// 用户点了「显示更早的」就多发一些（loadConversation 带 limit）。
    /// 开始读一份历史的时刻（毫秒，和网页的 Date.now() 同一时钟），随回包交给网页。打开历史、记录还没读回来就发的提问，
    /// 比这个时刻晚发的不可能在这份记录里；末尾同字的旧提问（「继续」）只核对文字分不出来（native-callbacks.js）。
    /// 在各位读历史的队列块一开头取：之后才定下读到哪儿，这一小段远短于 CLI 收到提问再写进记录的时间。
    func historyReadAt() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    func recentHistory(_ messages: [[String: Any]], into payload: [String: Any], reqId: Int? = nil) -> [String: Any] {
        var out = payload
        out["reqId"] = reqId
        procLock.lock()
        let limit = historyLimits[payload["conversationId"] as? String ?? ""] ?? 300
        procLock.unlock()
        var recent = Array(messages.suffix(limit))
        attachChatImages(&recent, payload: payload)   // 用户消息里的图片换成缩略图（ChatImages.swift）
        out["messages"] = recent
        // 搜索可能定位到很早的一句；默认仍只显示 300 条，明确展开时保留继续加载的入口。
        out["omitted"] = max(0, messages.count - limit)
        out["limit"] = limit
        return out
    }

    func textTurns(_ messages: [[String: String]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var turn: TurnBuilder?
        func flush() {
            guard let t = turn else { return }
            var bot = t.finish(finalText: nil)
            if !trimmed(bot["text"] as? String).isEmpty || !((bot["steps"] as? [Any]) ?? []).isEmpty {
                bot["role"] = "bot"
                out.append(bot)
            }
            turn = nil
        }
        for m in messages {
            if m["role"] == "user" {
                flush()
                out.append(["role": "user", "text": m["text"] ?? ""])
                turn = TurnBuilder()
            } else {
                if turn == nil { turn = TurnBuilder() }
                turn?.add(makeStep("text", "说明", detail: m["text"]))
            }
        }
        flush()
        return out
    }
}
