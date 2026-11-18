// Codex 的历史会话：读它的 SQLite 和 rollout 记录；删除是归档。
import Cocoa
import SQLite3

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
    func activeRollouts() -> [(path: String, mtime: Date)] {
        let root = "\(codexHome)/sessions"
        var result: [(String, Date)] = []
        guard let walker = fm.enumerator(atPath: root) else { return [] }
        while let rel = walker.nextObject() as? String {
            guard rel.hasSuffix(".jsonl") || rel.hasSuffix(".jsonl.zst"), (rel as NSString).lastPathComponent.hasPrefix("rollout-") else { continue }
            let path = "\(root)/\(rel)"
            if let m = modificationDate(path) { result.append((path, m)) }
        }
        return result
    }

    func findRollout(cid: String, hint: String) -> String? {
        for p in [hint, hint + ".zst"] where !hint.isEmpty && fm.fileExists(atPath: p) { return p }
        let root = "\(codexHome)/sessions"
        guard let walker = fm.enumerator(atPath: root) else { return nil }
        while let rel = walker.nextObject() as? String {
            if rel.hasSuffix("-\(cid).jsonl") || rel.hasSuffix("-\(cid).jsonl.zst") { return "\(root)/\(rel)" }
        }
        return nil
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
    private func standaloneCodexRollouts(indexed: Set<String>) -> [[String: Any]] {
        var seen = indexed, items: [[String: Any]] = []
        for (path, mtime) in activeRollouts() {
            let name = path.dropLast(path.hasSuffix(".zst") ? 10 : 6)
            if seen.contains(String(name.suffix(36))) { continue }
            let ts = mtime.timeIntervalSince1970
            let item: [String: Any]?
            if let cached = codexRolloutCache[path], abs(cached.mtime - ts) < 0.001 {
                item = cached.item
            } else {
                item = path.hasSuffix(".zst") ? compressedRolloutSummary(path: path, mtime: mtime) : rolloutSummary(path: path, mtime: mtime)
                codexRolloutCache[path] = (ts, item)
            }
            if let item = item, let cid = item["id"] as? String, seen.insert(cid).inserted { items.append(item) }
        }
        return items
    }

    func listCodex() {
        codexQueue.async { [self] in
            var items: [[String: Any]] = []
            var seen = Set<String>()
            _ = withReadableSQLite("\(codexHome)/state_5.sqlite") { db in
                // source 以 { 开头的是子代理线程，不单独列出。
                queryRows(db, "SELECT id FROM threads") { seen.insert(columnText($0, 0)) }
                let sql = """
                    SELECT id, title, first_user_message, cwd, updated_at, source FROM threads
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

            items.append(contentsOf: standaloneCodexRollouts(indexed: seen))
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
        var inStateDb = false
        _ = withReadableSQLite("\(codexHome)/state_5.sqlite") { db in
            queryRows(db, "SELECT cwd, rollout_path FROM threads WHERE id = ? LIMIT 1;", [cid]) { s in
                cwd = columnText(s, 0)
                rolloutHint = columnText(s, 1)
                inStateDb = true
            }
        }

        var projection = readCodexProjection(cid)
        let rolloutPath = findRollout(cid: cid, hint: rolloutHint)
        var readError = ""
        var decodedRollout: String?
        if !projection.items.isEmpty, let path = rolloutPath {
            let newer = codexProjectionTail(path: path, projection: projection)
            if let tail = newer.tail {
                mergeCodexProjection(tail, items: &projection.items, endings: &projection.endings)
                if includeContext { decodedRollout = tail.content }
            }
            readError = newer.error ?? ""
        }
        var messages = codexProjectedTurns(projection), lastTurn = projection.lastTurn
        if messages.isEmpty, let path = rolloutPath {
            if let content = readRollout(path) {
                if includeContext { decodedRollout = content }
                let parsed = codexRolloutTurns(content)
                messages = parsed.messages
                if lastTurn == nil { lastTurn = parsed.lastTurn }
                if cwd.isEmpty { cwd = parsed.cwd }
            } else { readError = "Codex 记录无法读取或解压" }
        }
        if let path = rolloutPath, path.hasSuffix(".jsonl"), let stamp = modificationDate(path), var current = lastTurn {
            current.updatedAt = max(current.updatedAt, stamp.timeIntervalSince1970)
            lastTurn = current
        }
        var payload: [String: Any] = ["messages": messages, "readError": readError,
            "agent": "gpt", "conversationId": cid, "cwd": cwd,
            "missing": messages.isEmpty && !inStateDb && rolloutPath == nil]
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
            let payload = readCodexConversation(cid: cid, includeContext: true)
            sendToJS("onConversationLoaded", recentHistory(payload["messages"] as? [[String: Any]] ?? [], into: payload, reqId: reqId))
        }
    }

    /// Codex 历史条目（数据库里是 camelCase，rollout 里是 PascalCase）→ 工作步骤。
    func codexHistoryItem(type: String, obj: [String: Any], turn: TurnBuilder, finalAnswer: inout String, afterAbort: Bool = false) {
        let itemStatus = obj["status"] as? String ?? "completed"
        let stepStatus = ["failed", "declined"].contains(itemStatus) ? "error" : (itemStatus == "completed" ? "ok" : "running")
        switch type {
        case "agentMessage", "AgentMessage":
            let text = trimmed((obj["text"] as? String) ?? textOf(obj["content"]))
            guard !text.isEmpty else { return }
            if obj["phase"] as? String == "final_answer" {
                finalAnswer = finalAnswer.isEmpty ? text : finalAnswer + "\n\n" + text
            } else {
                turn.add(makeStep("text", "说明", detail: text))
            }
        case "reasoning", "Reasoning":
            turn.addThink(trimmed(textOf(obj["summary"] ?? obj["summary_text"])))
        case "commandExecution", "CommandExecution":
            let command = (obj["command"] as? String) ?? ((obj["command"] as? [String])?.last ?? "")
            let exitCode = (obj["exitCode"] as? NSNumber)?.intValue ?? (obj["exit_code"] as? NSNumber)?.intValue ?? 0
            let status = obj["status"] as? String ?? "completed"
            let failed = status == "failed" || status == "declined" || exitCode != 0
            var step = makeStep("command", "运行命令", detail: command, status: failed ? "error" : (status == "completed" ? "ok" : "running"))
            // turn_aborted 后补写的 -1 表示命令没拿到退出码。中断之前就失败的命令保留红色。
            if afterAbort, status == "failed", exitCode == -1 { step["status"] = "interrupted" }
            let output = status == "declined" ? "没有执行：没有得到同意" : trimmed((obj["aggregatedOutput"] as? String) ?? (obj["aggregated_output"] as? String))
            if !output.isEmpty { step["output"] = clip(output, maxOutput) }
            turn.add(step)
        case "fileChange", "FileChange":
            let status = obj["status"] as? String ?? "completed"
            for change in codexChanges(obj["changes"]) {
                var step = fileStep(kind: change.kind, path: change.path)
                if status == "failed" || status == "declined" {
                    step["status"] = "error"
                    step["output"] = status == "declined" ? "没有改：没有得到同意" : "没有改成"
                } else if status != "completed" { step["status"] = "running" }
                turn.add(step)
                if status == "completed" { turn.addFile(change.path, kind: change.kind, diff: change.diff) }
            }
        case "mcpToolCall", "McpToolCall":
            turn.add(makeStep("tool", "调用 \(obj["server"] as? String ?? "") · \(obj["tool"] as? String ?? "")", status: stepStatus))
        case "dynamicToolCall", "DynamicToolCall":
            turn.add(makeStep("tool", "调用 \(obj["tool"] as? String ?? "工具")", status: stepStatus))
        case "webSearch", "WebSearch":
            turn.add(makeStep("web", "联网搜索 \(obj["query"] as? String ?? "")", status: stepStatus))
        case "imageGeneration", "ImageGeneration":
            let path = (obj["savedPath"] as? String) ?? (obj["saved_path"] as? String)
            turn.add(makeStep("tool", "生成图片", path: path, status: stepStatus))
            if let path = path, obj["status"] as? String == "completed" { turn.addFile(path, kind: "create") }
        case "contextCompaction", "ContextCompaction":
            turn.add(makeStep("tool", "压缩上下文"))
        case "imageView", "ImageView":
            turn.add(makeStep("read", "查看图片", path: obj["path"] as? String))
        case "collabAgentToolCall", "CollabAgentToolCall":
            turn.add(makeStep("agent", "协作子代理", status: stepStatus))
        default:
            break
        }
    }

    func codexChanges(_ raw: Any?) -> [(path: String, kind: String, diff: String?)] {
        if let list = raw as? [[String: Any]] {
            return list.compactMap { c in
                guard let path = c["path"] as? String else { return nil }
                return (path, codexChangeKind(c["kind"]), (c["diff"] as? String) ?? (c["unified_diff"] as? String))
            }
        }
        if let map = raw as? [String: Any] {
            return map.map { path, value in
                let d = value as? [String: Any] ?? [:]
                return (path, codexChangeKind(d["type"] ?? d["kind"]), (d["unified_diff"] as? String) ?? (d["diff"] as? String))
            }
        }
        return []
    }

    func codexDbTurns(_ cid: String, databasePath: String? = nil) -> [[String: Any]] {
        codexProjectedTurns(readCodexProjection(cid, databasePath: databasePath))
    }

    func codexProjectedTurns(_ projection: CodexStoredHistory) -> [[String: Any]] {
        var items = projection.items
        let endings = projection.endings
        if let latest = projection.latestKnownTurn, items.last?.turnId != latest {
            items = items.filter { $0.turnId != latest } + items.filter { $0.turnId == latest }
        }
        let g = CodexTurnGrouper(app: self, ticksPerSecond: 1000) { turnId, t, _ in
            let ending = endings[turnId]
            let outcome = ending.map { ["completed", "failed", "interrupted"].contains($0.status) ? $0.status : "incomplete" }
                ?? (t.steps.contains { $0["status"] as? String == "running" } ? "incomplete" : "completed")
            return (outcome, outcome == "failed" && ending?.error != "null" ? ending?.error : nil)
        }
        for item in items {
            g.enter(item.turnId)
            if item.type == "legacyUserMessage" { g.user(text: item.object["text"] as? String ?? "", turnId: item.turnId, at: item.created) }
            else if ["userMessage", "UserMessage"].contains(item.type) { g.userMessage(item.object["content"], turnId: item.turnId, at: item.created, completed: item.completed) }
            else {
                let afterAbort = endings[item.turnId]?.abortOrdinal.map { (item.completedOrdinal ?? item.ordinal) >= $0 } ?? false
                g.item(type: item.type, obj: item.object, turnId: item.turnId, at: item.created, completed: item.completed, afterAbort: afterAbort)
            }
        }
        g.flush()
        return g.out
    }
}


/// Codex 的历史有两个来源（数据库、rollout 文件），记录的外形不同，但「怎么归成一问一答」是同一套：
/// 用户消息开一轮；同一个回合里再来的用户消息是中途补充，算这一轮里的一步「你补充说」；回合身份变了就收尾。
/// 两个来源只管把记录喂进来，这样改归组的规则只用改这一处。
final class CodexTurnGrouper {
    /// 收尾时这一轮的结局由来源决定（数据库查回合表，rollout 看结束事件）
    typealias Ending = (_ turnId: String, _ turn: TurnBuilder, _ finalAnswer: String) -> (outcome: String, error: String?)
    private unowned let app: AppDelegate
    private let ticksPerSecond: Double   // 时间戳的单位：数据库是毫秒，rollout 是秒
    private let ending: Ending
    private(set) var out: [[String: Any]] = []
    private(set) var turn: TurnBuilder?
    private(set) var turnId = ""
    private var acceptsSteers = false
    private var finalAnswer = ""
    private var stepTimes: [Double] = []
    private var needsOrder = false
    private var start: Double?
    private var end: Double?

    init(app: AppDelegate, ticksPerSecond: Double, ending: @escaping Ending) {
        self.app = app
        self.ticksPerSecond = ticksPerSecond
        self.ending = ending
    }

    /// 这条记录属于别的回合：把手头这一轮收尾。没有回合身份的旧记录不靠它分轮。
    func enter(_ id: String) {
        if !id.isEmpty, !turnId.isEmpty, id != turnId { flush() }
    }

    /// 还没有开着的一轮就开一轮（回答先于提问出现、或只有结束事件的回合）
    func begin(_ id: String, at: Double?) {
        guard turn == nil else { return }
        turn = TurnBuilder(); turnId = id; acceptsSteers = true; start = at
    }

    func touch(_ at: Double?) {
        if let at = at { end = max(end ?? at, at) }
    }

    /// 这一轮已经结束：之后同一回合再来的用户消息不算补充（晚落盘的命令结果仍然算这一轮的）
    func closeToSteers() { acceptsSteers = false }

    func userMessage(_ content: Any?, turnId id: String, at: Double?, completed: Double?) {
        let images = codexImageSources(content)
        let text = stripCodexAttachmentHeader(app.stripPersonaPrefix(app.textBlocks(content)), images: images)
        guard !text.isEmpty || !images.isEmpty else { return }
        if let t = turn, acceptsSteers, !id.isEmpty, id == turnId {
            var step = makeStep("user", "你补充说", detail: text)
            if !images.isEmpty { step["imageSources"] = images }
            t.add(step)
            stampSteps(at)
            touch(completed)
            return
        }
        flush()
        out.append(images.isEmpty ? ["role": "user", "text": text] : ["role": "user", "text": text, "imageSources": images])
        turn = TurnBuilder(); turnId = id; acceptsSteers = true; start = at; end = at
    }

    /// 旧格式里只有文字的一句提问
    func user(text: String, turnId id: String = "", at: Double? = nil) {
        flush()
        out.append(["role": "user", "text": text])
        turn = TurnBuilder(); turnId = id; acceptsSteers = true; start = at; end = at
    }

    func item(type: String, obj: [String: Any], turnId id: String, at: Double?, completed: Double?, afterAbort: Bool = false) {
        begin(id, at: at)
        touch(completed)
        if let t = turn { app.codexHistoryItem(type: type, obj: obj, turn: t, finalAnswer: &finalAnswer, afterAbort: afterAbort) }
        stampSteps(at)
    }

    /// 命令在完成时才入库，开始时间可能早于已记录的补充。只在本轮出现倒序时排序，同时间保留原序。
    func stampSteps(_ at: Double?) {
        guard let count = turn?.steps.count, stepTimes.count < count else { return }
        let time = at ?? stepTimes.last ?? 0
        if let last = stepTimes.last, time < last { needsOrder = true }
        stepTimes.append(contentsOf: repeatElement(time, count: count - stepTimes.count))
    }

    func flush() {
        guard let t = turn else { return }
        let result = ending(turnId, t, finalAnswer)
        let order = needsOrder ? stepTimes.indices.sorted {
            stepTimes[$0] == stepTimes[$1] ? $0 < $1 : stepTimes[$0] < stepTimes[$1]
        } : nil
        var bot = t.finish(finalText: finalAnswer, outcome: result.outcome, error: result.error, stepOrder: order)
        stepTimes.removeAll(keepingCapacity: true); needsOrder = false
        if let s = start, let e = end, e > s { bot["duration"] = (e - s) / ticksPerSecond }
        if !trimmed(bot["text"] as? String).isEmpty || !((bot["steps"] as? [Any]) ?? []).isEmpty {
            bot["role"] = "bot"
            out.append(bot)
        }
        turn = nil; turnId = ""; acceptsSteers = false; finalAnswer = ""
    }
}
