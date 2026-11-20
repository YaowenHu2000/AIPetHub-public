// Codex 的历史会话：读它的 SQLite 和 rollout 记录（归成一问一答在 CodexTurns.swift）；删除是归档。
//
// Codex 侧栏和项目清单也收录只有压缩 rollout 的主会话；桌面版标为 `projectless-thread-ids` 的会话归入「未绑定工作空间」，续聊仍用原目录。
import Cocoa
import SQLite3

/// 当前 Codex 改名只写 threads.name，title 仍留着首问；侧栏和搜索共用这一列表达式，老库没有 name 列时只取 title。
let codexNamedTitle = "COALESCE(NULLIF(TRIM(name), ''), title)"

extension AppDelegate {
    var codexHome: String {
        // CLI 子进程继承这一环境变量，历史、搜索和原图也必须读同一个位置。
        let configured = (hooks.codexEnvironment ?? ProcessInfo.processInfo.environment)["CODEX_HOME"] ?? ""
        return configured.isEmpty ? "\(home)/.codex" : (configured as NSString).standardizingPath
    }

    /// 只读压缩帧的长度信息；未知长度或旧版 zstd 无法列出时，仍由正常解压路径确认。
    func rolloutUncompressedSize(_ path: String) -> Int64? {
        guard path.hasSuffix(".zst"),
              let zstd = hooks.cliExecutable ?? findExecutable(["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]) else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        let result = runTool(zstd, ["-lv", path], cwd: home, environment: environment, timeout: 30)
        guard result.status == 0,
              let line = result.out.components(separatedBy: "\n").first(where: { $0.hasPrefix("Decompressed Size:") }),
              let range = line.range(of: #"\([0-9]+ B\)$"#, options: .regularExpression) else { return nil }
        return Int64(line[range].dropFirst().dropLast(3))
    }

    /// 读取 rollout 文件（旧文件会被 Codex 压成 .jsonl.zst，用 zstd 解压）。
    func readRollout(_ path: String) -> String? {
        hooks.codexFullRolloutRead?(path)
        if path.hasSuffix(".jsonl") {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
            var lines: [String] = []
            var start = data.startIndex
            // 正在追加的尾行可能停在 UTF8 字符中间，不能让它抹掉前面完整的历史。
            while start < data.endIndex, let end = data[start...].firstIndex(of: 0x0A) {
                if let line = String(data: data[start..<end], encoding: .utf8) { lines.append(line + "\n") }
                start = end + 1
            }
            return lines.joined()
        }
        let executable = hooks.cliExecutable ?? findExecutable(["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"])
        guard path.hasSuffix(".zst"), let zstd = executable else { return nil }
        let res = runTool(zstd, ["-dc", path], cwd: home,
                          environment: ProcessInfo.processInfo.environment, timeout: 30)
        return res.status == 0 ? res.out : nil
    }

    /// 只扫活跃目录。Codex 压缩旧记录时会在原处把扩展名换成 .jsonl.zst。
    func activeRollouts(onError: @escaping (String) -> Void = { _ in }) -> [(path: String, mtime: Date)] {
        let root = "\(codexHome)/sessions"
        var result: [(String, Date)] = []
        guard let walker = fm.enumerator(at:URL(fileURLWithPath:root),includingPropertiesForKeys:nil,errorHandler:{ url,_ in
            if let reason = self.historyAccessError(url.path,mode:R_OK | X_OK) { onError(reason) }
            return true
        }) else { return [] }
        for case let file as URL in walker {
            let rel = file.lastPathComponent
            guard rel.hasSuffix(".jsonl") || rel.hasSuffix(".jsonl.zst"), (rel as NSString).lastPathComponent.hasPrefix("rollout-") else { continue }
            let path = file.path
            if let m = modificationDate(path) { result.append((path, m)) }
        }
        return result
    }

    func findRollout(cid: String, hint: String, onError: @escaping (String) -> Void = { _ in }) -> String? {
        for p in [hint, hint + ".zst"] where !hint.isEmpty && fm.fileExists(atPath: p) { return p }
        let root = "\(codexHome)/sessions"
        hooks.rolloutLookupWalk?()
        let directory = URL(fileURLWithPath: root)
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [], errorHandler: { url, error in
            if let reason = self.historyAccessError(url.path, mode: R_OK | X_OK) { onError(reason) }
            return true
        }) else {
            if let reason = historyAccessError(root, mode: R_OK | X_OK) { onError(reason) }
            return nil
        }
        for case let file as URL in walker {
            let name = file.lastPathComponent
            if name.hasSuffix("-\(cid).jsonl") || name.hasSuffix("-\(cid).jsonl.zst") { return file.path }
        }
        return nil
    }

    /// 无索引的旧会话移走 rollout 后，正文投影可能还在。只有归档目录有同编号文件且没有活动来源时才屏蔽投影。
    func archivedRolloutIds() -> Set<String> {
        var ids = Set<String>()
        for name in (try? fm.contentsOfDirectory(atPath:codexHome + "/archived_sessions")) ?? [] where name.hasPrefix("rollout-") {
            guard name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst") else { continue }
            let stem = name.dropLast(name.hasSuffix(".zst") ? 10 : 6)
            let uuid = String(stem.suffix(36))
            if UUID(uuidString:uuid) != nil { ids.insert(uuid); continue }
            // 短编号本身也可能含连字符。缺失投影不能只凭相同后缀归给另一条归档。
            if let meta = codexRolloutMeta(codexHome + "/archived_sessions/" + name),
               let id = (meta["id"] ?? meta["session_id"]) as? String { ids.insert(id) }
        }
        return ids
    }

    /// 桌面端把「不在项目下」单独记为线程 ID，这些会话仍有自己的工作目录。
    func codexProjectlessIds() -> Set<String> {
        struct Projects: Decodable { let projectlessThreadIds: [String]
            enum CodingKeys: String, CodingKey { case projectlessThreadIds = "projectless-thread-ids" }
        }
        let file = URL(fileURLWithPath: codexHome).appendingPathComponent(".codex-global-state.json")
        guard let data = try? Data(contentsOf: file), let projects = try? JSONDecoder().decode(Projects.self, from: data) else { return [] }
        return Set(projects.projectlessThreadIds)
    }

    /// 已收录的文件按索引的归档和主/子线程状态判断，不因目录里还留有压缩副本再次出现。
    private func standaloneCodexRollouts(indexed: Set<String>, onError: @escaping (String) -> Void = { _ in }) -> [[String: Any]] {
        var seen = indexed, items: [[String: Any]] = []
        for (path, mtime) in activeRollouts(onError:onError) {
            let name = path.dropLast(path.hasSuffix(".zst") ? 10 : 6)
            if seen.contains(String(name.suffix(36))) { continue }
            if let item = cachedRolloutSummary(path, mtime), let cid = item["id"] as? String, seen.insert(cid).inserted { items.append(item) }
        }
        return items
    }

    func cachedRolloutSummary(_ path: String, _ mtime: Date) -> [String: Any]? {
        let ts = mtime.timeIntervalSince1970
        if let cached = codexRolloutCache[path], abs(cached.mtime - ts) < 0.001 { return cached.item }
        let item = path.hasSuffix(".zst") ? compressedRolloutSummary(path: path, mtime: mtime) : rolloutSummary(path: path, mtime: mtime)
        if let item { codexRolloutCache[path] = (ts, item) }
        return item
    }

    func listCodex() {
        codexQueue.async { [self] in
            var items: [[String: Any]] = []
            var seen = Set<String>()
            let state = codexHome + "/state_5.sqlite", sessions = codexHome + "/sessions"
            if let reason = historyAccessError(state) ?? historyAccessError(sessions,mode:R_OK | X_OK) {
                sendToJS("onConversationsListed",["agent":"gpt","unavailable":reason]); return
            }
            let read: Void? = withReadableSQLite(state) { db in
                // source 以 { 开头的是子代理线程，不单独列出。
                queryRows(db, "SELECT id FROM threads") { seen.insert(columnText($0, 0)) }
                var first = "''", title = "title"
                queryRows(db, "PRAGMA table_info(threads)") {
                    if columnText($0, 1) == "first_user_message" { first = "first_user_message" }
                    if columnText($0, 1) == "name" { title = codexNamedTitle }
                }
                let sql = """
                    SELECT id, \(title), \(first), cwd, updated_at, source FROM threads
                    WHERE archived = 0 AND source NOT LIKE '{%' ORDER BY updated_at DESC LIMIT 320;
                    """
                queryRows(db, sql) { s in
                    let cid = columnText(s, 0)
                    guard !cid.isEmpty else { return }
                    let title = columnText(s, 1).trimmingCharacters(in: .whitespacesAndNewlines)
                    let firstMsg = stripPersonaPrefix(columnText(s, 2))
                    let updated = Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 4)))
                    var item: [String: Any] = ["id": cid, "title": titleFrom(title.isEmpty ? firstMsg : title, fallbackId: cid),
                                               "time": timeLabel(updated), "timestamp": updated.timeIntervalSince1970,
                                               "cwd": columnText(s, 3)]
                    if columnText(s, 5) == "exec" { item["task"] = true }   // `codex exec` 派出去的一次性任务：侧栏归进「任务会话」
                    items.append(item)
                }
            }

            if read == nil && fm.fileExists(atPath:state) {
                sendToJS("onConversationsListed",["agent":"gpt","unavailable":"会话列表数据库无法读取"]); return
            }
            var readError: String?
            items.append(contentsOf: standaloneCodexRollouts(indexed: seen,onError:{ readError = $0 }))
            if let readError { sendToJS("onConversationsListed",["agent":"gpt","unavailable":readError]); return }
            items.sort { ($0["timestamp"] as? Double ?? 0) > ($1["timestamp"] as? Double ?? 0) }
            sendToJS("onConversationsListed", ["agent": "gpt", "items": Array(items.prefix(historyListLimit)), "projectlessIds": Array(codexProjectlessIds())])
        }
    }

    /// 目录是 target 的全部未归档会话：数据库里的线程 + 只存在于 rollout 的会话。
    /// onTask 收到其中 `codex exec` 派出去的：侧栏把它们归进「任务会话」，删除项目时网页据此跳过。
    func codexIds(inWorkspace target: String, onTask: (String) -> Void = { _ in }) -> [String] {
        var ids: [String] = [], indexed = Set<String>()
        let projectless = codexProjectlessIds()
        func matches(_ cid: String, _ cwd: String) -> Bool { (projectless.contains(cid) ? "" : trimmedPath(cwd)) == target }
        _ = withReadableSQLite("\(codexHome)/state_5.sqlite") { db in
            queryRows(db, "SELECT id, cwd, archived, source FROM threads") { s in
                let cid = columnText(s, 0)
                indexed.insert(cid)
                if sqlite3_column_int(s, 2) == 0, !columnText(s, 3).hasPrefix("{"), matches(cid, columnText(s, 1)) {
                    ids.append(cid)
                    if columnText(s, 3) == "exec" { onTask(cid) }
                }
            }
        }
        for item in standaloneCodexRollouts(indexed: indexed) {
            if let cid = item["id"] as? String, matches(cid, item["cwd"] as? String ?? "") {
                ids.append(cid)
                if item["task"] as? Bool == true { onTask(cid) }
            }
        }
        return ids
    }

    func rolloutSummary(path: String, mtime: Date) -> [String: Any]? {
        guard !(codexRolloutMeta(path)?["source"] is [String: Any]) else { return nil }
        guard let content = readRollout(path) else { return nil }
        let (messages, meta) = rolloutMessages(content)
        guard let cid = (meta["id"] as? String) ?? (meta["session_id"] as? String), isSafeId(cid),
              meta["source"] is String,  // 子代理的 source 是对象
              let firstUser = messages.first(where: { $0["role"] == "user" })?["text"] else { return nil }
        var item: [String: Any] = ["id": cid, "title": titleFrom(firstUser, fallbackId: cid), "time": timeLabel(mtime),
                                   "timestamp": mtime.timeIntervalSince1970, "count": messages.count,
                                   "cwd": meta["cwd"] as? String ?? ""]
        if meta["source"] as? String == "exec" { item["task"] = true }
        return item
    }

    /// 搜索和打开会话共用来源选择，避免正文命中后打开的是另一份历史。
    func readCodexConversation(cid: String, includeContext: Bool = false) -> [String: Any] {
        var cwd = ""
        var rolloutHint = ""
        var inStateDb = false, archived = false
        _ = withReadableSQLite("\(codexHome)/state_5.sqlite") { db in
            let hasArchived = sqlite3_table_column_metadata(db, nil, "threads", "archived", nil, nil, nil, nil, nil) == SQLITE_OK
            queryRows(db, "SELECT cwd, rollout_path, \(hasArchived ? "archived" : "0") FROM threads WHERE id = ? LIMIT 1;", [cid]) { s in
                archived = sqlite3_column_int(s, 2) != 0
                cwd = columnText(s, 0)
                rolloutHint = columnText(s, 1)
                inStateDb = true
            }
        }

        if archived { return ["agent":"gpt", "conversationId":cid, "cwd":cwd, "missing":true, "messages":[]] }
        var lookupError: String?
        let rolloutPath = findRollout(cid: cid, hint: rolloutHint) { lookupError = $0 }
        if !inStateDb, rolloutPath == nil, lookupError == nil, archivedRolloutIds().contains(cid) {
            return ["agent":"gpt","conversationId":cid,"cwd":cwd,"missing":true,"messages":[]]
        }
        let effective = rolloutPath.map(codexHasHistoryBase) == true
        var readError = ""
        var projection: CodexStoredHistory
        if effective {
            (projection, readError) = codexEffectiveHistory(cid)
            // 另起的只读 app-server 不持写锁，会把别的客户端正在写的末轮报成 interrupted。
            // 写锁被占、这一轮是本分叉自己开的、rollout 里也没有结束事件，才是在别处运行中。
            // 空闲打开分叉的客户端同样占着写锁，继承自父会话的末轮要保持原结局。
            if let path = rolloutPath, let id = projection.latestKnownTurn, projection.endings[id]?.status == "interrupted",
               codexWriterActive(cid) == true, codexRolloutEnded(path, turnId: id) == false {
                projection.endings[id]?.status = "inProgress"
            }
        } else { projection = readCodexProjection(cid) }
        var decodedRollout: String?
        if !effective, !projection.items.isEmpty, let path = rolloutPath {
            let newer = codexProjectionTail(path: path, projection: projection)
            if let tail = newer.tail {
                mergeCodexProjection(tail, items: &projection.items, endings: &projection.endings)
                if includeContext { decodedRollout = tail.content }
            }
            readError = newer.error ?? ""
        }
        var messages = codexProjectedTurns(projection, cid:cid), lastTurn = projection.lastTurn
        if !effective, messages.isEmpty, let path = rolloutPath {
            if let content = readRollout(path) {
                if includeContext { decodedRollout = content }
                let parsed = codexRolloutTurns(content)
                messages = parsed.messages
                if lastTurn == nil { lastTurn = parsed.lastTurn }
                if cwd.isEmpty { cwd = parsed.cwd }
            } else { readError = "Codex 记录无法读取或解压" }
        }
        // 本机已确认这一轮停下或崩溃：历史遗留的 inProgress 不再交给界面当作「在别处运行中」。
        // 外部写入端崩溃也不会写结束事件；写锁已经没人占着，就没有谁还在写这一轮。
        if let turn = lastTurn, turn.running,
           messages.last?["localEndingTurn"] as? String == turn.turnId || codexWriterActive(cid) == false {
            lastTurn = HistoryTurnActivity(running: false, startedAt: turn.startedAt, updatedAt: turn.updatedAt)
        }
        if let path = rolloutPath, path.hasSuffix(".jsonl"), let stamp = modificationDate(path), var current = lastTurn {
            current.updatedAt = max(current.updatedAt, stamp.timeIntervalSince1970)
            lastTurn = current
        }
        if messages.isEmpty, rolloutPath == nil {
            readError = lookupError ?? projection.readError ?? historyAccessError(codexHome + "/state_5.sqlite") ?? readError
        }
        var payload: [String: Any] = ["messages": messages, "readError": readError,
            "agent": "gpt", "conversationId": cid, "cwd": cwd,
            "missing": messages.isEmpty && !inStateDb && rolloutPath == nil && readError.isEmpty]
        payload["lastTurn"] = lastTurn?.payload
        if includeContext, let path = rolloutPath {
            if let content = decodedRollout {
                payload["context"] = codexHistoryContext(content)
            } else if path.hasSuffix(".zst") {
                loadPackedContext(path, cid: cid)
            } else if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) {
                payload["context"] = codexHistoryContext(data)
            }
        }
        return payload
    }

    func loadCodex(cid: String, reqId: Int? = nil) {
        codexQueue.async { [self] in
            let readAt = historyReadAt()
            var payload = readCodexConversation(cid: cid, includeContext: true)
            payload["readAt"] = readAt
            sendToJS("onConversationLoaded", recentHistory(payload["messages"] as? [[String: Any]] ?? [], into: payload, reqId: reqId))
        }
    }

    func codexDbTurns(_ cid: String, databasePath: String? = nil) -> [[String: Any]] {
        codexProjectedTurns(readCodexProjection(cid, databasePath: databasePath), cid:cid)
    }

    func codexProjectedTurns(_ projection: CodexStoredHistory, cid: String = "") -> [[String: Any]] {
        var items = projection.items
        let endings = projection.endings
        if let latest = projection.latestKnownTurn, items.last?.turnId != latest {
            items = items.filter { $0.turnId != latest } + items.filter { $0.turnId == latest }
        }
        let g = CodexTurnGrouper(app: self, cid:cid, ticksPerSecond: 1000) { turnId, t, _ in
            let ending = endings[turnId]
            let outcome = ending.map { ["completed", "failed", "interrupted"].contains($0.status) ? $0.status : "incomplete" }
                ?? (t.steps.contains { $0["status"] as? String == "running" } ? "incomplete" : "completed")
            return (outcome, outcome == "failed" && ending?.error != "null" ? ending?.error : nil, ending?.status == "completed")
        }
        for item in items {
            g.enter(item.turnId)
            if item.type == "legacyUserMessage" { g.user(text: item.object["text"] as? String ?? "", turnId: item.turnId, at: item.created) }
            else if ["userMessage", "UserMessage"].contains(item.type) { g.userMessage(item.object["content"], turnId: item.turnId, at: item.created, completed: item.completed) }
            else {
                let afterAbort = endings[item.turnId]?.abortOrdinal.map { (item.completedOrdinal ?? item.ordinal) >= $0 } ?? false
                g.item(type: item.type, obj: item.object, turnId: item.turnId, at: item.created, completed: item.completed, afterAbort: afterAbort)
            }
            // 失败、停止前的等待没有条目，按回合表的结束时刻算（rollout 来源按结束事件，同一口径）。
            // 正常完成的一轮仍按条目算，和原来的显示一样
            if let ending = endings[item.turnId], ending.status != "completed", g.turnId == item.turnId { g.touch(ending.endedAt) }
        }
        g.flush()
        return g.out
    }
}
