// SQLite 是 rollout 的异步投影；按游标补齐尾部，保留数据库已投影条目的字段和同一套回合归组。
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
}

struct CodexStoredHistory {
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
                                   updatedAt: max(start, (rows.map(\.completed).max() ?? 0) / 1000))
    }
}

extension AppDelegate {
    func readCodexProjection(_ cid: String, databasePath: String? = nil) -> CodexStoredHistory {
        var projection = CodexStoredHistory()
        _ = withReadableSQLite(databasePath ?? "\(codexHome)/thread_history_1.sqlite") { db in
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
                let sql = "SELECT turn_id, status, error_json, rollout_ordinal, started_at, \(hasEnd ? "rollout_end_ordinal" : "NULL") FROM thread_turns WHERE thread_id = ?;"
                queryRows(db, sql, [cid]) { s in
                    let status = columnText(s, 1)
                    let abort = status == "interrupted" && sqlite3_column_type(s, 5) != SQLITE_NULL ? sqlite3_column_int64(s, 5) : nil
                    endings[columnText(s, 0)] = CodexStoredTurn(status: status, error: codexReadableError(columnText(s, 2)),
                        ordinal: sqlite3_column_int64(s, 3), startedAt: sqlite3_column_double(s, 4), abortOrdinal: abort)
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
                let status = type == "turn_aborted" ? "interrupted" : (type == "turn_failed" ? "failed" : "completed")
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
