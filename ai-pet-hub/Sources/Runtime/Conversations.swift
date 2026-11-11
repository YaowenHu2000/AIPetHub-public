// 历史会话：列出、读取、删除，三位各自的实现在 Agents/ 下，这里按位分发。
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

    func loadConversation(agent: String, cid: String) {
        switch agent {
        case "gemini": loadGemini(cid: cid)
        case "claude": loadClaude(cid: cid)
        case "deepseek": loadDeepSeek(cid: cid)
        default: loadCodex(cid: cid)
        }
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

    /// 删掉一个会话（在该位的队列上调用）：Gemini / Claude 移到废纸篓，Codex 归档。
    func deleteOne(agent: String, cid: String) -> Bool {
        // 会话 ID 必须是个正经的名字：空的或带路径的 ID 拼出来的会是整个目录（比如 brain/），绝不能删
        guard isSafeId(cid) else { return false }
        switch agent {
        case "gemini":
            let db = geminiConversationDb(cid)
            let removedDb = trash(db)
            _ = trash(db + "-wal")
            _ = trash(db + "-shm")
            let removedBrain = trash("\(geminiBrainDir)/\(cid)")
            geminiCache.removeValue(forKey: cid)
            return removedDb || removedBrain
        case "claude":
            var ok = false
            if let path = findClaudeSession(cid: cid) {
                ok = trash(path)
                _ = trash(String(path.dropLast(6)))  // 同名的子代理 / 工具结果目录
            }
            claudeCache.removeValue(forKey: cid)
            return ok
        case "deepseek":
            return trashDeepSeek(cid: cid)
        default:
            return archiveCodex(cid: cid)
        }
    }

    func deleteConversation(agent: String, cid: String) {
        queue(for: agent).async { [self] in
            let ok = deleteOne(agent: agent, cid: cid)
            sendToJS("onConversationDeleted", ["agent": agent, "conversationId": cid, "ok": ok])
            listConversations(agent: agent)
        }
    }

    /// 「删除项目」：一次删掉多个会话，最后只通知、刷新一次。
    func deleteConversations(agent: String, ids: [String]) {
        queue(for: agent).async { [self] in
            var deleted: [String] = [], failed: [String] = []
            for cid in ids {
                if deleteOne(agent: agent, cid: cid) { deleted.append(cid) } else { failed.append(cid) }
            }
            sendToJS("onConversationsDeleted", ["agent": agent, "deleted": deleted, "failed": failed])
            listConversations(agent: agent)
        }
    }

    /// 某个工作空间里这一位的全部会话（不受列表只显示 50 条的限制），「删除项目」先用它统计。
    func projectConversations(agent: String, workspace: String) {
        let target = trimmedPath(workspace)
        queue(for: agent).async { [self] in
            let ids: [String]
            switch agent {
            case "gemini": ids = geminiIds(inWorkspace: target)
            case "claude": ids = claudeIds(inWorkspace: target)
            case "deepseek": ids = deepseekIds(inWorkspace: target)
            default: ids = codexIds(inWorkspace: target)
            }
            sendToJS("onProjectConversations", ["agent": agent, "workspace": workspace, "ids": ids])
        }
    }

    /// 只有文字的记录（Gemini 历史）：每轮最后一段回答是正式回答，前面的算工作过程。
    /// 历史会话默认只发最近 300 条消息（太长的会话全部渲染会卡），并告诉网页省略了多少条；
    /// 用户点了「显示更早的」就多发一些（loadConversation 带 limit）。
    func recentHistory(_ messages: [[String: Any]], into payload: [String: Any]) -> [String: Any] {
        var out = payload
        procLock.lock()
        let limit = historyLimits[payload["conversationId"] as? String ?? ""] ?? 300
        procLock.unlock()
        var recent = Array(messages.suffix(limit))
        attachChatImages(&recent, payload: payload)   // 用户消息里的图片换成缩略图（ChatImages.swift）
        out["messages"] = recent
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
