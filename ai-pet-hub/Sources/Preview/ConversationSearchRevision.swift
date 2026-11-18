// 共享 SQLite 的 WAL 会因别的会话改变；复核本会话原始字段，避免再次解析 rollout 和渲染全部正文。
import Foundation
import SQLite3
import CryptoKit

extension AppDelegate {
    func searchSharedDatabases(_ source: ConversationSearchSource) -> Set<String> {
        if source.kind == "codex-db" { return Set(source.paths) }
        guard source.kind == "gpt" else { return [] }
        return Set(source.paths.filter { ["state_5.sqlite", "thread_history_1.sqlite"].contains(($0 as NSString).lastPathComponent) })
    }

    /// 只散列当前会话的原始列，不解 JSON；同 ordinal 的正文/结果变化同样必须失效。
    /// 不认识的旧 schema 或读取失败返回 nil，继续沿用文件指纹失效，不能误复用旧正文。
    func searchDatabaseRevision(_ source: ConversationSearchSource) -> String? {
        let paths = searchSharedDatabases(source).sorted()
        guard !paths.isEmpty else { return nil }
        var hash = SHA256()
        func mark(_ value: String) { hash.update(data: Data((value + "\0").utf8)) }
        for path in paths {
            mark(path)
            if !fm.fileExists(atPath: path) { mark("missing"); continue }
            let valid = withReadableSQLite(path) { db -> Bool in
                guard sqlite3_exec(db, "BEGIN;", nil, nil, nil) == SQLITE_OK else { return false }
                defer { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }
                var schemas: [String: String] = [:]
                queryRows(db, "SELECT name, sql FROM sqlite_master WHERE type = 'table';") { row in
                    schemas[columnText(row, 0)] = columnText(row, 1)
                }
                let state = (path as NSString).lastPathComponent == "state_5.sqlite"
                let tables = state ? ["threads"] : ["thread_items", "thread_turns", "thread_history_projection_state"]
                guard schemas[state ? "threads" : "thread_items"] != nil else { return false }
                for table in tables {
                    mark(table); mark(schemas[table] ?? "absent")
                    guard schemas[table] != nil else { continue }
                    let identity = state ? "id" : "thread_id"
                    let order = ["thread_items", "thread_turns"].contains(table) ? "rollout_ordinal" : identity
                    var statement: OpaquePointer?
                    guard sqlite3_prepare_v2(db, "SELECT * FROM \(table) WHERE \(identity) = ? ORDER BY \(order);", -1, &statement, nil) == SQLITE_OK,
                          let row = statement else { return false }
                    defer { sqlite3_finalize(row) }
                    sqlite3_bind_text(row, 1, source.cid, -1, SQLITE_TRANSIENT)
                    var status = sqlite3_step(row)
                    while status == SQLITE_ROW {
                        mark("row")
                        for index in 0..<sqlite3_column_count(row) {
                            let type = sqlite3_column_type(row, index)
                            let bytes = sqlite3_column_blob(row, index), count = Int(sqlite3_column_bytes(row, index))
                            mark("\(type):\(count)")
                            if let bytes = bytes, count > 0 { hash.update(bufferPointer: UnsafeRawBufferPointer(start: bytes, count: count)) }
                        }
                        status = sqlite3_step(row)
                    }
                    guard status == SQLITE_DONE else { return false }
                }
                return true
            }
            guard valid == true else { return nil }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
