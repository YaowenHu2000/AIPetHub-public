// 各处都用的小工具：校验、路径、JSON、文字清理、废纸篓、SQLite。
import Cocoa
import SQLite3

/// SQLite 绑定文字时用：让它自己拷一份。
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension AppDelegate {
    func isSafeId(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 200 && !s.hasPrefix(".")
            && s.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return !path.isEmpty && fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func validWorkspace(_ path: String) -> String? { isDirectory(path) ? path : nil }

    /// 先看这几个固定的安装位置；都没有，再按第一个的文件名去登录 shell 的 PATH 里找（AgentSetup.swift 的 lookupOnPath）。
    func findExecutable(_ candidates: [String]) -> String? {
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }
        return candidates.first.flatMap { lookupOnPath(($0 as NSString).lastPathComponent) }
    }

    func modificationDate(_ path: String) -> Date? {
        (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    func jsonObject<S: StringProtocol>(_ line: S) -> [String: Any]? {
        guard let data = String(line).data(using: .utf8) else { return nil }
        return jsonObject(data)
    }

    func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 从 CLI 输出里找最后一个满足条件的 JSON 对象（容忍行首的转圈字符等杂质）。
    func lastJSONObject(in output: String, where match: ([String: Any]) -> Bool) -> [String: Any]? {
        for line in output.split(separator: "\n").reversed() {
            guard let brace = line.firstIndex(of: "{") else { continue }
            if let obj = jsonObject(line[brace...]), match(obj) { return obj }
        }
        if let brace = output.firstIndex(of: "{"), let obj = jsonObject(output[brace...]), match(obj) {
            return obj
        }
        return nil
    }

    func textBlocks(_ content: Any?) -> String {
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            if let type = block["type"] as? String, type != "text", type != "Text",
               type != "input_text", type != "output_text" { return nil }
            return block["text"] as? String
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stripTagBlocks(_ text: String, tags: [String]) -> String {
        var s = text
        for tag in tags {
            s = s.replacingOccurrences(of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "", options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 旧版桌宠曾在提示词前拼接人设，展示历史时去掉。
    func stripPersonaPrefix(_ raw: String) -> String {
        var s = raw
        if let note = s.range(of: codexNoteMarker) { s = String(s[..<note.lowerBound]) }   // 应用自动附的说明（CodexLive.swift）
        if let start = s.range(of: "<USER_REQUEST>"), let end = s.range(of: "</USER_REQUEST>"), start.upperBound <= end.lowerBound {
            s = String(s[start.upperBound..<end.lowerBound])
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["【主人对你说】", "【主人指令】"] {
            if let r = s.range(of: marker) {
                s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }

    func titleFrom(_ text: String, fallbackId: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return oneLine.isEmpty ? "会话 \(fallbackId.prefix(6))" : String(oneLine.prefix(40))
    }

    func trash(_ path: String) -> Bool {
        guard fm.fileExists(atPath: path) else { return false }
        return (try? fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)) != nil
    }

    func withSQLite<T>(_ path: String, readOnly: Bool, _ body: (OpaquePointer) -> T) -> T? {
        guard fm.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle = db else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 3000)
        return body(handle)
    }

    /// 只读打开；WAL 库缺 -shm 等原因读不了时，退回 immutable 方式（不加锁的快照读）。
    func withReadableSQLite<T>(_ path: String, _ body: (OpaquePointer) -> T) -> T? {
        guard fm.fileExists(atPath: path) else { return nil }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        for uri in ["file:\(encoded)?mode=ro", "file:\(encoded)?immutable=1"] {
            var db: OpaquePointer?
            guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle = db else {
                if db != nil { sqlite3_close(db) }
                continue
            }
            sqlite3_busy_timeout(handle, 3000)
            if sqlite3_exec(handle, "SELECT count(*) FROM sqlite_master;", nil, nil, nil) == SQLITE_OK {
                defer { sqlite3_close(handle) }
                return body(handle)
            }
            sqlite3_close(handle)
        }
        return nil
    }

    func queryRows(_ db: OpaquePointer, _ sql: String, _ binds: [String] = [], _ row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return }
        defer { sqlite3_finalize(s) }
        for (i, value) in binds.enumerated() {
            sqlite3_bind_text(s, Int32(i + 1), value, -1, SQLITE_TRANSIENT)
        }
        while sqlite3_step(s) == SQLITE_ROW { row(s) }
    }

    func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
    }

    func trimmedPath(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
