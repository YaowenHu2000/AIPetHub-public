// 反重力桌面版只认自己的索引列会话，不会按文件重建（用户 2026-11-18 实测：重启后已删会话的条目还在，点开报「数据找不到」）。
// 所以桌面版关着时从 App 删除，除了把文件挪进废纸篓，还要把这个 ID 从它的三份索引里删掉；改之前整份备份，出错就不动。
// 桌面版开着时不碰：它的内存里有一份，会把改动写回去（调用方先确认它没在运行）。
import Foundation
import SQLite3

/// 两份 protobuf 索引的顶层都是「会话 ID → 摘要」的 map：每条是长度前缀的子消息，子消息的字段 1 是会话 ID。
/// 只删 key 等于 id 的条目，其余字节原样保留；遇到不认识的结构返回 nil，宁可不改。
func removingProtoMapEntries(_ data: Data, key id: String) -> Data? {
    let bytes = [UInt8](data), target = Array(id.utf8)
    func varint(_ i: inout Int) -> Int? {
        var value = 0, shift = 0
        while i < bytes.count {
            let b = bytes[i]; i += 1
            value |= Int(b & 0x7f) << shift
            if b < 0x80 { return value }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
    var out: [UInt8] = [], i = 0
    out.reserveCapacity(bytes.count)
    while i < bytes.count {
        let start = i
        guard let tag = varint(&i), tag & 7 == 2, let length = varint(&i), length >= 0, i + length <= bytes.count else { return nil }
        let body = i, end = i + length
        i = end
        // 子消息开头应是 key（字段 1，长度前缀的字符串）
        var j = body
        if j < end, bytes[j] == 0x0a {
            j += 1
            if let keyLength = varint(&j), j + keyLength <= end, Array(bytes[j..<j + keyLength]) == target { continue }
        }
        out += bytes[start..<end]
    }
    return Data(out)
}

extension AppDelegate {
    var geminiIndexBackupRoot: URL { TestHooks.defaultGeminiIndexBackupRoot }

    /// 从桌面版目录 root 的三份索引里删掉会话 id：先整份备份，再逐份原子写回。全部成功才返回 true。
    func removeFromDesktopIndex(_ id: String, root: String) -> Bool {
        let protos = ["agyhub_summaries_proto.pb", "jetbox_summaries_proto.pb"].map { root + "/" + $0 }.filter { fm.fileExists(atPath: $0) }
        let summaries = root + "/conversation_summaries.db"
        // 备份：同一时刻的三份索引放在一个目录里，最多留最近 20 次
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + id.prefix(8)
        let backup = geminiIndexBackupRoot.appendingPathComponent(stamp, isDirectory: true)
        guard (try? fm.createDirectory(at: backup, withIntermediateDirectories: true)) != nil else { return false }
        for path in protos + [summaries, summaries + "-wal", summaries + "-shm"] where fm.fileExists(atPath: path) {
            guard (try? fm.copyItem(atPath: path, toPath: backup.appendingPathComponent((path as NSString).lastPathComponent).path)) != nil else { return false }
        }
        if let old = try? fm.contentsOfDirectory(at: geminiIndexBackupRoot, includingPropertiesForKeys: nil) {
            old.sorted { $0.lastPathComponent > $1.lastPathComponent }.dropFirst(20).forEach { try? fm.removeItem(at: $0) }
        }
        // 先在内存里把两份 protobuf 都改好，任何一份结构不认识就整件不做
        var edits: [(String, Data)] = []
        for path in protos {
            guard let data = fm.contents(atPath: path), let edited = removingProtoMapEntries(data, key: id) else { return false }
            if edited != data { edits.append((path, edited)) }
        }
        var ok = true
        if fm.fileExists(atPath: summaries) {
            ok = withSQLite(summaries, readOnly: false) { db -> Bool in
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "DELETE FROM conversation_summaries WHERE conversation_id = ?;", -1, &stmt, nil) == SQLITE_OK,
                      let s = stmt else { return false }
                defer { sqlite3_finalize(s) }
                sqlite3_bind_text(s, 1, id, -1, SQLITE_TRANSIENT)
                return sqlite3_step(s) == SQLITE_DONE
            } ?? false
        }
        guard ok else { return false }
        for (path, data) in edits {
            guard (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil else { return false }
        }
        return true
    }
}
