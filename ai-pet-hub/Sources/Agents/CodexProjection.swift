// SQLite 是 rollout 的异步投影；按游标补齐尾部，保留数据库已投影条目的字段和同一套回合归组。
//
// Codex 回退或分叉记录的首行带 history_base 或 forked_from_id 时，打开和搜索通过只读 thread/read 取得有效回合；这个只读进程会把别的客户端正在写的末轮报成中断，
// 所以写锁（`thread-writer-locks/<id>.lock`）被占、这一轮是本分叉自己开的、rollout 里又没有结束事件时仍按在别处运行；空闲打开分叉的客户端也占写锁，
// 继承自父会话的末轮（rollout 里没有它的开始，或复制来的开始早于分叉创建）保持原结局。
// 反过来，外部写入端崩溃不写结束事件，任何来源里未完成的末轮在写锁已释放时都不再算在别处运行，重试照常显示；没有锁目录的旧版 CLI 仍按磁盘记录。
//
// 数据库投影落后时按实际游标补齐尾部，保留数据库已有字段，同一条目的新结果覆盖旧结果。
// 失败、停止的回合按回合表的结束时刻算工作时长，正常完成的仍按条目。
import Foundation
import SQLite3

struct CodexProjectionTail {
    let content: String
    let ordinal: Int64
}

struct CodexStoredItem {
    var type: String
    var object: [String: Any]
    let turnId: String
    let id: String
    var created: Double
    var completed: Double
    let ordinal: Int64
    var completedOrdinal: Int64?
}

struct CodexStoredTurn {
    var status: String
    var error: String
    let ordinal: Int64
    let startedAt: Double
    var abortOrdinal: Int64?
    /// 回合表记下的结束时刻（毫秒）。失败或停止前可能久等而没有新条目，只看条目会少算这段等待
    var endedAt: Double? = nil
}

struct CodexStoredHistory {
    var readError: String?
    var items: [CodexStoredItem] = []
    var endings: [String: CodexStoredTurn] = [:]
    var byteOffset: Int64?
    var nextOrdinal: Int64?
    // 旧命令的输出可能晚于下一轮开始。最后一轮按开启顺序判断；没有回合信息的旧格式仍按条目顺序。
    var latestKnownTurn: String? {
        guard let last = items.last, endings[last.turnId] != nil else { return nil }
        return endings.max { $0.value.ordinal < $1.value.ordinal }?.key
    }
    var lastTurn: HistoryTurnActivity? {
        guard let id = latestKnownTurn, let turn = endings[id],
              ["inProgress", "completed", "interrupted", "failed"].contains(turn.status) else { return nil }
        let rows = items.lazy.filter { $0.turnId == id }
        let start = turn.startedAt > 0 ? turn.startedAt : (rows.first?.created ?? 0) / 1000
        return HistoryTurnActivity(running: turn.status == "inProgress", startedAt: start,
                                   updatedAt: max(start, (rows.map(\.completed).max() ?? 0) / 1000), turnId: id)
    }
}

