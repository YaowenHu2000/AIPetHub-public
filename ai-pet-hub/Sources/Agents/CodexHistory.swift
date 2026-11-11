// Codex 的历史会话：读它的 SQLite 和 rollout 记录；删除是归档。
import Cocoa
import SQLite3

extension AppDelegate {
    var codexHome: String { "\(home)/.codex" }

    func rolloutMessages(_ content: String) -> (messages: [[String: String]], meta: [String: Any]) {
        var items: [[String: String]] = []
        var legacy: [[String: String]] = []
        var meta: [String: Any] = [:]
        for line in content.split(separator: "\n") {
            guard let obj = jsonObject(line), let type = obj["type"] as? String,
                  let payload = obj["payload"] as? [String: Any] else { continue }
            if type == "session_meta" {
                if meta.isEmpty { meta = payload }
                continue
            }
            guard type == "event_msg", let ptype = payload["type"] as? String else { continue }
            if ptype == "item_completed", let item = payload["item"] as? [String: Any],
               let itemType = item["type"] as? String, itemType == "UserMessage" || itemType == "AgentMessage" {
                let raw = textBlocks(item["content"])
                let text = itemType == "UserMessage" ? stripPersonaPrefix(raw) : raw
                if !text.isEmpty { items.append(["role": itemType == "UserMessage" ? "user" : "bot", "text": text]) }
            } else if ptype == "user_message" || ptype == "agent_message", let raw = payload["message"] as? String {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { legacy.append(["role": ptype == "user_message" ? "user" : "bot", "text": text]) }
            }
        }
        return (items.isEmpty ? legacy : items, meta)
    }

