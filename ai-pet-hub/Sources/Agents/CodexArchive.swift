// 有索引的会话交给 Codex 归档，让桌面端、CLI 和磁盘上的 rollout 始终使用同一路径。
import Cocoa
import SQLite3

extension AppDelegate {
    func archiveCodex(_ ids: [String]) -> Set<String> {
        let requested = Set(ids.filter(isSafeId))
        guard !requested.isEmpty else { return [] }
        let state = "\(codexHome)/state_5.sqlite"
        var indexed = Set<String>()
        if fm.fileExists(atPath: state) {
            // 读不到（包括 WAL 忙或表结构变了）不能当成「没收录」而擅自挪文件。
            let read = withSQLite(state, readOnly: true) { db -> Bool in
                for cid in requested {
                    guard let present = codexIndexed(cid, in: db) else { return false }
                    if present { indexed.insert(cid) }
                }
                return true
            }
            guard read == true else { return [] }
        }

        let legacy = requested.subtracting(indexed)
        guard !legacy.isEmpty else { return archiveIndexedCodex(Array(indexed)) }
        let files = activeRollouts().compactMap { path, _ -> (String, URL)? in
            let file = URL(fileURLWithPath: path)
            // ID 可能含连字符，不能按最后一个连字符拆名字。
            let name = path.hasSuffix(".zst") ? file.deletingPathExtension().lastPathComponent : file.lastPathComponent
            return legacy.first { name.hasSuffix("-\($0).jsonl") }.map { ($0, file) }
        }
        var moved = Set<String>()
        if !files.isEmpty {
            let archive = URL(fileURLWithPath: codexHome).appendingPathComponent("archived_sessions")
            func moveLegacy(_ db: OpaquePointer?) {
                for (cid, file) in files {
                    if let db = db {
                        guard let present = codexIndexed(cid, in: db) else { continue }
                        if present { indexed.insert(cid); continue }
                    }
                    try? fm.createDirectory(at: archive, withIntermediateDirectories: true)
                    if (try? fm.moveItem(at: file, to: archive.appendingPathComponent(file.lastPathComponent))) != nil {
                        codexRolloutCache.removeValue(forKey: file.path)
                        moved.insert(cid)
                    }
                }
            }
            hooks.codexLegacyArchiveLocated?()
            if fm.fileExists(atPath: state) {
                // 扫目录期间 Codex 可能已补上索引。只在最后复核和挪文件时短暂挡住其他写入。
                _ = withSQLite(state, readOnly: false) { db in
                    guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
                    defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
                    moveLegacy(db)
                }
            } else { moveLegacy(nil) }
        }
        return moved.union(archiveIndexedCodex(Array(indexed)))
    }

    private func codexIndexed(_ cid: String, in db: OpaquePointer) -> Bool? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM threads WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, cid, -1, SQLITE_TRANSIENT)
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: return nil
        }
    }

    /// 一次批量删除共用一个进程。逐条等 CLI 确认，拒绝、启动失败或提前退出都只上报已成功的部分。
    private func archiveIndexedCodex(_ ids: [String]) -> Set<String> {
        guard !ids.isEmpty, let executable = codexExecutable() else { return [] }
        let input = LiveInput(), cli = CLIProcess(input: input)
        var done = Set<String>(), index = 0
        cli.warmFilter = { line in
            guard let obj = self.jsonObject(line), obj["method"] == nil, let id = obj["id"] as? Int else { return true }
            if id == 1 {
                guard obj["result"] != nil else { input.close(); return true }
                input.send(["method": "initialized"])
            } else {
                guard index < ids.count, id == index + 2 else { return true }
                if obj["result"] != nil && obj["error"] == nil { done.insert(ids[index]) }
                index += 1
            }
            if index == ids.count { input.close() }
            else { input.send(["id": index + 2, "method": "thread/archive", "params": ["threadId": ids[index]]]) }
            return true
        }
        guard (try? cli.start(executable: executable, arguments: ["app-server"], cwd: home,
                              environment: cliEnvironment(["CODEX_HOME": codexHome]))) != nil else { return [] }
        input.send(codexInitialize)
        _ = cli.waitForExit(until: .now() + .seconds(10 + ids.count)) {
            terminateTree(cli.proc.processIdentifier)
        }
        input.close()
        return done
    }
}