extension AppDelegate {
    /// 分叉和回退的有效前缀可以在其他段中，只有 Codex 自己知道最终保留了哪些回合。
    func codexRolloutMeta(_ path: String) -> [String: Any]? {
        let header: [String: Any]?
        if path.hasSuffix(".zst") {
            guard let zstd = hooks.cliExecutable ?? findExecutable(["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]) else { return nil }
            let first = runTool("/bin/sh", ["-c", #""$1" -dc "$2" | /usr/bin/head -n 1"#, "sh", zstd, path], cwd: home, timeout: 30)
            header = jsonObject(first.out)
        } else {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped),
                  !data.isEmpty else { return nil }
            let end = data.firstIndex(of: 10) ?? data.endIndex
            header = jsonObject(Data(data[..<end]))
        }
        guard header?["type"] as? String == "session_meta" else { return nil }
        return header?["payload"] as? [String: Any]
    }

    func codexHasHistoryBase(_ path: String) -> Bool {
        guard let meta = codexRolloutMeta(path) else { return false }
        return meta["history_base"] is [String: Any] || meta["forked_from_id"] is String
    }

    /// 写入端对 thread-writer-locks/<id>.lock 持 flock 独占锁；正常释放会删掉文件，崩溃只留下没人锁着的文件。
    /// 没有这个目录的旧版 CLI 不写锁，返回 nil，调用方仍按磁盘记录判断。
    func codexWriterActive(_ cid: String) -> Bool? {
        let dir = codexHome + "/thread-writer-locks"
        guard isSafeId(cid), fm.fileExists(atPath: dir) else { return nil }
        let fd = open(dir + "/" + cid + ".lock", O_RDONLY)
        guard fd >= 0 else { return errno == ENOENT ? false : nil }
        defer { close(fd) }
        // 共享锁只和写入端的独占锁冲突；拿到就立即放开，不挡后来的写入端。
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { return errno == EWOULDBLOCK ? true : nil }
        flock(fd, LOCK_UN)
        return false
    }

    /// 这一轮在 rollout 里有没有结束事件。末轮的结束事件就在文件尾部，从后往前读到这一轮的 task_started 为止，不读整份。
    /// nil 表示这一轮不是这份 rollout 自己开的：用户分叉（history_base）的 rollout 里没有父会话的回合，
    /// 复制父历史的分叉（现行 CLI 的 forked_from_id 子智能体分叉也是这样，0.167.1 实测）带着开始早于分叉创建的 task_started。继承来的回合结局由父会话定，写锁说明不了它还在跑。
    func codexRolloutEnded(_ path: String, turnId: String) -> Bool? {
        guard path.hasSuffix(".jsonl"), let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return false }
        let needle = Data(turnId.utf8), endTypes = ["task_complete", "turn_aborted", "turn_failed"]
        var end = data.endIndex
        while end > data.startIndex {
            let start = data[..<end].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let line = data[start..<end]
            end = start > data.startIndex ? start - 1 : data.startIndex
            guard line.range(of: needle) != nil || endTypes.contains(where: { line.range(of: Data($0.utf8)) != nil }),
                  let payload = jsonObject(Data(line))?["payload"] as? [String: Any] else { continue }
            let type = payload["type"] as? String ?? "", owner = payload["turn_id"] as? String
            // 旧版只在 task_started 写编号：本轮开始之后没有编号的结束事件也算本轮的。
            if endTypes.contains(type), owner == nil || owner == turnId { return true }
            if type == "task_started", owner == turnId {
                // started_at 只到秒；分叉自己的第一轮可能和分叉创建落在同一秒，所以和创建时间的整秒比。没有时间的旧格式按本 rollout 的回合算。
                let head = data[..<(data.firstIndex(of: 0x0A) ?? data.endIndex)]
                guard let at = payload["started_at"] as? Double,
                      let created = contextTime((jsonObject(Data(head))?["payload"] as? [String: Any])?["timestamp"] as? String) else { return false }
                return at >= (created / 1000).rounded(.down) ? false : nil
            }
        }
        return nil
    }

    func codexEffectiveHistory(_ cid: String) -> (CodexStoredHistory, String) {
        var history = CodexStoredHistory(), error = "Codex 未返回有效历史"
        guard let exe = codexExecutable() else { return (history, "找不到 Codex，无法读取有效历史") }
        let input = LiveInput(), cli = CLIProcess(input: input)
        cli.warmFilter = { line in
            guard let row = self.jsonObject(line), row["method"] == nil, let id = row["id"] as? Int else { return true }
            if let why = row["error"] as? [String: Any] { error = why["message"] as? String ?? error; input.close(); return true }
            if id == 1 {
                input.send(["method": "initialized"])
                input.send(["id": 2, "method": "thread/read", "params": ["threadId": cid, "includeTurns": true]])
            } else if id == 2 {
                defer { input.close() }
                guard let result = row["result"] as? [String: Any], let thread = result["thread"] as? [String: Any],
                      thread["id"] as? String == cid, let turns = thread["turns"] as? [[String: Any]] else { return true }
                for (index, turn) in turns.enumerated() {
                    guard let tid = turn["id"] as? String else { continue }
                    let start = turn["startedAt"] as? Double ?? 0
                    history.endings[tid] = CodexStoredTurn(status: turn["status"] as? String ?? "", error: (turn["error"] as? [String: Any])?["message"] as? String ?? "",
                        ordinal: Int64(index), startedAt: start)
                    let items = turn["items"] as? [[String: Any]] ?? []
                    for item in items.isEmpty ? [[:]] : items {
                        let created = item["startedAtMs"] as? Double ?? start * 1000
                        history.items.append(CodexStoredItem(type: item["type"] as? String ?? "", object: item,
                            turnId: tid, id: item["id"] as? String ?? "", created: created,
                            completed: item["completedAtMs"] as? Double ?? (turn["completedAt"] as? Double).map { $0 * 1000 } ?? created,
                            ordinal: Int64(history.items.count)))
                    }
                }
                error = ""
            }
            return true
        }
        do { try cli.start(executable: exe, arguments: ["app-server"], cwd: home, environment: cliEnvironment(["CODEX_HOME": codexHome])) }
        catch { return (history, error.localizedDescription) }
        input.send(codexInitialize)
        _ = cli.waitForExit(until: .now() + 30) { terminateTree(cli.proc.processIdentifier) }
        input.close()
        return (history, error)
    }

    func readCodexProjection(_ cid: String, databasePath: String? = nil) -> CodexStoredHistory {
        var projection = CodexStoredHistory()
        let path = databasePath ?? "\(codexHome)/thread_history_1.sqlite"
        let opened: Void? = withReadableSQLite(path) { db in
            // 条目、结局、游标必须来自同一快照；否则 CLI 推进游标时会把刚才读到的旧条目误当成完整投影。
            guard sqlite3_exec(db, "BEGIN;", nil, nil, nil) == SQLITE_OK else { return }
            defer { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }
            let immutable = sqlite3_uri_boolean(sqlite3_db_filename(db, "main"), "immutable", 0) != 0
            let earlierProgress = immutable ? codexProjectionProgress(db, cid: cid) : nil
            var items: [CodexStoredItem] = [], endings: [String: CodexStoredTurn] = [:]
            // 旧数据库可能没有回合身份；这时仍按每条用户消息分轮，不猜补充。
            var hasTurnId = false, hasItemId = false, hasStarted = false, hasUpdatedOrdinal = false
            queryRows(db, "PRAGMA table_info(thread_items);") { s in
                switch columnText(s, 1) {
                case "turn_id": hasTurnId = true
                case "started_at_ms": hasStarted = true
                case "item_id": hasItemId = true
                case "updated_at_ordinal": hasUpdatedOrdinal = true
                default: break
                }
            }
            if hasTurnId {
                // 较老的投影没有结束序号，仍可读取原来的回合和条目。
                let hasEnd = sqlite3_table_column_metadata(db, nil, "thread_turns", "rollout_end_ordinal", nil, nil, nil, nil, nil) == SQLITE_OK
                let hasDuration = sqlite3_table_column_metadata(db, nil, "thread_turns", "duration_ms", nil, nil, nil, nil, nil) == SQLITE_OK
                let sql = "SELECT turn_id, status, error_json, rollout_ordinal, started_at, \(hasEnd ? "rollout_end_ordinal" : "NULL"), completed_at * 1000, \(hasDuration ? "started_at * 1000 + duration_ms" : "NULL") FROM thread_turns WHERE thread_id = ?;"
                queryRows(db, sql, [cid]) { s in
                    let status = columnText(s, 1)
                    let abort = status == "interrupted" && sqlite3_column_type(s, 5) != SQLITE_NULL ? sqlite3_column_int64(s, 5) : nil
                    // 起止都只记到秒（截掉零头），起点加毫秒时长和结束秒数都不会晚于真正结束，取较晚的那个更接近
                    let ends = [Int32(6), 7].filter { sqlite3_column_type(s, $0) != SQLITE_NULL }.map { sqlite3_column_double(s, $0) }
                    endings[columnText(s, 0)] = CodexStoredTurn(status: status, error: codexReadableError(columnText(s, 2)),
                        ordinal: sqlite3_column_int64(s, 3), startedAt: sqlite3_column_double(s, 4), abortOrdinal: abort, endedAt: ends.max())
                }
            }
            // 失败可能发生在任何 item 落盘之前，必须把这种回合也放回原来的顺序。
            let emptyTurns = endings.isEmpty ? "" : """
                UNION ALL SELECT '', '{}', started_at * 1000, COALESCE(completed_at, started_at) * 1000, turn_id, rollout_ordinal, '', NULL
                FROM thread_turns t WHERE thread_id = ? AND NOT EXISTS (
                    SELECT 1 FROM thread_items i WHERE i.thread_id = t.thread_id AND i.turn_id = t.turn_id)
                """
            let sql = """
                SELECT item_type, item_json, \(hasStarted ? "COALESCE(started_at_ms, created_at_ms)" : "created_at_ms"), COALESCE(completed_at_ms, created_at_ms), \(hasTurnId ? "turn_id" : "NULL"), rollout_ordinal, \(hasItemId ? "item_id" : "''"), \(hasUpdatedOrdinal ? "updated_at_ordinal" : "NULL")
                FROM thread_items WHERE thread_id = ?
                \(emptyTurns)
                ORDER BY rollout_ordinal ASC;
                """
            queryRows(db, sql, emptyTurns.isEmpty ? [cid] : [cid, cid]) { s in
                let type = columnText(s, 0)
                guard let obj = jsonObject(columnText(s, 1)) else { return }
                let created = Double(sqlite3_column_int64(s, 2))
                let completed = Double(sqlite3_column_int64(s, 3))
                let turnId = columnText(s, 4)
                items.append(CodexStoredItem(type: type, object: obj, turnId: turnId,
                    id: (obj["id"] as? String) ?? columnText(s, 6), created: created, completed: completed,
                    ordinal: sqlite3_column_int64(s, 5), completedOrdinal: sqlite3_column_type(s, 7) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 7)))
            }
            hooks.codexProjectionRead?()
            var progress = codexProjectionProgress(db, cid: cid)
            if let earlier = earlierProgress {
                // 缺 WAL 辅助文件时共享读取器退回 immutable，它不持有读取锁；只采用读条目前后的较早进度。
                // 无法确认进度则从头按 item 身份合并，不能用晚到的游标掩盖刚读到的旧条目。
                func earlierValue(_ a: Int64?, _ b: Int64?) -> Int64? {
                    guard let a = a, let b = b else { return nil }
                    return min(a, b)
                }
                progress = (earlierValue(earlier.0, progress.0), earlierValue(earlier.1, progress.1))
            }
            projection.items = items; projection.endings = endings
            projection.byteOffset = progress.0; projection.nextOrdinal = progress.1
        }
        if opened == nil {
            projection.readError = historyAccessError(path) ?? (fm.fileExists(atPath: path) ? "Codex 正文数据库无法读取" : nil)
        }
        return projection
    }

    private func codexProjectionProgress(_ db: OpaquePointer, cid: String) -> (Int64?, Int64?) {
        var byteOffset: Int64?, nextOrdinal: Int64?
        queryRows(db, "SELECT next_rollout_byte_offset, next_rollout_ordinal FROM thread_history_projection_state WHERE thread_id = ?;", [cid]) { row in
            byteOffset = sqlite3_column_int64(row, 0); nextOrdinal = sqlite3_column_int64(row, 1)
        }
        guard nextOrdinal == nil else { return (byteOffset, nextOrdinal) }
        // 老版本没有投影表，但条目/回合仍保存真实 rollout 序号；不能拿消息条数或文件时间猜进度。
        var last: Int64 = -1
        for (table, candidates) in [("thread_items", ["rollout_ordinal", "updated_at_ordinal"]),
                                    ("thread_turns", ["rollout_ordinal", "rollout_end_ordinal"])] {
            var columns = Set<String>()
            queryRows(db, "PRAGMA table_info(\(table));") { columns.insert(columnText($0, 1)) }
            for column in candidates where columns.contains(column) {
                queryRows(db, "SELECT MAX(\(column)) FROM \(table) WHERE thread_id = ?;", [cid]) { row in
                    if sqlite3_column_type(row, 0) != SQLITE_NULL { last = max(last, sqlite3_column_int64(row, 0)) }
                }
            }
        }
        if last >= 0 { nextOrdinal = last + 1 }
        return (byteOffset, nextOrdinal)
    }

    func codexProjectionTail(path: String, projection: CodexStoredHistory) -> (tail: CodexProjectionTail?, error: String?) {
        let byteOffset = projection.byteOffset, nextOrdinal = projection.nextOrdinal
        if path.hasSuffix(".jsonl"), let byteOffset = byteOffset,
           let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber,
           byteOffset >= size.int64Value { return (nil, nil) }
        // 完整投影只需核对解压长度，不能为判断“没有尾部”重新遍历几百 MB 的正文。
        if let byteOffset = byteOffset, nextOrdinal != nil,
           let size = rolloutUncompressedSize(path), byteOffset == size { return (nil, nil) }
        guard let content = readRollout(path) else { return (nil, "Codex 记录无法读取或解压，当前仅有数据库投影") }
        let completeLines = content.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        let ordinal = max(0, nextOrdinal ?? 0)
        guard ordinal < completeLines else { return (nil, nil) }
        // 镜像可以分跨游标两侧，必须先整份配对；合并时再用来源序号筛选尾部。
        return (CodexProjectionTail(content: content, ordinal: ordinal), nil)
    }

    func mergeCodexProjection(_ tail: CodexProjectionTail, items: inout [CodexStoredItem],
                              endings: inout [String: CodexStoredTurn]) {
        var activeTurn = items.last?.turnId ?? ""
        for event in rolloutEvents(tail.content).events where event.latestSourceOrdinal >= tail.ordinal {
            let payload = event.payload, type = payload["type"] as? String ?? ""
            let explicitTurn = payload["turn_id"] as? String ?? ""
            if !explicitTurn.isEmpty { activeTurn = explicitTurn }
            let ordinal = event.ordinal
            let time = (event.timestamp ?? 0) * 1000
            if type == "task_started" {
                if activeTurn.isEmpty || explicitTurn.isEmpty { activeTurn = "rollout-task-\(ordinal)" }
                endings[activeTurn] = CodexStoredTurn(status: "inProgress", error: "", ordinal: ordinal, startedAt: event.timestamp ?? 0)
                if !items.contains(where: { $0.turnId == activeTurn }) {
                    items.append(CodexStoredItem(type: "", object: [:], turnId: activeTurn, id: "", created: time, completed: time, ordinal: ordinal))
                }
            } else if ["task_complete", "turn_aborted", "turn_failed"].contains(type) {
                let previous = endings[activeTurn]
                let status = codexRolloutEnding(type, payload)
                let error = ((payload["error"] as? [String: Any])?["message"] as? String).map(codexReadableError) ?? ""
                endings[activeTurn] = CodexStoredTurn(status: status, error: error, ordinal: previous?.ordinal ?? ordinal, startedAt: previous?.startedAt ?? 0,
                                                     abortOrdinal: status == "interrupted" ? ordinal : nil)
                if !items.contains(where: { $0.turnId == activeTurn }) {
                    items.append(CodexStoredItem(type: "", object: [:], turnId: activeTurn, id: "", created: time, completed: time, ordinal: ordinal))
                }
            } else if type == "item_completed", var obj = payload["item"] as? [String: Any], let kind = obj["type"] as? String {
                let id = obj["id"] as? String ?? ""
                let started = (payload["started_at_ms"] as? NSNumber)?.doubleValue
                // 数据库是 camelCase，rollout 是 snake_case；新结果不能被旧字段的优先读取顺序遮住。
                for (raw, projected) in [("exit_code", "exitCode"), ("aggregated_output", "aggregatedOutput"), ("summary_text", "summary")] {
                    if let value = obj[raw] { obj[projected] = value }
                }
                if kind == "AgentMessage", let content = obj["content"], obj["text"] == nil { obj["text"] = textOf(content) }
                if obj["status"] == nil { obj["status"] = "completed" }
                if !id.isEmpty, let index = items.firstIndex(where: { $0.id == id && $0.turnId == activeTurn }) {
                    obj.forEach { items[index].object[$0.key] = $0.value }
                    items[index].type = kind
                    items[index].completedOrdinal = ordinal
                    if let started = started { items[index].created = started }
                    if event.timestamp != nil { items[index].completed = time }
                } else {
                    items.append(CodexStoredItem(type: kind, object: obj, turnId: activeTurn, id: id, created: started ?? time, completed: time, ordinal: ordinal))
                }
            } else if type == "user_message", let text = payload["message"] as? String {
                // 没有回合身份的旧格式仍按每句提问分轮；不能猜它是同轮补充。
                if explicitTurn.isEmpty, endings[activeTurn]?.status != "inProgress" { activeTurn = "rollout-legacy-\(ordinal)" }
                items.append(CodexStoredItem(type: "legacyUserMessage", object: ["text": trimmed(text)], turnId: activeTurn, id: "", created: time, completed: time, ordinal: ordinal))
            } else if type == "agent_message", let text = payload["message"] as? String {
                items.append(CodexStoredItem(type: "agentMessage", object: ["text": trimmed(text)], turnId: activeTurn, id: "", created: time, completed: time, ordinal: ordinal))
            }
        }
        // thread_turns 可能先于首个 item 投影；补到真实提问后，空占位不能再提前开启回合而把提问当补充。
        let populatedTurns = Set(items.filter { !$0.type.isEmpty }.map(\.turnId))
        items.removeAll { $0.type.isEmpty && populatedTurns.contains($0.turnId) }
        items = items.enumerated().sorted { a, b in
            a.element.ordinal == b.element.ordinal ? a.offset < b.offset : a.element.ordinal < b.element.ordinal
        }.map(\.element)
    }
}
