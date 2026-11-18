// DeepSeek 历史从新往旧分页；只缓存当前打开的会话，让“显示更早”从上次游标继续。
import Cocoa

struct DeepSeekHistoryWindow {
    let cid: String
    var rows: [[String: Any]]
    var before: Int?
    var hasMore: Bool
    var limit: Int
}

extension AppDelegate {
    // MARK: 历史会话

    /// 列出 dsh 里的会话。它一次给出所有目录的全部会话；没聊过的空会话不列。
    func listDeepSeek() {
        deepseekQueue.async { [self] in
            guard dshExecutable() != nil, dshReady() == nil,
                  let rows = (dshServer.call("session.list").value as? [String: Any])?["items"] as? [[String: Any]] else {
                sendToJS("onConversationsListed", ["agent": "deepseek", "items": [[String: Any]]()])
                return
            }
            var cwds: [String: String] = [:]
            let items: [[String: Any]] = rows.compactMap { r in
                guard let id = r["sessionId"] as? String, r["blank"] as? Bool != true else { return nil }
                let cwd = r["cwd"] as? String ?? ""
                cwds[id] = cwd
                let updated = Date(timeIntervalSince1970: ((r["updatedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000)
                let title = (((r["projections"] as? [String: Any])?["values"] as? [String: Any])?["title"] as? String) ?? ""
                return ["id": id, "title": titleFrom(title, fallbackId: id), "time": timeLabel(updated),
                        "timestamp": updated.timeIntervalSince1970, "cwd": cwd]
            }
            procLock.lock(); dshCwds = cwds; procLock.unlock()
            sendToJS("onConversationsListed", ["agent": "deepseek", "items": Array(items.prefix(historyListLimit))])
        }
    }

    /// 搜索要翻完整份历史，页面载入仍分批；游标和失败原因由同一条读取路径保留。
    func readDeepSeekHistory(cid: String, before: Int? = nil, pageLimit: Int? = 60, until: Int? = nil,
                             onTail: (([String: Any], [[String: Any]]) -> Void)? = nil)
        -> (rows: [[String: Any]], before: Int?, hasMore: Bool, error: String?, missing: Bool) {
        var rows: [[String: Any]] = [], cursor = before
        var hasMore = false, pages = 0
        if let error = dshReady() { return (rows, cursor, false, error, false) }
        repeat {
            var params: [String: Any] = ["sessionId": cid, "maxMessages": 80]
            if let cursor = cursor { params["beforeSeq"] = cursor }
            let result = dshServer.call("session.history", params, timeout: 90)
            guard let value = result.value as? [String: Any], let page = value["events"] as? [[String: Any]] else {
                return (rows, cursor, hasMore, result.error ?? "DeepSeek 历史没有返回正文", result.code == "session-not-found")
            }
            if cursor == nil, let projection = value["projections"] as? [String: Any] { onTail?(projection, page) }
            let more = value["hasMore"] as? Bool == true
            let first = ((page.first?["event"] as? [String: Any])?["seq"] as? NSNumber)?.intValue
            if (more && first == nil) || (first != nil && cursor != nil && first! >= cursor!) {
                return (rows, cursor, true, "DeepSeek 历史翻页游标没有向更早推进", false)
            }
            rows = page + rows
            pages += 1
            hasMore = more
            cursor = first ?? cursor
            guard hasMore else { break }
            if let until = until, let first = first, first <= until { break }
        } while pageLimit.map({ pages < $0 }) ?? true
        return (rows, cursor, hasMore, nil, false)
    }

    /// 读一个会话的内容：它是从最后往前一页一页给的。
    func loadDeepSeek(cid: String, reqId: Int? = nil) {
        deepseekQueue.async { [self] in
            procLock.lock(); let cwd = dshCwds[cid] ?? "", limit = historyLimits[cid] ?? 300; procLock.unlock()
            let previous = deepseekHistoryWindow.flatMap { $0.cid == cid ? $0 : nil }
            var context: [String: Any]?
            var window: DeepSeekHistoryWindow, missing = false, error: String?
            func seq(_ row: [String: Any]) -> Int? { ((row["event"] as? [String: Any])?["seq"] as? NSNumber)?.intValue }
            if let previous = previous, limit > previous.limit {
                window = previous
            } else {
                let history = readDeepSeekHistory(cid: cid, until: previous?.rows.last.flatMap(seq)) { projection, page in
                    guard let values = projection["values"] as? [String: Any],
                          let pressure = values["contextPressure"] as? [String: Any],
                          let used = (pressure["projectedTokens"] ?? pressure["pressureTokens"]) as? Int, used >= 0,
                          let max = pressure["contextWindow"] as? Int, max > 0 else { return }
                    let parts = deepSeekContextParts(values["contextBreakdown"] as? [String: Any] ?? [:])
                    context = ["used": used, "max": max, "parts": parts, "estimated": true]
                    if let watermark = projection["asOfSeq"] as? Int {
                        context?["seq"] = watermark
                        let event = page.last(where: { seq($0) == watermark })?["event"] as? [String: Any]
                        context?["at"] = event?["time"]
                    }
                }
                missing = history.missing; error = history.error
                window = DeepSeekHistoryWindow(cid: cid, rows: history.rows, before: history.before, hasMore: history.hasMore, limit: limit)
                if let previous = previous, !missing {
                    if history.rows.isEmpty && error != nil { window = previous }
                    else if history.hasMore, let first = history.rows.first.flatMap(seq),
                            previous.rows.contains(where: { seq($0) == first }) {
                        // 最新一页接回已有页时只保留交点以前的旧事件；交点以后用服务刚返回的版本。
                        window.rows = previous.rows.filter { seq($0).map { $0 < first } ?? false } + history.rows
                        window.before = previous.before; window.hasMore = previous.hasMore
                    }
                }
            }
            var messages = dshTurns(window.rows), prepended = 0
            // 搜索可能直接要求很早的命中；每批仍最多60页，明确展开时才接着取到请求范围。
            while limit > 300 && messages.count < limit && window.hasMore && error == nil {
                let beforeCount = messages.count
                let history = readDeepSeekHistory(cid: cid, before: window.before)
                window.rows = history.rows + window.rows
                window.before = history.before
                window.hasMore = history.hasMore || history.error != nil
                error = history.error
                messages = dshTurns(window.rows)
                // 这里只请求旧游标以前的事件；最新消息同步不计入本轮起点的前移量。
                if previous != nil { prepended += max(0, messages.count - beforeCount) }
            }
            window.limit = limit
            deepseekHistoryWindow = missing ? nil : window
            var payload: [String: Any] = ["agent": "deepseek", "conversationId": cid, "cwd": cwd,
                                         "missing": missing, "hasMore": window.hasMore, "historyPrepended": prepended]
            payload["context"] = context
            if let state = dshLastTurn(window.rows) { payload["lastTurn"] = state.payload }
            if let error = error { payload["historyError"] = error }
            sendToJS("onConversationLoaded", recentHistory(messages, into: payload, reqId: reqId))
        }
    }

    /// dsh 没有删除会话的接口：把这个会话在磁盘上的目录移到废纸篓（~/.dsh/sessions/<目录编码>/<会话编号>/）。
    /// 只认名字和会话编号完全一样的目录。
    func trashDeepSeek(cid: String) -> Bool {
        guard isSafeId(cid), cid.hasPrefix("session-") else { return false }
        let root = "\(home)/.dsh/sessions"
        var ok = false
        for group in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let dir = "\(root)/\(group)/\(cid)"
            if isDirectory(dir), fm.fileExists(atPath: "\(dir)/session.jsonl.zstd") || !((try? fm.contentsOfDirectory(atPath: dir)) ?? []).isEmpty {
                ok = trash(dir) || ok
            }
        }
        procLock.lock(); dshApplied[cid] = nil; dshCwds[cid] = nil; procLock.unlock()
        if deepseekHistoryWindow?.cid == cid { deepseekHistoryWindow = nil }
        return ok
    }

    func deepseekIds(inWorkspace target: String) -> [String] {
        guard dshReady() == nil, let rows = (dshServer.call("session.list").value as? [String: Any])?["items"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard r["blank"] as? Bool != true, trimmedPath(r["cwd"] as? String ?? "") == target else { return nil }
            return r["sessionId"] as? String
        }
    }
}
