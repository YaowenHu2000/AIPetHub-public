// DeepSeek 历史从新往旧分页；只缓存当前打开的会话，让“显示更早”从上次游标继续。
//
// DeepSeek 历史按每批最多 60 页读取，保留服务端游标和「还有更早内容」状态；点击「显示更早」从旧游标继续，后台同步合并新记录，从搜索定位需要更早内容结果打开时继续取足请求范围（范围只有默认的 300 条也一样，
// 流式片段多的会话 60 页凑不满），普通打开不受影响。
// 侧栏和搜索的标题、排序时间按会话日志指纹核对：别处续写、改名过、缺标题或 App 第一次见到的会话读一次末页投影，
// 结果按指纹存档，App 重开后日志没变的照用（dshCheckedListRows）。
// dsh 网页归档的会话单条刷新答缺失，和侧栏、搜索一致。
import Cocoa

struct DeepSeekHistoryWindow {
    let cid: String
    var rows: [[String: Any]]
    var before: Int?
    var hasMore: Bool
    var limit: Int
}

/// 一条列表核对：这版日志（mark）下核实的标题和最后提问时刻；gen 不是 nil 时只在那一代 dsh 服务里作数（见 dshCheckedListRows）。
struct DshListCheck {
    var mark: String
    var title: String?
    var updatedAt: Double? = nil
    var gen: Int? = nil
}

extension AppDelegate {
    // MARK: 历史会话

