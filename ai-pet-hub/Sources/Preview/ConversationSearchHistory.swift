// 搜索要枚举全部可打开的来源，包括压缩 rollout、数据库独有会话、旧 transcript 和 DeepSeek 服务。
import Cocoa
import SQLite3

struct ConversationSearchSource {
    let cid: String
    let paths: [String]
    let kind: String
    var revision = ""
    var item: [String: Any]
}

extension AppDelegate {
    func searchStamp(_ source: ConversationSearchSource, excluding: Set<String> = []) -> String {
        ([source.revision] + source.paths.filter { !excluding.contains($0) }.flatMap { path in
            [path, path + "-wal"].map { file in
                guard let attr = try? fm.attributesOfItem(atPath: file) else { return file + ":missing" }
                return "\(file):\((attr[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(attr[.size] ?? 0)"
            }
        }).joined(separator: "|")
    }

    func searchSources(agent: String, files: [(cid: String, path: String)]?) -> (sources: [ConversationSearchSource], error: String?) {
        func source(_ cid: String, _ paths: [String], _ kind: String, title: String = "", cwd: String = "", timestamp: Double? = nil) -> ConversationSearchSource {
            let date = timestamp ?? paths.compactMap { modificationDate($0)?.timeIntervalSince1970 }.max() ?? 0
            return ConversationSearchSource(cid: cid, paths: paths, kind: kind,
                item: ["id": cid, "title": title, "cwd": cwd, "timestamp": date, "time": timeLabel(Date(timeIntervalSince1970: date))])
        }
        if agent == "claude" {
            // 搜索跑在后台并发队列；副本选择和打开历史一样，缓存只能在 Claude 自己的队列上读。
            let selected = claudeQueue.sync { () -> [ConversationSearchSource] in
                let candidates = files.map { rows in
                    rows.map { (cid: $0.cid, path: $0.path, mtime: modificationDate($0.path) ?? .distantPast) }.sorted { $0.mtime > $1.mtime }
                } ?? claudeSessionFiles()
                var seen = Set<String>()
                return candidates.compactMap { entry in
                    guard seen.insert(entry.cid).inserted else { return nil }
                    let path = findClaudeSession(cid: entry.cid, files: candidates) ?? entry.path
                    return source(entry.cid, [path], "claude")
                }
            }
            return (selected, nil)
        }
        if let files = files { return (files.map { source($0.cid, [$0.path], agent == "gpt" && $0.path.hasSuffix(".sqlite") ? "codex-db" : agent) }, nil) }
        switch agent {
        case "gpt":
            var rows: [ConversationSearchSource] = [], seen = Set<String>(), excluded = Set<String>()
            var errors: [String] = []
            let state = "\(codexHome)/state_5.sqlite", history = "\(codexHome)/thread_history_1.sqlite"
            let stateReadable: Void? = withReadableSQLite(state) { db in
                queryRows(db, "SELECT id, title, cwd, updated_at, rollout_path, archived, source FROM threads;") { row in
                    let cid = columnText(row, 0)
                    guard isSafeId(cid) else { return }
                    if sqlite3_column_int(row, 5) != 0 || columnText(row, 6).hasPrefix("{") { excluded.insert(cid); return }
                    let rollout = findRollout(cid: cid, hint: columnText(row, 4))
                    rows.append(source(cid, [state, history] + (rollout.map { [$0] } ?? []), "gpt",
                        title: columnText(row, 1), cwd: columnText(row, 2), timestamp: Double(sqlite3_column_int64(row, 3))))
                    seen.insert(cid)
                }
            }
            if stateReadable == nil, fm.fileExists(atPath: state) { errors.append("Codex 会话列表数据库无法读取") }
            let historyReadable: Void? = withReadableSQLite(history) { db in
                queryRows(db, "SELECT DISTINCT thread_id FROM thread_items;") { row in
                    let cid = columnText(row, 0)
                    guard isSafeId(cid), !seen.contains(cid), !excluded.contains(cid) else { return }
                    let rollout = findRollout(cid: cid, hint: "")
                    rows.append(source(cid, [history] + (rollout.map { [$0] } ?? []), "gpt")); seen.insert(cid)
                }
            }
            if historyReadable == nil, fm.fileExists(atPath: history) { errors.append("Codex 正文数据库无法读取") }
            let dir = "\(codexHome)/sessions"
            if let walker = fm.enumerator(atPath: dir) {
                while let rel = walker.nextObject() as? String {
                    guard rel.hasSuffix(".jsonl") || rel.hasSuffix(".jsonl.zst") else { continue }
                    let name = ((rel as NSString).lastPathComponent).replacingOccurrences(of: ".jsonl.zst", with: "").replacingOccurrences(of: ".jsonl", with: "")
                    guard name.hasPrefix("rollout-"), name.count >= 36 else { continue }
                    let cid = String(name.suffix(36))
                    guard isSafeId(cid), !seen.contains(cid), !excluded.contains(cid) else { continue }
                    rows.append(source(cid, ["\(dir)/\(rel)"], "gpt")); seen.insert(cid)
                }
            }
            return (rows.sorted { ($0.item["timestamp"] as? Double ?? 0) > ($1.item["timestamp"] as? Double ?? 0) }, errors.isEmpty ? nil : errors.joined(separator: "；"))
        case "deepseek":
            if let error = dshReady() { return ([], error) }
            let result = dshServer.call("session.list")
            guard let rows = (result.value as? [String: Any])?["items"] as? [[String: Any]] else { return ([], result.error ?? "DeepSeek 会话列表读取失败") }
            let groups = (try? fm.contentsOfDirectory(atPath: "\(home)/.dsh/sessions")) ?? []
            return (rows.compactMap { row in
                guard let cid = row["sessionId"] as? String, row["blank"] as? Bool != true else { return nil }
                let paths = groups.map { "\(home)/.dsh/sessions/\($0)/\(cid)/session.jsonl.zstd" }.filter { fm.fileExists(atPath: $0) }
                let title = (((row["projections"] as? [String: Any])?["values"] as? [String: Any])?["title"] as? String) ?? ""
                var entry = source(cid, paths, "deepseek", title: title, cwd: row["cwd"] as? String ?? "", timestamp: ((row["updatedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000)
                entry.revision = "\(row["updatedAt"] ?? "")"
                return entry
            }, nil)
        default:
            var keys = Set<String>()
            for store in geminiStores {
                let dbs = (try? fm.contentsOfDirectory(atPath: store.root + "/conversations")) ?? []
                let ids = dbs.filter { $0.hasSuffix(".db") }.map { String($0.dropLast(3)) }
                keys.formUnion(ids.filter(isSafeId).map { geminiKey($0, in: store) })
                for id in (try? fm.contentsOfDirectory(atPath: store.brain)) ?? [] where isSafeId(id) {
                    if fm.fileExists(atPath: geminiTranscriptPath(store.key(id))) { keys.insert(geminiKey(id, in: store)) }
                }
            }
            return (keys.map { source($0, [geminiConversationDb($0), geminiStore($0).summaries, geminiTranscriptPath($0)], "gemini") }, nil)
        }
    }

    func searchHistory(_ source: ConversationSearchSource, agent: String, explicit: Bool)
        -> (messages: [[String: Any]], cwd: String, error: String?) {
        let path = source.paths.first ?? ""
        switch source.kind {
        case "claude":
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return ([], "", "部分会话没搜：Claude 记录无法读取") }
            let (messages, cwd) = claudeTurns(data)
            return (messages, cwd, nil)
        case "deepseek":
            let history = readDeepSeekHistory(cid: source.cid, pageLimit: nil)
            return (dshTurns(history.rows), source.item["cwd"] as? String ?? "", history.error.map { "部分会话没搜：" + $0 })
        case "codex-db":
            guard searchDatabaseReadable(path, sql: "SELECT item_json FROM thread_items LIMIT 0") else { return ([], "", "部分会话没搜：Codex 正文数据库无法读取") }
            return (codexDbTurns(source.cid, databasePath: path), "", nil)
        case "gpt":
            if explicit {
                guard let content = readRollout(path) else { return ([], "", "部分会话没搜：Codex 记录无法读取或解压") }
                let parsed = codexRolloutTurns(content)
                return (parsed.messages, parsed.cwd, nil)
            }
            let history = readCodexConversation(cid: source.cid)
            return (history["messages"] as? [[String: Any]] ?? [], history["cwd"] as? String ?? "",
                (history["readError"] as? String).flatMap { $0.isEmpty ? nil : "部分会话没搜：" + $0 }
                    ?? (history["missing"] as? Bool == true ? "部分会话没搜：Codex 记录无法读取" : nil))
        default:
            let history = readGeminiConversation(cid: source.cid, databasePath: explicit ? path : nil)
            let messages = history["messages"] as? [[String: Any]] ?? []
            if messages.isEmpty, fm.fileExists(atPath: path), !searchDatabaseReadable(path, sql: "SELECT step_type, step_payload FROM steps LIMIT 0") {
                return ([], "", "部分会话没搜：Gemini 正文数据库无法读取")
            }
            return (history["messages"] as? [[String: Any]] ?? [], history["cwd"] as? String ?? "",
                history["missing"] as? Bool == true ? "部分会话没搜：Gemini 记录无法读取" : nil)
        }
    }

    private func searchDatabaseReadable(_ path: String, sql: String) -> Bool {
        withReadableSQLite(path) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_DONE
        } ?? false
    }

    /// 粗筛只排除确定不可能命中的记录：转义、排版拆字与界面合成的步骤标题都留到解析后确认。
    func searchCandidate(_ source: ConversationSearchSource, query: String) -> (possible: Bool, error: String?) {
        // 数据库、压缩文件和服务端历史由现成读取器解码，不能在容器原始字节中断言正文不存在。
        if source.kind != "claude" || source.paths.count != 1 { return (true, nil) }
        // 大记录直接交给内存映射的历史解析，避免先把同一份几十 MB 的原文转换、扫描一遍。
        if let bytes = (try? fm.attributesOfItem(atPath: source.paths[0]))?[.size] as? NSNumber, bytes.intValue >= 8_000_000 { return (true, nil) }
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: source.paths[0])) else { return (false, "部分会话没搜：记录无法读取") }
        defer { try? file.close() }
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var matched = Set<Int>(), tail = Data()
        let overlap = max(256, words.map { $0.utf8.count * 12 + 32 }.max() ?? 256)
        let unicode = try! NSRegularExpression(pattern: #"(?:\\u[0-9a-fA-F]{4})+"#)
        do {
            while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
                let data = tail + chunk
                let original = String(decoding: data, as: UTF8.self)
                var raw = original
                // 智能体记录和补充附件能生成原文里没有的标题，Markdown/公式也会重排文字；粗筛不能据此排除。
                if raw.contains("\"assistant\"") || raw.contains("\"attachment\"") || raw.contains("\"tool_use\"") { return (true, nil) }
                for match in unicode.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).reversed() {
                    guard let range = Range(match.range, in: raw), let bytes = ("\"" + raw[range] + "\"").data(using: .utf8),
                          let decoded = try? JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed) as? String else { continue }
                    raw.replaceSubrange(range, with: decoded)
                }
                raw = raw.replacingOccurrences(of: "\\/", with: "/")
                for (index, word) in words.enumerated() where !matched.contains(index) {
                    let encoded = String(data: (try? JSONSerialization.data(withJSONObject: [word], options: .withoutEscapingSlashes)) ?? Data(), encoding: .utf8).map { String($0.dropFirst(2).dropLast(2)) } ?? word
                    if original.range(of: word, options: .caseInsensitive) != nil || original.range(of: encoded, options: .caseInsensitive) != nil
                        || raw.range(of: word, options: .caseInsensitive) != nil || raw.range(of: encoded, options: .caseInsensitive) != nil {
                        matched.insert(index)
                    } else if raw.contains("*") || raw.contains("[") || raw.contains("`") || raw.contains("_") || raw.contains("<br") {
                        // Markdown 可以把单词拆在几个节点中；允许子序列当候选，宁多读一份也不漏掉可见正文。
                        var at = raw.startIndex
                        let found = word.allSatisfy { character in
                            guard let range = raw.range(of: String(character), options: .caseInsensitive, range: at..<raw.endIndex) else { return false }
                            at = range.upperBound; return true
                        }
                        if found { matched.insert(index) }
                    }
                }
                if matched.count == words.count { return (true, nil) }
                tail = Data(data.suffix(overlap))
            }
        } catch { return (false, "部分会话没搜：记录读取中断") }
        return (false, nil)
    }
}