    /// 读取 rollout 文件（旧文件会被 Codex 压成 .jsonl.zst，用 zstd 解压）。
    func readRollout(_ path: String) -> String? {
        if path.hasSuffix(".jsonl") { return try? String(contentsOfFile: path, encoding: .utf8) }
        guard path.hasSuffix(".zst"),
              let zstd = findExecutable(["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: zstd)
        proc.arguments = ["-dc", path]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return proc.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// ~/.codex/sessions 下还没被压缩的 rollout（最近的会话，codex exec 新建的也只在这里）。
    func plainRollouts() -> [(path: String, mtime: Date)] {
        let root = "\(codexHome)/sessions"
        var result: [(String, Date)] = []
        guard let walker = fm.enumerator(atPath: root) else { return [] }
        while let rel = walker.nextObject() as? String {
            guard rel.hasSuffix(".jsonl"), (rel as NSString).lastPathComponent.hasPrefix("rollout-") else { continue }
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

    func listCodex() {
        codexQueue.async { [self] in
            var items: [[String: Any]] = []
            var seen = Set<String>()
            _ = withReadableSQLite("\(codexHome)/state_5.sqlite") { db in
                // source 以 { 开头的是子代理线程，不单独列出。
                let sql = """
                    SELECT id, title, first_user_message, cwd, updated_at FROM threads
                    WHERE archived = 0 AND source NOT LIKE '{%' ORDER BY updated_at DESC LIMIT 320;
                    """
                queryRows(db, sql) { s in
                    let cid = columnText(s, 0)
                    guard !cid.isEmpty else { return }
                    let title = columnText(s, 1).trimmingCharacters(in: .whitespacesAndNewlines)
                    let firstMsg = stripPersonaPrefix(columnText(s, 2))
                    let updated = Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 4)))
                    items.append(["id": cid, "title": titleFrom(title.isEmpty ? firstMsg : title, fallbackId: cid),
                                  "time": timeLabel(updated), "timestamp": updated.timeIntervalSince1970,
                                  "cwd": columnText(s, 3)])
                    seen.insert(cid)
                }
            }

            for (path, mtime) in plainRollouts() {
                let ts = mtime.timeIntervalSince1970
                let item: [String: Any]?
                if let cached = codexRolloutCache[path], abs(cached.mtime - ts) < 0.001 {
                    item = cached.item
                } else {
                    item = rolloutSummary(path: path, mtime: mtime)
                    codexRolloutCache[path] = (ts, item)
                }
                if let item = item, let cid = item["id"] as? String, !seen.contains(cid) {
                    seen.insert(cid)
                    items.append(item)
                }
            }

            items.sort { ($0["timestamp"] as? Double ?? 0) > ($1["timestamp"] as? Double ?? 0) }
            sendToJS("onConversationsListed", ["agent": "gpt", "items": Array(items.prefix(historyListLimit))])
        }
    }

    /// 目录是 target 的全部未归档会话：数据库里的线程 + 只存在于 rollout 的会话。
    func codexIds(inWorkspace target: String) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        _ = withReadableSQLite("\(codexHome)/state_5.sqlite") { db in
            queryRows(db, "SELECT id, cwd FROM threads WHERE archived = 0 AND source NOT LIKE '{%';") { s in
                let cid = columnText(s, 0)
                guard !cid.isEmpty else { return }
                seen.insert(cid)
                if trimmedPath(columnText(s, 1)) == target { ids.append(cid) }
            }
        }
        for (path, mtime) in plainRollouts() {
            let ts = mtime.timeIntervalSince1970
            let item: [String: Any]?
            if let cached = codexRolloutCache[path], abs(cached.mtime - ts) < 0.001 {
                item = cached.item
            } else {
                item = rolloutSummary(path: path, mtime: mtime)
                codexRolloutCache[path] = (ts, item)
            }
            guard let item = item, let cid = item["id"] as? String, !seen.contains(cid) else { continue }
            seen.insert(cid)
            if trimmedPath(item["cwd"] as? String ?? "") == target { ids.append(cid) }
        }
        return ids
    }

    func rolloutSummary(path: String, mtime: Date) -> [String: Any]? {
        guard let content = readRollout(path) else { return nil }
        let (messages, meta) = rolloutMessages(content)
        guard let cid = (meta["id"] as? String) ?? (meta["session_id"] as? String), isSafeId(cid),
              meta["source"] is String,  // 子代理的 source 是对象
              let firstUser = messages.first(where: { $0["role"] == "user" })?["text"] else { return nil }
        return ["id": cid, "title": titleFrom(firstUser, fallbackId: cid), "time": timeLabel(mtime),
                "timestamp": mtime.timeIntervalSince1970, "count": messages.count,
                "cwd": meta["cwd"] as? String ?? ""]
    }

    func loadCodex(cid: String) {
        codexQueue.async { [self] in
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

            var messages = codexDbTurns(cid)
            var rolloutPath: String?
            if messages.isEmpty {
                rolloutPath = findRollout(cid: cid, hint: rolloutHint)
                if let path = rolloutPath, let content = readRollout(path) {
                    let parsed = codexRolloutTurns(content)
                    messages = parsed.messages
                    if cwd.isEmpty { cwd = parsed.cwd }
                }
            }
            sendToJS("onConversationLoaded", recentHistory(messages, into: [
                "agent": "gpt", "conversationId": cid, "cwd": cwd,
                "missing": messages.isEmpty && !inStateDb && rolloutPath == nil
            ]))
        }
    }

    /// Codex 历史条目（数据库里是 camelCase，rollout 里是 PascalCase）→ 工作步骤。
    func codexHistoryItem(type: String, obj: [String: Any], turn: TurnBuilder, finalAnswer: inout String) {
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
            let failed = obj["status"] as? String == "failed" || exitCode != 0
            var step = makeStep("command", "运行命令", detail: command, status: failed ? "error" : "ok")
            let output = trimmed((obj["aggregatedOutput"] as? String) ?? (obj["aggregated_output"] as? String))
            if !output.isEmpty { step["output"] = clip(output, maxOutput) }
            turn.add(step)
        case "fileChange", "FileChange":
            for change in codexChanges(obj["changes"]) {
                turn.add(fileStep(kind: change.kind, path: change.path))
                turn.addFile(change.path, kind: change.kind, diff: change.diff)
            }
        case "mcpToolCall", "McpToolCall":
            let failed = obj["status"] as? String == "failed"
            turn.add(makeStep("tool", "调用 \(obj["server"] as? String ?? "") · \(obj["tool"] as? String ?? "")", status: failed ? "error" : "ok"))
        case "dynamicToolCall", "DynamicToolCall":
            turn.add(makeStep("tool", "调用 \(obj["tool"] as? String ?? "工具")"))
        case "webSearch", "WebSearch":
            turn.add(makeStep("web", "联网搜索 \(obj["query"] as? String ?? "")"))
        case "imageGeneration", "ImageGeneration":
            turn.add(makeStep("tool", "生成图片"))
        case "imageView", "ImageView":
            turn.add(makeStep("read", "查看图片", path: obj["path"] as? String))
        case "collabAgentToolCall", "CollabAgentToolCall":
            turn.add(makeStep("agent", "协作子代理"))
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

    func codexDbTurns(_ cid: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var turn: TurnBuilder?
        var finalAnswer = ""
        var start: Double?
        var end: Double?
        func flush() {
            guard let t = turn else { return }
            var bot = t.finish(finalText: finalAnswer)
            if let s = start, let e = end, e > s { bot["duration"] = (e - s) / 1000 }
            if !trimmed(bot["text"] as? String).isEmpty || !((bot["steps"] as? [Any]) ?? []).isEmpty {
                bot["role"] = "bot"
                out.append(bot)
            }
            turn = nil
            finalAnswer = ""
        }
        _ = withReadableSQLite("\(codexHome)/thread_history_1.sqlite") { db in
            let sql = """
                SELECT item_type, item_json, created_at_ms, COALESCE(completed_at_ms, created_at_ms)
                FROM thread_items WHERE thread_id = ? ORDER BY rollout_ordinal ASC;
                """
            queryRows(db, sql, [cid]) { s in
                let type = columnText(s, 0)
                guard let obj = jsonObject(columnText(s, 1)) else { return }
                let created = Double(sqlite3_column_int64(s, 2))
                let completed = Double(sqlite3_column_int64(s, 3))
                if type == "userMessage" {
                    let images = codexImageSources(obj["content"])
                    let text = stripCodexAttachmentHeader(stripPersonaPrefix(textBlocks(obj["content"])), images: images)
                    guard !text.isEmpty || !images.isEmpty else { return }
                    flush()
                    out.append(images.isEmpty ? ["role": "user", "text": text] : ["role": "user", "text": text, "imageSources": images])
                    turn = TurnBuilder()
                    start = created
                    end = created
                    return
                }
                if turn == nil { turn = TurnBuilder(); start = created }
                end = max(end ?? completed, completed)
                if let t = turn { codexHistoryItem(type: type, obj: obj, turn: t, finalAnswer: &finalAnswer) }
            }
        }
        flush()
        return out
    }

    func codexRolloutTurns(_ content: String) -> (messages: [[String: Any]], cwd: String) {
        var out: [[String: Any]] = []
        var legacy: [[String: String]] = []
        var turn: TurnBuilder?
        var finalAnswer = ""
        var cwd = ""
        var start: Date?
        var end: Date?
        var sawItems = false
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func flush() {
            guard let t = turn else { return }
            var bot = t.finish(finalText: finalAnswer)
            if let s = start, let e = end, e > s { bot["duration"] = e.timeIntervalSince(s) }
            if !trimmed(bot["text"] as? String).isEmpty || !((bot["steps"] as? [Any]) ?? []).isEmpty {
                bot["role"] = "bot"
                out.append(bot)
            }
            turn = nil
            finalAnswer = ""
        }
        for line in content.split(separator: "\n") {
            guard let obj = jsonObject(line), let type = obj["type"] as? String,
                  let payload = obj["payload"] as? [String: Any] else { continue }
            let ts = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) }
            if type == "session_meta" {
                if cwd.isEmpty { cwd = payload["cwd"] as? String ?? "" }
                continue
            }
            guard type == "event_msg", let ptype = payload["type"] as? String else { continue }
            if ptype == "item_completed", let item = payload["item"] as? [String: Any], let itemType = item["type"] as? String {
                sawItems = true
                if itemType == "UserMessage" {
                    let images = codexImageSources(item["content"])
                    let text = stripCodexAttachmentHeader(stripPersonaPrefix(textBlocks(item["content"])), images: images)
                    guard !text.isEmpty || !images.isEmpty else { continue }
                    flush()
                    out.append(images.isEmpty ? ["role": "user", "text": text] : ["role": "user", "text": text, "imageSources": images])
                    turn = TurnBuilder()
                    start = ts
                    end = ts
                } else {
                    if turn == nil { turn = TurnBuilder(); start = ts }
                    if let ts = ts { end = ts }
                    if let t = turn { codexHistoryItem(type: itemType, obj: item, turn: t, finalAnswer: &finalAnswer) }
                }
            } else if ptype == "user_message" || ptype == "agent_message", let message = payload["message"] as? String {
                legacy.append(["role": ptype == "user_message" ? "user" : "bot", "text": trimmed(message)])
            }
        }
        flush()
        return (sawItems ? out : textTurns(legacy), cwd)
    }

