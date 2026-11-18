// CLI 内部日志只是可选的提示信号：格式不认识或库读不了时，回答照常继续。
import Foundation
import SQLite3

struct CodexRetryRecord {
    let id: Int64
    let statusCode: Int?
    let waitSeconds: TimeInterval
    let recordedAt: Date
    let message: String
}

extension AppDelegate {
    /// 只读当前 thread 的最新重试；可用本轮 CLI 的 PID 再限定 process_uuid。
    /// 依据 logs_2.sqlite 的实际 schema / responses_retry WARN，不把一般警告猜成重试。
    func codexLatestRetry(threadId: String, since: Date, processID: pid_t? = nil,
                          databasePath: String? = nil) -> CodexRetryRecord? {
        guard !threadId.isEmpty, since.timeIntervalSince1970.isFinite else { return nil }
        return withReadableSQLite(databasePath ?? "\(codexHome)/logs_2.sqlite", busyTimeout: 50) { db -> CodexRetryRecord? in
            // 即使 CLI 升级移除了索引，也不允许这次可选查询长时间扫描整个日志库。
            var deadline = ProcessInfo.processInfo.systemUptime + 0.1
            return withUnsafeMutablePointer(to: &deadline) { deadlinePtr in
                sqlite3_progress_handler(db, 1000, { context in
                    guard let context = context else { return 1 }
                    return ProcessInfo.processInfo.systemUptime >= context.assumingMemoryBound(to: Double.self).pointee ? 1 : 0
                }, deadlinePtr)
                defer { sqlite3_progress_handler(db, 0, nil, nil) }
                var columns = Set<String>()
                queryRows(db, "PRAGMA table_info(logs);") { columns.insert(columnText($0, 1)) }
                let required: Set<String> = ["id", "ts", "ts_nanos", "level", "target", "feedback_log_body", "thread_id", "process_uuid"]
                guard required.isSubset(of: columns) else { return nil }
                var binds = [threadId, String(floor(since.timeIntervalSince1970))]
                if let pid = processID { binds.append("pid:\(pid):%") }
                let sql = """
                    SELECT id, ts, ts_nanos, feedback_log_body FROM logs
                    WHERE thread_id = ? AND ts >= CAST(? AS INTEGER)
                      AND target = 'codex_core::responses_retry' AND level = 'WARN'
                      AND feedback_log_body LIKE '%stream disconnected - retrying sampling request (%'
                      \(processID == nil ? "" : "AND process_uuid LIKE ?")
                    ORDER BY ts DESC, ts_nanos DESC, id DESC LIMIT 1;
                    """
                var record: CodexRetryRecord?
                queryRows(db, sql, binds) { s in
                    guard sqlite3_column_type(s, 0) == SQLITE_INTEGER,
                          sqlite3_column_type(s, 1) == SQLITE_INTEGER,
                          sqlite3_column_type(s, 2) == SQLITE_INTEGER else { return }
                    let nanos = sqlite3_column_int64(s, 2)
                    guard (0..<1_000_000_000).contains(nanos) else { return }
                    let at = Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 1)) + Double(nanos) / 1e9)
                    guard at > since else { return }
                    let message = columnText(s, 3)
                    guard message.utf8.count <= 65_536,
                          let regex = try? NSRegularExpression(pattern: #"stream disconnected - retrying sampling request \([0-9]+/[0-9]+ in ([0-9]+(?:\.[0-9]+)?)s\)\.\.\..*sampling_error=(.+)$"#),
                          let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                          let waitRange = Range(match.range(at: 1), in: message),
                          let errorRange = Range(match.range(at: 2), in: message),
                          let seconds = Double(message[waitRange]), seconds.isFinite, seconds >= 0 else { return }
                    let error = String(message[errorRange])
                    let codeRange = error.range(of: #"(?<=last status: )[45][0-9]{2}\b"#, options: .regularExpression)
                    record = CodexRetryRecord(id: sqlite3_column_int64(s, 0), statusCode: codeRange.flatMap { Int(error[$0]) },
                                              waitSeconds: seconds, recordedAt: at, message: message)
                }
                return record
            }
        } ?? nil
    }
}