    /// 列出 dsh 里的会话。它一次给出所有目录的全部会话；没聊过的空会话不列。
    func listDeepSeek() {
        deepseekQueue.async { [self] in
            // 服务起不来、列表读不出时不能当成「没有会话」：不发 items，网页保留上次的列表并写明原因
            if let error = dshReady() {
                sendToJS("onConversationsListed", ["agent": "deepseek", "unavailable": error])
                return
            }
            let marks = DshServer.logMarks()
            let listed = dshServer.call("session.list")
            guard let rows = (listed.value as? [String: Any])?["items"] as? [[String: Any]] else {
                sendToJS("onConversationsListed", ["agent": "deepseek", "unavailable": "DeepSeek 会话列表读取失败：\(listed.error ?? "没有返回列表")"])
                return
            }
            var cwds: [String: String] = [:]
            let items: [[String: Any]] = dshCheckedListRows(rows, marks: marks).compactMap { r in
                guard let id = r["sessionId"] as? String, r["blank"] as? Bool != true else { return nil }
                let cwd = r["cwd"] as? String ?? ""
                cwds[id] = cwd
                let updated = Date(timeIntervalSince1970: ((r["updatedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000)
                let title = (((r["projections"] as? [String: Any])?["values"] as? [String: Any])?["title"] as? String) ?? ""
                return ["id": id, "title": titleFrom(title, fallbackId: id), "time": timeLabel(updated),
                        "timestamp": updated.timeIntervalSince1970, "cwd": cwd, "task": dshScriptSession(r, id) == true]
            }
            procLock.lock(); dshCwds = cwds; procLock.unlock()
            sendToJS("onConversationsListed", ["agent": "deepseek", "items": Array(items.prefix(historyListLimit))])
        }
    }

    /// 本服务的 session.list 从 dsh 的投影缓存给标题和时间：别的 dsh 续写或改名后不会更新，写它的 dsh 没来得及把缓存落盘就退出时
    /// 新起的服务给的也是旧的，缓存里没有的会话连标题都没有；session.history 末页（maxMessages 1）的投影是按磁盘现算的。
    /// 所以比对会话日志指纹（marks 要在 session.list 之前取）：日志在本服务写完之后没变的照用列表；别处改过、缺标题、
    /// 或 App 第一次见到的才读一次末页，结果按指纹记住，侧栏和搜索共用，同一版日志不再读。
    /// 核对结果存进 UserDefaults：App 每次启动都是新服务，不存的话启动后第一次列出就要把全部会话的末页读一遍（150 条实测多 1.4–2 秒）。
    /// 还没有存档时（升级后第一次运行）有标题的照信列表、只读缺标题的，免得这一次也慢；代价是在那之前就在别处改过名的会话要等它再有变化才更正。
    /// 本服务内存里接手过、又被别处改过的会话，末页同样按旧内存给；读失败的也没核实。这两种结果只记在这一代服务名下、不存档，
    /// 打开会话重起服务（或 App 重开）后重新核对。只在 deepseekQueue 上调用；返回按更新时间从新到旧排好的行。
    func dshCheckedListRows(_ rows: [[String: Any]], marks: [String: String]) -> [[String: Any]] {
        func values(_ row: [String: Any]) -> [String: Any] { (row["projections"] as? [String: Any])?["values"] as? [String: Any] ?? [:] }
        func title(_ value: Any?) -> String? { (value as? String).flatMap { trimmed($0).isEmpty ? nil : $0 } }
        let stored = dshListChecks == nil ? loadDshListChecks() : nil
        let seeding = dshListChecks == nil && stored == nil
        var checks = dshListChecks ?? stored ?? [:], changed = seeding
        let gen = dshServer.currentGeneration
        var seen = Set<String>(), pending: [(cid: String, unverified: Bool)] = []
        for row in rows {
            guard let cid = row["sessionId"] as? String, row["blank"] as? Bool != true, seen.insert(cid).inserted else { continue }
            let mark = marks[cid] ?? ""
            if let known = checks[cid], known.mark == mark, known.gen == nil || known.gen == gen { continue }
            // 本服务自己写的会话列表就是最新的，缺标题也只是 dsh 还没起好标题，读末页也一样
            if dshServer.wroteLast(cid, mark: mark) || (seeding && title(values(row)["title"]) != nil) {
                checks[cid] = DshListCheck(mark: mark, title: title(values(row)["title"]))
                changed = true
            } else {
                pending.append((cid, dshServer.changedElsewhere(cid, attaching: false)))
            }
        }
        // 第一次列出时缺标题的可能有很多条；dsh 读冷会话主要在等磁盘，并发几条能把多出来的耗时压到原来的一半以下
        var tails = [[String: Any]?](repeating: nil, count: pending.count)
        let tailLock = NSLock(), lanes = min(8, pending.count)
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            for i in stride(from: lane, to: pending.count, by: lanes) {
                let tail = (dshServer.call("session.history", ["sessionId": pending[i].cid, "maxMessages": 1]).value as? [String: Any])?["projections"] as? [String: Any]
                tailLock.lock(); tails[i] = tail?["values"] as? [String: Any]; tailLock.unlock()
            }
        }
        for (item, fresh) in zip(pending, tails) {
            let prompt = ((fresh?["sessionListMetadata"] as? [String: Any])?["lastPromptAt"] as? NSNumber)?.doubleValue
            let unverified = item.unverified || fresh == nil
            checks[item.cid] = DshListCheck(mark: marks[item.cid] ?? "", title: title(fresh?["title"]), updatedAt: prompt, gen: unverified ? gen : nil)
            if !unverified { changed = true }
        }
        let checked: [[String: Any]] = rows.map { row in
            guard let cid = row["sessionId"] as? String, row["blank"] as? Bool != true,
                  let check = checks[cid], check.title != nil || check.updatedAt != nil else { return row }
            var row = row, values = values(row)
            if let title = check.title {
                values["title"] = title
                var projections = row["projections"] as? [String: Any] ?? [:]
                projections["values"] = values
                row["projections"] = projections
            }
            if let prompt = check.updatedAt {
                // dsh 的排序时间是创建时刻和最后一次提问取大；列表给的不会早于创建时刻
                row["updatedAt"] = max((row["updatedAt"] as? NSNumber)?.doubleValue ?? 0, prompt)
            }
            return row
        }
        let kept = checks.filter { seen.contains($0.key) }
        if kept.count != checks.count { changed = true }
        dshListChecks = kept
        if changed { saveDshListChecks(kept) }
        return checked.enumerated().sorted {
            let a = ($0.element["updatedAt"] as? NSNumber)?.doubleValue ?? 0, b = ($1.element["updatedAt"] as? NSNumber)?.doubleValue ?? 0
            return a != b ? a > b : $0.offset < $1.offset
        }.map(\.element)
    }

    /// 核对存档按数据目录分开；自测和窗口测试放 hooks，不写进 App 的 UserDefaults。
    private var dshListStoreKey: String { "dshListChecks:" + DshServer.sessionsRoot }
    private func loadDshListChecks() -> [String: DshListCheck]? {
        let raw = TestHooks.selfTest || UITest.active ? hooks.dshListStore
            : UserDefaults.standard.dictionary(forKey: dshListStoreKey) as? [String: [String: Any]]
        return raw?.compactMapValues { entry in
            (entry["mark"] as? String).map { DshListCheck(mark: $0, title: entry["title"] as? String, updatedAt: entry["updatedAt"] as? Double) }
        }
    }
    private func saveDshListChecks(_ checks: [String: DshListCheck]) {
        var raw: [String: [String: Any]] = [:]
        for (cid, check) in checks where check.gen == nil {
            var entry: [String: Any] = ["mark": check.mark]
            entry["title"] = check.title
            entry["updatedAt"] = check.updatedAt
            raw[cid] = entry
        }
        if TestHooks.selfTest || UITest.active { hooks.dshListStore = raw } else { UserDefaults.standard.set(raw, forKey: dshListStoreKey) }
    }

    /// 搜索要翻完整份历史，页面载入仍分批；游标和失败原因由同一条读取路径保留。
    func readDeepSeekHistory(cid: String, before: Int? = nil, pageLimit: Int? = 60, until: Int? = nil, promptRpc: String? = nil,
                             untilTurnBoundary: Bool = false, onTail: (([String: Any], [[String: Any]]) -> Void)? = nil)
        -> (rows: [[String: Any]], before: Int?, hasMore: Bool, error: String?, missing: Bool) {
        var rows: [[String: Any]] = [], cursor = before
        var hasMore = false, pages = 0
        if promptRpc == nil, let error = dshReady() { return (rows, cursor, false, error, false) }
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
            if untilTurnBoundary, dshLastTurn(page) != nil { break }
            if let rpc = promptRpc, page.contains(where: { dshHistoryRpc($0) == rpc }) { break }
            if let until = until, let first = first, first <= until { break }
        } while pageLimit.map({ pages < $0 }) ?? true
        return (rows, cursor, hasMore, nil, false)
    }

    private func dshHistoryRpc(_ row: [String: Any]) -> String? {
        guard let event = row["event"] as? [String: Any], event["type"] as? String == "user/message",
              let data = event["data"] as? [String: Any] else { return nil }
        return (data["source"] as? [String: Any])?["rpcId"] as? String
    }

    /// 同一会话可能已经排进另一轮，恢复范围必须从原提问开始，不能借用后面的正文或结束记录。
    func dshRecoveredTurn(_ sid: String, rpc: String) -> (turn: [String: Any]?, ended: Bool, superseded: Bool) {
        let rows = readDeepSeekHistory(cid: sid, promptRpc: rpc).rows
        guard let start = rows.lastIndex(where: { dshHistoryRpc($0) == rpc }) else { return (nil, false, false) }
        var current = [rows[start]], ended = false, superseded = false
        for row in rows.suffix(from: start + 1) {
            let type = (row["event"] as? [String: Any])?["type"] as? String
            if type == "turn/start" || (type == "user/message" && dshHistoryRpc(row)?.hasPrefix(dshSteerPrefix) != true) { superseded = true; break }
            current.append(row)
            if type == "turn/end" { ended = true; break }
        }
        return (dshTurns(current).last { $0["role"] as? String == "bot" }, ended, superseded)
    }

    /// 读一个会话的内容：它是从最后往前一页一页给的。
    func loadDeepSeek(cid: String, reqId: Int? = nil) {
        deepseekQueue.async { [self] in
            // dsh 网页归档的会话侧栏和搜索都不列（DeepSeekServerCalls.swift）；单条刷新也按「会话不在了」答，
            // 网页和外部删除一样退出空闲的聊天页，免得在原页接着问、答完却哪儿都找不到
            let archived = DshServer.archivedSessionIds().contains(cid)
            // 本服务接手过、又在别处续写过的会话，dsh 仍按旧内存给历史：能重起就重起，让它按磁盘给
            let reloadError = archived ? nil : dshReloadIfChangedElsewhere(cid, attaching: false)
            // 重起服务可能要好几秒，期间发的提问会排在重起之后：读取时刻从这里算
            let readAt = historyReadAt()
            procLock.lock()
            let cwd = dshCwds[cid] ?? "", limit = historyLimits[cid] ?? 300, fromSearch = historySearchOpens.remove(cid) != nil
            procLock.unlock()
            let previous = deepseekHistoryWindow.flatMap { $0.cid == cid ? $0 : nil }
            var context: [String: Any]?
            var window: DeepSeekHistoryWindow, missing = false, error: String?
            func seq(_ row: [String: Any]) -> Int? { ((row["event"] as? [String: Any])?["seq"] as? NSNumber)?.intValue }
            if archived {
                window = DeepSeekHistoryWindow(cid: cid, rows: [], before: nil, hasMore: false, limit: limit)
                missing = true
            } else if let previous = previous, limit > previous.limit, !dshServer.isDeleted(cid) {
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
            let endings = localEndings(agent: "deepseek", cid: cid)
            var messages = dshTurns(window.rows, endings: endings, hasMore:window.hasMore), prepended = 0
            // 搜索可能直接要求很早的命中；每批仍最多60页，明确展开时才接着取到请求范围。
            // 搜索给的范围按可见消息数算，最少 300；60 页原始事件可能还凑不满（流式片段多的长会话），
            // 所以从搜索结果点开时即使范围是 300 也接着读，命中那条才在里面。普通打开仍只读 60 页。
            while (limit > 300 || fromSearch) && messages.count < limit && window.hasMore && error == nil {
                let beforeCount = messages.count
                let history = readDeepSeekHistory(cid: cid, before: window.before)
                window.rows = history.rows + window.rows
                window.before = history.before
                window.hasMore = history.hasMore || history.error != nil
                error = history.error
                messages = dshTurns(window.rows, endings: endings, hasMore:window.hasMore)
                // 这里只请求旧游标以前的事件；最新消息同步不计入本轮起点的前移量。
                if previous != nil { prepended += max(0, messages.count - beforeCount) }
            }
            window.limit = limit
            deepseekHistoryWindow = missing ? nil : window
            var payload: [String: Any] = ["agent": "deepseek", "conversationId": cid, "cwd": cwd,
                                         "missing": missing, "hasMore": window.hasMore, "historyPrepended": prepended, "readAt": readAt]
            payload["context"] = context
            if let state = dshLastTurn(window.rows, endings: endings) { payload["lastTurn"] = state.payload }
            // 旁观实例的 dsh 会替别处仍在等答题的回合补出中断；只有持锁者能确认该结局。
            // 按调用编号认领了本机补记的中断是这个 App 自己确认的停止，不必再等另一实例。
            if isSafeId(cid), let last = messages.indices.last, messages[last]["outcome"] as? String == "interrupted",
               messages[last]["endingReqId"] == nil,
               let reason = dshServer.sessionLock(cid).error ?? unconfirmedInterruption(cid, window.rows) {
                messages[last]["outcome"] = nil
                if var steps = messages[last]["steps"] as? [[String: Any]], steps.last?["title"] as? String == "已中断" {
                    steps.removeLast()
                    messages[last]["steps"] = steps
                }
                payload["lastTurn"] = nil
                error = "无法确认另一实例中最后一轮的状态。" + reason
            }
            if !missing, let reason = reloadError ?? error { payload["historyError"] = reason }
            sendToJS("onConversationLoaded", recentHistory(messages, into: payload, reqId: reqId))
            if !missing { dshShowUnattended(cid) }   // 点开会话：dsh 自己开的一轮里还等着用户答的，照常弹卡
        }
    }

    /// 旁观服务会给未结束的外部回合合成中断。近期中断必须在同一轮的持久日志里也能找到。
    private func unconfirmedInterruption(_ cid: String, _ rows: [[String: Any]]) -> String? {
        guard isSafeId(cid), let boundary = rows.reversed().compactMap({ $0["event"] as? [String: Any] }).first(where: {
            ["turn/start", "turn/end"].contains($0["type"] as? String ?? "")
        }), boundary["type"] as? String == "turn/end", let data = boundary["data"] as? [String: Any],
              ["interrupted", "aborted"].contains((data["reason"] as? [String: Any])?["kind"] as? String ?? ""),
              let at = boundary["time"] as? Double, Date().timeIntervalSince1970 - at / 1000 < 3600 else { return nil }
        let warning = "持久记录尚无法确认这个 DeepSeek 回合已经结束，请稍后刷新。"
        let root = DshServer.sessionsRoot
        for group in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let base = "\(root)/\(group)/\(cid)/session.jsonl"
            let contents: String?
            if fm.fileExists(atPath: base + ".zstd") {
                guard let zstd = findExecutable(["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]) else { return warning }
                let result = runTool(zstd, ["-dc", base + ".zstd"], cwd: home, timeout: 30)
                contents = result.status == 0 ? result.out : nil
            } else if fm.fileExists(atPath: base) {
                contents = try? String(contentsOfFile: base, encoding: .utf8)
            } else { continue }
            let last = contents?.split(separator: "\n").reversed().lazy.compactMap { self.jsonObject($0) }
                .first { ["turn/start", "turn/end"].contains($0["type"] as? String ?? "") }
            if last?["type"] as? String == "turn/end", let turn = data["turn"] as? Int,
               (last?["data"] as? [String: Any])?["turn"] as? Int == turn { return nil }
            return warning
        }
        return warning
    }

    /// dsh 没有删除会话的接口：把这个会话在磁盘上的目录移到废纸篓（数据根目录/sessions/<目录编码>/<会话编号>/）。
    /// 只认名字和会话编号完全一样的目录。
    func trashDeepSeek(cid: String, onBlocked: (String) -> Void = { _ in }) -> Bool {
        guard isSafeId(cid), cid.hasPrefix("session-") else { return false }
        let claim = dshServer.sessionLock(cid)
        if let reason = claim.error { onBlocked(reason); return false }
        defer { withExtendedLifetime(claim.handle) {} }
        if let reason = dshReloadIfChangedElsewhere(cid, attaching: false) { onBlocked(reason); return false }
        let history = readDeepSeekHistory(cid: cid, pageLimit: nil, untilTurnBoundary: true)
        if let error = history.error, !history.missing { onBlocked(error); return false }
        if let reason = unconfirmedInterruption(cid, history.rows) { onBlocked(reason); return false }
        if let last = dshLastTurn(history.rows, endings: localEndings(agent:"deepseek", cid:cid)), last.running, Date().timeIntervalSince1970 - last.updatedAt < 3600 {
            onBlocked("这个 DeepSeek 会话正在回答，请等这一轮结束后再删除。")
            return false
        }
        let root = DshServer.sessionsRoot
        var removed: String?
        for group in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let dir = "\(root)/\(group)/\(cid)"
            if isDirectory(dir), fm.fileExists(atPath: "\(dir)/session.jsonl.zstd") || !((try? fm.contentsOfDirectory(atPath: dir)) ?? []).isEmpty {
                guard trash(dir) else { return false }
                removed = dir
            }
        }
        if let removed { dshServer.markDeleted(cid, directory:removed) }
        procLock.lock(); dshApplied[cid] = nil; dshCwds[cid] = nil; procLock.unlock()
        if deepseekHistoryWindow?.cid == cid { deepseekHistoryWindow = nil }
        return removed != nil
    }

    /// headless 直接把首问交给 agent；网页、终端和 App 的首问由 session.prompt 写入 RPC 编号。
    func dshScriptSession(_ row: [String: Any], _ cid: String) -> Bool? {
        guard row["origin"] == nil, row["parentSessionId"] == nil, row["agentPreset"] == nil else { return false }
        if let known = dshScriptOrigins[cid] { return known }
        let result = dshServer.call("session.history", ["sessionId":cid, "beforeSeq":128, "maxMessages":128])
        guard let page = result.value as? [String: Any], page["hasMore"] as? Bool == false,
              let events = page["events"] as? [[String: Any]],
              let first = events.compactMap({ $0["event"] as? [String: Any] }).first(where: { $0["type"] as? String == "user/message" }),
              let data = first["data"] as? [String: Any], let source = data["source"] as? [String: Any],
              source["kind"] as? String == "user" else { return nil }
        let script = source.count == 1
        dshScriptOrigins[cid] = script
        return script
    }

    func deepseekIds(inWorkspace target: String, onTask: (String) -> Void = { _ in }) -> [String] {
        guard dshReady() == nil, let rows = (dshServer.call("session.list").value as? [String: Any])?["items"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard r["blank"] as? Bool != true, trimmedPath(r["cwd"] as? String ?? "") == target else { return nil }
            guard let cid = r["sessionId"] as? String else { return nil }
            // 读不到启动记录时保留会话，避免项目删除带走脚本任务。
            guard let script = dshScriptSession(r, cid) else { return nil }
            if script { onTask(cid) }
            return cid
        }
    }
}