    /// 「删除」= 归档：数据库里的线程标记 archived，仅存在于 rollout 的会话移进 archived_sessions，可在 Codex 中恢复。
    func archiveCodex(cid: String) -> Bool {
        var changed = false
        _ = withSQLite("\(codexHome)/state_5.sqlite", readOnly: false) { db in
            var stmt: OpaquePointer?
            let sql = "UPDATE threads SET archived = 1, archived_at = ? WHERE id = ? AND archived = 0;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return }
            defer { sqlite3_finalize(s) }
            sqlite3_bind_int64(s, 1, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_text(s, 2, cid, -1, SQLITE_TRANSIENT)
            if sqlite3_step(s) == SQLITE_DONE && sqlite3_changes(db) > 0 { changed = true }
        }
        for (path, _) in plainRollouts() where path.hasSuffix("-\(cid).jsonl") {
            let archiveDir = "\(codexHome)/archived_sessions"
            try? fm.createDirectory(atPath: archiveDir, withIntermediateDirectories: true)
            let dest = "\(archiveDir)/\((path as NSString).lastPathComponent)"
            if (try? fm.moveItem(atPath: path, toPath: dest)) != nil {
                changed = true
                codexRolloutCache.removeValue(forKey: path)
            }
        }
        return changed
    }
}
